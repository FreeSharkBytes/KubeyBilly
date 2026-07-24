defmodule KubeybillyWeb.IncidentListLive do
  @moduledoc """
  The Log: every incident on disk, newest first.

  Disk is the source of truth, so the list is a scan over
  `Kubeybilly.Incident.Store` and live updates are just rescans
  triggered by the "incidents" PubSub topic; the broadcast payload is a
  signal, never data to render.
  """

  use KubeybillyWeb, :live_view

  alias Kubeybilly.Incident.Broadcaster
  alias Kubeybilly.Incident.Store
  alias KubeybillyWeb.Format

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Kubeybilly.PubSub, Broadcaster.topic())
    end

    {:ok, socket |> assign(:page_title, "The Log") |> reload()}
  end

  @impl true
  def handle_info({:incident_transition, _meta}, socket) do
    {:noreply, reload(socket)}
  end

  defp reload(socket), do: assign(socket, :records, Store.list())

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        The Log
        <:subtitle>Every incident KubeyBilly has handled or is handling, newest first.</:subtitle>
      </.header>

      <p :if={@records == []} id="empty-log" class="text-sm opacity-70">
        No incidents in the log. Calm seas.
      </p>

      <div :if={@records != []} class="overflow-x-auto">
        <table id="incidents" class="table table-zebra w-full">
          <thead>
            <tr>
              <th>Incident</th>
              <th>Workload</th>
              <th>Signature</th>
              <th>Status</th>
              <th>Outcome</th>
              <th>Updated</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={record <- @records} id={"incident-#{record.id}"}>
              <td>
                <.link navigate={~p"/incidents/#{record.id}"} class="link font-mono text-xs">
                  {record.id}
                </.link>
              </td>
              <td>{Format.workload(record)}</td>
              <td>{Format.label(Format.field(record.signature, :name))}</td>
              <td>{Format.label(record.status)}</td>
              <td>{Format.label(record.outcome)}</td>
              <td class="font-mono text-xs">{Format.stamp(Store.updated_at(record))}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end
end
