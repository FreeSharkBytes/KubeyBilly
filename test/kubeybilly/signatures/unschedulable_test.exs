defmodule Kubeybilly.Signatures.UnschedulableTest do
  use ExUnit.Case, async: true

  alias Kubeybilly.FixtureBundles
  alias Kubeybilly.Signatures.Signature
  alias Kubeybilly.Signatures.Unschedulable

  test "matches a pod the scheduler cannot place" do
    bundle = FixtureBundles.load!("unschedulable")

    assert {:match, %Signature{} = signature} = Unschedulable.match(bundle)
    assert signature.name == :unschedulable
    assert signature.confidence == 0.9
    assert signature.proposed_action == %{action: :no_action, params: %{}}
    assert signature.rationale =~ "Insufficient cpu"
    assert signature.evidence_refs == ["pods/demo/web-9f8d7c6b5-ggggg/status.json"]
  end

  test "does not match scheduled pods" do
    bundle = FixtureBundles.load!("oomkill-galley")

    assert Unschedulable.match(bundle) == :no_match
  end
end
