defmodule Kubeybilly.K8sClient.Real do
  @moduledoc """
  The `Kubeybilly.K8sClient` implementation backed by the `k8s` library.

  Operation construction is split from execution so the request shapes are
  unit-testable without a cluster: `build_*` functions are pure and `run/2`
  is the only place a connection is touched. All library errors are mapped
  into the behaviour's tagged tuples here, so callers never see `k8s`
  exceptions or structs.
  """

  @behaviour Kubeybilly.K8sClient

  alias Kubeybilly.K8sClient.Conn

  # The API machinery reason string ("NotFound", "Forbidden", ...) is used as
  # the status because the k8s library surfaces reasons, not numeric codes,
  # and the reason is what signatures and gap entries want to record anyway.
  @api_versions %{
    "Deployment" => "apps/v1",
    "ReplicaSet" => "apps/v1",
    "StatefulSet" => "apps/v1",
    "DaemonSet" => "apps/v1",
    "EndpointSlice" => "discovery.k8s.io/v1"
  }

  ## Behaviour callbacks

  @impl true
  def get(kind, name, namespace) do
    kind |> build_get(name, namespace) |> run()
  end

  @impl true
  def list(kind, namespace, label_selector) do
    case kind |> build_list(namespace, label_selector) |> run() do
      {:ok, %{"items" => items}} -> {:ok, items}
      {:ok, other} -> {:ok, List.wrap(other)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def pod_logs(namespace, pod, container, opts) do
    case namespace |> build_pod_logs(pod, container, opts) |> run() do
      {:ok, logs} when is_binary(logs) -> {:ok, logs}
      {:ok, other} -> {:ok, to_string(other)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def patch(kind, name, namespace, patch) do
    kind |> build_patch(name, namespace, patch) |> run()
  end

  @impl true
  def delete_pod(namespace, pod) do
    namespace |> build_delete_pod(pod) |> run()
  end

  @impl true
  def scale(kind, name, namespace, replicas) do
    kind |> build_scale(name, namespace, replicas) |> run()
  end

  ## Operation construction (pure)

  @doc "Build a get operation for a resource, namespaced or cluster-scoped."
  @spec build_get(String.t(), String.t(), String.t() | nil) :: K8s.Operation.t()
  def build_get(kind, name, namespace) do
    K8s.Client.get(api_version(kind), kind, path_params(name, namespace))
  end

  @doc "Build a list operation, optionally filtered by a label selector string."
  @spec build_list(String.t(), String.t(), String.t() | nil) :: K8s.Operation.t()
  def build_list(kind, namespace, label_selector) do
    op = K8s.Client.list(api_version(kind), kind, namespace: namespace)

    case label_selector do
      nil -> op
      selector -> K8s.Operation.put_query_param(op, :labelSelector, selector)
    end
  end

  @doc "Build a pod log fetch, with `previous: true` for the prior container instance."
  @spec build_pod_logs(String.t(), String.t(), String.t() | nil, keyword()) ::
          K8s.Operation.t()
  def build_pod_logs(namespace, pod, container, opts) do
    op = K8s.Client.get("v1", "pods/log", name: pod, namespace: namespace)

    op =
      case container do
        nil -> op
        name -> K8s.Operation.put_query_param(op, :container, name)
      end

    if Keyword.get(opts, :previous, false) do
      K8s.Operation.put_query_param(op, :previous, true)
    else
      op
    end
  end

  @doc "Build a patch: a list is sent as a JSON patch, a map as a merge patch."
  @spec build_patch(String.t(), String.t(), String.t() | nil, list() | map()) ::
          K8s.Operation.t()
  def build_patch(kind, name, namespace, patch) do
    patch_type = if is_list(patch), do: :json_merge, else: :merge

    K8s.Operation.build(
      :patch,
      api_version(kind),
      kind,
      path_params(name, namespace),
      patch,
      patch_type: patch_type
    )
  end

  @doc "Build a single pod deletion."
  @spec build_delete_pod(String.t(), String.t()) :: K8s.Operation.t()
  def build_delete_pod(namespace, pod) do
    K8s.Client.delete("v1", "Pod", namespace: namespace, name: pod)
  end

  @doc "Build a merge patch of the scale subresource to the given replica count."
  @spec build_scale(String.t(), String.t(), String.t(), non_neg_integer()) ::
          K8s.Operation.t()
  def build_scale(kind, name, namespace, replicas) do
    K8s.Client.patch(
      api_version(kind),
      scale_subresource(kind),
      path_params(name, namespace),
      %{"spec" => %{"replicas" => replicas}},
      :merge
    )
  end

  ## Execution

  @doc """
  Run an operation against the shared connection.

  The only function in this module that performs IO. Errors from the k8s
  library are normalized through `map_error/1`.
  """
  @spec run(K8s.Operation.t(), GenServer.server()) ::
          {:ok, term()} | {:error, Kubeybilly.K8sClient.error()}
  def run(operation, conn_server \\ Conn) do
    with {:ok, conn} <- Conn.get(conn_server) do
      case K8s.Client.run(conn, operation) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, map_error(reason)}
      end
    end
  end

  @doc "Normalize a k8s library failure into the behaviour's error tuples."
  @spec map_error(term()) :: Kubeybilly.K8sClient.error()
  def map_error(%K8s.Client.APIError{reason: reason, message: message}) do
    {:api, reason, message}
  end

  def map_error(%K8s.Client.HTTPError{message: message}) do
    {:transport, message}
  end

  def map_error(reason), do: {:transport, reason}

  ## Helpers

  defp api_version(kind), do: Map.get(@api_versions, kind, "v1")

  defp path_params(name, nil), do: [name: name]
  defp path_params(name, namespace), do: [name: name, namespace: namespace]

  defp scale_subresource(kind), do: String.downcase(kind) <> "s/scale"
end
