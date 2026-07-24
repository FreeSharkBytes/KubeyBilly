defmodule Kubeybilly.Signatures.NodeNotReady do
  @moduledoc """
  Detects nodes whose Ready condition has gone false or unknown.

  Cordoning stops the scheduler from placing new pods on a sick node
  without touching the workloads already there, which is the least
  invasive way to stop the bleeding. `Unknown` is treated like `False`
  because a kubelet that stopped reporting is exactly the node you do not
  want new pods on. Cordon is an approval-tier action, so confidence sits
  at 0.85: the condition is explicit, but node flapping makes it slightly
  less certain than a rollout correlation.
  """

  @behaviour Kubeybilly.Signatures.Matcher

  alias Kubeybilly.Signatures.LoadedBundle
  alias Kubeybilly.Signatures.Signature
  alias Kubeybilly.Soundings.Bundle

  @not_ready_statuses ["False", "Unknown"]

  @impl true
  def match(%LoadedBundle{} = bundle) do
    bundle.nodes
    |> Enum.sort_by(fn {name, _node} -> name end)
    |> Enum.find(fn {_name, node} -> not_ready?(node) end)
    |> case do
      nil -> :no_match
      {name, node} -> {:match, signature(name, node)}
    end
  end

  defp not_ready?(node) do
    case ready_condition(node) do
      nil -> false
      condition -> condition["status"] in @not_ready_statuses
    end
  end

  defp ready_condition(node) do
    node
    |> get_in(["status", "conditions"])
    |> List.wrap()
    |> Enum.find(&(&1["type"] == "Ready"))
  end

  defp signature(name, node) do
    condition = ready_condition(node)

    Signature.new(%{
      name: :node_not_ready,
      confidence: 0.85,
      proposed_action: %{action: :cordon_node, params: %{node: name}},
      rationale:
        "Node #{name} reports Ready=#{condition["status"]} " <>
          "(#{condition["reason"] || "no reason"}: " <>
          "#{condition["message"] || "no message"}). Cordoning stops the scheduler " <>
          "from placing new pods there without touching running workloads.",
      evidence_refs: [Bundle.node_path(name)]
    })
  end
end
