defmodule Kubeybilly.Signatures.Oomkilled do
  @moduledoc """
  Detects containers the kernel OOM killer terminated.

  `lastState.terminated.reason == "OOMKilled"` is direct kubelet evidence,
  so confidence is high, yet the proposal is `no_action`: the kubelet
  already restarts OOMKilled containers and the real fix is a memory limit
  change, which is out of scope for a first responder. The value of
  matching at all is the frozen `logs-previous.txt`, captured before the
  next restart destroys it, which the rationale points the human at.
  """

  @behaviour Kubeybilly.Signatures.Matcher

  alias Kubeybilly.Signatures.LoadedBundle
  alias Kubeybilly.Signatures.Signature
  alias Kubeybilly.Soundings.Bundle

  @impl true
  def match(%LoadedBundle{} = bundle) do
    case Enum.find(bundle.pods, &oomkilled_container/1) do
      nil -> :no_match
      pod -> {:match, signature(pod, oomkilled_container(pod))}
    end
  end

  defp oomkilled_container(pod) do
    pod.status
    |> Kernel.||(%{})
    |> Map.get("containerStatuses")
    |> List.wrap()
    |> Enum.find(&(get_in(&1, ["lastState", "terminated", "reason"]) == "OOMKilled"))
  end

  defp signature(pod, container_status) do
    Signature.new(%{
      name: :oomkilled,
      confidence: 0.9,
      proposed_action: %{action: :no_action, params: %{}},
      rationale: rationale(pod, container_status),
      evidence_refs: evidence_refs(pod)
    })
  end

  defp rationale(pod, container_status) do
    "Container #{container_status["name"]} in pod #{pod.namespace}/#{pod.name} was " <>
      "OOMKilled. The kubelet already restarts OOMKilled containers and the fix is a " <>
      "memory limit change, which is out of scope. #{previous_logs_sentence(pod)}"
  end

  defp previous_logs_sentence(%{logs_previous: nil}) do
    "The previous container logs could not be captured before the restart."
  end

  defp previous_logs_sentence(pod) do
    "The logs of the killed container are frozen in the bundle at " <>
      "#{Bundle.pod_logs_previous_path(pod.namespace, pod.name)}."
  end

  defp evidence_refs(%{logs_previous: nil} = pod) do
    [Bundle.pod_status_path(pod.namespace, pod.name)]
  end

  defp evidence_refs(pod) do
    [
      Bundle.pod_status_path(pod.namespace, pod.name),
      Bundle.pod_logs_previous_path(pod.namespace, pod.name)
    ]
  end
end
