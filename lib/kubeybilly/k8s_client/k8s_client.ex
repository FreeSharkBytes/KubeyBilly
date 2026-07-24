defmodule Kubeybilly.K8sClient do
  @moduledoc """
  The single boundary between KubeyBilly and the Kubernetes API.

  Every module that needs cluster state depends on this behaviour instead of
  the `k8s` library, so tests drive the whole pipeline through a mock and the
  safety-relevant call surface stays narrow and reviewable. Callbacks return
  tagged tuples and never raise across the boundary.

  The mutating callbacks (`patch/4`, `delete_pod/2`, `scale/4`) are declared
  now so the surface is complete, but only the executor may call them, and it
  does not exist yet.
  """

  @typedoc ~S(A Kubernetes kind, for example "Pod" or "Deployment".)
  @type kind :: String.t()

  @typedoc "A resource or namespace name."
  @type name :: String.t()

  @typedoc "A namespace, or nil for cluster-scoped resources."
  @type namespace :: String.t() | nil

  @typedoc """
  Why a call failed.

  `{:api, status, message}` is a Kubernetes API rejection (status is the
  API machinery reason, for example \"NotFound\"), `{:transport, reason}`
  is a network or HTTP failure, `{:conn, reason}` means no connection
  could be established at all.
  """
  @type error ::
          {:api, status :: String.t(), message :: String.t()}
          | {:transport, term()}
          | {:conn, term()}

  @doc "Fetch a single resource by kind, name, and namespace (nil for cluster-scoped)."
  @callback get(kind(), name(), namespace()) :: {:ok, map()} | {:error, error()}

  @doc "List resources of a kind in a namespace, optionally filtered by label selector."
  @callback list(kind(), namespace(), label_selector :: String.t() | nil) ::
              {:ok, [map()]} | {:error, error()}

  @doc """
  Fetch container logs for a pod.

  `previous: true` requests the logs of the previously terminated container
  instance, the single most volatile artifact soundings captures.
  """
  @callback pod_logs(
              namespace :: String.t(),
              pod :: name(),
              container :: String.t() | nil,
              opts :: [previous: boolean()]
            ) :: {:ok, binary()} | {:error, error()}

  @doc "Apply a JSON patch (list) or merge patch (map) to a resource. Executor only."
  @callback patch(kind(), name(), namespace(), patch :: list() | map()) ::
              {:ok, map()} | {:error, error()}

  @doc "Delete a single pod. Executor only."
  @callback delete_pod(namespace :: String.t(), pod :: name()) ::
              {:ok, map()} | {:error, error()}

  @doc "Patch the scale subresource of a workload to the given replica count. Executor only."
  @callback scale(kind(), name(), namespace(), replicas :: non_neg_integer()) ::
              {:ok, map()} | {:error, error()}

  @doc """
  The configured client implementation.

  Resolved through application config so tests substitute the Mox mock while
  dev and prod use the real client.
  """
  @spec impl() :: module()
  def impl do
    Application.get_env(:kubeybilly, :k8s_client, Kubeybilly.K8sClient.Real)
  end
end
