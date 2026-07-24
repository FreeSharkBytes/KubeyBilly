defmodule Kubeybilly.Signatures.CrashloopStable do
  @moduledoc """
  Detects crash loops on a revision that has not changed recently.

  When nothing rolled out inside the correlation window there is no
  known-good revision to return to, and Kubernetes is already restarting
  the container; another restart adds nothing and burns action budget. The
  proposal is therefore `no_action` with the reason written down, which is
  the honest first-responder answer for an application that started
  crashing on its own.
  """

  @behaviour Kubeybilly.Signatures.Matcher

  alias Kubeybilly.Signatures.CrashloopPostRollout
  alias Kubeybilly.Signatures.LoadedBundle
  alias Kubeybilly.Signatures.Revisions
  alias Kubeybilly.Signatures.Signature
  alias Kubeybilly.Soundings.Bundle

  @waiting_reasons ["CrashLoopBackOff"]

  @impl true
  def match(%LoadedBundle{} = bundle) do
    case LoadedBundle.waiting_pods(bundle, @waiting_reasons) do
      [] ->
        :no_match

      [{pod, container_status} | _rest] ->
        if recent_rollout?(bundle) do
          :no_match
        else
          {:match, signature(pod, container_status)}
        end
    end
  end

  # The exact complement of the post-rollout matcher's correlation: a
  # rollout is recent only when a newest/previous pair exists and the
  # newest revision was created inside the shared window.
  defp recent_rollout?(bundle) do
    with {:ok, rollout} <- Revisions.newest_and_previous(bundle),
         {:ok, captured_at} <- LoadedBundle.captured_at(bundle),
         {:ok, rolled_out_at} <- Revisions.created_at(rollout.newest) do
      abs(DateTime.diff(captured_at, rolled_out_at)) <=
        CrashloopPostRollout.correlation_window_seconds()
    else
      _no_history -> false
    end
  end

  defp signature(pod, container_status) do
    restarts = container_status["restartCount"] || 0

    Signature.new(%{
      name: :crashloop_stable,
      confidence: 0.8,
      proposed_action: %{action: :no_action, params: %{}},
      rationale:
        "Pod #{pod.namespace}/#{pod.name} is in CrashLoopBackOff " <>
          "(#{restarts} restarts) on a revision that has not changed recently. " <>
          "Kubernetes is already restarting it; another restart adds nothing and " <>
          "burns budget. Escalating with the evidence instead.",
      evidence_refs: [Bundle.pod_status_path(pod.namespace, pod.name)]
    })
  end
end
