defmodule Kubeybilly.Signatures.ImagepullPostRolloutTest do
  use ExUnit.Case, async: true

  alias Kubeybilly.FixtureBundles
  alias Kubeybilly.Signatures.ImagepullPostRollout
  alias Kubeybilly.Signatures.Signature

  test "matches when the failing image arrived with the newest revision" do
    bundle = FixtureBundles.load!("imagepull-post-rollout")

    assert {:match, %Signature{} = signature} = ImagepullPostRollout.match(bundle)
    assert signature.name == :imagepull_post_rollout
    assert signature.confidence == 0.9

    assert signature.proposed_action == %{
             action: :rollback_deployment,
             params: %{namespace: "demo", name: "web", revision: 1}
           }

    assert signature.rationale =~ "ImagePullBackOff"
    assert signature.rationale =~ "registry.example.com/web:2.0.1"
    assert "pods/demo/web-9f8d7c6b5-aaaaa/status.json" in signature.evidence_refs
    assert "owners/demo/web-revisions.json" in signature.evidence_refs
  end

  test "matches ErrImageNeverPull, the shape kind and imagePullPolicy Never produce" do
    bundle = FixtureBundles.load!("imagepull-never-pull")

    assert {:match, %Signature{} = signature} = ImagepullPostRollout.match(bundle)
    assert signature.name == :imagepull_post_rollout

    assert signature.proposed_action == %{
             action: :rollback_deployment,
             params: %{namespace: "demo", name: "web", revision: 1}
           }

    assert signature.rationale =~ "ErrImageNeverPull"
  end

  test "does not match when the image is unchanged across revisions" do
    bundle = FixtureBundles.load!("imagepull-no-rollout")

    assert ImagepullPostRollout.match(bundle) == :no_match
  end

  test "does not match a bundle without an image pull failure" do
    bundle = FixtureBundles.load!("crashloop-post-rollout")

    assert ImagepullPostRollout.match(bundle) == :no_match
  end
end
