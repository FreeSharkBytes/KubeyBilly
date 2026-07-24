defmodule Kubeybilly.Signatures.ReadinessPostRolloutTest do
  use ExUnit.Case, async: true

  alias Kubeybilly.FixtureBundles
  alias Kubeybilly.Signatures.ReadinessPostRollout
  alias Kubeybilly.Signatures.Signature

  test "matches new ReplicaSet pods failing readiness while the old one is healthy" do
    bundle = FixtureBundles.load!("readiness-post-rollout")

    assert {:match, %Signature{} = signature} = ReadinessPostRollout.match(bundle)
    assert signature.name == :readiness_post_rollout
    assert signature.confidence == 0.9

    assert signature.proposed_action == %{
             action: :rollback_deployment,
             params: %{namespace: "demo", name: "web", revision: 2}
           }

    assert signature.rationale =~ "readiness"
    assert "pods/demo/web-c3c3c3c3c-eeeee/status.json" in signature.evidence_refs
    assert "owners/demo/web-revisions.json" in signature.evidence_refs
  end

  test "does not match when the previous revision holds no ready replicas" do
    bundle = FixtureBundles.load!("crashloop-post-rollout")

    assert ReadinessPostRollout.match(bundle) == :no_match
  end

  test "does not match a bundle where every pod is ready" do
    bundle = FixtureBundles.load!("oomkill-galley")

    assert ReadinessPostRollout.match(bundle) == :no_match
  end
end
