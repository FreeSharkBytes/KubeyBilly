defmodule Kubeybilly.Signatures.NodeNotReadyTest do
  use ExUnit.Case, async: true

  alias Kubeybilly.FixtureBundles
  alias Kubeybilly.Signatures.NodeNotReady
  alias Kubeybilly.Signatures.Signature

  test "matches a node whose Ready condition is false and proposes a cordon" do
    bundle = FixtureBundles.load!("node-not-ready")

    assert {:match, %Signature{} = signature} = NodeNotReady.match(bundle)
    assert signature.name == :node_not_ready
    assert signature.confidence == 0.85

    assert signature.proposed_action == %{
             action: :cordon_node,
             params: %{node: "worker-1"}
           }

    assert signature.rationale =~ "worker-1"
    assert signature.evidence_refs == ["nodes/worker-1.json"]
  end

  test "does not match a bundle whose nodes are all Ready" do
    bundle = FixtureBundles.load!("oomkill-galley")

    assert NodeNotReady.match(bundle) == :no_match
  end
end
