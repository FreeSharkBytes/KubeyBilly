defmodule Kubeybilly.ExecutorVerifierBoundaryTest do
  use ExUnit.Case, async: true

  import Mox

  alias Kubeybilly.Executor
  alias Kubeybilly.Formulary.Action
  alias Kubeybilly.Incident.Record
  alias Kubeybilly.StandingOrders.Decision
  alias Kubeybilly.Verifier

  setup :verify_on_exit!

  test "test config resolves both boundaries to the Mox mocks" do
    assert Executor.impl() == Kubeybilly.ExecutorMock
    assert Verifier.impl() == Kubeybilly.VerifierMock
  end

  test "the executor mock satisfies the behaviour contract" do
    {:ok, action} = Action.new(:restart_pod, %{namespace: "demo", name: "web-1"})

    decision = %Decision{
      verdict: :permit_auto,
      rule_id: "tier-auto",
      chain: ["tier-auto"],
      reason: "test"
    }

    record =
      Record.new(%{
        id: "20260724T000000Z-deadbeef",
        group_key: "gk",
        namespace: "demo",
        workload: %{kind: "Deployment", name: "web", uid: "u1"}
      })

    expect(Kubeybilly.ExecutorMock, :execute, fn ^action, ^decision, ^record ->
      {:ok, %{dry_run: true}}
    end)

    assert {:ok, %{dry_run: true}} = Executor.impl().execute(action, decision, record)
  end

  test "the verifier mock satisfies the behaviour contract" do
    record =
      Record.new(%{
        id: "20260724T000000Z-cafecafe",
        group_key: "gk",
        namespace: "demo",
        workload: %{kind: "Deployment", name: "web", uid: "u2"}
      })

    detail = %{reason: :recovered_sustained, unmet: [], polls: 2}

    expect(Kubeybilly.VerifierMock, :verify, fn ^record, nil, window_seconds: 20 ->
      {:ok, :recovered, detail}
    end)

    assert {:ok, :recovered, ^detail} = Verifier.impl().verify(record, nil, window_seconds: 20)
  end

  test "the verifier contract carries a diagnosis alongside the outcome" do
    record =
      Record.new(%{
        id: "20260724T000000Z-f00df00d",
        group_key: "gk",
        namespace: "demo",
        workload: %{kind: "Deployment", name: "web", uid: "u3"}
      })

    expect(Kubeybilly.VerifierMock, :verify, fn _record, _baseline, _opts ->
      {:ok, :unchanged, %{reason: :window_expired, unmet: [:rolled_to_available], polls: 7}}
    end)

    assert {:ok, :unchanged, detail} = Verifier.impl().verify(record, nil, [])
    assert detail.reason == :window_expired
    assert detail.unmet == [:rolled_to_available]
    assert detail.polls == 7
  end
end
