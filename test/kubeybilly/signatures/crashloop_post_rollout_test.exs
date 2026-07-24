defmodule Kubeybilly.Signatures.CrashloopPostRolloutTest do
  use ExUnit.Case, async: true

  alias Kubeybilly.FixtureBundles
  alias Kubeybilly.Signatures.CrashloopPostRollout
  alias Kubeybilly.Signatures.Signature

  test "matches a crash loop when the newest revision landed inside the window" do
    bundle = FixtureBundles.load!("crashloop-post-rollout")

    assert {:match, %Signature{} = signature} = CrashloopPostRollout.match(bundle)
    assert signature.name == :crashloop_post_rollout
    assert signature.confidence == 0.9

    assert signature.proposed_action == %{
             action: :rollback_deployment,
             params: %{namespace: "demo", name: "web", revision: 1}
           }

    assert signature.rationale =~ "CrashLoopBackOff"
    assert "pods/demo/web-9f8d7c6b5-ccccc/status.json" in signature.evidence_refs
    assert "owners/demo/web-revisions.json" in signature.evidence_refs
  end

  test "does not match a crash loop on a revision hours old" do
    bundle = FixtureBundles.load!("crashloop-stable")

    assert CrashloopPostRollout.match(bundle) == :no_match
  end

  test "does not match a bundle without a crash loop" do
    bundle = FixtureBundles.load!("imagepull-post-rollout")

    assert CrashloopPostRollout.match(bundle) == :no_match
  end
end
