defmodule Kubeybilly.Formulary.ValidatorTest do
  use ExUnit.Case, async: true

  import Mox

  alias Kubeybilly.Formulary.Action
  alias Kubeybilly.Formulary.Validator
  alias Kubeybilly.K8sClient.Mock, as: Client

  setup :verify_on_exit!

  @fixtures Path.expand("../../fixtures/incidents/oomkill-galley", __DIR__)

  defp deployment do
    @fixtures |> Path.join("owners/demo/galley.json") |> File.read!() |> Jason.decode!()
  end

  defp replicasets do
    @fixtures |> Path.join("owners/demo/galley-revisions.json") |> File.read!() |> Jason.decode!()
  end

  defp pod(name) do
    %{
      "apiVersion" => "v1",
      "kind" => "Pod",
      "metadata" => %{"name" => name, "namespace" => "demo", "labels" => %{"app" => "galley"}},
      "spec" => %{"nodeName" => "worker-1"},
      "status" => %{"phase" => "Running"}
    }
  end

  defp node_fixture(unschedulable) do
    spec = if unschedulable, do: %{"unschedulable" => true}, else: %{}

    %{
      "apiVersion" => "v1",
      "kind" => "Node",
      "metadata" => %{"name" => "worker-1"},
      "spec" => spec
    }
  end

  defp action!(name, params) do
    {:ok, action} = Action.new(name, params)
    action
  end

  describe "rollback_deployment" do
    defp rollback_action(to_revision) do
      action!(:rollback_deployment, %{namespace: "demo", name: "galley", to_revision: to_revision})
    end

    test "gathers the current revision, patch, and live pod count" do
      dep = deployment()
      revisions = replicasets()
      pods = [pod("galley-a"), pod("galley-b"), pod("galley-c")]

      expect(Client, :get, fn "Deployment", "galley", "demo" -> {:ok, dep} end)

      expect(Client, :list, 2, fn
        "ReplicaSet", "demo", "app=galley" -> {:ok, revisions}
        "Pod", "demo", "app=galley" -> {:ok, pods}
      end)

      assert {:ok, %{action: validated, facts: facts}} =
               Validator.validate(rollback_action("3"), Client)

      assert validated.blast_estimate == 3
      assert facts.current_revision == "5"
      assert facts.live_pod_count == 3
      assert %{"spec" => %{"template" => _template}} = facts.patch
    end

    test "rolling back to the current revision is declined as a noop" do
      dep = deployment()
      revisions = replicasets()

      expect(Client, :get, fn "Deployment", "galley", "demo" -> {:ok, dep} end)

      expect(Client, :list, 2, fn
        "ReplicaSet", "demo", "app=galley" -> {:ok, revisions}
        "Pod", "demo", "app=galley" -> {:ok, [pod("galley-a")]}
      end)

      assert {:error, {:validation, :noop_rollback, %{revision: "5"}}} =
               Validator.validate(rollback_action("5"), Client)
    end

    test "a vanished target revision is declined" do
      dep = deployment()
      revisions = replicasets()

      expect(Client, :get, fn "Deployment", "galley", "demo" -> {:ok, dep} end)

      expect(Client, :list, 2, fn
        "ReplicaSet", "demo", "app=galley" -> {:ok, revisions}
        "Pod", "demo", "app=galley" -> {:ok, []}
      end)

      assert {:error, {:validation, :revision_not_found, detail}} =
               Validator.validate(rollback_action("2"), Client)

      assert detail.available == ["1", "3", "4", "5"]
    end

    test "a missing Deployment is declined as target_missing" do
      expect(Client, :get, fn "Deployment", "galley", "demo" ->
        {:error, {:api, "NotFound", "not found"}}
      end)

      assert {:error, {:validation, :target_missing, _detail}} =
               Validator.validate(rollback_action("3"), Client)
    end

    test "a resource of the wrong kind is declined as kind_mismatch" do
      expect(Client, :get, fn "Deployment", "galley", "demo" ->
        {:ok, %{"kind" => "StatefulSet", "metadata" => %{"name" => "galley"}}}
      end)

      assert {:error, {:validation, :kind_mismatch, detail}} =
               Validator.validate(rollback_action("3"), Client)

      assert detail.expected == "Deployment"
      assert detail.found == "StatefulSet"
    end

    test "a failed pod listing is declined as cluster_unavailable" do
      dep = deployment()
      revisions = replicasets()

      expect(Client, :get, fn "Deployment", "galley", "demo" -> {:ok, dep} end)

      expect(Client, :list, 2, fn
        "ReplicaSet", "demo", "app=galley" -> {:ok, revisions}
        "Pod", "demo", "app=galley" -> {:error, {:transport, :timeout}}
      end)

      assert {:error, {:validation, :cluster_unavailable, {:transport, :timeout}}} =
               Validator.validate(rollback_action("3"), Client)
    end
  end

  describe "scale" do
    defp scale_action(replicas) do
      action!(:scale, %{namespace: "demo", kind: "Deployment", name: "galley", replicas: replicas})
    end

    test "computes the delta from live replicas for the standing-orders check" do
      dep = deployment()
      expect(Client, :get, fn "Deployment", "galley", "demo" -> {:ok, dep} end)

      assert {:ok, %{action: validated, facts: facts}} =
               Validator.validate(scale_action(5), Client)

      assert facts.current_replicas == 3
      assert facts.delta == 2
      assert validated.blast_estimate == 2
    end

    test "scaling down reports the absolute delta" do
      dep = deployment()
      expect(Client, :get, fn "Deployment", "galley", "demo" -> {:ok, dep} end)

      assert {:ok, %{facts: %{delta: 3, current_replicas: 3}}} =
               Validator.validate(scale_action(0), Client)
    end

    test "a missing workload is declined" do
      expect(Client, :get, fn "Deployment", "galley", "demo" ->
        {:error, {:api, "NotFound", "not found"}}
      end)

      assert {:error, {:validation, :target_missing, _detail}} =
               Validator.validate(scale_action(5), Client)
    end
  end

  describe "restart_workload" do
    test "estimates blast from the live pods behind the selector" do
      dep = deployment()

      action =
        action!(:restart_workload, %{namespace: "demo", kind: "Deployment", name: "galley"})

      expect(Client, :get, fn "Deployment", "galley", "demo" -> {:ok, dep} end)

      expect(Client, :list, fn "Pod", "demo", "app=galley" ->
        {:ok, [pod("galley-a"), pod("galley-b")]}
      end)

      assert {:ok, %{action: validated, facts: facts}} = Validator.validate(action, Client)
      assert validated.blast_estimate == 2
      assert facts.live_pod_count == 2
    end
  end

  describe "restart_pod" do
    test "touches exactly one pod" do
      action = action!(:restart_pod, %{namespace: "demo", name: "galley-a"})

      expect(Client, :get, fn "Pod", "galley-a", "demo" -> {:ok, pod("galley-a")} end)

      assert {:ok, %{action: validated, facts: facts}} = Validator.validate(action, Client)
      assert validated.blast_estimate == 1
      assert facts.live_pod_count == 1
    end

    test "a vanished pod is declined" do
      action = action!(:restart_pod, %{namespace: "demo", name: "galley-a"})

      expect(Client, :get, fn "Pod", "galley-a", "demo" ->
        {:error, {:api, "NotFound", "gone"}}
      end)

      assert {:error, {:validation, :target_missing, _detail}} =
               Validator.validate(action, Client)
    end
  end

  describe "cordon_node" do
    test "passes when the node is schedulable" do
      action = action!(:cordon_node, %{name: "worker-1"})
      expect(Client, :get, fn "Node", "worker-1", nil -> {:ok, node_fixture(false)} end)

      assert {:ok, %{action: validated, facts: facts}} = Validator.validate(action, Client)
      assert validated.blast_estimate == 0
      assert facts.unschedulable == false
    end

    test "an already cordoned node is declined" do
      action = action!(:cordon_node, %{name: "worker-1"})
      expect(Client, :get, fn "Node", "worker-1", nil -> {:ok, node_fixture(true)} end)

      assert {:error, {:validation, :already_cordoned, %{node: "worker-1"}}} =
               Validator.validate(action, Client)
    end
  end

  describe "uncordon_node (internal inverse)" do
    test "passes only when the node is actually cordoned" do
      {:ok, action} = Action.internal_new(:uncordon_node, %{name: "worker-1"})
      expect(Client, :get, fn "Node", "worker-1", nil -> {:ok, node_fixture(true)} end)

      assert {:ok, %{facts: %{unschedulable: true}}} = Validator.validate(action, Client)
    end

    test "a schedulable node is declined" do
      {:ok, action} = Action.internal_new(:uncordon_node, %{name: "worker-1"})
      expect(Client, :get, fn "Node", "worker-1", nil -> {:ok, node_fixture(false)} end)

      assert {:error, {:validation, :not_cordoned, %{node: "worker-1"}}} =
               Validator.validate(action, Client)
    end
  end

  describe "no_action" do
    test "validates without touching the cluster" do
      action = action!(:no_action, %{reason: "no matching signature"})

      assert {:ok, %{action: validated, facts: %{}}} = Validator.validate(action, Client)
      assert validated.blast_estimate == 0
    end
  end

  describe "telemetry" do
    test "emits an event for both validation outcomes" do
      handler_id = "validator-test-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:kubeybilly, :formulary, :validate],
        fn _event, measurements, metadata, pid ->
          send(pid, {:validated, measurements, metadata})
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      action = action!(:restart_pod, %{namespace: "demo", name: "galley-a"})

      expect(Client, :get, fn "Pod", "galley-a", "demo" -> {:ok, pod("galley-a")} end)
      assert {:ok, _validated} = Validator.validate(action, Client)

      assert_receive {:validated, %{blast_estimate: 1}, %{action: :restart_pod, outcome: :ok}}

      expect(Client, :get, fn "Pod", "galley-a", "demo" ->
        {:error, {:api, "NotFound", "gone"}}
      end)

      assert {:error, _reason} = Validator.validate(action, Client)

      assert_receive {:validated, %{blast_estimate: 0},
                      %{action: :restart_pod, outcome: :error, rule: :target_missing}}
    end
  end
end
