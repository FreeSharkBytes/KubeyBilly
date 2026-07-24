defmodule Kubeybilly.Signatures.ImagepullNoRolloutTest do
  use ExUnit.Case, async: true

  alias Kubeybilly.FixtureBundles
  alias Kubeybilly.Signatures.ImagepullNoRollout
  alias Kubeybilly.Signatures.Signature

  test "matches an image pull failure with no image change to blame" do
    bundle = FixtureBundles.load!("imagepull-no-rollout")

    assert {:match, %Signature{} = signature} = ImagepullNoRollout.match(bundle)
    assert signature.name == :imagepull_no_rollout
    assert signature.confidence == 0.8
    assert signature.proposed_action == %{action: :no_action, params: %{}}
    assert signature.rationale =~ "registry"
    assert "pods/demo/web-1a2b3c4d5-bbbbb/status.json" in signature.evidence_refs
  end

  test "does not match when the newest revision changed the image" do
    bundle = FixtureBundles.load!("imagepull-post-rollout")

    assert ImagepullNoRollout.match(bundle) == :no_match
  end

  test "does not match a bundle without an image pull failure" do
    bundle = FixtureBundles.load!("oomkill-galley")

    assert ImagepullNoRollout.match(bundle) == :no_match
  end
end
