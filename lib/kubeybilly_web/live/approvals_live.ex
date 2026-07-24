defmodule KubeybillyWeb.ApprovalsLive do
  @moduledoc """
  The captain's desk: every incident waiting on a human yes.

  An incident is offered only when its record says awaiting approval
  and its machine is still registered, because a dead machine cannot
  receive a verdict (the timeout has already escalated it). The page
  shows exactly what a yes means (action, parameters, and the rule
  chain that routed it here) before the buttons, and the buttons send
  the machine's own approval events (`Machine.approve/1` and
  `Machine.deny/1`), nothing else. The timeout path needs no button:
  it escalates on its own (plan/04).
  """

  use KubeybillyWeb, :live_view

  alias Kubeybilly.Incident.Broadcaster
  alias Kubeybilly.Incident.Machine
  alias Kubeybilly.Incident.Registry, as: IncidentRegistry
  alias Kubeybilly.Incident.Store
  alias KubeybillyWeb.Format

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Kubeybilly.PubSub, Broadcaster.topic())
    end

    {:ok, socket |> assign(:page_title, "Approvals") |> reload()}
  end

  @impl true
  def handle_info({:incident_transition, _meta}, socket) do
    {:noreply, reload(socket)}
  end

  @impl true
  def handle_event("approve", %{"id" => id}, socket) do
    {:noreply, verdict(socket, id, &Machine.approve/1, "Approval sent")}
  end

  def handle_event("deny", %{"id" => id}, socket) do
    {:noreply, verdict(socket, id, &Machine.deny/1, "Denial sent")}
  end

  defp verdict(socket, id, send_verdict, sent_message) do
    case IncidentRegistry.whereis_incident(id) do
      {:ok, pid} ->
        :ok = send_verdict.(pid)
        socket |> put_flash(:info, "#{sent_message} for #{id}.") |> reload()

      :error ->
        socket
        |> put_flash(:error, "Incident #{id} is no longer awaiting approval.")
        |> reload()
    end
  end

  defp reload(socket) do
    awaiting =
      Enum.filter(Store.list(), fn record ->
        Store.awaiting_approval?(record) and
          match?({:ok, _pid}, IncidentRegistry.whereis_incident(record.id))
      end)

    assign(socket, :awaiting, awaiting)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Approvals
        <:subtitle>
          Actions waiting on a human yes. A timeout never proceeds; it escalates.
        </:subtitle>
      </.header>

      <p :if={@awaiting == []} id="empty-approvals" class="text-sm opacity-70">
        Nothing awaiting approval.
      </p>

      <div
        :for={record <- @awaiting}
        id={"approval-#{record.id}"}
        class="card bg-base-200 p-4 space-y-3"
      >
        <div>
          <.link navigate={~p"/incidents/#{record.id}"} class="link font-mono text-sm">
            {record.id}
          </.link>
          <p class="text-sm">{Format.workload(record)}</p>
          <p class="text-sm opacity-70">
            Signature {Format.label(Format.field(record.signature, :name))}, confidence {Format.field(
              record.signature,
              :confidence
            )}
          </p>
        </div>

        <div class="text-sm space-y-1">
          <p>
            <span class="font-medium">Approving executes:</span>
            {Format.label(Format.field(record.action, :name))}
            <span class="font-mono text-xs">{Format.detail(Format.field(record.action, :params))}</span>
          </p>
          <p class="font-medium">Routed here by rule chain:</p>
          <ol class="list-decimal list-inside font-mono text-xs">
            <li :for={rule <- List.wrap(Format.field(record.decision, :chain))}>{rule}</li>
          </ol>
          <p class="opacity-70">{Format.field(record.decision, :reason)}</p>
        </div>

        <div class="flex gap-2">
          <button
            type="button"
            class="btn btn-primary btn-sm"
            phx-click="approve"
            phx-value-id={record.id}
          >Approve</button>
          <button
            type="button"
            class="btn btn-outline btn-sm"
            phx-click="deny"
            phx-value-id={record.id}
          >Deny</button>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
