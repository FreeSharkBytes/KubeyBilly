defmodule Kubeybilly.StandingOrders.DecisionTest do
  use ExUnit.Case, async: true

  alias Kubeybilly.StandingOrders.Decision

  test "carries verdict, deciding rule, chain, and reason" do
    decision = %Decision{
      verdict: :deny,
      rule_id: "kill-switch",
      chain: [],
      reason: "kill switch engaged"
    }

    assert decision.verdict == :deny
    assert decision.rule_id == "kill-switch"
    assert decision.chain == []
    assert decision.reason == "kill switch engaged"
  end

  test "every field is mandatory" do
    assert_raise ArgumentError, fn -> struct!(Decision, verdict: :permit_auto) end
  end
end
