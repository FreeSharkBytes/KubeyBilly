defmodule Kubeybilly.Signatures.LoadedBundle do
  @moduledoc """
  A sealed evidence bundle read off disk into one in-memory value.

  Matchers must be pure functions over frozen evidence, so this module is
  the only place signature code touches the filesystem: everything a
  matcher needs (manifest, pod specs and statuses, logs, events, owners
  with revision history, nodes, the baseline) is loaded up front and the
  matchers see plain data.

  Gaps are tolerated because the writer seals honest partial bundles: a
  missing artifact loads as `nil` (or an absent entry) and each matcher
  decides whether it can still reach a verdict. Malformed JSON is not a
  gap, it is corruption of a sealed record, so it fails the load. SHA-256
  verification is deliberately not done here; hashing is the writer's
  concern and fixtures may be newline-touched in transit.
  """

  @enforce_keys [:dir]
  defstruct dir: nil,
            manifest: nil,
            pods: [],
            events: %{},
            owners: [],
            nodes: %{},
            baseline: nil

  @typedoc "One pod's captured artifacts; absent artifacts are nil."
  @type pod :: %{
          namespace: String.t(),
          name: String.t(),
          spec: map() | nil,
          status: map() | nil,
          logs_current: binary() | nil,
          logs_previous: binary() | nil
        }

  @typedoc "One owning workload with its captured revision history."
  @type owner :: %{
          namespace: String.t(),
          name: String.t(),
          resource: map() | nil,
          revisions: [map()] | nil
        }

  @type t :: %__MODULE__{
          dir: String.t(),
          manifest: map() | nil,
          pods: [pod()],
          events: %{String.t() => [map()]},
          owners: [owner()],
          nodes: %{String.t() => map()},
          baseline: map() | nil
        }

  @doc """
  Load a bundle directory into memory.

  Returns `{:error, {:not_a_directory, dir}}` when the incident directory
  does not exist and `{:error, {:invalid_json, relative_path}}` when a
  captured JSON artifact does not parse.
  """
  @spec load(Path.t()) ::
          {:ok, t()} | {:error, {:not_a_directory, Path.t()} | {:invalid_json, String.t()}}
  def load(dir) do
    if File.dir?(dir) do
      with {:ok, manifest} <- read_json(dir, "manifest.json"),
           {:ok, pods} <- load_pods(dir),
           {:ok, events} <- load_events(dir),
           {:ok, owners} <- load_owners(dir),
           {:ok, nodes} <- load_nodes(dir),
           {:ok, baseline} <- read_json(dir, "metrics/baseline.json") do
        {:ok,
         %__MODULE__{
           dir: dir,
           manifest: manifest,
           pods: pods,
           events: events,
           owners: owners,
           nodes: nodes,
           baseline: baseline
         }}
      end
    else
      {:error, {:not_a_directory, dir}}
    end
  end

  @doc """
  The capture instant recorded in the manifest.

  Matchers correlating rollouts to the incident need one authoritative
  clock; that is the sealed `captured_at`, never the wall clock at match
  time. Returns `:error` when the manifest or timestamp is absent or
  unparseable, which simply means time-correlated signatures cannot fire.
  """
  @spec captured_at(t()) :: {:ok, DateTime.t()} | :error
  def captured_at(%__MODULE__{manifest: %{"captured_at" => stamp}}) when is_binary(stamp) do
    case DateTime.from_iso8601(stamp) do
      {:ok, at, _offset} -> {:ok, at}
      {:error, _reason} -> :error
    end
  end

  def captured_at(%__MODULE__{}), do: :error

  @doc """
  Pods with a container waiting for one of the given reasons.

  Half the signature table starts from "some container is stuck waiting on
  X", so the scan lives here once instead of in every matcher. Returns
  `{pod, container_status}` pairs in the bundle's deterministic pod order.
  """
  @spec waiting_pods(t(), [String.t()]) :: [{pod(), map()}]
  def waiting_pods(%__MODULE__{pods: pods}, reasons) when is_list(reasons) do
    for pod <- pods,
        container_status <- container_statuses(pod),
        get_in(container_status, ["state", "waiting", "reason"]) in reasons,
        do: {pod, container_status}
  end

  defp container_statuses(%{status: status}) do
    status
    |> Kernel.||(%{})
    |> Map.get("containerStatuses")
    |> List.wrap()
  end

  ## Pods

  defp load_pods(dir) do
    dir
    |> Path.join("pods/*/*")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
    |> Enum.sort()
    |> reduce_ok([], fn pod_dir, acc ->
      namespace = pod_dir |> Path.dirname() |> Path.basename()
      name = Path.basename(pod_dir)
      relative = fn file -> "pods/#{namespace}/#{name}/#{file}" end

      with {:ok, spec} <- read_json(dir, relative.("spec.json")),
           {:ok, status} <- read_json(dir, relative.("status.json")) do
        pod = %{
          namespace: namespace,
          name: name,
          spec: spec,
          status: status,
          logs_current: read_text(dir, relative.("logs-current.txt")),
          logs_previous: read_text(dir, relative.("logs-previous.txt"))
        }

        {:ok, acc ++ [pod]}
      end
    end)
  end

  ## Events

  defp load_events(dir) do
    dir
    |> Path.join("events/*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> reduce_ok(%{}, fn path, acc ->
      namespace = Path.basename(path, ".json")

      with {:ok, events} <- read_json(dir, "events/#{namespace}.json") do
        {:ok, Map.put(acc, namespace, List.wrap(events))}
      end
    end)
  end

  ## Owners

  defp load_owners(dir) do
    dir
    |> Path.join("owners/*/*.json")
    |> Path.wildcard()
    |> Enum.map(&Path.basename(&1, ".json"))
    |> Enum.zip(owner_namespaces(dir))
    |> Enum.reject(fn {base, _ns} -> String.ends_with?(base, "-revisions") end)
    |> Enum.sort()
    |> reduce_ok([], fn {name, namespace}, acc ->
      with {:ok, resource} <- read_json(dir, "owners/#{namespace}/#{name}.json"),
           {:ok, revisions} <- read_json(dir, "owners/#{namespace}/#{name}-revisions.json") do
        owner = %{namespace: namespace, name: name, resource: resource, revisions: revisions}
        {:ok, acc ++ [owner]}
      end
    end)
  end

  defp owner_namespaces(dir) do
    dir
    |> Path.join("owners/*/*.json")
    |> Path.wildcard()
    |> Enum.map(&(&1 |> Path.dirname() |> Path.basename()))
  end

  ## Nodes

  defp load_nodes(dir) do
    dir
    |> Path.join("nodes/*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> reduce_ok(%{}, fn path, acc ->
      name = Path.basename(path, ".json")

      with {:ok, node} <- read_json(dir, "nodes/#{name}.json") do
        {:ok, Map.put(acc, name, node)}
      end
    end)
  end

  ## Disk primitives

  defp read_json(dir, relative_path) do
    case File.read(Path.join(dir, relative_path)) do
      {:ok, binary} ->
        case Jason.decode(binary) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _reason} -> {:error, {:invalid_json, relative_path}}
        end

      {:error, _reason} ->
        {:ok, nil}
    end
  end

  defp read_text(dir, relative_path) do
    case File.read(Path.join(dir, relative_path)) do
      {:ok, binary} -> binary
      {:error, _reason} -> nil
    end
  end

  defp reduce_ok(enumerable, initial, fun) do
    Enum.reduce_while(enumerable, {:ok, initial}, fn element, {:ok, acc} ->
      case fun.(element, acc) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
