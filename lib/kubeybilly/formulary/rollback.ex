defmodule Kubeybilly.Formulary.Rollback do
  @moduledoc """
  Client-side construction of a Deployment rollback, and nothing else.

  There is no rollback verb in the Kubernetes API; `kubectl rollout undo`
  is client-side arithmetic. This module reproduces it: find the
  ReplicaSet whose `deployment.kubernetes.io/revision` annotation matches
  the target and is actually owned by the Deployment, then build the JSON
  merge patch that replaces `spec.template` with that ReplicaSet's
  template minus the `pod-template-hash` label. Construction only; the
  executor makes the patch call, and it does not exist yet.
  """

  alias Kubeybilly.K8sClient
  alias Kubeybilly.Soundings.LabelSelector

  @revision_annotation "deployment.kubernetes.io/revision"
  @pod_template_hash "pod-template-hash"

  @typedoc "A constructed rollback: the patch and both revisions involved."
  @type plan :: %{patch: map(), from_revision: String.t() | nil, to_revision: String.t()}

  @typedoc "Why a rollback could not be constructed."
  @type error ::
          {:rollback, :deployment_missing | :deployment_unavailable | :replicasets_unavailable,
           term()}
          | {:rollback, :revision_not_found, %{to_revision: String.t(), available: [String.t()]}}

  @doc """
  Fetch the Deployment and its ReplicaSets, then construct the rollback.

  The ReplicaSets are listed by the Deployment's own selector, exactly the
  set the Deployment controller manages.
  """
  @spec plan(String.t(), String.t(), String.t() | pos_integer(), module()) ::
          {:ok, plan()} | {:error, error()}
  def plan(namespace, name, to_revision, client \\ K8sClient.impl()) do
    with {:ok, deployment} <- fetch_deployment(client, namespace, name),
         {:ok, replicasets} <- fetch_replicasets(client, namespace, deployment) do
      plan_from(deployment, replicasets, to_revision)
    end
  end

  @doc """
  Construct the rollback from already-fetched resources.

  Pure, so the validator can reuse the resources it fetched for its own
  checks instead of racing a second read against the incident.
  """
  @spec plan_from(map(), [map()], String.t() | pos_integer()) :: {:ok, plan()} | {:error, error()}
  def plan_from(deployment, replicasets, to_revision) do
    target = to_string(to_revision)
    owned = Enum.filter(replicasets, &owned_by?(&1, deployment))

    case Enum.find(owned, &(revision_of(&1) == target)) do
      nil ->
        available = owned |> Enum.map(&revision_of/1) |> Enum.reject(&is_nil/1) |> Enum.sort()
        {:error, {:rollback, :revision_not_found, %{to_revision: target, available: available}}}

      replicaset ->
        {:ok,
         %{
           patch: merge_patch(replicaset),
           from_revision: revision_of(deployment),
           to_revision: target
         }}
    end
  end

  @doc "The resource's revision annotation, nil when absent."
  @spec revision_of(map()) :: String.t() | nil
  def revision_of(resource),
    do: get_in(resource, ["metadata", "annotations", @revision_annotation])

  defp fetch_deployment(client, namespace, name) do
    case client.get("Deployment", name, namespace) do
      {:ok, deployment} -> {:ok, deployment}
      {:error, {:api, "NotFound", _message} = error} -> tagged(:deployment_missing, error)
      {:error, error} -> tagged(:deployment_unavailable, error)
    end
  end

  defp fetch_replicasets(client, namespace, deployment) do
    case client.list("ReplicaSet", namespace, LabelSelector.workload_selector(deployment)) do
      {:ok, replicasets} -> {:ok, replicasets}
      {:error, error} -> tagged(:replicasets_unavailable, error)
    end
  end

  defp tagged(reason, error), do: {:error, {:rollback, reason, error}}

  defp owned_by?(replicaset, deployment) do
    deployment_uid = get_in(deployment, ["metadata", "uid"])
    deployment_name = get_in(deployment, ["metadata", "name"])

    replicaset
    |> get_in(["metadata", "ownerReferences"])
    |> List.wrap()
    |> Enum.any?(fn ref ->
      ref["kind"] == "Deployment" and matches_owner?(ref, deployment_uid, deployment_name)
    end)
  end

  # uid is the authoritative identity; names only stand in when either
  # side lacks one (as replayed or hand-built fixtures sometimes do).
  defp matches_owner?(ref, uid, name) do
    if is_binary(uid) and is_binary(ref["uid"]) do
      ref["uid"] == uid
    else
      ref["name"] == name
    end
  end

  defp merge_patch(replicaset) do
    template =
      replicaset
      |> get_in(["spec", "template"])
      |> strip_pod_template_hash()

    %{"spec" => %{"template" => template}}
  end

  defp strip_pod_template_hash(%{"metadata" => %{"labels" => labels} = metadata} = template) do
    %{template | "metadata" => %{metadata | "labels" => Map.delete(labels, @pod_template_hash)}}
  end

  defp strip_pod_template_hash(template), do: template
end
