defmodule Kubeybilly.Signatures.ReadinessPostRollout do
  @moduledoc """
  Detects the classic bad deploy: new pods never go Ready, old pods were.

  The tell is structural, not temporal: the newest ReplicaSet's pods are
  failing readiness while the previous revision still reports ready
  replicas, which is exactly the shape of a rollout stuck on a readiness
  probe under `maxUnavailable`. Pods are tied to their ReplicaSet through
  the `pod-template-hash` label, the same link Kubernetes itself uses.
  Rolling back to the still-healthy previous revision is the deterministic
  fix.
  """

  @behaviour Kubeybilly.Signatures.Matcher

  alias Kubeybilly.Signatures.LoadedBundle
  alias Kubeybilly.Signatures.Revisions
  alias Kubeybilly.Signatures.Signature
  alias Kubeybilly.Soundings.Bundle

  @template_hash_label "pod-template-hash"

  @impl true
  def match(%LoadedBundle{} = bundle) do
    with {:ok, rollout} <- Revisions.newest_and_previous(bundle),
         true <- Revisions.ready_replicas(rollout.previous) > 0,
         [pod | _rest] <- unready_pods_of_revision(bundle, rollout.newest) do
      {:match, signature(pod, rollout)}
    else
      _no_stuck_rollout -> :no_match
    end
  end

  defp unready_pods_of_revision(bundle, replica_set) do
    hash = Revisions.template_hash(replica_set)

    Enum.filter(bundle.pods, fn pod ->
      hash != nil and pod_template_hash(pod) == hash and readiness_false?(pod)
    end)
  end

  defp pod_template_hash(pod) do
    get_in(pod.spec || %{}, ["metadata", "labels", @template_hash_label])
  end

  defp readiness_false?(pod) do
    pod.status
    |> Kernel.||(%{})
    |> Map.get("conditions")
    |> List.wrap()
    |> Enum.any?(&(&1["type"] == "Ready" and &1["status"] == "False"))
  end

  defp signature(pod, %{owner: owner, newest: newest, previous: previous}) do
    Signature.new(%{
      name: :readiness_post_rollout,
      confidence: 0.9,
      proposed_action: %{
        action: :rollback_deployment,
        params: %{
          namespace: owner.namespace,
          name: owner.name,
          revision: Revisions.number(previous)
        }
      },
      rationale: rationale(pod, owner, newest, previous),
      evidence_refs: [
        Bundle.pod_status_path(pod.namespace, pod.name),
        Bundle.owner_revisions_path(owner.namespace, owner.name)
      ]
    })
  end

  defp rationale(pod, owner, newest, previous) do
    "Pod #{pod.namespace}/#{pod.name} from revision #{Revisions.number(newest)} of " <>
      "#{owner.namespace}/#{owner.name} is failing readiness while revision " <>
      "#{Revisions.number(previous)} still reports " <>
      "#{Revisions.ready_replicas(previous)} ready replica(s). Classic bad deploy; " <>
      "the previous revision is demonstrably healthy."
  end
end
