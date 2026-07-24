defmodule Kubeybilly.Incident.RecoveryTest do
  use ExUnit.Case, async: true

  alias Kubeybilly.Incident.Record
  alias Kubeybilly.Incident.Recovery

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "kubeybilly-recovery-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  defp write_record(root, id, fun) do
    record =
      Record.new(%{
        id: id,
        group_key: "gk-#{id}",
        namespace: "demo",
        workload: %{kind: "Deployment", name: "web", uid: "uid-#{id}"}
      })

    :ok = record |> fun.() |> Record.to_disk(root: root)
  end

  test "closes stale open records as interrupted and leaves closed ones alone",
       %{root: root} do
    write_record(root, "20260724T000000Z-stale001", & &1)
    write_record(root, "20260724T000000Z-done0001", &Record.close(&1, :recovered))

    assert {:ok, ["20260724T000000Z-stale001"]} = Recovery.run(root)

    assert {:ok, stale} = Record.from_disk("20260724T000000Z-stale001", root: root)
    assert stale.status == :closed
    assert stale.outcome == :interrupted

    assert Enum.any?(stale.timeline, fn {_at, event, detail} ->
             event == :interrupted and detail == %{"by" => "boot_recovery"}
           end)

    assert {:ok, done} = Record.from_disk("20260724T000000Z-done0001", root: root)
    assert done.outcome == :recovered
  end

  test "a missing incidents directory is a fresh install", %{root: root} do
    assert {:ok, []} = Recovery.run(Path.join(root, "nowhere"))
  end

  test "foreign directory entries are skipped", %{root: root} do
    File.mkdir_p!(Path.join(root, "not-an-incident"))
    File.write!(Path.join(root, "loose-file.txt"), "hello")
    write_record(root, "20260724T000000Z-open0001", & &1)

    assert {:ok, ["20260724T000000Z-open0001"]} = Recovery.run(root)
  end

  test "start_link runs the pass and returns :ignore", %{root: root} do
    write_record(root, "20260724T000000Z-boot0001", & &1)

    assert :ignore = Recovery.start_link(root: root)

    assert {:ok, record} = Record.from_disk("20260724T000000Z-boot0001", root: root)
    assert record.outcome == :interrupted
  end
end
