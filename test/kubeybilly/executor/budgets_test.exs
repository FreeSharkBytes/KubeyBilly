defmodule Kubeybilly.Executor.BudgetsTest do
  use ExUnit.Case, async: true

  alias Kubeybilly.Executor.Budgets
  alias Kubeybilly.Incident.Record

  @budgets %{actions_per_incident: 2, actions_per_hour: 10}

  setup do
    root =
      System.tmp_dir!()
      |> Path.join("kubeybilly-budgets-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    %{root: root}
  end

  defp start_budgets(root) do
    start_supervised!(
      {Budgets, name: nil, root: root},
      id: :"budgets_#{System.unique_integer([:positive])}"
    )
  end

  defp write_record(root, id, events) do
    record =
      Record.new(%{
        id: id,
        group_key: "gk-#{id}",
        namespace: "demo",
        workload: %{kind: "Deployment", name: "web", uid: "uid-#{id}"},
        timeline: events,
        status: :closed,
        outcome: :recovered
      })

    :ok = Record.to_disk(record, root: root)
  end

  defp minutes_ago(minutes) do
    DateTime.utc_now(:second) |> DateTime.add(-minutes * 60, :second)
  end

  describe "server/0" do
    test "resolves to the application-started process by default" do
      assert Budgets.server() == Budgets
    end
  end

  describe "consume/3" do
    test "counts the mutation against both budgets atomically", %{root: root} do
      budgets = start_budgets(root)

      assert {:ok, %{actions_this_incident: 1, actions_this_hour: 1}} =
               Budgets.consume(budgets, "incident-a", @budgets)

      assert {:ok, %{actions_this_incident: 2, actions_this_hour: 2}} =
               Budgets.consume(budgets, "incident-a", @budgets)

      assert Budgets.actions_this_incident(budgets, "incident-a") == 2
      assert Budgets.actions_this_hour(budgets) == 2
    end

    test "refuses past the per-incident budget without incrementing", %{root: root} do
      budgets = start_budgets(root)

      {:ok, _counts} = Budgets.consume(budgets, "incident-a", @budgets)
      {:ok, _counts} = Budgets.consume(budgets, "incident-a", @budgets)

      assert {:error, :budget_exceeded, :actions_per_incident} =
               Budgets.consume(budgets, "incident-a", @budgets)

      assert Budgets.actions_this_incident(budgets, "incident-a") == 2
      assert Budgets.actions_this_hour(budgets) == 2
    end

    test "per-incident counters are independent", %{root: root} do
      budgets = start_budgets(root)

      {:ok, _counts} = Budgets.consume(budgets, "incident-a", @budgets)

      assert {:ok, %{actions_this_incident: 1, actions_this_hour: 2}} =
               Budgets.consume(budgets, "incident-b", @budgets)

      assert Budgets.actions_this_incident(budgets, "incident-a") == 1
      assert Budgets.actions_this_incident(budgets, "incident-b") == 1
      assert Budgets.actions_this_incident(budgets, "incident-unknown") == 0
    end

    test "refuses past the hourly budget across incidents", %{root: root} do
      budgets = start_budgets(root)
      limits = %{actions_per_incident: 10, actions_per_hour: 2}

      {:ok, _counts} = Budgets.consume(budgets, "incident-a", limits)
      {:ok, _counts} = Budgets.consume(budgets, "incident-b", limits)

      assert {:error, :budget_exceeded, :actions_per_hour} =
               Budgets.consume(budgets, "incident-c", limits)

      assert Budgets.actions_this_hour(budgets) == 2
      assert Budgets.actions_this_incident(budgets, "incident-c") == 0
    end

    test "emits telemetry with the outcome", %{root: root} do
      budgets = start_budgets(root)
      parent = self()
      handler_id = "budgets-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:kubeybilly, :executor, :budget],
        fn _event, measurements, metadata, _config ->
          send(parent, {:budget, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, _counts} = Budgets.consume(budgets, "incident-a", %{@budgets | actions_per_hour: 1})

      assert_receive {:budget, %{actions_this_hour: 1},
                      %{incident_id: "incident-a", outcome: :ok}}

      {:error, :budget_exceeded, which} =
        Budgets.consume(budgets, "incident-b", %{@budgets | actions_per_hour: 1})

      assert_receive {:budget, _measurements,
                      %{incident_id: "incident-b", outcome: :budget_exceeded, budget: ^which}}
    end
  end

  describe "boot rebuild" do
    test "rebuilds the hourly count from executed events in the last hour", %{root: root} do
      write_record(root, "recent", [
        {minutes_ago(30), :executed, %{result: %{action: :restart_pod}}}
      ])

      write_record(root, "stale", [
        {minutes_ago(120), :executed, %{result: %{action: :restart_pod}}}
      ])

      budgets = start_budgets(root)

      assert Budgets.actions_this_hour(budgets) == 1
    end

    test "counts reverts but never dry runs", %{root: root} do
      write_record(root, "reverted", [
        {minutes_ago(10), :executed, %{result: %{action: :scale}}},
        {minutes_ago(5), :reverted_hard_stop, %{reverted: true}}
      ])

      write_record(root, "dry", [
        {minutes_ago(10), :executed, %{result: %{dry_run: true, would_execute: %{}}}},
        {minutes_ago(9), :reverted_hard_stop, %{reverted: false, reason: "refused"}}
      ])

      budgets = start_budgets(root)

      assert Budgets.actions_this_hour(budgets) == 2
    end

    test "a rebuilt count still gates the hourly budget", %{root: root} do
      write_record(root, "spent", [
        {minutes_ago(10), :executed, %{result: %{action: :restart_pod}}},
        {minutes_ago(8), :executed, %{result: %{action: :restart_pod}}}
      ])

      budgets = start_budgets(root)
      limits = %{actions_per_incident: 10, actions_per_hour: 2}

      assert {:error, :budget_exceeded, :actions_per_hour} =
               Budgets.consume(budgets, "incident-new", limits)
    end

    test "a missing incidents directory is a fresh install, not an error", %{root: root} do
      budgets = start_budgets(Path.join(root, "does-not-exist"))
      assert Budgets.actions_this_hour(budgets) == 0
    end

    test "unreadable or foreign entries are skipped", %{root: root} do
      File.mkdir_p!(Path.join(root, "garbage"))
      File.write!(Path.join([root, "garbage", "record.json"]), "not json")

      budgets = start_budgets(root)
      assert Budgets.actions_this_hour(budgets) == 0
    end
  end
end
