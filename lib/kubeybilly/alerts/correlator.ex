defmodule Kubeybilly.Alerts.Correlator do
  @moduledoc """
  Buffers alert groups for a few seconds and routes each to exactly one
  incident.

  The buffer absorbs Alertmanager's burstiness; the routing enforces the
  idempotency invariants from plan/01. A firing group whose `groupKey`
  matches an open incident is an update, never a second incident; a
  group targeting a workload that already has an open incident merges
  into it; only a genuinely new target spawns a machine. Resolved groups
  route to the open incident if one exists and are dropped otherwise.
  The buffer is memory-only on purpose: Alertmanager re-delivers on
  `repeat_interval`, so a crash delays an incident, never loses it.
  """

  use GenServer

  alias Kubeybilly.Alerts.Target
  alias Kubeybilly.Incident.Machine
  alias Kubeybilly.Incident.Registry, as: IncidentRegistry
  alias Kubeybilly.Incident.Supervisor, as: IncidentSupervisor
  alias Kubeybilly.StandingOrders.Parser
  alias Kubeybilly.StandingOrders.Policy

  @routed_event [:kubeybilly, :alerts, :correlator]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Accept one alertmanager-shaped alert group map."
  @spec ingest(GenServer.server(), map()) :: :ok
  def ingest(server \\ __MODULE__, group), do: GenServer.cast(server, {:ingest, group})

  @impl true
  def init(opts) do
    {:ok,
     %{
       buffer: %{},
       order: [],
       timer: nil,
       window_ms:
         Keyword.get_lazy(opts, :window_ms, fn ->
           Application.get_env(:kubeybilly, :correlation_window_ms, 3000)
         end),
       machine_opts: resolve_policy(Keyword.get(opts, :machine_opts, [])),
       supervisor: Keyword.get(opts, :supervisor, IncidentSupervisor)
     }}
  end

  # The policy is the safety contract: resolve it once at boot and fail
  # loudly on a broken file rather than correlating without orders.
  defp resolve_policy(machine_opts) do
    Keyword.put_new_lazy(machine_opts, :policy, fn ->
      case Application.get_env(:kubeybilly, :standing_orders_path) do
        nil -> %Policy{tiers: %{"read" => Policy.default_read_tier()}}
        path -> load_policy!(path)
      end
    end)
  end

  defp load_policy!(path) do
    case Parser.load(path) do
      {:ok, policy} -> policy
      {:error, reason} -> raise "standing orders unreadable: #{inspect(reason)}"
    end
  end

  @impl true
  def handle_cast({:ingest, %{"groupKey" => group_key} = group}, state)
      when is_binary(group_key) do
    key = {group_key, group["status"]}

    state =
      if Map.has_key?(state.buffer, key) do
        %{state | buffer: Map.update!(state.buffer, key, &merge_groups(&1, group))}
      else
        %{state | buffer: Map.put(state.buffer, key, group), order: [key | state.order]}
      end

    {:noreply, ensure_timer(state)}
  end

  def handle_cast({:ingest, _group}, state) do
    emit(:dropped, nil, %{reason: :malformed})
    {:noreply, state}
  end

  @impl true
  def handle_info(:flush, state) do
    state.order
    |> Enum.reverse()
    |> Enum.each(&route(state.buffer[&1], state))

    {:noreply, %{state | buffer: %{}, order: [], timer: nil}}
  end

  defp ensure_timer(%{timer: nil} = state) do
    %{state | timer: Process.send_after(self(), :flush, state.window_ms)}
  end

  defp ensure_timer(state), do: state

  # Groups within one window merge their alert lists; Alertmanager sends
  # the whole group each time, so last write wins on everything else.
  defp merge_groups(buffered, group) do
    %{group | "alerts" => List.wrap(buffered["alerts"]) ++ List.wrap(group["alerts"])}
  end

  ## Routing

  defp route(%{"status" => "resolved", "groupKey" => group_key}, _state) do
    case IncidentRegistry.whereis_group_key(group_key) do
      {:ok, pid} ->
        Machine.resolve(pid, group_key)
        emit(:resolved_routed, group_key)

      :error ->
        emit(:resolved_unmatched, group_key)
    end
  end

  defp route(%{"status" => "firing", "groupKey" => group_key} = group, state) do
    case IncidentRegistry.whereis_group_key(group_key) do
      {:ok, pid} ->
        Machine.alerts(pid, group)
        emit(:deduped, group_key)

      :error ->
        spawn_or_merge(group, state)
    end
  end

  defp route(%{"groupKey" => group_key}, _state) do
    emit(:dropped, group_key, %{reason: :unknown_status})
  end

  defp spawn_or_merge(%{"groupKey" => group_key} = group, state) do
    case Target.extract(group) do
      {:error, {:target, reason}} ->
        emit(:dropped, group_key, %{reason: reason})

      {:ok, target} ->
        case IncidentRegistry.whereis_workload(target.namespace, target.workload.uid) do
          {:ok, pid} ->
            # One open incident per workload: the alerts merge into it.
            Machine.alerts(pid, group)
            emit(:merged, group_key)

          :error ->
            start_machine(group_key, target, state)
        end
    end
  end

  defp start_machine(group_key, target, state) do
    machine_opts =
      Keyword.merge(state.machine_opts,
        group_key: group_key,
        namespace: target.namespace,
        workload: target.workload,
        pods: target.pods,
        nodes: target.nodes
      )

    case IncidentSupervisor.start_incident(state.supervisor, machine_opts) do
      {:ok, _pid} -> emit(:spawned, group_key)
      {:error, reason} -> emit(:spawn_failed, group_key, %{reason: inspect(reason)})
    end
  end

  defp emit(action, group_key, extra \\ %{}) do
    :telemetry.execute(
      @routed_event,
      %{system_time: System.system_time()},
      Map.merge(%{action: action, group_key: group_key}, extra)
    )
  end
end
