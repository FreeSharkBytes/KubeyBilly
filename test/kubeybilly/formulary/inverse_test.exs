defmodule Kubeybilly.Formulary.InverseTest do
  use ExUnit.Case, async: true

  alias Kubeybilly.Formulary.Action
  alias Kubeybilly.Formulary.Inverse

  defp action!(name, params) do
    {:ok, action} = Action.new(name, params)
    action
  end

  describe "invertible actions" do
    test "a rollback's inverse rolls back to the revision current before patching" do
      action =
        action!(:rollback_deployment, %{namespace: "demo", name: "galley", to_revision: "3"})

      assert {:ok, recorded} = Inverse.construct(action, %{current_revision: "5"})

      assert %Action{name: :rollback_deployment} = recorded.inverse
      assert recorded.inverse.params == %{namespace: "demo", name: "galley", to_revision: "5"}
      assert recorded.inverse.inverse == nil
    end

    test "a rollback without a recorded current revision is not permitted" do
      action =
        action!(:rollback_deployment, %{namespace: "demo", name: "galley", to_revision: "3"})

      assert {:error, :inverse_unconstructible} = Inverse.construct(action, %{})

      assert {:error, :inverse_unconstructible} =
               Inverse.construct(action, %{current_revision: nil})
    end

    test "a scale's inverse restores the replicas current before patching" do
      action =
        action!(:scale, %{namespace: "demo", kind: "Deployment", name: "galley", replicas: 5})

      assert {:ok, recorded} = Inverse.construct(action, %{current_replicas: 3})

      assert %Action{name: :scale} = recorded.inverse

      assert recorded.inverse.params == %{
               namespace: "demo",
               kind: "Deployment",
               name: "galley",
               replicas: 3
             }
    end

    test "a scale without recorded current replicas is not permitted" do
      action =
        action!(:scale, %{namespace: "demo", kind: "Deployment", name: "galley", replicas: 5})

      assert {:error, :inverse_unconstructible} = Inverse.construct(action, %{})

      assert {:error, :inverse_unconstructible} =
               Inverse.construct(action, %{current_replicas: -1})
    end

    test "a cordon's inverse is the internal uncordon action" do
      action = action!(:cordon_node, %{name: "worker-1"})

      assert {:ok, recorded} = Inverse.construct(action, %{unschedulable: false})

      assert %Action{name: :uncordon_node} = recorded.inverse
      assert recorded.inverse.params == %{name: "worker-1"}
      assert recorded.inverse.inverse_class == :invertible
    end

    test "the uncordon inverse itself inverts back to cordon" do
      {:ok, action} = Action.internal_new(:uncordon_node, %{name: "worker-1"})

      assert {:ok, recorded} = Inverse.construct(action, %{})
      assert %Action{name: :cordon_node} = recorded.inverse
    end
  end

  describe "declared irreversibility classes" do
    test "restart_workload records no inverse, only its class" do
      action =
        action!(:restart_workload, %{namespace: "demo", kind: "Deployment", name: "galley"})

      assert {:ok, recorded} = Inverse.construct(action, %{live_pod_count: 3})
      assert recorded.inverse == nil
      assert recorded.inverse_class == :irreversible_benign
    end

    test "restart_pod records no inverse, only its class" do
      action = action!(:restart_pod, %{namespace: "demo", name: "galley-a"})

      assert {:ok, recorded} = Inverse.construct(action, %{live_pod_count: 1})
      assert recorded.inverse == nil
      assert recorded.inverse_class == :irreversible_benign
    end

    test "no_action has the null class and no inverse" do
      action = action!(:no_action, %{reason: "nothing matched"})

      assert {:ok, recorded} = Inverse.construct(action, %{})
      assert recorded.inverse == nil
      assert recorded.inverse_class == :null
    end
  end
end
