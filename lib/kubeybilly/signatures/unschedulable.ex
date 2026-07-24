defmodule Kubeybilly.Signatures.Unschedulable do
  @moduledoc """
  Detects pods the scheduler has explicitly given up on.

  A `PodScheduled` condition of false with reason `Unschedulable` is the
  scheduler's own verdict, so the evidence is unambiguous, but capacity
  and affinity problems have no entry in the formulary: nothing a first
  responder can restart or roll back will create room on a node. The
  proposal is `no_action` carrying the scheduler's message, which is
  exactly what the human needs to size the fix.
  """

  @behaviour Kubeybilly.Signatures.Matcher

  alias Kubeybilly.Signatures.LoadedBundle
  alias Kubeybilly.Signatures.Signature
  alias Kubeybilly.Soundings.Bundle

  @impl true
  def match(%LoadedBundle{} = bundle) do
    bundle.pods
    |> Enum.find_value(fn pod ->
      case unschedulable_condition(pod) do
        nil -> nil
        condition -> {pod, condition}
      end
    end)
    |> case do
      nil -> :no_match
      {pod, condition} -> {:match, signature(pod, condition)}
    end
  end

  defp unschedulable_condition(pod) do
    pod.status
    |> Kernel.||(%{})
    |> Map.get("conditions")
    |> List.wrap()
    |> Enum.find(fn condition ->
      condition["type"] == "PodScheduled" and condition["status"] == "False" and
        condition["reason"] == "Unschedulable"
    end)
  end

  defp signature(pod, condition) do
    Signature.new(%{
      name: :unschedulable,
      confidence: 0.9,
      proposed_action: %{action: :no_action, params: %{}},
      rationale:
        "Pod #{pod.namespace}/#{pod.name} is unschedulable: " <>
          "#{condition["message"] || "no scheduler message recorded"}. Capacity and " <>
          "affinity problems are not in the formulary; escalating with the evidence.",
      evidence_refs: [Bundle.pod_status_path(pod.namespace, pod.name)]
    })
  end
end
