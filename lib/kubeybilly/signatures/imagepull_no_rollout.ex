defmodule Kubeybilly.Signatures.ImagepullNoRollout do
  @moduledoc """
  Detects image pull failures with no rollout to blame.

  The same waiting reasons as `imagepull_post_rollout`, but the image is
  unchanged across revisions (or there is no revision history to compare),
  which points at the registry or its credentials rather than at a deploy.
  Rollback cannot fix a registry outage, so the proposal is `no_action`
  with the reason written down; confidence sits below the rollout pair
  because this is diagnosis by exclusion.
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
    case LoadedBundle.waiting_pods(bundle, @waiting_reasons) do
      [] ->
        :no_match

      [{pod, container_status} | _rest] ->
        if rollout_changed_image?(bundle) do
          :no_match
        else
          {:match, signature(pod, container_status)}
        end
    end
  end

  defp rollout_changed_image?(bundle) do
    case Revisions.newest_and_previous(bundle) do
      {:ok, %{newest: newest, previous: previous}} ->
        not MapSet.equal?(Revisions.images(newest), Revisions.images(previous))

      :error ->
        false
    end
  end

  defp signature(pod, container_status) do
    reason = get_in(container_status, ["state", "waiting", "reason"])

    Signature.new(%{
      name: :imagepull_no_rollout,
      confidence: 0.8,
      proposed_action: %{action: :no_action, params: %{}},
      rationale:
        "Pod #{pod.namespace}/#{pod.name} is stuck in #{reason} on image " <>
          "#{container_status["image"]}, but no revision changed the image, so this " <>
          "is a registry or image pull credential problem. Rollback cannot fix a " <>
          "registry outage; escalating with the evidence instead.",
      evidence_refs: [Bundle.pod_status_path(pod.namespace, pod.name)]
    })
  end
end
