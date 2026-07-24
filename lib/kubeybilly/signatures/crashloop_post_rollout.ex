defmodule Kubeybilly.Signatures.CrashloopPostRollout do
  @moduledoc """
  Detects crash loops that arrived with a fresh rollout.

  `CrashLoopBackOff` plus a newest ReplicaSet revision created inside the
  correlation window before the incident capture means the crash and the
  change are correlated, so rolling back to the previous revision is the
  deterministic fix. The window compares the revision's creation timestamp
  against the sealed `captured_at` in the manifest, never the wall clock,
  so replaying the bundle always reaches the same verdict.
  """

  @behaviour Kubeybilly.Signatures.Matcher

  alias Kubeybilly.Signatures.LoadedBundle
  alias Kubeybilly.Signatures.Revisions
  alias Kubeybilly.Signatures.Signature
  alias Kubeybilly.Soundings.Bundle

  @waiting_reasons ["CrashLoopBackOff"]

  # Fifteen minutes: long enough to cover a rollout that takes a few
  # minutes to start crashing, short enough that an old revision cannot be
  # blamed for an unrelated failure.
  @correlation_window_seconds 15 * 60

  @doc "The rollout-to-incident correlation window, in seconds."
  @spec correlation_window_seconds() :: pos_integer()
  def correlation_window_seconds, do: @correlation_window_seconds

  @impl true
  def match(%LoadedBundle{} = bundle) do
    with [{pod, container_status} | _rest] <-
           LoadedBundle.waiting_pods(bundle, @waiting_reasons),
         {:ok, rollout} <- Revisions.newest_and_previous(bundle),
         {:ok, captured_at} <- LoadedBundle.captured_at(bundle),
         {:ok, rolled_out_at} <- Revisions.created_at(rollout.newest),
         true <- within_window?(captured_at, rolled_out_at) do
      {:match, signature(pod, container_status, rollout)}
    else
      _no_correlated_crashloop -> :no_match
    end
  end

  defp within_window?(captured_at, rolled_out_at) do
    abs(DateTime.diff(captured_at, rolled_out_at)) <= @correlation_window_seconds
  end

  defp signature(pod, container_status, %{owner: owner, newest: newest, previous: previous}) do
    Signature.new(%{
      name: :crashloop_post_rollout,
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
    restarts = container_status["restartCount"] || 0

    "Pod #{pod.namespace}/#{pod.name} is in CrashLoopBackOff " <>
      "(#{restarts} restarts) and revision #{Revisions.number(newest)} of " <>
      "#{owner.namespace}/#{owner.name} rolled out within " <>
      "#{div(@correlation_window_seconds, 60)} minutes of the incident capture. " <>
      "The crash arrived with the change; revision #{Revisions.number(previous)} " <>
      "is known-good."
  end
end
