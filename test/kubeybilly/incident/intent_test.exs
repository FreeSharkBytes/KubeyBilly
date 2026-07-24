defmodule Kubeybilly.Incident.IntentTest do
  use ExUnit.Case, async: true

  alias Kubeybilly.Formulary.Action
  alias Kubeybilly.Incident.Intent
  alias Kubeybilly.Signatures.Signature

  defp signature(action, params, rationale \\ "because the evidence says so") do
    Signature.new(%{
      name: :test_signature,
      confidence: 0.9,
      proposed_action: %{action: action, params: params},
      rationale: rationale,
      evidence_refs: []
    })
  end

  test "maps a rollback intent's revision onto to_revision" do
    signature =
      signature(:rollback_deployment, %{namespace: "demo", name: "web", revision: 1})

    assert {:ok, %Action{name: :rollback_deployment, params: params}} =
             Intent.to_action(signature)

    assert params == %{namespace: "demo", name: "web", to_revision: 1}
  end

  test "passes through a rollback intent already shaped for the formulary" do
    signature =
      signature(:rollback_deployment, %{namespace: "demo", name: "web", to_revision: "3"})

    assert {:ok, %Action{params: %{to_revision: "3"}}} = Intent.to_action(signature)
  end

  test "maps a cordon intent's node onto name" do
    signature = signature(:cordon_node, %{node: "worker-1"})

    assert {:ok, %Action{name: :cordon_node, params: %{name: "worker-1"}}} =
             Intent.to_action(signature)
  end

  test "gives no_action the signature rationale as its reason" do
    signature = signature(:no_action, %{}, "upstream db has zero ready endpoints")

    assert {:ok, %Action{name: :no_action, params: %{reason: reason}}} =
             Intent.to_action(signature)

    assert reason == "upstream db has zero ready endpoints"
  end

  test "passes other intents through unchanged" do
    signature = signature(:restart_pod, %{namespace: "demo", name: "web-1"})

    assert {:ok, %Action{name: :restart_pod, params: %{namespace: "demo", name: "web-1"}}} =
             Intent.to_action(signature)
  end

  test "surfaces formulary rejection of malformed intents" do
    signature = signature(:restart_pod, %{namespace: "demo"})

    assert {:error, {:invalid_action, %{missing: [:name]}}} = Intent.to_action(signature)
  end
end
