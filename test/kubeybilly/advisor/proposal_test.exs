defmodule Kubeybilly.Advisor.ProposalTest do
  use ExUnit.Case, async: true

  alias Kubeybilly.Advisor.Proposal

  @valid %{
    action: :restart_pod,
    params: %{"namespace" => "demo", "name" => "galley-1"},
    confidence: 0.6,
    rationale: "restart clears the wedged state"
  }

  describe "validate/1 accepts" do
    test "a well-formed atom-keyed map" do
      assert {:ok, %Proposal{action: :restart_pod, confidence: 0.6} = proposal} =
               Proposal.validate(@valid)

      assert proposal.params == @valid.params
      assert proposal.rationale == @valid.rationale
    end

    test "a string-keyed map with a string action, as models emit" do
      raw = %{
        "action" => "rollback_deployment",
        "params" => %{"namespace" => "demo", "name" => "galley", "to_revision" => 3},
        "confidence" => 0.5,
        "rationale" => "the crash arrived with the rollout"
      }

      assert {:ok, %Proposal{action: :rollback_deployment, confidence: 0.5}} =
               Proposal.validate(raw)
    end

    test "every name in the public formulary" do
      for action <- [
            :rollback_deployment,
            :restart_workload,
            :restart_pod,
            :scale,
            :cordon_node,
            :no_action
          ] do
        assert {:ok, %Proposal{action: ^action}} =
                 Proposal.validate(%{@valid | action: action})
      end
    end

    test "integer confidence at the boundaries, normalized to a float" do
      assert {:ok, %Proposal{confidence: +0.0}} = Proposal.validate(%{@valid | confidence: 0})
      assert {:ok, %Proposal{confidence: 1.0}} = Proposal.validate(%{@valid | confidence: 1})
      assert {:ok, %Proposal{confidence: 1.0}} = Proposal.validate(%{@valid | confidence: 1.0})
    end

    test "an existing struct, returned unchanged" do
      {:ok, proposal} = Proposal.validate(@valid)
      assert {:ok, ^proposal} = Proposal.validate(proposal)
    end
  end

  describe "validate/1 rejects" do
    test "an action outside the formulary" do
      assert {:error, %{invalid: invalid}} =
               Proposal.validate(%{@valid | action: :delete_namespace})

      assert :action in invalid
    end

    test "an internal-only action name" do
      assert {:error, %{invalid: [:action]}} =
               Proposal.validate(%{@valid | action: :uncordon_node})
    end

    test "a string action outside the formulary without creating atoms" do
      assert {:error, %{invalid: [:action]}} =
               Proposal.validate(Map.put(@valid, :action, "drop_all_tables_no_such_atom"))
    end

    test "params that are not a map" do
      assert {:error, %{invalid: [:params]}} =
               Proposal.validate(%{@valid | params: [namespace: "demo"]})
    end

    test "confidence outside 0..1 or non-numeric" do
      for bad <- [-0.1, 1.1, 2, "0.5", nil] do
        assert {:error, %{invalid: [:confidence]}} =
                 Proposal.validate(%{@valid | confidence: bad})
      end
    end

    test "a rationale that is not a binary" do
      assert {:error, %{invalid: [:rationale]}} =
               Proposal.validate(%{@valid | rationale: :because})
    end

    test "missing keys, reported by name" do
      assert {:error, %{missing: missing}} = Proposal.validate(%{})
      assert missing == [:action, :confidence, :params, :rationale]
    end

    test "unknown keys, reported by name" do
      assert {:error, %{unknown: ["kubectl_command"]}} =
               Proposal.validate(Map.put(@valid, "kubectl_command", "delete ns"))
    end

    test "anything that is not a map" do
      assert {:error, %{invalid: [:proposal]}} = Proposal.validate("just do a rollback")
      assert {:error, %{invalid: [:proposal]}} = Proposal.validate(nil)
    end
  end
end
