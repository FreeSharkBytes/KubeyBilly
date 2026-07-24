defmodule Kubeybilly.Executor.Budgets do
  @moduledoc """
  Owns the action budget counters the executor spends against.

  One process serializes every check-and-increment, so two incidents
  racing for the last budgeted action can never both win: `consume/3` is
  atomic by construction. Reverts pass through the same gate as
  mitigations, because plan/04 is explicit that a revert counts.

  At boot the hourly count is rebuilt by scanning the incident records
  on disk for mutation events in the last hour, so a restart can never
  reset spent budget (plan/01). Per-incident counts start empty on
  purpose: boot recovery closes every open incident as interrupted, so
  no incident that could still act survives a restart.
  """

  use GenServer

  alias Kubeybilly.Incident.Record

  @hour_seconds 3_600
  @budget_event [:kubeybilly, :executor, :budget]

  @typedoc "The counts after a successful consume."
  @type counts :: %{actions_this_incident: pos_integer(), actions_this_hour: pos_integer()}

  @typedoc "The budget limits to consume against, as the policy carries them."
  @type limits :: %{
          :actions_per_incident => pos_integer(),
          :actions_per_hour => pos_integer(),
          optional(atom()) => term()
        }

  @doc """
  Start the counter process.

  Options: `:root` overrides the incidents directory scanned at boot,
  `:name` overrides (or with nil, suppresses) registration; both exist
  so tests run isolated instances beside the application-started one.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Atomically check both budgets and count the mutation.

  Refusal names the exhausted budget and increments nothing; the
  per-incident budget is checked first, matching the evaluation order in
  plan/04.
  """
  @spec consume(GenServer.server(), String.t(), limits()) ::
          {:ok, counts()} | {:error, :budget_exceeded, :actions_per_incident | :actions_per_hour}
  def consume(server \\ __MODULE__, incident_id, limits) do
    GenServer.call(server, {:consume, incident_id, limits})
  end

  @doc "Mutations counted against the incident so far."
  @spec actions_this_incident(GenServer.server(), String.t()) :: non_neg_integer()
  def actions_this_incident(server \\ __MODULE__, incident_id) do
    GenServer.call(server, {:actions_this_incident, incident_id})
  end

  @doc "Mutations counted in the sliding hour window."
  @spec actions_this_hour(GenServer.server()) :: non_neg_integer()
  def actions_this_hour(server \\ __MODULE__) do
    GenServer.call(server, :actions_this_hour)
  end

  ## GenServer callbacks

  @impl GenServer
  def init(opts) do
    root =
      Keyword.get_lazy(opts, :root, fn ->
        Application.get_env(:kubeybilly, :incidents_dir, "incidents")
      end)

    {:ok, %{hour: rebuild(root, DateTime.utc_now(:second)), incidents: %{}}}
  end

  @impl GenServer
  def handle_call({:consume, incident_id, limits}, _from, state) do
    now = DateTime.utc_now(:second)
    state = prune(state, now)
    spent = Map.get(state.incidents, incident_id, 0)

    cond do
      spent >= Map.fetch!(limits, :actions_per_incident) ->
        refuse(state, incident_id, :actions_per_incident)

      length(state.hour) >= Map.fetch!(limits, :actions_per_hour) ->
        refuse(state, incident_id, :actions_per_hour)

      true ->
        counts = %{actions_this_incident: spent + 1, actions_this_hour: length(state.hour) + 1}
        emit(counts, %{incident_id: incident_id, outcome: :ok})

        {:reply, {:ok, counts},
         %{
           hour: [now | state.hour],
           incidents: Map.put(state.incidents, incident_id, spent + 1)
         }}
    end
  end

  def handle_call({:actions_this_incident, incident_id}, _from, state) do
    {:reply, Map.get(state.incidents, incident_id, 0), state}
  end

  def handle_call(:actions_this_hour, _from, state) do
    state = prune(state, DateTime.utc_now(:second))
    {:reply, length(state.hour), state}
  end

  defp refuse(state, incident_id, budget) do
    emit(
      %{
        actions_this_incident: Map.get(state.incidents, incident_id, 0),
        actions_this_hour: length(state.hour)
      },
      %{incident_id: incident_id, outcome: :budget_exceeded, budget: budget}
    )

    {:reply, {:error, :budget_exceeded, budget}, state}
  end

  defp prune(state, now) do
    horizon = DateTime.add(now, -@hour_seconds, :second)
    %{state | hour: Enum.filter(state.hour, &(DateTime.compare(&1, horizon) == :gt))}
  end

  defp emit(counts, metadata) do
    :telemetry.execute(@budget_event, counts, metadata)
  end

  ## Boot rebuild

  # Disk is the source of truth: every mutation the executor made in the
  # last hour left an event in some record's timeline, and the hourly
  # window is rebuilt from exactly those. Unreadable or foreign entries
  # are skipped, because the rebuild must never prevent boot.
  defp rebuild(root, now) do
    horizon = DateTime.add(now, -@hour_seconds, :second)

    case File.ls(root) do
      {:ok, entries} -> Enum.flat_map(entries, &mutations_since(root, &1, horizon))
      {:error, _reason} -> []
    end
  end

  defp mutations_since(root, id, horizon) do
    case Record.from_disk(id, root: root) do
      {:ok, record} ->
        for {at, event, detail} <- record.timeline,
            DateTime.compare(at, horizon) == :gt,
            mutation?(event, detail),
            do: at

      {:error, _reason} ->
        []
    end
  end

  # An :executed event is a mutation unless the executor answered with a
  # dry run; a :reverted_hard_stop counts only when the revert actually
  # ran (plan/04: reverts spend budget, refusals do not).
  defp mutation?(:executed, detail), do: get_in(detail, ["result", "dry_run"]) != true
  defp mutation?(:reverted_hard_stop, detail), do: detail["reverted"] == true
  defp mutation?(_event, _detail), do: false
end
