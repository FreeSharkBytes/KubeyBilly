defmodule KubeybillyWeb.IncidentDetailLive do
  @moduledoc """
  One incident in full: the timeline, the signature that matched, the
  decision rule chain, the action with its recorded inverse, the
  verification outcome, and a browser over the evidence bundle.

  Everything renders from the on-disk record and manifest; the evidence
  browser reads through `KubeybillyWeb.Evidence`, which confines every
  read to the bundle directory and caps content at 100KB.
  """

  use KubeybillyWeb, :live_view

  alias Kubeybilly.Incident.Broadcaster
  alias Kubeybilly.Incident.Record
  alias Kubeybilly.Soundings.Bundle
  alias KubeybillyWeb.Evidence
  alias KubeybillyWeb.Format

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Record.from_disk(id) do
      {:error, {:record, _reason}} ->
        {:ok,
         socket
         |> put_flash(:error, "No incident #{id} in the log.")
         |> redirect(to: ~p"/")}

      {:ok, record} ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Kubeybilly.PubSub, Broadcaster.topic())
        end

        {:ok,
         socket
         |> assign(:id, id)
         |> assign(:page_title, id)
         |> assign(:selected_path, nil)
         |> assign(:file_result, nil)
         |> load(record)}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:incident_transition, %{incident_id: id}}, %{assigns: %{id: id}} = socket) do
    case Record.from_disk(id) do
      {:ok, record} -> {:noreply, load(socket, record)}
      {:error, _reason} -> {:noreply, socket}
    end
  end

  def handle_info({:incident_transition, _meta}, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select_file", %{"path" => path}, socket) do
    {:noreply,
     socket
     |> assign(:selected_path, path)
     |> assign(:file_result, Evidence.read(bundle_dir(socket.assigns.id), path))}
  end

  defp load(socket, record) do
    dir = bundle_dir(record.id)

    files =
      case Evidence.files(dir) do
        {:ok, files} -> files
        {:error, _reason} -> []
      end

    socket
    |> assign(:record, record)
    |> assign(:files, files)
    |> assign(:log_present, Evidence.log_present?(dir))
  end

  defp bundle_dir(id), do: id |> Bundle.new() |> Bundle.dir()

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        <span class="font-mono">{@record.id}</span>
        <:subtitle>
          {Format.workload(@record)} &middot; status {Format.label(@record.status)} &middot; outcome {Format.label(
            @record.outcome
          )}
        </:subtitle>
      </.header>

      <section id="signature" class="space-y-1">
        <h2 class="text-lg font-semibold">Signature</h2>
        <p :if={@record.signature == nil} class="text-sm opacity-70">No signature matched.</p>
        <dl :if={@record.signature != nil} class="text-sm space-y-1">
          <div>
            <dt class="inline font-medium">Name:</dt>
            <dd class="inline">{Format.label(Format.field(@record.signature, :name))}</dd>
          </div>
          <div>
            <dt class="inline font-medium">Confidence:</dt>
            <dd class="inline">{Format.field(@record.signature, :confidence)}</dd>
          </div>
          <div>
            <dt class="inline font-medium">Rationale:</dt>
            <dd class="inline">{Format.field(@record.signature, :rationale)}</dd>
          </div>
        </dl>
      </section>

      <section id="decision" class="space-y-1">
        <h2 class="text-lg font-semibold">Standing orders decision</h2>
        <p :if={@record.decision == nil} class="text-sm opacity-70">
          The incident never reached the gate.
        </p>
        <div :if={@record.decision != nil} class="text-sm space-y-1">
          <p>
            <span class="font-medium">Verdict:</span>
            {Format.label(Format.field(@record.decision, :verdict))}
            <span class="font-medium">by rule</span>
            <span class="font-mono">{Format.field(@record.decision, :rule_id)}</span>
          </p>
          <p>{Format.field(@record.decision, :reason)}</p>
          <p class="font-medium">Rule chain:</p>
          <ol id="rule-chain" class="list-decimal list-inside font-mono text-xs">
            <li :for={rule <- List.wrap(Format.field(@record.decision, :chain))}>{rule}</li>
          </ol>
        </div>
      </section>

      <section id="action" class="space-y-1">
        <h2 class="text-lg font-semibold">Action</h2>
        <p :if={@record.action == nil} class="text-sm opacity-70">No action was prepared.</p>
        <div :if={@record.action != nil} class="text-sm space-y-1">
          <p>
            <span class="font-medium">{Format.label(Format.field(@record.action, :name))}</span>
            <span class="font-mono text-xs">
              {Format.detail(Format.field(@record.action, :params))}
            </span>
          </p>
          <p>
            <span class="font-medium">Inverse:</span>
            {Format.label(Format.field(Format.field(@record.action, :inverse), :name))}
            <span class="opacity-70">
              (class {Format.label(Format.field(@record.action, :inverse_class))})
            </span>
          </p>
        </div>
      </section>

      <section id="verification" class="space-y-1">
        <h2 class="text-lg font-semibold">Verification</h2>
        <p class="text-sm">
          Outcome: {Format.label(@record.verification_outcome)}
        </p>
      </section>

      <section id="timeline" class="space-y-1">
        <h2 class="text-lg font-semibold">Timeline</h2>
        <div class="overflow-x-auto">
          <table class="table table-zebra w-full">
            <thead>
              <tr>
                <th>When</th>
                <th>Event</th>
                <th>Detail</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={{{at, event, detail}, index} <- Enum.with_index(@record.timeline)}
                id={"timeline-#{index}"}
              >
                <td class="font-mono text-xs whitespace-nowrap">{Format.stamp(at)}</td>
                <td>{Format.label(event)}</td>
                <td class="font-mono text-xs break-all">{Format.detail(detail)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section id="evidence" class="space-y-2">
        <h2 class="text-lg font-semibold">Soundings</h2>
        <p :if={@files == [] and not @log_present} class="text-sm opacity-70">
          No evidence bundle on disk for this incident.
        </p>
        <ul class="text-sm space-y-1">
          <li :for={file <- @files}>
            <button
              type="button"
              phx-click="select_file"
              phx-value-path={file.path}
              class="link font-mono text-xs"
            >
              {file.path}
            </button>
            <span class="opacity-70 text-xs">{Format.bytes(file.bytes)}</span>
          </li>
          <li :if={@log_present}>
            <button
              type="button"
              phx-click="select_file"
              phx-value-path={Evidence.log_file()}
              class="link font-mono text-xs"
            >
              {Evidence.log_file()}
            </button>
            <span class="opacity-70 text-xs">logbook report</span>
          </li>
        </ul>

        <div :if={@file_result != nil} id="file-view" class="space-y-1">
          <h3 class="font-mono text-sm">{@selected_path}</h3>
          <%= case @file_result do %>
            <% {:ok, content} -> %>
              <pre class="bg-base-200 rounded p-3 text-xs overflow-x-auto whitespace-pre-wrap">{content}</pre>
            <% {:error, :traversal} -> %>
              <p class="text-sm text-error">Refused: the path points outside the bundle.</p>
            <% {:error, :too_large} -> %>
              <p class="text-sm text-error">
                Refused: the file is too large to show inline (over 100KB).
              </p>
            <% {:error, :binary} -> %>
              <p class="text-sm text-error">Refused: not a text file.</p>
            <% {:error, :not_found} -> %>
              <p class="text-sm text-error">The file is not in the bundle.</p>
          <% end %>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
