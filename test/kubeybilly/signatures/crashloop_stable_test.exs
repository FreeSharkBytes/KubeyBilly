defmodule Kubeybilly.Signatures.CrashloopStableTest do
  use ExUnit.Case, async: true

  alias Kubeybilly.FixtureBundles
  alias Kubeybilly.Signatures.CrashloopStable
  alias Kubeybilly.Signatures.Signature

  test "matches a crash loop on a stable revision and declines to act" do
    bundle = FixtureBundles.load!("crashloop-stable")

    assert {:match, %Signature{} = signature} = CrashloopStable.match(bundle)
    assert signature.name == :crashloop_stable
    assert signature.confidence == 0.8
    assert signature.proposed_action == %{action: :no_action, params: %{}}
    assert signature.rationale =~ "already restarting"
    assert "pods/demo/web-9f8d7c6b5-ddddd/status.json" in signature.evidence_refs
  end

  test "does not match a crash loop correlated with a fresh rollout" do
    bundle = FixtureBundles.load!("crashloop-post-rollout")

    assert CrashloopStable.match(bundle) == :no_match
  end

  test "does not match a bundle without a crash loop" do
    bundle = FixtureBundles.load!("oomkill-galley")

    assert CrashloopStable.match(bundle) == :no_match
  end
end
