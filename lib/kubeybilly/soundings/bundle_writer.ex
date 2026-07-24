defmodule Kubeybilly.Soundings.BundleWriter do
  @moduledoc """
  Serializes all writes into one evidence bundle and seals its manifest.

  Collector tasks run concurrently per pod, but the manifest must record an
  exact, ordered account of what landed on disk, so every artifact and gap
  funnels through this GenServer. The manifest file is rewritten after each
  append: a crash mid-capture leaves an honest partial manifest with
  `complete: false` rather than nothing.

  Sealing is a barrier. Once `seal/1` returns, the manifest's `complete`
  flag and `gaps` list are final, nothing further can be written, and only
  then may the pipeline proceed to signature matching and the gate. The
  bundle is complete only when every required artifact was written; gaps on
  optional artifacts (previous logs of a container that never restarted)
  are recorded but do not flip completeness.
  """

  use GenServer

  alias Kubeybilly.Soundings.Bundle

  @artifact_event [:kubeybilly, :soundings, :artifact]
  @seal_event [:kubeybilly, :soundings, :seal]

  ## Client

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Write one artifact and append its hashed entry to the manifest."
  @spec write_artifact(GenServer.server(), String.t(), iodata()) ::
          :ok | {:error, :sealed | File.posix()}
  def write_artifact(writer, relative_path, content) do
    GenServer.call(writer, {:write_artifact, relative_path, content})
  end

  @doc "Record a capture failure as a manifest gap instead of crashing."
  @spec record_gap(GenServer.server(), String.t(), term()) :: :ok | {:error, :sealed}
  def record_gap(writer, relative_path, reason) do
    GenServer.call(writer, {:record_gap, relative_path, reason})
  end

  @doc """
  Record a structural absence: a gap that also waives the requirement.

  For artifacts that cannot exist given the cluster's state (current logs
  of a container that never started), the honest manifest records the gap
  but the bundle stays complete: nothing capturable was missed.
  """
  @spec record_absence(GenServer.server(), String.t(), term()) :: :ok | {:error, :sealed}
  def record_absence(writer, relative_path, reason) do
    GenServer.call(writer, {:record_absence, relative_path, reason})
  end

  @doc """
  Finalize the manifest and return it.

  Required artifacts that never arrived become gaps and force
  `complete: false`. Idempotence is refused loudly: a second seal returns
  `{:error, :already_sealed}` because two seals means a pipeline bug.
  """
  @spec seal(GenServer.server()) :: {:ok, map()} | {:error, :already_sealed | File.posix()}
  def seal(writer) do
    GenServer.call(writer, :seal)
  end

  ## Server

  @impl true
  def init(opts) do
    bundle = Keyword.fetch!(opts, :bundle)
    required = Keyword.get(opts, :required, [])

    state = %{
      bundle: bundle,
      required: required,
      captured_at: DateTime.utc_now(:second),
      files: [],
      gaps: [],
      sealed: false
    }

    case File.mkdir_p(Bundle.dir(bundle)) do
      :ok ->
        case write_manifest(state) do
          :ok -> {:ok, state}
          {:error, reason} -> {:stop, {:manifest_stub, reason}}
        end

      {:error, reason} ->
        {:stop, {:mkdir, reason}}
    end
  end

  @impl true
  def handle_call({:write_artifact, _path, _content}, _from, %{sealed: true} = state) do
    {:reply, {:error, :sealed}, state}
  end

  def handle_call({:record_gap, _path, _reason}, _from, %{sealed: true} = state) do
    {:reply, {:error, :sealed}, state}
  end

  def handle_call({:record_absence, _path, _reason}, _from, %{sealed: true} = state) do
    {:reply, {:error, :sealed}, state}
  end

  def handle_call(:seal, _from, %{sealed: true} = state) do
    {:reply, {:error, :already_sealed}, state}
  end

  def handle_call({:write_artifact, path, content}, _from, state) do
    binary = IO.iodata_to_binary(content)

    case persist_artifact(state.bundle, path, binary) do
      :ok ->
        entry = %{
          "path" => path,
          "sha256" => :sha256 |> :crypto.hash(binary) |> Base.encode16(case: :lower),
          "bytes" => byte_size(binary)
        }

        state = %{state | files: state.files ++ [entry]}
        :ok = write_manifest(state)

        :telemetry.execute(@artifact_event, %{bytes: byte_size(binary)}, %{
          path: path,
          incident_id: state.bundle.incident_id
        })

        {:reply, :ok, state}

      {:error, reason} ->
        state = add_gap(state, path, reason)
        :ok = write_manifest(state)
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:record_gap, path, reason}, _from, state) do
    state = add_gap(state, path, reason)
    :ok = write_manifest(state)
    {:reply, :ok, state}
  end

  def handle_call({:record_absence, path, reason}, _from, state) do
    state = %{state | required: List.delete(state.required, path)}
    state = add_gap(state, path, reason)
    :ok = write_manifest(state)
    {:reply, :ok, state}
  end

  def handle_call(:seal, _from, state) do
    state = state |> add_missing_required_gaps() |> Map.put(:sealed, true)
    manifest = manifest(state)

    case do_write_manifest(state.bundle, manifest) do
      :ok ->
        :telemetry.execute(
          @seal_event,
          %{files: length(state.files), gaps: length(state.gaps)},
          %{complete: manifest["complete"], incident_id: state.bundle.incident_id}
        )

        {:reply, {:ok, manifest}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  ## Manifest construction

  defp manifest(state) do
    %{
      "incident_id" => state.bundle.incident_id,
      "captured_at" => DateTime.to_iso8601(state.captured_at),
      "complete" => state.sealed and complete?(state),
      "files" => state.files,
      "gaps" => state.gaps
    }
  end

  defp complete?(state) do
    written = MapSet.new(state.files, & &1["path"])
    Enum.all?(state.required, &MapSet.member?(written, &1))
  end

  defp add_missing_required_gaps(state) do
    written = MapSet.new(state.files, & &1["path"])
    gapped = MapSet.new(state.gaps, & &1["path"])

    state.required
    |> Enum.reject(&(MapSet.member?(written, &1) or MapSet.member?(gapped, &1)))
    |> Enum.reduce(state, &add_gap(&2, &1, :missing))
  end

  defp add_gap(state, path, reason) do
    gap = %{"path" => path, "reason" => format_reason(reason)}
    %{state | gaps: state.gaps ++ [gap]}
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  ## Disk

  defp persist_artifact(bundle, relative_path, binary) do
    absolute = Bundle.absolute(bundle, relative_path)

    with :ok <- File.mkdir_p(Path.dirname(absolute)) do
      File.write(absolute, binary)
    end
  end

  defp write_manifest(state), do: do_write_manifest(state.bundle, manifest(state))

  defp do_write_manifest(bundle, manifest) do
    File.write(
      Bundle.absolute(bundle, Bundle.manifest_path()),
      Jason.encode!(manifest, pretty: true)
    )
  end
end
