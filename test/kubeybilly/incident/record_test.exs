defmodule Kubeybilly.Incident.RecordTest do
  use ExUnit.Case, async: true

  alias Kubeybilly.Incident.Record

  @workload %{kind: "Deployment", name: "web", uid: "uid-1234"}

  defp tmp_root(context) do
    root =
      Path.join(
        System.tmp_dir!(),
        "kubeybilly-record-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    Map.put(context, :root, root)
  end

  setup :tmp_root

  defp new_record(id \\ "20260724T031500Z-a1b2c3d4") do
    Record.new(%{
      id: id,
      group_key: "{}:{alertname=\"KubePodCrashLooping\"}",
      namespace: "demo",
      workload: @workload,
      pods: ["web-9f8d7c6b5-ccccc"],
      nodes: ["worker-1"]
    })
  end

  describe "new/1" do
    test "opens with an empty timeline and no outcome" do
      record = new_record()

      assert record.status == :open
      assert record.outcome == nil
      assert record.timeline == []
      assert Record.open?(record)
    end

    test "rejects a record without an id" do
      assert_raise ArgumentError, fn ->
        Record.new(%{group_key: "gk", namespace: "demo", workload: @workload})
      end
    end
  end

  describe "append/3" do
    test "appends a timestamped event to the timeline in order" do
      record =
        new_record()
        |> Record.append(:opened, %{})
        |> Record.append(:evidence_sealed, %{files: 3})

      assert [{%DateTime{}, :opened, %{}}, {%DateTime{}, :evidence_sealed, %{files: 3}}] =
               record.timeline
    end
  end

  describe "close/2" do
    test "closes with a known outcome" do
      record = Record.close(new_record(), :recovered)

      assert record.status == :closed
      assert record.outcome == :recovered
      refute Record.open?(record)
    end

    test "rejects an unknown outcome" do
      outcome = String.to_existing_atom("error")

      assert_raise FunctionClauseError, fn ->
        Record.close(new_record(), outcome)
      end
    end
  end

  describe "to_disk/2 and from_disk/2" do
    test "round-trips a fresh open record", %{root: root} do
      record = new_record() |> Record.append(:opened, %{"source" => "test"})

      assert :ok = Record.to_disk(record, root: root)
      assert {:ok, loaded} = Record.from_disk(record.id, root: root)

      assert loaded.id == record.id
      assert loaded.group_key == record.group_key
      assert loaded.namespace == "demo"
      assert loaded.workload == @workload
      assert loaded.pods == record.pods
      assert loaded.nodes == record.nodes
      assert loaded.status == :open
      assert loaded.outcome == nil
      assert [{%DateTime{}, :opened, %{"source" => "test"}}] = loaded.timeline
    end

    test "round-trips a closed record with outcome and verification outcome",
         %{root: root} do
      record =
        new_record()
        |> Map.put(:verification_outcome, :recovered)
        |> Record.close(:recovered)
        |> Record.append(:verified_recovered, %{})

      assert :ok = Record.to_disk(record, root: root)
      assert {:ok, loaded} = Record.from_disk(record.id, root: root)

      assert loaded.status == :closed
      assert loaded.outcome == :recovered
      assert loaded.verification_outcome == :recovered
    end

    test "persists structs in timeline details as plain maps", %{root: root} do
      decision = %Kubeybilly.StandingOrders.Decision{
        verdict: :deny,
        rule_id: "scope-namespace",
        chain: ["kill-switch"],
        reason: "namespace out of scope"
      }

      record =
        new_record()
        |> Map.put(:decision, decision)
        |> Record.append(:policy_denied, %{rule_id: "scope-namespace"})

      assert :ok = Record.to_disk(record, root: root)
      assert {:ok, loaded} = Record.from_disk(record.id, root: root)

      assert loaded.decision["verdict"] == "deny"
      assert loaded.decision["rule_id"] == "scope-namespace"
      assert [{_at, :policy_denied, %{"rule_id" => "scope-namespace"}}] = loaded.timeline
    end

    test "from_disk on a missing incident is an error", %{root: root} do
      assert {:error, {:record, :not_found}} = Record.from_disk("nope", root: root)
    end

    test "from_disk rejects an unknown status", %{root: root} do
      dir = Path.join(root, "badstatus")
      File.mkdir_p!(dir)

      File.write!(
        Path.join(dir, "record.json"),
        Jason.encode!(%{"id" => "badstatus", "status" => "pondering"})
      )

      assert {:error, {:record, {:invalid_status, "pondering"}}} =
               Record.from_disk("badstatus", root: root)
    end

    test "from_disk rejects an unknown outcome", %{root: root} do
      dir = Path.join(root, "badoutcome")
      File.mkdir_p!(dir)

      File.write!(
        Path.join(dir, "record.json"),
        Jason.encode!(%{"id" => "badoutcome", "status" => "closed", "outcome" => "vibes"})
      )

      assert {:error, {:record, {:invalid_outcome, "vibes"}}} =
               Record.from_disk("badoutcome", root: root)
    end

    test "from_disk rejects a record without an id", %{root: root} do
      dir = Path.join(root, "anonymous")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "record.json"), Jason.encode!(%{"status" => "open"}))

      assert {:error, {:record, {:invalid_record, _decoded}}} =
               Record.from_disk("anonymous", root: root)
    end

    test "a foreign timeline event name survives as a string", %{root: root} do
      dir = Path.join(root, "foreign")
      File.mkdir_p!(dir)

      File.write!(
        Path.join(dir, "record.json"),
        Jason.encode!(%{
          "id" => "foreign",
          "status" => "open",
          "timeline" => [["2026-07-24T03:15:00Z", "not_an_existing_atom_xyzzy", %{}]]
        })
      )

      assert {:ok, record} = Record.from_disk("foreign", root: root)
      assert [{%DateTime{}, "not_an_existing_atom_xyzzy", %{}}] = record.timeline
    end

    test "from_disk on corrupt json is an error", %{root: root} do
      dir = Path.join(root, "corrupt")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "record.json"), "{not json")

      assert {:error, {:record, {:invalid_json, _path}}} =
               Record.from_disk("corrupt", root: root)
    end

    test "to_disk writes into the configured incidents dir by default", %{root: root} do
      previous = Application.get_env(:kubeybilly, :incidents_dir)
      Application.put_env(:kubeybilly, :incidents_dir, root)
      on_exit(fn -> Application.put_env(:kubeybilly, :incidents_dir, previous) end)

      record = new_record("20260724T031500Z-default00")
      assert :ok = Record.to_disk(record)
      assert File.exists?(Path.join([root, record.id, "record.json"]))
      assert {:ok, _loaded} = Record.from_disk(record.id)
    end
  end
end
