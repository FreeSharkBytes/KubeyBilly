defmodule Kubeybilly.Advisor.StubTest do
  use ExUnit.Case, async: true

  alias Kubeybilly.Advisor.Proposal
  alias Kubeybilly.Advisor.Stub

  describe "propose/1" do
    test "returns a deterministic no_action proposal naming the stub" do
      assert {:ok, raw} = Stub.propose(%{"signature" => "none"})
      assert {:ok, %Proposal{} = proposal} = Proposal.validate(raw)

      assert proposal.action == :no_action
      assert proposal.confidence == 0.0
      assert proposal.params == %{reason: "advisor_stub_active"}
      assert proposal.rationale =~ "stub"
    end

    test "returns the same answer for any summary" do
      assert Stub.propose(%{}) == Stub.propose(%{"anything" => "else"})
    end
  end

  describe "narrate/1" do
    test "returns a short fixed narrative naming the stub" do
      assert {:ok, narrative} = Stub.narrate(%{"incident_id" => "inc-1"})
      assert is_binary(narrative)
      assert narrative =~ "stub"
    end

    test "returns the same narrative for any record" do
      assert Stub.narrate(%{}) == Stub.narrate(%{"incident_id" => "inc-2"})
    end
  end
end
