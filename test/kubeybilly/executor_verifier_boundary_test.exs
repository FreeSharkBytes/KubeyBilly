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

    expect(Kubeybilly.VerifierMock, :verify, fn ^record, nil, window_seconds: 20 ->
      {:ok, :recovered}
    end)

    assert {:ok, :recovered} = Verifier.impl().verify(record, nil, window_seconds: 20)
  end
end
