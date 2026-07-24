defmodule Kubeybilly.Executor.RealTest do
  # async: false: the kill switch lives in a global :persistent_term key,
  # and the budgets server and incidents root are resolved through
  # application env, both shared with the application-started processes.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Mox

  alias Kubeybilly.Executor.Budgets
  alias Kubeybilly.Executor.Real
  alias Kubeybilly.Formulary.Action
  alias Kubeybilly.Incident.Record
  alias Kubeybilly.StandingOrders.Decision

  @kill_key {Kubeybilly, :killswitch}
  @limits %{actions_per_incident: 2, actions_per_hour: 10, max_pods_touched: 20}
  @merge_patch %{"spec" => %{"template" => %{"metadata" => %{"labels" => %{"app" => "web"}}}}}

  setup :verify_on_exit!

  setup do
    root =
      System.tmp_dir!()
      |> Path.join("kubeybilly-executor-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    previous_root = Application.get_env(:kubeybilly, :incidents_dir)
    Application.put_env(:kubeybilly, :incidents_dir, root)

    budgets =
      start_supervised!(
        {Budgets, name: nil, root: root},
        id: :"budgets_#{System.unique_integer([:positive])}"
      )

    previous_server = Application.get_env(:kubeybilly, :budgets_server)
    Application.put_env(:kubeybilly, :budgets_server, budgets)

    previous_kill = :persistent_term.get(@kill_key, false)
    :persistent_term.put(@kill_key, false)

    on_exit(fn ->
      restore_env(:incidents_dir, previous_root)
      restore_env(:budgets_server, previous_server)
      :persistent_term.put(@kill_key, previous_kill)
      File.rm_rf(root)
    end)

    %{root: root, budgets: budgets}
  end

  defp restore_env(key, nil), do: Application.delete_env(:kubeybilly, key)
  defp restore_env(key, value), do: Application.put_env(:kubeybilly, key, value)

  defp record(root, opts \\ []) do
    id = "incident-#{System.unique_integer([:positive])}"

    if Keyword.get(opts, :manifest, true) do
      File.mkdir_p!(Path.join(root, id))
      File.write!(Path.join([root, id, "manifest.json"]), ~s({"complete": true}))
    end

    Record.new(%{
      id: id,
      group_key: "gk-#{id}",
      namespace: "demo",
      workload: %{kind: "Deployment", name: "web", uid: "uid-#{id}"}
    })
  end

  defp decision(overrides \\ []) do
    struct!(
      %Decision{
        verdict: :permit_auto,
        rule_id: "tier-auto",
        chain: ["kill-switch", "tier-auto"],
        reason: "permitted",
        mode: :auto,
        budgets: @limits
      },
      overrides
    )
  end

  defp restart_pod_action do
    {:ok, action} = Action.new(:restart_pod, %{namespace: "demo", name: "web-abc"})
    action
  end

  defp restart_workload_action do
    {:ok, action} =
      Action.new(:restart_workload, %{namespace: "demo", kind: "Deployment", name: "web"})

    action
  end

  defp scale_action(opts \\ []) do
    {:ok, action} =
      Action.new(:scale, %{namespace: "demo", kind: "Deployment", name: "web", replicas: 5})

    if Keyword.get(opts, :inverse, true) do
      {:ok, inverse} =
        Action.new(:scale, %{namespace: "demo", kind: "Deployment", name: "web", replicas: 3})

      %{action | inverse: inverse}
    else
      action
    end
  end

  defp rollback_action do
    {:ok, action} =
      Action.new(:rollback_deployment, %{namespace: "demo", name: "web", to_revision: 3})

    {:ok, inverse} =
      Action.new(:rollback_deployment, %{namespace: "demo", name: "web", to_revision: 4})

    %{action | inverse: inverse, facts: %{current_revision: 4, patch: @merge_patch}}
  end

  defp cordon_action do
    {:ok, action} = Action.new(:cordon_node, %{name: "node-1"})
    {:ok, inverse} = Action.internal_new(:uncordon_node, %{name: "node-1"})
    %{action | inverse: inverse}
  end

  describe "boundary wiring" do
    test "the executor boundary resolves the real executor by default" do
      previous = Application.get_env(:kubeybilly, :executor)
      Application.delete_env(:kubeybilly, :executor)
      on_exit(fn -> Application.put_env(:kubeybilly, :executor, previous) end)

      assert Kubeybilly.Executor.impl() == Real
    end
  end

  describe "guard rails" do
    test "an engaged kill switch refuses before anything else", %{root: root, budgets: budgets} do
      :persistent_term.put(@kill_key, true)
      rec = record(root)

      assert {:error, :kill_switch_engaged} = Real.execute(scale_action(), decision(), rec)

      assert Budgets.actions_this_hour(budgets) == 0
      assert Budgets.actions_this_incident(budgets, rec.id) == 0
    end

    test "the kill switch beats even a dry run", %{root: root} do
      :persistent_term.put(@kill_key, true)
      rec = record(root)

      assert {:error, :kill_switch_engaged} =
               Real.execute(scale_action(), decision(mode: :dry_run), rec)
    end

    test "dry run logs the action and inverse and touches nothing", %{
      root: root,
      budgets: budgets
    } do
      rec = record(root)
      action = scale_action()

      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: :warning) end)

      log =
        capture_log(fn ->
          assert {:ok, %{dry_run: true, would_execute: ^action}} =
                   Real.execute(action, decision(mode: :dry_run), rec)
        end)

      assert log =~ "dry run"
      assert log =~ rec.id
      assert log =~ ":scale"
      assert log =~ "replicas: 5"
      assert log =~ "inverse"
      assert log =~ "replicas: 3"

      assert Budgets.actions_this_hour(budgets) == 0
      assert Budgets.actions_this_incident(budgets, rec.id) == 0
    end

    test "a dry run of an irreversible action logs its class", %{root: root} do
      rec = record(root)
      action = restart_pod_action()

      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: :warning) end)

      log =
        capture_log(fn ->
          assert {:ok, %{dry_run: true, would_execute: ^action}} =
                   Real.execute(action, decision(mode: :dry_run), rec)
        end)

      assert log =~ ":irreversible_benign"
    end

    test "an exhausted per-incident budget refuses", %{root: root, budgets: budgets} do
      rec = record(root)

      {:ok, _counts} = Budgets.consume(budgets, rec.id, @limits)
      {:ok, _counts} = Budgets.consume(budgets, rec.id, @limits)

      assert {:error, {:budget_exceeded, :actions_per_incident}} =
               Real.execute(restart_pod_action(), decision(), rec)

      assert Budgets.actions_this_incident(budgets, rec.id) == 2
    end

    test "an exhausted hourly budget refuses", %{root: root, budgets: budgets} do
      rec = record(root)
      limits = %{@limits | actions_per_hour: 1}

      {:ok, _counts} = Budgets.consume(budgets, "some-other-incident", limits)

      assert {:error, {:budget_exceeded, :actions_per_hour}} =
               Real.execute(restart_pod_action(), decision(budgets: limits), rec)

      assert Budgets.actions_this_incident(budgets, rec.id) == 0
    end

    test "a missing bundle manifest refuses after the budget is spent", %{
      root: root,
      budgets: budgets
    } do
      rec = record(root, manifest: false)

      assert {:error, :evidence_missing} = Real.execute(restart_pod_action(), decision(), rec)

      # The budget consume precedes the evidence check (plan/03 sequence),
      # so the refused action still spent its slot.
      assert Budgets.actions_this_incident(budgets, rec.id) == 1
    end

    test "an invertible action without its inverse refuses", %{root: root} do
      rec = record(root)

      assert {:error, :inverse_missing} =
               Real.execute(scale_action(inverse: false), decision(), rec)
    end

    test "a recorded inverse executes as a revert without carrying its own", %{root: root} do
      action = cordon_action()
      rec = %{record(root) | action: action}

      expect(Kubeybilly.K8sClient.Mock, :patch, fn "Node", "node-1", nil, patch ->
        assert patch == %{"spec" => %{"unschedulable" => false}}
        {:ok, %{}}
      end)

      assert {:ok, %{action: :uncordon_node}} = Real.execute(action.inverse, decision(), rec)
    end
  end

  describe "action-to-call mapping" do
    test "rollback_deployment patches with the validated merge patch", %{
      root: root,
      budgets: budgets
    } do
      rec = record(root)

      expect(Kubeybilly.K8sClient.Mock, :patch, fn "Deployment", "web", "demo", patch ->
        assert patch == @merge_patch
        {:ok, %{"metadata" => %{"resourceVersion" => "99"}}}
      end)

      assert {:ok, result} = Real.execute(rollback_action(), decision(), rec)
      assert result.action == :rollback_deployment
      assert result.params == %{namespace: "demo", name: "web", to_revision: 3}
      assert Budgets.actions_this_incident(budgets, rec.id) == 1
    end

    test "restart_workload patches the restartedAt template annotation", %{root: root} do
      rec = record(root)

      expect(Kubeybilly.K8sClient.Mock, :patch, fn "Deployment", "web", "demo", patch ->
        stamp =
          get_in(patch, [
            "spec",
            "template",
            "metadata",
            "annotations",
            "kubectl.kubernetes.io/restartedAt"
          ])

        assert {:ok, _at, _offset} = DateTime.from_iso8601(stamp)
        {:ok, %{}}
      end)

      assert {:ok, %{action: :restart_workload}} =
               Real.execute(restart_workload_action(), decision(), rec)
    end

    test "restart_pod deletes the pod", %{root: root} do
      rec = record(root)

      expect(Kubeybilly.K8sClient.Mock, :delete_pod, fn "demo", "web-abc" -> {:ok, %{}} end)

      assert {:ok, %{action: :restart_pod}} =
               Real.execute(restart_pod_action(), decision(), rec)
    end

    test "scale patches the scale subresource", %{root: root} do
      rec = record(root)

      expect(Kubeybilly.K8sClient.Mock, :scale, fn "Deployment", "web", "demo", 5 ->
        {:ok, %{}}
      end)

      assert {:ok, %{action: :scale}} = Real.execute(scale_action(), decision(), rec)
    end

    test "cordon_node patches the node unschedulable", %{root: root} do
      rec = record(root)

      expect(Kubeybilly.K8sClient.Mock, :patch, fn "Node", "node-1", nil, patch ->
        assert patch == %{"spec" => %{"unschedulable" => true}}
        {:ok, %{}}
      end)

      assert {:ok, %{action: :cordon_node}} = Real.execute(cordon_action(), decision(), rec)
    end

    test "a client error passes through and the budget stays spent", %{
      root: root,
      budgets: budgets
    } do
      rec = record(root)

      expect(Kubeybilly.K8sClient.Mock, :delete_pod, fn "demo", "web-abc" ->
        {:error, {:api, "Forbidden", "denied"}}
      end)

      assert {:error, {:execute, {:api, "Forbidden", "denied"}}} =
               Real.execute(restart_pod_action(), decision(), rec)

      # Spent budget is the honest count: the cluster may have received
      # the call even when the answer was an error.
      assert Budgets.actions_this_incident(budgets, rec.id) == 1
    end
  end

  describe "telemetry and PubSub" do
    setup do
      parent = self()
      handler_id = "executor-real-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:kubeybilly, :executor, :execute],
        fn _event, measurements, metadata, _config ->
          send(parent, {:execute_event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "a successful execution emits telemetry and the PubSub event", %{root: root} do
      rec = record(root)
      id = rec.id
      :ok = Phoenix.PubSub.subscribe(Kubeybilly.PubSub, "incidents")

      expect(Kubeybilly.K8sClient.Mock, :delete_pod, fn "demo", "web-abc" -> {:ok, %{}} end)

      assert {:ok, _result} = Real.execute(restart_pod_action(), decision(), rec)

      assert_receive {:execute_event, %{system_time: _},
                      %{outcome: :ok, action: :restart_pod, incident_id: ^id}}

      assert_receive {:executed, ^id, :restart_pod}
    end

    test "every refusal emits telemetry with its outcome", %{root: root} do
      :persistent_term.put(@kill_key, true)
      rec = record(root)
      id = rec.id

      assert {:error, :kill_switch_engaged} = Real.execute(restart_pod_action(), decision(), rec)

      assert_receive {:execute_event, _measurements,
                      %{outcome: :kill_switch_engaged, action: :restart_pod, incident_id: ^id}}
    end

    test "a dry run emits telemetry but never the executed event", %{root: root} do
      rec = record(root)
      id = rec.id
      :ok = Phoenix.PubSub.subscribe(Kubeybilly.PubSub, "incidents")

      assert {:ok, %{dry_run: true}} =
               Real.execute(restart_pod_action(), decision(mode: :dry_run), rec)

      assert_receive {:execute_event, _measurements,
                      %{outcome: :dry_run, action: :restart_pod, incident_id: ^id}}

      refute_receive {:executed, _id, _action}, 50
    end
  end
end
