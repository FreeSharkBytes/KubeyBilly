defmodule Kubeybilly.Soundings.Collector do
  @moduledoc """
  Freezes the evidence for one incident to disk before anything else runs.

  Capture happens in value order because artifacts differ wildly in
  volatility: previous container logs vanish on the next restart, so they
  are requested first, then current logs, then pod statuses and specs,
  events, the owning workload with its revision history, and nodes.
  Per-pod capture fans out under a `Task.Supervisor` so a slow kubelet on
  one node cannot starve the rest.

  A capture failure is never a crash: every `{:error, reason}` from the
  client becomes a manifest gap, and the sealed manifest reports honestly
  whether the bundle is complete. The pipeline downstream trusts the seal,
  not this module.
  """

  alias Kubeybilly.K8sClient
  alias Kubeybilly.Soundings.Baseline
  alias Kubeybilly.Soundings.Bundle
  alias Kubeybilly.Soundings.BundleWriter
  alias Kubeybilly.Soundings.LabelSelector

  @task_supervisor Kubeybilly.Soundings.TaskSupervisor
  @pod_capture_timeout :timer.seconds(30)
  @collect_event [:kubeybilly, :soundings, :collect]

  @typedoc """
  What to capture: the incident, its namespace, the owning workload, and
  the involved pod and node names (already correlated upstream).
  """
  @type target :: %{
          incident_id: String.t(),
          namespace: String.t(),
          workload_kind: String.t(),
          workload_name: String.t(),
          pods: [String.t()],
          nodes: [String.t()]
        }

  @doc """
  Collect the full evidence bundle for a target and seal it.

  Returns the sealed manifest. `{:error, reason}` only for failures that
  prevent the bundle from existing at all (bad target, unwritable disk);
  partial capture is a sealed manifest with gaps, not an error.
  """
  @spec collect(target(), keyword()) :: {:ok, map()} | {:error, term()}
  def collect(target, opts \\ [])

  def collect(
        %{
          incident_id: incident_id,
          namespace: namespace,
          workload_kind: workload_kind,
          workload_name: workload_name,
          pods: pods,
          nodes: nodes
        } = target,
        opts
      ) do
    bundle = Bundle.new(incident_id, Keyword.take(opts, [:root]))
    client = Keyword.get(opts, :client, K8sClient.impl())
    required = required_artifacts(namespace, workload_name, pods, nodes)

    with {:ok, writer} <- BundleWriter.start_link(bundle: bundle, required: required) do
      capture_pods(writer, client, namespace, pods)
      capture_events(writer, client, namespace)
      capture_owner(writer, client, workload_kind, namespace, workload_name)
      capture_nodes(writer, client, nodes)
      capture_baseline(writer, client, target)

      result = BundleWriter.seal(writer)
      GenServer.stop(writer)

      with {:ok, manifest} <- result do
        :telemetry.execute(@collect_event, %{pods: length(pods)}, %{
          incident_id: incident_id,
          complete: manifest["complete"]
        })

        {:ok, manifest}
      end
    end
  end

  def collect(_target, _opts), do: {:error, :invalid_target}

  ## Required set

  # Previous logs are deliberately absent: they only exist once a container
  # has restarted, so their absence is a recorded gap, not incompleteness.
  defp required_artifacts(namespace, workload_name, pods, nodes) do
    pod_artifacts =
      Enum.flat_map(pods, fn pod ->
        [
          Bundle.pod_logs_current_path(namespace, pod),
          Bundle.pod_status_path(namespace, pod),
          Bundle.pod_spec_path(namespace, pod)
        ]
      end)

    node_artifacts = Enum.map(nodes, &Bundle.node_path/1)

    pod_artifacts ++
      [
        Bundle.events_path(namespace),
        Bundle.owner_path(namespace, workload_name),
        Bundle.owner_revisions_path(namespace, workload_name),
        Bundle.baseline_path()
      ] ++ node_artifacts
  end

  ## Pods

  defp capture_pods(writer, client, namespace, pods) do
    @task_supervisor
    |> Task.Supervisor.async_stream_nolink(
      pods,
      &capture_pod(writer, client, namespace, &1),
      timeout: @pod_capture_timeout,
      on_timeout: :kill_task
    )
    |> Enum.zip(pods)
    |> Enum.each(fn
      {{:ok, _result}, _pod} -> :ok
      {{:exit, reason}, pod} -> record_pod_crash(writer, namespace, pod, reason)
    end)
  end

  # Value order within one pod: previous logs are the most volatile artifact
  # in the whole bundle and must be requested before anything else.
  defp capture_pod(writer, client, namespace, pod) do
    capture_pod_logs(writer, client, namespace, pod, previous: true)
    capture_pod_logs(writer, client, namespace, pod, previous: false)
    capture_pod_manifest(writer, client, namespace, pod)
  end

  defp capture_pod_logs(writer, client, namespace, pod, previous: previous) do
    path =
      if previous,
        do: Bundle.pod_logs_previous_path(namespace, pod),
        else: Bundle.pod_logs_current_path(namespace, pod)

    case client.pod_logs(namespace, pod, nil, previous: previous) do
      {:ok, logs} ->
        BundleWriter.write_artifact(writer, path, logs)

      {:error, reason} ->
        if structural_log_absence?(reason) do
          BundleWriter.record_absence(writer, path, reason)
        else
          BundleWriter.record_gap(writer, path, reason)
        end
    end
  end

  # Current logs of a container that never started cannot exist, exactly
  # like previous logs of a container that never restarted: the API's
  # "waiting to start" BadRequest is a structural absence, not a capture
  # failure, so it must not flip the bundle incomplete.
  defp structural_log_absence?({:api, "BadRequest", message}) when is_binary(message) do
    String.contains?(message, "waiting to start")
  end

  defp structural_log_absence?(_reason), do: false

  defp capture_pod_manifest(writer, client, namespace, pod) do
    status_path = Bundle.pod_status_path(namespace, pod)
    spec_path = Bundle.pod_spec_path(namespace, pod)

    case client.get("Pod", pod, namespace) do
      {:ok, pod_resource} ->
        BundleWriter.write_artifact(
          writer,
          status_path,
          encode(Map.get(pod_resource, "status", %{}))
        )

        BundleWriter.write_artifact(writer, spec_path, encode(Map.delete(pod_resource, "status")))

      {:error, reason} ->
        BundleWriter.record_gap(writer, status_path, reason)
        BundleWriter.record_gap(writer, spec_path, reason)
    end
  end

  defp record_pod_crash(writer, namespace, pod, reason) do
    for path <- [
          Bundle.pod_logs_previous_path(namespace, pod),
          Bundle.pod_logs_current_path(namespace, pod),
          Bundle.pod_status_path(namespace, pod),
          Bundle.pod_spec_path(namespace, pod)
        ] do
      BundleWriter.record_gap(writer, path, {:task_exit, reason})
    end
  end

  ## Events

  defp capture_events(writer, client, namespace) do
    path = Bundle.events_path(namespace)

    case client.list("Event", namespace, nil) do
      {:ok, events} -> BundleWriter.write_artifact(writer, path, encode(events))
      {:error, reason} -> BundleWriter.record_gap(writer, path, reason)
    end
  end

  ## Owner and revisions

  defp capture_owner(writer, client, workload_kind, namespace, workload_name) do
    owner_path = Bundle.owner_path(namespace, workload_name)
    revisions_path = Bundle.owner_revisions_path(namespace, workload_name)

    case client.get(workload_kind, workload_name, namespace) do
      {:ok, owner} ->
        BundleWriter.write_artifact(writer, owner_path, encode(owner))
        capture_revisions(writer, client, namespace, revisions_path, owner)

      {:error, reason} ->
        BundleWriter.record_gap(writer, owner_path, reason)
        BundleWriter.record_gap(writer, revisions_path, reason)
    end
  end

  defp capture_revisions(writer, client, namespace, revisions_path, owner) do
    case client.list("ReplicaSet", namespace, LabelSelector.workload_selector(owner)) do
      {:ok, revisions} -> BundleWriter.write_artifact(writer, revisions_path, encode(revisions))
      {:error, reason} -> BundleWriter.record_gap(writer, revisions_path, reason)
    end
  end

  ## Nodes

  defp capture_nodes(writer, client, nodes) do
    Enum.each(nodes, fn node ->
      path = Bundle.node_path(node)

      case client.get("Node", node, nil) do
        {:ok, resource} -> BundleWriter.write_artifact(writer, path, encode(resource))
        {:error, reason} -> BundleWriter.record_gap(writer, path, reason)
      end
    end)
  end

  ## Baseline

  defp capture_baseline(writer, client, target) do
    path = Bundle.baseline_path()

    case Baseline.build(client, target) do
      {:ok, baseline} -> BundleWriter.write_artifact(writer, path, encode(baseline))
      {:error, reason} -> BundleWriter.record_gap(writer, path, reason)
    end
  end

  defp encode(value), do: Jason.encode!(value, pretty: true)
end
