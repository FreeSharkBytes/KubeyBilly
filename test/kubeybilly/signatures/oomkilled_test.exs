defmodule Kubeybilly.Signatures.OomkilledTest do
  use ExUnit.Case, async: true

  alias Kubeybilly.FixtureBundles
  alias Kubeybilly.Signatures.Oomkilled
  alias Kubeybilly.Signatures.Signature

  test "matches the real oomkill-galley capture" do
    bundle = FixtureBundles.load!("oomkill-galley")

    assert {:match, %Signature{} = signature} = Oomkilled.match(bundle)
    assert signature.name == :oomkilled
    assert signature.confidence == 0.9
    assert signature.proposed_action == %{action: :no_action, params: %{}}
    assert signature.rationale =~ "OOMKilled"
    assert signature.rationale =~ "logs-previous.txt"
    assert "pods/demo/galley-d7c6bc75c-fs89f/status.json" in signature.evidence_refs
    assert "pods/demo/galley-d7c6bc75c-fs89f/logs-previous.txt" in signature.evidence_refs
  end

  test "mentions previous logs as frozen even when the capture gapped them" do
    bundle = FixtureBundles.load!("triage-priority")

    assert {:match, %Signature{} = signature} = Oomkilled.match(bundle)
    assert signature.name == :oomkilled
    refute "pods/demo/web-9f8d7c6b5-jjjjj/logs-previous.txt" in signature.evidence_refs
  end

  test "does not match a crash loop whose last termination was a plain error" do
    bundle = FixtureBundles.load!("crashloop-stable")

    assert Oomkilled.match(bundle) == :no_match
  end
end
