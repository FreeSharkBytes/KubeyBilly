defmodule Kubeybilly.Incident.Broadcaster do
  @moduledoc """
  Bridges incident telemetry onto the "incidents" PubSub topic.

  The machines already emit a telemetry event on every transition and
  the monitor on every interruption; the dashboard needs those facts as
  PubSub messages to live-update. One handler forwards the metadata
  unchanged as `{:incident_transition, meta}`, so LiveViews reload from
  disk on any signal instead of trusting the payload, which keeps disk
  the single source of truth.

  Runs as a supervision child the way Recovery does: attach during
  start, leave no process behind.
  """

  @topic "incidents"
  @handler_id "kubeybilly-incident-broadcaster"
  @events [
    [:kubeybilly, :incident, :transition],
    [:kubeybilly, :incident, :interrupted]
  ]

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :worker
    }
  end

  @doc "Attach during supervisor start; no process is left behind."
  @spec start_link(keyword()) :: :ignore
  def start_link(_opts) do
    :ok = attach()
    :ignore
  end

  @doc "The PubSub topic the dashboard subscribes to."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Attach the telemetry handler; attaching twice is a no-op."
  @spec attach() :: :ok
  def attach do
    case :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc false
  @spec handle_event([atom()], map(), map(), term()) :: :ok
  def handle_event(_event, _measurements, meta, _config) do
    Phoenix.PubSub.broadcast(Kubeybilly.PubSub, @topic, {:incident_transition, meta})
  end
end
