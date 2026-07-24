defmodule Kubeybilly.Alerts.CorrelatorTest do
  # async: false: spawned machines register in the shared Registry and
  # run under the application's DynamicSupervisor.
  use ExUnit.Case, async: false

  alias Kubeybilly.Alerts.Correlator
  alias Kubeybilly.Incident.Record
  alias Kubeybilly.Incident.Registry, as: IncidentRegistry
  alias Kubeybilly.StandingOrders.Policy

  setup do
    root =
      System.tmp_dir!()
      |> Path.join("kubeybilly-correlator-#{System.unique_integer([:positive])}")
      |> String.replace("\\", "/")

    File.mkdir_p!(root)
    previous = Application.get_env(:kubeybilly, :incidents_dir)
    Application.put_env(:kubeybilly, :incidents_dir, root)

    on_exit(fn ->
      Application.put_env(:kubeybilly, :incidents_dir, previous)
      File.rm_rf(root)
    end)

    parent = self()
    handler_id = "correlator-telemetry-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:kubeybilly, :alerts, :correlator],
      fn _event, _measurements, metadata, _config -> send(parent, {:routed, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    policy = %Policy{tiers: %{"read" => Policy.default_read_tier()}}

    correlator =
      start_supervised!(
        {Correlator,
         name: :"correlator_#{System.unique_integer([:positive])}",
         window_ms: 40,
         machine_opts: [
           policy: policy,
           collector: fn _target, _opts ->
             Process.sleep(1_500)
             {:error, :idle_test_collector}
           end
         ]}
      )

    %{root: root, correlator: correlator}
  end

  defp unique_gk, do: "{}:{alertname=\"T#{System.unique_integer([:positive])}\"}"

  defp firing(group_key, deployment, extra_labels \\ %{}) do
    labels =
      Map.merge(
        %{"namespace" => "demo", "deployment" => deployment, "pod" => "#{deployment}-abc12-x1"},
        extra_labels
      )

    %{"groupKey" => group_key, "status" => "firing", "alerts" => [%{"labels" => labels}]}
  end

  defp resolved(group_key) do
    %{"groupKey" => group_key, "status" => "resolved", "alerts" => []}
  end

  defp await_open(group_key, tries \\ 200) do
    case IncidentRegistry.whereis_group_key(group_key) do
      {:ok, pid} ->
        pid

      :error when tries > 0 ->
        Process.sleep(10)
        await_open(group_key, tries - 1)

      :error ->
        flunk("no incident opened for #{group_key}")
    end
  end

  defp incident_id(pid) do
    {_state, data} = :sys.get_state(pid)
    data.record.id
  end

  defp await_timeline_event(root, id, event, tries \\ 200) do
    with {:ok, record} <- Record.from_disk(id, root: root),
         true <- Enum.any?(record.timeline, fn {_at, name, _detail} -> name == event end) do
      record
    else
      _not_yet when tries > 0 ->
        Process.sleep(10)
        await_timeline_event(root, id, event, tries - 1)

      _not_yet ->
        flunk("record #{id} never saw #{inspect(event)}")
    end
  end

  defp shutdown(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :shutdown)
  end

  test "a firing group spawns one incident machine", %{correlator: correlator} do
    group_key = unique_gk()
    Correlator.ingest(correlator, firing(group_key, "web"))

    pid = await_open(group_key)
    assert_receive {:routed, %{action: :spawned, group_key: ^group_key}}, 2000
    assert {:ok, ^pid} = IncidentRegistry.whereis_workload("demo", "demo/Deployment/web")

    shutdown(pid)
  end

  test "redelivery of an open group key routes as an update, never a second incident",
       %{root: root, correlator: correlator} do
    group_key = unique_gk()
    Correlator.ingest(correlator, firing(group_key, "shop"))
    pid = await_open(group_key)
    assert_receive {:routed, %{action: :spawned, group_key: ^group_key}}, 2000

    Correlator.ingest(correlator, firing(group_key, "shop"))
    assert_receive {:routed, %{action: :deduped, group_key: ^group_key}}, 2000

    assert {:ok, ^pid} = IncidentRegistry.whereis_group_key(group_key)
    await_timeline_event(root, incident_id(pid), :alerts_update)

    shutdown(pid)
  end

  test "a second group key on the same workload merges into the open incident",
       %{root: root, correlator: correlator} do
    first_gk = unique_gk()
    second_gk = unique_gk()

    Correlator.ingest(correlator, firing(first_gk, "galley"))
    pid = await_open(first_gk)
    assert_receive {:routed, %{action: :spawned, group_key: ^first_gk}}, 2000

    Correlator.ingest(correlator, firing(second_gk, "galley"))
    assert_receive {:routed, %{action: :merged, group_key: ^second_gk}}, 2000

    assert :error = IncidentRegistry.whereis_group_key(second_gk)
    await_timeline_event(root, incident_id(pid), :alerts_update)

    shutdown(pid)
  end

  test "groups buffered within one window merge before routing",
       %{correlator: correlator} do
    group_key = unique_gk()
    Correlator.ingest(correlator, firing(group_key, "buffered"))
    Correlator.ingest(correlator, firing(group_key, "buffered"))

    pid = await_open(group_key)
    assert_receive {:routed, %{action: :spawned, group_key: ^group_key}}, 2000
    refute_receive {:routed, %{action: :deduped, group_key: ^group_key}}, 100

    shutdown(pid)
  end

  test "a resolved group routes to the open incident and closes it",
       %{root: root, correlator: correlator} do
    group_key = unique_gk()
    Correlator.ingest(correlator, firing(group_key, "resolving"))
    pid = await_open(group_key)
    id = incident_id(pid)

    Correlator.ingest(correlator, resolved(group_key))
    assert_receive {:routed, %{action: :resolved_routed, group_key: ^group_key}}, 2000

    record = await_timeline_event(root, id, :resolved_before_action)
    assert record.outcome == :resolved_before_action
  end

  test "a resolved group with no open incident is dropped quietly",
       %{correlator: correlator} do
    group_key = unique_gk()
    Correlator.ingest(correlator, resolved(group_key))

    assert_receive {:routed, %{action: :resolved_unmatched, group_key: ^group_key}}, 2000
  end

  test "a group without a target is dropped with the reason", %{correlator: correlator} do
    group_key = unique_gk()

    Correlator.ingest(correlator, %{
      "groupKey" => group_key,
      "status" => "firing",
      "alerts" => [%{"labels" => %{"pod" => "standalone"}}]
    })

    assert_receive {:routed, %{action: :dropped, reason: :no_namespace}}, 2000
  end

  test "a malformed payload is dropped without crashing", %{correlator: correlator} do
    Correlator.ingest(correlator, %{"status" => "firing"})

    assert_receive {:routed, %{action: :dropped, reason: :malformed}}, 2000
    assert Process.alive?(correlator)
  end
end
