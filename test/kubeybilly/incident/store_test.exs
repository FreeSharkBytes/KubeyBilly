defmodule Kubeybilly.Incident.StoreTest do
  use ExUnit.Case, async: true

  alias Kubeybilly.Incident.Record
  alias Kubeybilly.Incident.Store

  @workload %{kind: "Deployment", name: "checkout", uid: "uid-1"}

  defp record(id, fields \\ %{}) do
    Record.new(
      Map.merge(
        %{id: id, group_key: "gk-#{id}", namespace: "demo", workload: @workload},
        fields
      )
    )
  end

  defp write!(record, root) do
    :ok = Record.to_disk(record, root: root)
    record
  end

  describe "list/1" do
    @describetag :tmp_dir

    test "returns records newest first by incident id", %{tmp_dir: root} do
      write!(record("20260724T010000Z-aaaa1111"), root)
      write!(record("20260724T020000Z-bbbb2222"), root)

      assert [%Record{id: "20260724T020000Z-bbbb2222"}, %Record{id: "20260724T010000Z-aaaa1111"}] =
               Store.list(root: root)
    end

    test "skips entries that are not readable records", %{tmp_dir: root} do
      write!(record("20260724T010000Z-aaaa1111"), root)
      File.mkdir_p!(Path.join(root, "not-an-incident"))
      File.write!(Path.join([root, "not-an-incident", "record.json"]), "{broken")

      assert [%Record{id: "20260724T010000Z-aaaa1111"}] = Store.list(root: root)
    end

    test "a missing directory is an empty list, not an error", %{tmp_dir: root} do
      assert Store.list(root: Path.join(root, "never-created")) == []
    end
  end

  describe "awaiting_approval?/1" do
    test "true for an open record whose latest approval event is a request" do
      record =
        record("20260724T010000Z-aaaa1111")
        |> Record.append(:opened, %{})
        |> Record.append(:approval_requested, %{verdict: :needs_approval})

      assert Store.awaiting_approval?(record)
    end

    test "still true when alerts keep arriving after the request" do
      record =
        record("20260724T010000Z-aaaa1111")
        |> Record.append(:approval_requested, %{})
        |> Record.append(:alerts_update, %{alerts: 3})

      assert Store.awaiting_approval?(record)
    end

    test "false once the approval was granted" do
      record =
        record("20260724T010000Z-aaaa1111")
        |> Record.append(:approval_requested, %{})
        |> Record.append(:approval_granted, %{})

      refute Store.awaiting_approval?(record)
    end

    test "false for a closed record" do
      record =
        record("20260724T010000Z-aaaa1111")
        |> Record.append(:approval_requested, %{})
        |> Record.close(:escalated)

      refute Store.awaiting_approval?(record)
    end

    test "false when approval was never requested" do
      refute Store.awaiting_approval?(record("20260724T010000Z-aaaa1111"))
    end
  end

  describe "updated_at/1" do
    test "the timestamp of the latest timeline event" do
      record =
        record("20260724T010000Z-aaaa1111")
        |> Record.append(:opened, %{})
        |> Record.append(:evidence_sealed, %{})

      assert {last_at, :evidence_sealed, _detail} = List.last(record.timeline)
      assert Store.updated_at(record) == last_at
    end

    test "nil for an empty timeline" do
      assert Store.updated_at(record("20260724T010000Z-aaaa1111")) == nil
    end
  end
end
