defmodule Kubeybilly.Soundings.Bundle do
  @moduledoc """
  Identifies an incident's evidence bundle and owns its on-disk layout.

  Every consumer of evidence (signature matchers, the report generator, the
  dashboard) navigates the same deterministic layout, so the path scheme
  lives in exactly one module. Artifact paths are relative to the bundle
  directory because that is how the manifest records them; `absolute/2`
  turns them into filesystem paths.
  """

  @enforce_keys [:incident_id, :root]
  defstruct [:incident_id, :root]

  @type t :: %__MODULE__{incident_id: String.t(), root: String.t()}

  @doc """
  Build a bundle handle for an incident.

  The root directory comes from `config :kubeybilly, :incidents_dir`
  (default "incidents") unless overridden, which tests do to write under a
  tmp dir.
  """
  @spec new(String.t(), keyword()) :: t()
  def new(incident_id, opts \\ []) do
    root =
      Keyword.get_lazy(opts, :root, fn ->
        Application.get_env(:kubeybilly, :incidents_dir, "incidents")
      end)

    %__MODULE__{incident_id: incident_id, root: root}
  end

  @doc """
  Derive the incident id from an Alertmanager group key and a timestamp.

  `<utc-timestamp>-<8-hex-of-groupKey-hash>`: sortable on disk, stable
  across restarts, derivable from the alert payload alone.
  """
  @spec incident_id(String.t(), DateTime.t()) :: String.t()
  def incident_id(group_key, %DateTime{} = at) do
    stamp = at |> DateTime.truncate(:second) |> Calendar.strftime("%Y%m%dT%H%M%SZ")

    hash =
      :sha256
      |> :crypto.hash(group_key)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 8)

    stamp <> "-" <> hash
  end

  @doc "The bundle's directory on disk."
  @spec dir(t()) :: Path.t()
  def dir(%__MODULE__{root: root, incident_id: id}), do: Path.join(root, id)

  @doc "Join a manifest-relative artifact path onto the bundle directory."
  @spec absolute(t(), String.t()) :: Path.t()
  def absolute(%__MODULE__{} = bundle, relative_path) do
    Path.join(dir(bundle), relative_path)
  end

  @doc "Relative path of a pod's spec artifact."
  @spec pod_spec_path(String.t(), String.t()) :: String.t()
  def pod_spec_path(namespace, pod), do: "pods/#{namespace}/#{pod}/spec.json"

  @doc "Relative path of a pod's status artifact."
  @spec pod_status_path(String.t(), String.t()) :: String.t()
  def pod_status_path(namespace, pod), do: "pods/#{namespace}/#{pod}/status.json"

  @doc "Relative path of a pod's current container logs."
  @spec pod_logs_current_path(String.t(), String.t()) :: String.t()
  def pod_logs_current_path(namespace, pod), do: "pods/#{namespace}/#{pod}/logs-current.txt"

  @doc "Relative path of a pod's previous container logs, the most volatile artifact."
  @spec pod_logs_previous_path(String.t(), String.t()) :: String.t()
  def pod_logs_previous_path(namespace, pod), do: "pods/#{namespace}/#{pod}/logs-previous.txt"

  @doc "Relative path of a namespace's events artifact."
  @spec events_path(String.t()) :: String.t()
  def events_path(namespace), do: "events/#{namespace}.json"

  @doc "Relative path of the owning workload's artifact."
  @spec owner_path(String.t(), String.t()) :: String.t()
  def owner_path(namespace, name), do: "owners/#{namespace}/#{name}.json"

  @doc "Relative path of the owning workload's revision history."
  @spec owner_revisions_path(String.t(), String.t()) :: String.t()
  def owner_revisions_path(namespace, name), do: "owners/#{namespace}/#{name}-revisions.json"

  @doc "Relative path of a node's artifact."
  @spec node_path(String.t()) :: String.t()
  def node_path(node), do: "nodes/#{node}.json"

  @doc "Relative path of the verification baseline snapshot."
  @spec baseline_path() :: String.t()
  def baseline_path, do: "metrics/baseline.json"

  @doc "Relative path of the bundle manifest."
  @spec manifest_path() :: String.t()
  def manifest_path, do: "manifest.json"
end
