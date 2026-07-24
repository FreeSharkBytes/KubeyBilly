defmodule Kubeybilly.Soundings.Baseline do
  @moduledoc """
  The pre-action snapshot the verifier judges recovery against.

  Verification cannot use alert state (resolution lags by minutes) so it
  compares live cluster reads against this snapshot, taken during soundings
  before any mutation: replica counts, per-pod phase, readiness, restart
  counts and node, the ready endpoint count of every Service selecting the
  workload, the set of pods Ready right now, and the current Deployment
  revision.

  The baseline is all or nothing: a snapshot with silently missing pieces
  would make the recovered/worse predicates lie, so any failed read fails
  the build and the collector records the whole baseline as a gap.
  """

  alias Kubeybilly.Soundings.LabelSelector

  @revision_annotation "deployment.kubernetes.io/revision"

  @typedoc "Namespace plus owning workload, as the collector's target carries them."
  @type target :: %{
          :namespace => String.t(),
          :workload_kind => String.t(),
          :workload_name => String.t(),
          optional(atom()) => term()
        }

  @doc """
  Build the baseline snapshot through the given client.

  String keys throughout because the snapshot is written to and read back
  from JSON, and one canonical shape beats two.
  """
  @spec build(module(), target()) :: {:ok, map()} | {:error, term()}
  def build(client, %{
        namespace: namespace,
        workload_kind: workload_kind,
        workload_name: workload_name
      }) do
    with {:ok, workload} <- client.get(workload_kind, workload_name, namespace),
         selector = LabelSelector.workload_selector(workload),
         {:ok, pods} <- client.list("Pod", namespace, selector),
         {:ok, {services, namespace_services}} <- service_readiness(client, namespace, workload) do
      pod_snapshots = Map.new(pods, &pod_snapshot/1)

      {:ok,
       %{
         "workload" => %{
           "kind" => workload_kind,
           "name" => workload_name,
           "namespace" => namespace
         },
         "desired_replicas" => get_in(workload, ["spec", "replicas"]) || 1,
         "ready_replicas" => get_in(workload, ["status", "readyReplicas"]) || 0,
         "available_replicas" => get_in(workload, ["status", "availableReplicas"]) || 0,
         "revision" => get_in(workload, ["metadata", "annotations", @revision_annotation]),
         "pods" => pod_snapshots,
         "ready_pods" => ready_pods(pod_snapshots),
         "services" => services,
         "namespace_services" => namespace_services
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
       "node" => get_in(pod, ["spec", "nodeName"])
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

  defp ready_pods(pod_snapshots) do
    for {name, %{"ready" => true}} <- pod_snapshots, do: name
  end

  ## Services

  # Two views over one namespace listing. "services" keeps only the
  # Services selecting the workload's pod template labels: those are the
  # ones whose endpoints go dark if this workload does, and the ones the
  # verifier judges recovery against. "namespace_services" keeps every
  # selectored Service in the namespace, because the upstream dependency
  # check needs to see a dead dependency (a database with zero ready
  # endpoints) that does not select this workload at all. Selectorless
  # Services are excluded from both: their empty slice sets would read
  # as permanent outages.
  defp service_readiness(client, namespace, workload) do
    template_labels = get_in(workload, ["spec", "template", "metadata", "labels"]) || %{}

    with {:ok, services} <- client.list("Service", namespace, nil),
         selectored = Enum.filter(services, &selectored?/1),
         {:ok, namespace_services} <-
           Enum.reduce_while(
             selectored,
             {:ok, %{}},
             &collect_service_readiness(client, namespace, &1, &2)
           ) do
      selecting_names =
        for service <- selectored,
            LabelSelector.selects?(get_in(service, ["spec", "selector"]), template_labels),
            do: get_in(service, ["metadata", "name"])

      {:ok, {Map.take(namespace_services, selecting_names), namespace_services}}
    end
  end

  defp selectored?(service) do
    case get_in(service, ["spec", "selector"]) do
      selector when is_map(selector) and map_size(selector) > 0 -> true
      _no_selector -> false
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
