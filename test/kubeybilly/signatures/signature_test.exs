defmodule Kubeybilly.Signatures.SignatureTest do
  use ExUnit.Case, async: true

  alias Kubeybilly.Signatures.Signature

  @valid_fields %{
    name: :oomkilled,
    confidence: 0.9,
    proposed_action: %{action: :no_action, params: %{}},
    rationale: "kubelet already restarts OOMKilled containers",
    evidence_refs: ["pods/demo/web-abc/status.json"]
  }

  describe "new/1" do
    test "builds a signature carrying every field" do
      signature = Signature.new(@valid_fields)

      assert %Signature{
               name: :oomkilled,
               confidence: 0.9,
               proposed_action: %{action: :no_action, params: %{}},
               rationale: "kubelet already restarts OOMKilled containers",
               evidence_refs: ["pods/demo/web-abc/status.json"]
             } = signature
    end

    test "accepts every intent in the action enum" do
      for action <- [
            :rollback_deployment,
            :restart_workload,
            :restart_pod,
            :scale,
            :cordon_node,
            :no_action
          ] do
        fields = %{@valid_fields | proposed_action: %{action: action, params: %{}}}
        assert %Signature{} = Signature.new(fields)
      end
    end

    test "rejects an action outside the intent enum" do
      fields = %{@valid_fields | proposed_action: %{action: :delete_namespace, params: %{}}}

      assert_raise ArgumentError, ~r/delete_namespace/, fn -> Signature.new(fields) end
    end

    test "rejects confidence outside the closed unit interval" do
      assert_raise ArgumentError, ~r/confidence/, fn ->
        Signature.new(%{@valid_fields | confidence: 1.5})
      end

      assert_raise ArgumentError, ~r/confidence/, fn ->
        Signature.new(%{@valid_fields | confidence: -0.1})
      end
    end
  end
end
