defmodule Kubeybilly.Incident.MachineTest.StubAdvisor do
  @moduledoc false

  alias Kubeybilly.Signatures.Signature

  def advise(_bundle) do
    {:match,
     Signature.new(%{
       name: :stub_advisor,
       confidence: 0.5,
       proposed_action: %{action: :no_action, params: %{}},
       rationale: "the advisor found nothing safe to do",
       evidence_refs: []
     })}
  end
end

defmodule Kubeybilly.Incident.MachineTest do
  # async: false: machines register in the shared Registry and the tests
  # use global Mox mode so the machine process sees the expectations.
  use ExUnit.Case, async: false

  import Mox

  alias Kubeybilly.Incident.Machine
  alias Kubeybilly.Incident.Record
  alias Kubeybilly.Incident.Registry, as: IncidentRegistry
  alias Kubeybilly.StandingOrders.Parser

  @fixtures "test/fixtures/incidents"
  @policy_fixture "test/fixtures/standing_orders/demo.yaml"

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    # Forward slashes: bundle loading globs with Path.wildcard, which does
    # not match Windows backslash separators.
    root =
      System.tmp_dir!()
      |> Path.join("kubeybilly-machine-#{System.unique_integer([:positive])}")
      |> String.replace("\\", "/")

    File.mkdir_p!(root)
    previous = Application.get_env(:kubeybilly, :incidents_dir)
    Application.put_env(:kubeybilly, :incidents_dir, root)

    on_exit(fn ->
      Application.put_env(:kubeybilly, :incidents_dir, previous)
      File.rm_rf(root)
    end)

    {:ok, policy} = Parser.load(@policy_fixture)
    %{root: root, policy: policy}
  end

  ## Helpers

  defp unique_id do
    "20260724T031500Z-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"
  end

  defp machine_opts(context, overrides) do
    suffix = System.unique_integer([:positive])

    Keyword.merge(
      [
        id: unique_id(),
        group_key: "gk-#{suffix}",
        namespace: "demo",
        workload: %{kind: "Deployment", name: "web", uid: "uid-#{suffix}"},
        pods: [],
        nodes: [],
        policy: context.policy,
        client: Kubeybilly.K8sClient.Mock
      ],
      overrides
    )
  end

  defp start_machine(context, overrides) do
    opts = machine_opts(context, overrides)
    pid = start_supervised!({Machine, opts})
    {pid, opts[:id]}
  end

  defp fixture_collector(root, fixture) do
    fn target, _opts ->
      destination = Path.join(root, target.incident_id)
      File.cp_r!(Path.join(@fixtures, fixture), destination)

      manifest =
        destination
        |> Path.join("manifest.json")
        |> File.read!()
        |> Jason.decode!()

      {:ok, manifest}
    end
  end

  defp slow_collector(sleep_ms) do
    fn _target, _opts ->
      Process.sleep(sleep_ms)
      {:error, :collector_still_running}
    end
  end

  defp fixture_json(path) do
    @fixtures |> Path.join(path) |> File.read!() |> Jason.decode!()
  end

  defp await_closed(root, id, tries \\ 200) do
    case Record.from_disk(id, root: root) do
      {:ok, %Record{status: :closed} = record} ->
        record

      _open_or_missing when tries > 0 ->
        Process.sleep(10)
        await_closed(root, id, tries - 1)

      other ->
        flunk("record never closed: #{inspect(other)}")
    end
  end

  defp await_state(pid, state, tries \\ 200) do
    case :sys.get_state(pid) do
      {^state, _data} ->
        :ok

      _other when tries > 0 ->
        Process.sleep(10)
        await_state(pid, state, tries - 1)

      other ->
        flunk("machine never reached #{inspect(state)}, at #{inspect(other)}")
    end
  end

  defp events(record) do
    Enum.map(record.timeline, fn {_at, event, _detail} -> event end)
  end

  # Records come back through disk, so details arrive string-keyed.
  defp detail(record, event) do
    case Enum.find(record.timeline, fn {_at, name, _detail} -> name == event end) do
      {_at, ^event, detail} -> detail
      nil -> flunk("no #{event} event in #{inspect(events(record))}")
    end
  end

  defp tier(policy, name, overrides) do
    %{policy | tiers: Map.update!(policy.tiers, name, &Map.merge(&1, overrides))}
  end

  defp stub_healthy_node do
    stub(Kubeybilly.K8sClient.Mock, :get, fn "Node", "worker-1", nil ->
      {:ok, %{"kind" => "Node", "spec" => %{}}}
    end)
  end

  defp stub_rollback_reads do
    deployment = fixture_json("imagepull-post-rollout/owners/demo/web.json")

    replicasets =
      "imagepull-post-rollout/owners/demo/web-revisions.json"
      |> fixture_json()
      |> Enum.map(
        &put_in(&1, ["metadata", "ownerReferences"], [
          %{"kind" => "Deployment", "name" => "web"}
        ])
      )

    stub(Kubeybilly.K8sClient.Mock, :get, fn "Deployment", "web", "demo" ->
      {:ok, deployment}
    end)

    stub(Kubeybilly.K8sClient.Mock, :list, fn
      "ReplicaSet", "demo", _selector -> {:ok, replicasets}
      "Pod", "demo", _selector -> {:ok, [%{"kind" => "Pod"}, %{"kind" => "Pod"}]}
    end)
  end

  ## Happy path

  test "recovers: evidence, gate, auto-permitted action, verified recovered",
       %{root: root, policy: policy} = context do
    policy = tier(policy, "node", %{auto: true})
    stub_healthy_node()

    expect(Kubeybilly.ExecutorMock, :execute, fn action, decision, record ->
      assert action.name == :cordon_node
      assert action.params == %{name: "worker-1"}
      assert action.inverse.name == :uncordon_node
      assert decision.verdict == :permit_auto
      assert record.namespace == "demo"
      {:ok, %{dry_run: false}}
    end)

    expect(Kubeybilly.VerifierMock, :verify, fn _record, _baseline, opts ->
      assert opts[:window_seconds] == policy.verification.window_seconds
      {:ok, :recovered, %{reason: :recovered_sustained, unmet: [], polls: 2}}
    end)

    {_pid, id} =
      start_machine(context, policy: policy, collector: fixture_collector(root, "node-not-ready"))

    record = await_closed(root, id)

    assert record.outcome == :recovered
    assert record.verification_outcome == :recovered
    assert record.signature["name"] == "node_not_ready"
    assert record.decision["rule_id"] == "tier-auto"
    assert record.action["name"] == "cordon_node"

    assert [
             :opened,
             :evidence_sealed,
             :permitted,
             :executed,
             :verified_recovered
           ] = events(record)

    assert detail(record, :verified_recovered) == %{
             "reason" => "recovered_sustained",
             "unmet" => [],
             "polls" => 2
           }
  end

  test "emits telemetry on every transition", %{root: root, policy: policy} = context do
    policy = tier(policy, "node", %{auto: true})
    stub_healthy_node()
    expect(Kubeybilly.ExecutorMock, :execute, fn _a, _d, _r -> {:ok, %{}} end)

    expect(Kubeybilly.VerifierMock, :verify, fn _r, _b, _o ->
      {:ok, :recovered, %{reason: :recovered_sustained, unmet: [], polls: 2}}
    end)

    parent = self()
    handler_id = "machine-telemetry-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:kubeybilly, :incident, :transition],
      fn _event, _measurements, metadata, _config -> send(parent, {:transition, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {_pid, id} =
      start_machine(context, policy: policy, collector: fixture_collector(root, "node-not-ready"))

    await_closed(root, id)

    for {from, to} <- [
          {nil, :collecting},
          {:collecting, :gating},
          {:gating, :acting},
          {:acting, :verifying},
          {:verifying, :closed}
        ] do
      assert_receive {:transition, %{incident_id: ^id, from: ^from, to: ^to}}, 2000
    end
  end

  ## Evidence failures

  test "an incomplete bundle escalates as evidence_incomplete",
       %{root: root} = context do
    collector = fn _target, _opts ->
      {:ok, %{"complete" => false, "gaps" => [%{"path" => "pods/demo/web-1/status.json"}]}}
    end

    {_pid, id} = start_machine(context, collector: collector)
    record = await_closed(root, id)

    assert record.outcome == :escalated
    assert :evidence_incomplete in events(record)
  end

  test "a collector error escalates as evidence_incomplete", %{root: root} = context do
    {_pid, id} = start_machine(context, collector: fn _t, _o -> {:error, :disk_full} end)
    record = await_closed(root, id)

    assert record.outcome == :escalated
    assert :evidence_incomplete in events(record)
  end

  test "a collector crash escalates as evidence_incomplete", %{root: root} = context do
    {_pid, id} = start_machine(context, collector: fn _t, _o -> raise "kubelet ate it" end)
    record = await_closed(root, id)

    assert record.outcome == :escalated
    assert :evidence_incomplete in events(record)
  end

  ## Resolved before action

  test "a resolved notification while collecting closes without mutation",
       %{root: root} = context do
    {pid, id} = start_machine(context, collector: slow_collector(500))

    Machine.resolve(pid, "any")
    record = await_closed(root, id)

    assert record.outcome == :resolved_before_action
    assert :resolved_before_action in events(record)
  end

  ## Gate outcomes

  test "a no_action signature escalates without touching the executor",
       %{root: root} = context do
    # oomkill-galley matches the oomkilled signature, which proposes no_action.
    {_pid, id} =
      start_machine(context, collector: fixture_collector(root, "oomkill-galley"))

    record = await_closed(root, id)

    assert record.outcome == :escalated
    assert :no_action in events(record)
    assert record.decision["verdict"] == "permit_auto"
    assert record.decision["rule_id"] == "tier-auto"
  end

  test "a policy deny closes as declined with the rule id on the record",
       %{root: root} = context do
    stub_healthy_node()

    {_pid, id} =
      start_machine(context,
        collector: fixture_collector(root, "node-not-ready"),
        context: %{actions_this_incident: 2}
      )

    record = await_closed(root, id)

    assert record.outcome == :declined
    assert :policy_denied in events(record)
    assert record.decision["verdict"] == "deny"
    assert record.decision["rule_id"] == "budget-actions-per-incident"
  end

  test "an unmatched bundle escalates when the advisor is disabled",
       %{root: root} = context do
    collector = fn target, _opts ->
      destination = Path.join(root, target.incident_id)
      File.mkdir_p!(destination)
      manifest = %{"incident_id" => target.incident_id, "complete" => true, "gaps" => []}
      File.write!(Path.join(destination, "manifest.json"), Jason.encode!(manifest))
      {:ok, manifest}
    end

    {_pid, id} = start_machine(context, collector: collector)
    record = await_closed(root, id)

    assert record.outcome == :escalated
    assert :no_signature_match in events(record)
  end

  test "an unmatched bundle routes to the advisor when enabled",
       %{root: root} = context do
    original_advisor = Application.get_env(:kubeybilly, :advisor_module)
    Application.put_env(:kubeybilly, :advisor_enabled, true)
    Application.put_env(:kubeybilly, :advisor_module, Kubeybilly.Incident.MachineTest.StubAdvisor)

    on_exit(fn ->
      Application.put_env(:kubeybilly, :advisor_enabled, false)
      Application.put_env(:kubeybilly, :advisor_module, original_advisor)
    end)

    collector = fn target, _opts ->
      destination = Path.join(root, target.incident_id)
      File.mkdir_p!(destination)
      manifest = %{"incident_id" => target.incident_id, "complete" => true, "gaps" => []}
      File.write!(Path.join(destination, "manifest.json"), Jason.encode!(manifest))
      {:ok, manifest}
    end

    {_pid, id} = start_machine(context, collector: collector)
    record = await_closed(root, id)

    # The stub advisor proposes no_action, which escalates with its
    # rationale instead of closing as an unmatched signature.
    assert record.outcome == :escalated
    assert :no_action in events(record)
    refute :no_signature_match in events(record)
    assert record.signature["name"] == "stub_advisor"
  end

  test "the default triage adapter carries a model proposal end to end",
       %{root: root} = context do
    original_facade = Application.fetch_env!(:kubeybilly, :advisor)
    Application.put_env(:kubeybilly, :advisor_enabled, true)

    Application.put_env(
      :kubeybilly,
      :advisor,
      Keyword.put(original_facade, :adapter, Kubeybilly.Advisor.AdapterMock)
    )

    on_exit(fn ->
      Application.put_env(:kubeybilly, :advisor_enabled, false)
      Application.put_env(:kubeybilly, :advisor, original_facade)
    end)

    stub(Kubeybilly.Advisor.AdapterMock, :propose, fn _summary ->
      {:ok,
       %{
         "action" => "cordon_node",
         "params" => %{"node" => "worker-1"},
         "confidence" => 0.95,
         "rationale" => "the node looks wedged"
       }}
    end)

    stub_healthy_node()

    collector = fn target, _opts ->
      destination = Path.join(root, target.incident_id)
      File.mkdir_p!(destination)
      manifest = %{"incident_id" => target.incident_id, "complete" => true, "gaps" => []}
      File.write!(Path.join(destination, "manifest.json"), Jason.encode!(manifest))
      {:ok, manifest}
    end

    {pid, id} = start_machine(context, collector: collector)

    # A capped 0.7 confidence can never clear the auto tier, so a
    # model-proposed cordon always waits for a human.
    await_state(pid, :awaiting_approval)
    Machine.deny(pid)

    record = await_closed(root, id)
    assert record.outcome == :declined
    assert record.signature["name"] == "advisor_proposed"
    assert record.signature["confidence"] == 0.7
    assert record.signature["rationale"] == "advisor: the node looks wedged"
    assert record.action["name"] == "cordon_node"
  end

  ## Approval

  test "the approval timeout escalates, never proceeds", %{root: root} = context do
    stub_healthy_node()

    {_pid, id} =
      start_machine(context,
        collector: fixture_collector(root, "node-not-ready"),
        approval_timeout_ms: 60
      )

    record = await_closed(root, id)

    assert record.outcome == :escalated
    assert :approval_requested in events(record)
    assert :approval_timeout in events(record)
  end

  test "an approval grant proceeds to acting and can recover",
       %{root: root} = context do
    stub_healthy_node()

    expect(Kubeybilly.ExecutorMock, :execute, fn action, _decision, _record ->
      assert action.name == :cordon_node
      {:ok, %{}}
    end)

    expect(Kubeybilly.VerifierMock, :verify, fn _r, _b, _o ->
      {:ok, :recovered, %{reason: :recovered_sustained, unmet: [], polls: 2}}
    end)

    {pid, id} =
      start_machine(context, collector: fixture_collector(root, "node-not-ready"))

    await_state(pid, :awaiting_approval)
    Machine.approve(pid)

    record = await_closed(root, id)
    assert record.outcome == :recovered
    assert :approval_granted in events(record)
  end

  test "an approval denial closes as declined", %{root: root} = context do
    stub_healthy_node()

    {pid, id} =
      start_machine(context, collector: fixture_collector(root, "node-not-ready"))

    await_state(pid, :awaiting_approval)
    Machine.deny(pid)

    record = await_closed(root, id)
    assert record.outcome == :declined
    assert :approval_denied in events(record)
  end

  ## Verification outcomes

  test "unchanged escalates", %{root: root, policy: policy} = context do
    policy = tier(policy, "node", %{auto: true})
    stub_healthy_node()
    expect(Kubeybilly.ExecutorMock, :execute, fn _a, _d, _r -> {:ok, %{}} end)

    expect(Kubeybilly.VerifierMock, :verify, fn _r, _b, _o ->
      {:ok, :unchanged,
       %{
         reason: :window_expired,
         unmet: [:no_restarts_since_settle, :rolled_to_available],
         polls: 7
       }}
    end)

    {_pid, id} =
      start_machine(context, policy: policy, collector: fixture_collector(root, "node-not-ready"))

    record = await_closed(root, id)

    assert record.outcome == :escalated
    assert record.verification_outcome == :unchanged
    assert :verified_unchanged in events(record)

    assert detail(record, :verified_unchanged) == %{
             "reason" => "window_expired",
             "unmet" => ["no_restarts_since_settle", "rolled_to_available"],
             "polls" => 7
           }
  end

  test "worse with a recorded inverse reverts, then hard-stops as escalated",
       %{root: root, policy: policy} = context do
    policy = tier(policy, "node", %{auto: true})
    stub_healthy_node()

    expect(Kubeybilly.ExecutorMock, :execute, fn action, _d, _r ->
      assert action.name == :cordon_node
      {:ok, %{}}
    end)

    expect(Kubeybilly.VerifierMock, :verify, fn _r, _b, _o ->
      {:ok, :worse, %{reason: :restart_rate_exceeded, unmet: [], polls: 3}}
    end)

    expect(Kubeybilly.ExecutorMock, :execute, fn action, _d, _r ->
      assert action.name == :uncordon_node
      assert action.params == %{name: "worker-1"}
      {:ok, %{}}
    end)

    {_pid, id} =
      start_machine(context, policy: policy, collector: fixture_collector(root, "node-not-ready"))

    record = await_closed(root, id)

    assert record.outcome == :escalated
    assert record.verification_outcome == :worse
    assert :worse_reverting in events(record)
    assert :reverted_hard_stop in events(record)

    assert detail(record, :worse_reverting) == %{
             "reason" => "restart_rate_exceeded",
             "unmet" => [],
             "polls" => 3,
             "inverse" => "uncordon_node"
           }
  end

  test "worse after a rollback freezes instead of reverting",
       %{root: root, policy: policy} = context do
    policy = tier(policy, "rollback", %{auto: true})
    stub_rollback_reads()

    expect(Kubeybilly.ExecutorMock, :execute, fn action, _d, _r ->
      assert action.name == :rollback_deployment
      assert action.params.to_revision == 1
      assert action.inverse.params.to_revision == "2"
      assert %{"spec" => %{"template" => _template}} = action.facts.patch
      assert action.facts.current_revision == "2"
      {:ok, %{}}
    end)

    expect(Kubeybilly.VerifierMock, :verify, fn _r, _b, _o ->
      {:ok, :worse, %{reason: :restart_rate_exceeded, unmet: [], polls: 3}}
    end)

    {_pid, id} =
      start_machine(context,
        policy: policy,
        collector: fixture_collector(root, "imagepull-post-rollout")
      )

    record = await_closed(root, id)

    assert record.outcome == :escalated
    assert record.verification_outcome == :worse
    assert :frozen_after_worse in events(record)
    refute :worse_reverting in events(record)

    assert detail(record, :frozen_after_worse) == %{
             "reason" => "restart_rate_exceeded",
             "unmet" => [],
             "polls" => 3,
             "action" => "rollback_deployment",
             "inverse_class" => "invertible"
           }
  end

  test "an executor error escalates as execution_failed",
       %{root: root, policy: policy} = context do
    policy = tier(policy, "node", %{auto: true})
    stub_healthy_node()

    expect(Kubeybilly.ExecutorMock, :execute, fn _a, _d, _r -> {:error, :forbidden} end)

    {_pid, id} =
      start_machine(context, policy: policy, collector: fixture_collector(root, "node-not-ready"))

    record = await_closed(root, id)

    assert record.outcome == :escalated
    assert :execution_failed in events(record)
  end

  test "a verifier that outlives the window escalates as unchanged",
       %{root: root, policy: policy} = context do
    policy = tier(policy, "node", %{auto: true})
    stub_healthy_node()
    expect(Kubeybilly.ExecutorMock, :execute, fn _a, _d, _r -> {:ok, %{}} end)

    stub(Kubeybilly.VerifierMock, :verify, fn _r, _b, _o ->
      Process.sleep(2_000)
      {:ok, :recovered, %{reason: :recovered_sustained, unmet: [], polls: 2}}
    end)

    {_pid, id} =
      start_machine(context,
        policy: policy,
        collector: fixture_collector(root, "node-not-ready"),
        verification_timeout_ms: 80
      )

    record = await_closed(root, id)

    assert record.outcome == :escalated
    assert record.verification_outcome == :unchanged
    assert :verification_window_expired in events(record)
  end

  ## Alert updates and crash safety

  test "alert updates append to the timeline without a second incident",
       %{root: root} = context do
    {pid, id} = start_machine(context, collector: slow_collector(700))

    Machine.alerts(pid, %{"groupKey" => "gk-again", "alerts" => [%{}, %{}]})
    Machine.resolve(pid, "gk-again")

    record = await_closed(root, id)
    assert :alerts_update in events(record)
  end

  test "a killed machine leaves an interrupted record via the monitor",
       %{root: root} = context do
    {pid, id} = start_machine(context, collector: slow_collector(2_000))

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    record = await_closed(root, id)
    assert record.outcome == :interrupted
  end

  ## Logbook on close

  test "closing writes log.md into the bundle, whatever the outcome",
       %{root: root} = context do
    {pid, id} = start_machine(context, collector: slow_collector(500))

    Machine.resolve(pid, "any")
    record = await_closed(root, id)
    assert record.outcome == :resolved_before_action

    log_path = Path.join([root, id, "log.md"])
    await_file(log_path)

    log = File.read!(log_path)
    assert log =~ "# Incident #{id} (resolved before action)"
    assert log =~ "## Timeline"
    assert log =~ "## Open questions"
  end

  @tag :capture_log
  test "a logbook failure never blocks the close", %{root: root} = context do
    id = unique_id()
    # A directory squatting on the log path makes the write fail.
    File.mkdir_p!(Path.join([root, id, "log.md"]))

    {pid, _id} = start_machine(context, id: id, collector: slow_collector(500))

    Machine.resolve(pid, "any")
    record = await_closed(root, id)

    assert record.outcome == :resolved_before_action
    refute File.regular?(Path.join([root, id, "log.md"]))
  end

  defp await_file(path, tries \\ 200) do
    cond do
      File.regular?(path) -> :ok
      tries > 0 -> Process.sleep(10) && await_file(path, tries - 1)
      true -> flunk("file never appeared: #{path}")
    end
  end

  test "a second machine for the same workload refuses to open", context do
    suffix = System.unique_integer([:positive])
    workload = %{kind: "Deployment", name: "web", uid: "uid-dup-#{suffix}"}

    {pid, _id} =
      start_machine(context, workload: workload, collector: slow_collector(1_000))

    opts =
      machine_opts(context,
        workload: workload,
        collector: slow_collector(1_000)
      )

    # The refused machine exits abnormally on purpose; trap so the linked
    # exit lands in the mailbox instead of killing the test.
    Process.flag(:trap_exit, true)
    assert {:error, {:already_open, ^pid}} = Machine.start_link(opts)
  end

  test "machines register under group key and workload while open", context do
    suffix = System.unique_integer([:positive])
    group_key = "gk-reg-#{suffix}"
    workload = %{kind: "Deployment", name: "web", uid: "uid-reg-#{suffix}"}

    {pid, id} =
      start_machine(context,
        group_key: group_key,
        workload: workload,
        collector: slow_collector(1_000)
      )

    assert {:ok, ^pid} = IncidentRegistry.whereis_incident(id)
    assert {:ok, ^pid} = IncidentRegistry.whereis_group_key(group_key)
    assert {:ok, ^pid} = IncidentRegistry.whereis_workload("demo", workload.uid)
  end
end
