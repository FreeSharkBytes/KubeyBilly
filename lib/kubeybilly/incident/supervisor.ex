defmodule Kubeybilly.Incident.Supervisor do
  @moduledoc """
  Spawns one temporary machine per incident.

  Machines are `:temporary` on purpose: a crashed incident process must
  never be restarted into guesswork about a half-executed mutation. The
  monitor marks the record interrupted instead (plan/01, boot and crash
  recovery). `max_children` is the flood-control cap; past it, ingest
  degrades to persisting raw payloads rather than dropping alerts.
  """

  use DynamicSupervisor

  alias Kubeybilly.Incident.Machine

  @default_max_children 50

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_children: Keyword.get(opts, :max_children, @default_max_children)
    )
  end

  @doc "Start an incident machine under the supervisor."
  @spec start_incident(Supervisor.supervisor(), keyword()) ::
          DynamicSupervisor.on_start_child()
  def start_incident(supervisor \\ __MODULE__, machine_opts) do
    DynamicSupervisor.start_child(supervisor, {Machine, machine_opts})
  end
end
