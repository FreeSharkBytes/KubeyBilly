defmodule Kubeybilly.Signatures.MissingConfigTest do
  use ExUnit.Case, async: true

  alias Kubeybilly.FixtureBundles
  alias Kubeybilly.Signatures.MissingConfig
  alias Kubeybilly.Signatures.Signature

  test "matches an event naming a missing ConfigMap" do
    bundle = FixtureBundles.load!("missing-config")

    assert {:match, %Signature{} = signature} = MissingConfig.match(bundle)
    assert signature.name == :missing_config
    assert signature.confidence == 0.85
    assert signature.proposed_action == %{action: :no_action, params: %{}}
    assert signature.rationale =~ ~s(configmap "app-config" not found)
    assert signature.rationale =~ "does not create resources"
    assert signature.evidence_refs == ["events/demo.json"]
  end

  test "does not match a bundle whose events name no missing object" do
    bundle = FixtureBundles.load!("oomkill-galley")

    assert MissingConfig.match(bundle) == :no_match
  end
end
