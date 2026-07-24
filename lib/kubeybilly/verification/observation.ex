defmodule Kubeybilly.Verification.Observation do
  @moduledoc """
  One verification poll's read of the cluster, in the baseline's shape.

  The recovered and worse predicates compare a live observation against
  the sealed `metrics/baseline.json` snapshot, so this module reads the
  same fields with the same string keys as `Kubeybilly.Soundings.Baseline`
  writes: replica counts, per-pod phase/readiness/restart counts/node, and
  the ready endpoint count of every Service selecting the workload. On
  top of the baseline's fields it observes what only matters after an
  action: each pod's `pod-template-hash` and termination state, and the
  Deployment's ReplicaSets with their revisions, because rollback
  verification and self-rollout settling are judged on ReplicaSet state.

  Any client error returns `{:error, reason}` for the verifier to count
  as an inconclusive poll; verification never crashes on a flaky read.
  """

  alias Kubeybilly.Soundings.LabelSelector

  @revision_annotation "deployment.kubernetes.io/revision"
  @revision_history_annotation "deployment.kubernetes.io/revision-history"
  @template_hash_label "pod-template-hash"

  @typedoc "Namespace plus owning workload, as the incident record carries them."
  @type target :: %{
          :namespace => String.t(),
          :workload_kind => String.t(),
          :workload_name => String.t(),
          optional(atom()) => term()
        }

  @doc """
  Read the target workload's current state through the given client.

  String keys throughout, mirroring the baseline snapshot, so predicates
  compare one canonical shape instead of two.
  """
  @spec observe(module(), target()) :: {:ok, map()} | {:error, term()}
  def observe(client, %{
        namespace: namespace,
        workload_kind: workload_kind,
        workload_name: workload_name
      }) do
    with {:ok, workload} <- client.get(workload_kind, workload_name, namespace),
         selector = LabelSelector.workload_selector(workload),
         {:ok, pods} <- client.list("Pod", namespace, selector),
         {:ok, replica_sets} <- client.list("ReplicaSet", namespace, selector),
         {:ok, services} <- service_readiness(client, namespace, workload) do
      replica_set_snapshots = Enum.map(replica_sets, &replica_set_snapshot/1)

      {:ok,
       %{
         "desired_replicas" => get_in(workload, ["spec", "replicas"]) || 1,
         "ready_replicas" => get_in(workload, ["status", "readyReplicas"]) || 0,
         "available_replicas" => get_in(workload, ["status", "availableReplicas"]) || 0,
         "revision" => get_in(workload, ["metadata", "annotations", @revision_annotation]),
         "pods" => Map.new(pods, &pod_snapshot/1),
         "services" => services,
         "replica_sets" => replica_set_snapshots,
         "newest_revision" => newest_revision(replica_set_snapshots)
       }}
    end
  end

  ## Pods

  defp pod_snapshot(pod) do
    name = get_in(pod, ["metadata", "name"])

    {name,
     %{
       "phase" => get_in(pod, ["status", "phase"]),
       "ready" => pod_ready?(pod),
       "restart_counts" => restart_counts(pod),
       "node" => get_in(pod, ["spec", "nodeName"]),
       "template_hash" => get_in(pod, ["metadata", "labels", @template_hash_label]),
       "terminating" => get_in(pod, ["metadata", "deletionTimestamp"]) != nil
     }}
  end

  defp pod_ready?(pod) do
    pod
    |> get_in(["status", "conditions"])
    |> List.wrap()
    |> Enum.any?(&(&1["type"] == "Ready" and &1["status"] == "True"))
  end

  defp restart_counts(pod) do
    pod
    |> get_in(["status", "containerStatuses"])
    |> List.wrap()
    |> Map.new(fn status -> {status["name"], status["restartCount"] || 0} end)
  end

  ## ReplicaSets

  defp replica_set_snapshot(replica_set) do
    %{
      "name" => get_in(replica_set, ["metadata", "name"]),
      "revision" => get_in(replica_set, ["metadata", "annotations", @revision_annotation]),
      "revision_history" => revision_history(replica_set),
      "template_hash" => get_in(replica_set, ["metadata", "labels", @template_hash_label]),
      "spec_replicas" => get_in(replica_set, ["spec", "replicas"]) || 0,
      "status_replicas" => get_in(replica_set, ["status", "replicas"]) || 0,
      "ready_replicas" => get_in(replica_set, ["status", "readyReplicas"]) || 0,
      "available_replicas" => get_in(replica_set, ["status", "availableReplicas"]) || 0
    }
  end

  # A rollback reuses the rolled-to ReplicaSet and bumps its revision
  # annotation to a fresh number; the numbers it held before land in this
  # comma-separated history, which is how the predicates recognize the
  # rolled-to ReplicaSet after the deployment controller renumbers it.
  defp revision_history(replica_set) do
    case get_in(replica_set, ["metadata", "annotations", @revision_history_annotation]) do
      history when is_binary(history) -> String.split(history, ",", trim: true)
      _absent -> []
    end
  end

  defp newest_revision(replica_set_snapshots) do
    replica_set_snapshots
    |> Enum.flat_map(fn snapshot ->
      case Integer.parse(snapshot["revision"] || "") do
        {number, ""} -> [number]
        _other -> []
      end
    end)
    |> Enum.max(fn -> nil end)
    |> then(fn
      nil -> nil
      number -> Integer.to_string(number)
    end)
  end

  ## Services

  # Identical membership rule to the baseline: a Service belongs when its
  # selector matches the workload's pod template labels, because those are
  # the Services whose endpoints go dark if this workload does.
  defp service_readiness(client, namespace, workload) do
    template_labels = get_in(workload, ["spec", "template", "metadata", "labels"]) || %{}

    with {:ok, services} <- client.list("Service", namespace, nil) do
      services
      |> Enum.filter(&LabelSelector.selects?(get_in(&1, ["spec", "selector"]), template_labels))
      |> Enum.reduce_while({:ok, %{}}, &collect_service_readiness(client, namespace, &1, &2))
    end
  end

  defp collect_service_readiness(client, namespace, service, {:ok, acc}) do
    name = get_in(service, ["metadata", "name"])

    case ready_endpoints(client, namespace, name) do
      {:ok, count} -> {:cont, {:ok, Map.put(acc, name, %{"ready_endpoints" => count})}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp ready_endpoints(client, namespace, service_name) do
    selector = "kubernetes.io/service-name=#{service_name}"

    with {:ok, slices} <- client.list("EndpointSlice", namespace, selector) do
      count =
        slices
        |> Enum.flat_map(&List.wrap(&1["endpoints"]))
        |> Enum.count(&endpoint_ready?/1)

      {:ok, count}
    end
  end

  # Per the EndpointSlice API, an absent ready condition means the consumer
  # should assume the endpoint is serving, so only an explicit false excludes.
  defp endpoint_ready?(endpoint) do
    get_in(endpoint, ["conditions", "ready"]) != false
  end
end
