defmodule Kubeybilly.Incident.MonitorTest do
  use ExUnit.Case, async: false

  alias Kubeybilly.Incident.Monitor
  alias Kubeybilly.Incident.Record

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "kubeybilly-monitor-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    monitor = start_supervised!({Monitor, name: :"monitor_#{System.unique_integer()}"})
    %{root: root, monitor: monitor}
  end

  defp open_record(root, id) do
    record =
      Record.new(%{
        id: id,
        group_key: "gk-#{id}",
        namespace: "demo",
        workload: %{kind: "Deployment", name: "web", uid: "uid-#{id}"}
      })

    :ok = Record.to_disk(record, root: root)
    record
  end

  defp watching_process(monitor, id, root) do
    parent = self()

    pid =
      spawn(fn ->
        :ok = Monitor.watch(monitor, id, root: root)
        send(parent, :watching)

        receive do
          :never -> :ok
        end
      end)

    assert_receive :watching
    pid
  end

  defp await_record(root, id, fun, tries \\ 100) do
    case Record.from_disk(id, root: root) do
      {:ok, record} ->
        if fun.(record) do
          record
        else
          retry_await(root, id, fun, tries)
        end

      _error ->
        retry_await(root, id, fun, tries)
    end
  end

  defp retry_await(_root, _id, _fun, 0), do: flunk("record never reached expected shape")

  defp retry_await(root, id, fun, tries) do
    Process.sleep(10)
    await_record(root, id, fun, tries - 1)
  end

  test "an abnormal termination closes the open record as interrupted",
       %{root: root, monitor: monitor} do
    id = "20260724T000000Z-abn00001"
    open_record(root, id)
    pid = watching_process(monitor, id, root)

    Process.exit(pid, :kill)

    record = await_record(root, id, &(&1.status == :closed))
    assert record.outcome == :interrupted
    assert Enum.any?(record.timeline, fn {_at, event, _detail} -> event == :interrupted end)
  end

  test "a normal termination leaves the record alone", %{root: root, monitor: monitor} do
    id = "20260724T000000Z-nrm00001"
    open_record(root, id)
    pid = watching_process(monitor, id, root)

    ref = Process.monitor(pid)
    Process.exit(pid, :shutdown)
    assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}

    # Give the monitor time to (wrongly) act before asserting it did not.
    Process.sleep(50)
    assert {:ok, record} = Record.from_disk(id, root: root)
    assert record.status == :open
  end

  test "a crash after the machine already closed does not overwrite the outcome",
       %{root: root, monitor: monitor} do
    id = "20260724T000000Z-cls00001"
    record = open_record(root, id)
    :ok = record |> Record.close(:recovered) |> Record.to_disk(root: root)
    pid = watching_process(monitor, id, root)

    Process.exit(pid, :kill)
    Process.sleep(50)

    assert {:ok, reloaded} = Record.from_disk(id, root: root)
    assert reloaded.outcome == :recovered
  end

  test "watch reports :error when the monitor is not running" do
    assert :error = Monitor.watch(:no_such_monitor, "id", root: "nowhere")
  end
end
