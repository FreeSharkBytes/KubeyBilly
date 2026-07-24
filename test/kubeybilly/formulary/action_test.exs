defmodule Kubeybilly.Formulary.ActionTest do
  use ExUnit.Case, async: true

  alias Kubeybilly.Formulary.Action

  describe "new/2 builds every public action" do
    test "rollback_deployment is invertible" do
      params = %{namespace: "demo", name: "galley", to_revision: "3"}

      assert {:ok, %Action{} = action} = Action.new(:rollback_deployment, params)
      assert action.name == :rollback_deployment
      assert action.params == params
      assert action.inverse_class == :invertible
      assert action.inverse == nil
      assert action.blast_estimate == 0
      assert action.facts == %{}
    end

    test "rollback_deployment accepts an integer revision" do
      assert {:ok, %Action{}} =
               Action.new(:rollback_deployment, %{
                 namespace: "demo",
                 name: "galley",
                 to_revision: 3
               })
    end

    test "restart_workload is irreversible_benign" do
      assert {:ok, %Action{} = action} =
               Action.new(:restart_workload, %{
                 namespace: "demo",
                 kind: "Deployment",
                 name: "galley"
               })

      assert action.inverse_class == :irreversible_benign
    end

    test "restart_pod is irreversible_benign" do
      assert {:ok, %Action{} = action} =
               Action.new(:restart_pod, %{namespace: "demo", name: "galley-d7c6bc75c-drbdd"})

      assert action.inverse_class == :irreversible_benign
    end

    test "scale is invertible" do
      assert {:ok, %Action{} = action} =
               Action.new(:scale, %{
                 namespace: "demo",
                 kind: "Deployment",
                 name: "galley",
                 replicas: 5
               })

      assert action.inverse_class == :invertible
    end

    test "cordon_node is invertible" do
      assert {:ok, %Action{} = action} = Action.new(:cordon_node, %{name: "worker-1"})
      assert action.inverse_class == :invertible
    end

    test "no_action is a first-class outcome with the null class" do
      assert {:ok, %Action{} = action} =
               Action.new(:no_action, %{reason: "no matching signature"})

      assert action.inverse_class == :null
    end
  end

  describe "new/2 rejects anything outside the closed set" do
    test "an unknown action name" do
      assert {:error, {:invalid_action, %{action: :drain_node, reason: :unknown_action}}} =
               Action.new(:drain_node, %{name: "worker-1"})
    end

    test "uncordon_node is not publicly selectable" do
      assert {:error, {:invalid_action, %{action: :uncordon_node, reason: :unknown_action}}} =
               Action.new(:uncordon_node, %{name: "worker-1"})
    end

    test "missing parameters are reported by key" do
      assert {:error, {:invalid_action, details}} =
               Action.new(:rollback_deployment, %{namespace: "demo"})

      assert details.action == :rollback_deployment
      assert details.missing == [:name, :to_revision]
      assert details.unknown == []
      assert details.invalid == []
    end

    test "unknown parameters are reported by key" do
      assert {:error, {:invalid_action, details}} =
               Action.new(:restart_pod, %{namespace: "demo", name: "web-abc", grace: 0})

      assert details.unknown == [:grace]
    end

    test "a negative replica count is invalid" do
      assert {:error, {:invalid_action, details}} =
               Action.new(:scale, %{
                 namespace: "demo",
                 kind: "Deployment",
                 name: "galley",
                 replicas: -1
               })

      assert details.invalid == [:replicas]
    end

    test "an empty namespace is invalid" do
      assert {:error, {:invalid_action, details}} =
               Action.new(:restart_pod, %{namespace: "", name: "web-abc"})

      assert details.invalid == [:namespace]
    end

    test "a kind outside the mutable set is invalid" do
      assert {:error, {:invalid_action, details}} =
               Action.new(:scale, %{
                 namespace: "demo",
                 kind: "StatefulSet",
                 name: "galley",
                 replicas: 2
               })

      assert details.invalid == [:kind]
    end

    test "a nil revision is invalid" do
      assert {:error, {:invalid_action, details}} =
               Action.new(:rollback_deployment, %{
                 namespace: "demo",
                 name: "galley",
                 to_revision: nil
               })

      assert details.invalid == [:to_revision]
    end

    test "params must be a map" do
      assert {:error, {:invalid_action, %{action: :no_action, reason: :params_not_a_map}}} =
               Action.new(:no_action, reason: "nope")
    end
  end

  describe "internal_new/2" do
    test "builds the uncordon_node inverse action" do
      assert {:ok, %Action{} = action} = Action.internal_new(:uncordon_node, %{name: "worker-1"})
      assert action.name == :uncordon_node
      assert action.inverse_class == :invertible
    end

    test "still validates parameters" do
      assert {:error, {:invalid_action, details}} = Action.internal_new(:uncordon_node, %{})
      assert details.missing == [:name]
    end
  end

  test "names/0 lists exactly the public formulary" do
    assert Action.names() == [
             :rollback_deployment,
             :restart_workload,
             :restart_pod,
             :scale,
             :cordon_node,
             :no_action
           ]
  end
end
