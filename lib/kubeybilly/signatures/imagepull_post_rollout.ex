defmodule Kubeybilly.Signatures.ImagepullPostRollout do
  @moduledoc """
  Detects image pull failures the latest rollout introduced.

  A container stuck in `ImagePullBackOff`/`ErrImagePull` while the newest
  ReplicaSet revision changed the image relative to its predecessor means
  the bad image arrived with the rollout, so the prior revision is
  known-good and a rollback is the deterministic fix. The image comparison
  is what separates this from a registry outage, where rolling back cannot
  help (that case is `imagepull_no_rollout`).
  """

  @behaviour Kubeybilly.Signatures.Matcher

  alias Kubeybilly.Signatures.LoadedBundle
  alias Kubeybilly.Signatures.Revisions
  alias Kubeybilly.Signatures.Signature
  alias Kubeybilly.Soundings.Bundle

  # ErrImageNeverPull is the imagePullPolicy Never shape of the same
  # failure: kind and other side-loaded-image environments produce it
  # instead of a pull back-off.
  @waiting_reasons ["ImagePullBackOff", "ErrImagePull", "ErrImageNeverPull"]

  @impl true
  def match(%LoadedBundle{} = bundle) do
    with [{pod, container_status} | _rest] <-
           LoadedBundle.waiting_pods(bundle, @waiting_reasons),
         {:ok, rollout} <- Revisions.newest_and_previous(bundle),
         true <- image_changed?(rollout) do
      {:match, signature(pod, container_status, rollout)}
    else
      _no_correlated_pull_failure -> :no_match
    end
  end

  defp image_changed?(%{newest: newest, previous: previous}) do
    not MapSet.equal?(Revisions.images(newest), Revisions.images(previous))
  end

  defp signature(pod, container_status, %{owner: owner, newest: newest, previous: previous}) do
    Signature.new(%{
      name: :imagepull_post_rollout,
      confidence: 0.9,
      proposed_action: %{
        action: :rollback_deployment,
        params: %{
          namespace: owner.namespace,
          name: owner.name,
          revision: Revisions.number(previous)
        }
      },
      rationale: rationale(pod, container_status, owner, newest, previous),
      evidence_refs: [
        Bundle.pod_status_path(pod.namespace, pod.name),
        Bundle.owner_revisions_path(owner.namespace, owner.name)
      ]
    })
  end

  defp rationale(pod, container_status, owner, newest, previous) do
    reason = get_in(container_status, ["state", "waiting", "reason"])

    "Pod #{pod.namespace}/#{pod.name} is stuck in #{reason} on image " <>
      "#{container_status["image"]}, and revision #{Revisions.number(newest)} of " <>
      "#{owner.namespace}/#{owner.name} changed the image " <>
      "(#{images_sentence(previous)} -> #{images_sentence(newest)}). The bad image " <>
      "arrived with the rollout; revision #{Revisions.number(previous)} is known-good."
  end

  defp images_sentence(replica_set) do
    replica_set |> Revisions.images() |> Enum.sort() |> Enum.join(", ")
  end
end
