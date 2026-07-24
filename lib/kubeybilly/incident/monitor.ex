defmodule Kubeybilly.Incident.Monitor do
  @moduledoc """
  Turns an incident machine crash into an honest disk record.

  Machines are temporary and never restarted, because a restarted process
  cannot prove the state of a half-executed mutation. This monitor is the
  other half of that rule: when a watched machine terminates abnormally,
  the incident's disk record is closed as `:interrupted` and escalated,
  so the crash becomes a first responder calling the captain rather than
  a silently vanished incident. Normal termination (a machine closing
  itself) is left alone; the machine already wrote its own outcome.
  """

  use GenServer

  alias Kubeybilly.Incident.Record

  @interrupted_event [:kubeybilly, :incident, :interrupted]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Watch the calling incident machine.

  The incidents root is captured at watch time so a later configuration
  change cannot orphan the record. Watching is best effort: a machine
  must still open when no monitor is running (as in isolated tests).
  """
  @spec watch(GenServer.server(), String.t(), keyword()) :: :ok | :error
  def watch(server \\ __MODULE__, incident_id, opts \\ []) do
    case GenServer.whereis(server) do
      nil -> :error
      _pid -> GenServer.call(server, {:watch, self(), incident_id, root(opts)})
    end
  end

  @impl true
  def init(_opts) do
    {:ok, %{watched: %{}}}
  end

  defp root(opts) do
    Keyword.get_lazy(opts, :root, fn ->
      Application.get_env(:kubeybilly, :incidents_dir, "incidents")
    end)
  end

  @impl true
  def handle_call({:watch, pid, incident_id, root}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, :ok, put_in(state.watched[ref], {incident_id, root})}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    {watch, watched} = Map.pop(state.watched, ref)

    case watch do
      {incident_id, root} ->
        if abnormal?(reason), do: mark_interrupted(incident_id, root, reason)

      nil ->
        :ok
    end

    {:noreply, %{state | watched: watched}}
  end

  defp abnormal?(:normal), do: false
  defp abnormal?(:shutdown), do: false
  defp abnormal?({:shutdown, _reason}), do: false
  defp abnormal?(_reason), do: true

  # Only a record the machine left open needs marking; a closed record
  # already tells the truth about how the incident ended.
  defp mark_interrupted(incident_id, root, reason) do
    with {:ok, record} <- Record.from_disk(incident_id, root: root),
         true <- Record.open?(record),
         :ok <-
           record
           |> Record.close(:interrupted)
           |> Record.append(:interrupted, %{by: :monitor, reason: inspect(reason)})
           |> Record.to_disk(root: root) do
      :telemetry.execute(@interrupted_event, %{system_time: System.system_time()}, %{
        incident_id: incident_id,
        reason: reason
      })
    else
      _closed_or_unreadable -> :ok
    end
  end
end
