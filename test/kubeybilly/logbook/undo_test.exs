defmodule Kubeybilly.Logbook.UndoTest do
  use ExUnit.Case, async: true

  alias Kubeybilly.Formulary.Action
  alias Kubeybilly.Logbook.Undo

  defp rollback_action do
    %Action{
      name: :rollback_deployment,
      params: %{namespace: "demo", name: "web", to_revision: 1},
      inverse_class: :invertible,
      inverse: %Action{
        name: :rollback_deployment,
        params: %{namespace: "demo", name: "web", to_revision: "2"},
        inverse_class: :invertible
      }
    }
  end

  test "a rollback renders the kubectl undo to the pre-action revision" do
    assert Undo.command(rollback_action()) ==
             "kubectl rollout undo deployment/web --to-revision=2 -n demo"
  end

  test "a scale renders kubectl scale back to the recorded replica count" do
    action = %Action{
      name: :scale,
      params: %{namespace: "shop", kind: "Deployment", name: "carts", replicas: 1},
      inverse_class: :invertible,
      inverse: %Action{
        name: :scale,
        params: %{namespace: "shop", kind: "Deployment", name: "carts", replicas: 3},
        inverse_class: :invertible
      }
    }

    assert Undo.command(action) ==
             "kubectl scale deployment/carts --replicas=3 -n shop"
  end

  test "a cordon renders kubectl uncordon" do
    action = %Action{
      name: :cordon_node,
      params: %{name: "worker-1"},
      inverse_class: :invertible,
      inverse: %Action{
        name: :uncordon_node,
        params: %{name: "worker-1"},
        inverse_class: :invertible
      }
    }

    assert Undo.command(action) == "kubectl uncordon worker-1"
  end

  test "restarts and no_action have nothing to undo" do
    restart = %Action{
      name: :restart_workload,
      params: %{namespace: "demo", kind: "Deployment", name: "web"},
      inverse_class: :irreversible_benign
    }

    no_action = %Action{
      name: :no_action,
      params: %{reason: "declined"},
      inverse_class: :null
    }

    assert Undo.command(restart) == "nothing to undo"
    assert Undo.command(no_action) == "nothing to undo"
    assert Undo.command(nil) == "nothing to undo"
  end

  test "reads string-keyed action maps as written to disk" do
    action = %{
      "name" => "rollback_deployment",
      "params" => %{"namespace" => "demo", "name" => "web", "to_revision" => 1},
      "inverse" => %{
        "name" => "rollback_deployment",
        "params" => %{"namespace" => "demo", "name" => "web", "to_revision" => "2"}
      }
    }

    assert Undo.command(action) ==
             "kubectl rollout undo deployment/web --to-revision=2 -n demo"
  end

  test "a rollback with no recorded inverse admits it has nothing to run" do
    action = %Action{
      name: :rollback_deployment,
      params: %{namespace: "demo", name: "web", to_revision: 1},
      inverse_class: :invertible
    }

    assert Undo.command(action) == "nothing to undo"
  end
end
