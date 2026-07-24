defmodule Kubeybilly.Formulary.RollbackTest do
  use ExUnit.Case, async: true

  import Mox

  alias Kubeybilly.Formulary.Rollback
  alias Kubeybilly.K8sClient.Mock, as: Client

  setup :verify_on_exit!

  @fixtures Path.expand("../../fixtures/incidents/oomkill-galley", __DIR__)

  defp deployment do
    @fixtures |> Path.join("owners/demo/galley.json") |> File.read!() |> Jason.decode!()
  end

  defp replicasets do
    @fixtures |> Path.join("owners/demo/galley-revisions.json") |> File.read!() |> Jason.decode!()
  end

  defp stub_cluster do
    dep = deployment()
    revisions = replicasets()

    expect(Client, :get, fn "Deployment", "galley", "demo" -> {:ok, dep} end)
    expect(Client, :list, fn "ReplicaSet", "demo", "app=galley" -> {:ok, revisions} end)
  end

  describe "plan/4 against the recorded galley incident" do
    test "builds the merge patch for a past revision" do
      stub_cluster()

      assert {:ok, plan} = Rollback.plan("demo", "galley", "3", Client)
      assert plan.from_revision == "5"
      assert plan.to_revision == "3"

      target_rs = Enum.find(replicasets(), &(&1["metadata"]["name"] == "galley-85c59d6b58"))
      expected_template = target_rs["spec"]["template"]

      assert %{"spec" => %{"template" => template}} = plan.patch
      assert template["metadata"]["labels"] == %{"app" => "galley"}
      refute Map.has_key?(template["metadata"]["labels"], "pod-template-hash")
      assert template["spec"] == expected_template["spec"]

      # Revision 3 raised the memory limit to 512Mi; the patch must carry it.
      assert get_in(template, [
               "spec",
               "containers",
               Access.at(0),
               "resources",
               "limits",
               "memory"
             ]) == "512Mi"
    end

    test "accepts an integer target revision" do
      stub_cluster()

      assert {:ok, plan} = Rollback.plan("demo", "galley", 4, Client)
      assert plan.to_revision == "4"
    end

    test "a revision with no surviving ReplicaSet is a tagged error" do
      stub_cluster()

      assert {:error, {:rollback, :revision_not_found, detail}} =
               Rollback.plan("demo", "galley", "2", Client)

      assert detail.to_revision == "2"
      assert detail.available == ["1", "3", "4", "5"]
    end

    test "a ReplicaSet not owned by the Deployment is never a rollback target" do
      dep = deployment()

      impostor =
        replicasets()
        |> Enum.find(&(&1["metadata"]["name"] == "galley-85c59d6b58"))
        |> put_in(["metadata", "ownerReferences", Access.at(0), "uid"], "someone-else")

      expect(Client, :get, fn "Deployment", "galley", "demo" -> {:ok, dep} end)
      expect(Client, :list, fn "ReplicaSet", "demo", "app=galley" -> {:ok, [impostor]} end)

      assert {:error, {:rollback, :revision_not_found, detail}} =
               Rollback.plan("demo", "galley", "3", Client)

      assert detail.available == []
    end

    test "a missing Deployment is a tagged error" do
      expect(Client, :get, fn "Deployment", "galley", "demo" ->
        {:error, {:api, "NotFound", "deployments.apps \"galley\" not found"}}
      end)

      assert {:error, {:rollback, :deployment_missing, _detail}} =
               Rollback.plan("demo", "galley", "3", Client)
    end

    test "a transport failure fetching the Deployment is a tagged error" do
      expect(Client, :get, fn "Deployment", "galley", "demo" ->
        {:error, {:transport, :timeout}}
      end)

      assert {:error, {:rollback, :deployment_unavailable, {:transport, :timeout}}} =
               Rollback.plan("demo", "galley", "3", Client)
    end

    test "a failed ReplicaSet listing is a tagged error" do
      dep = deployment()
      expect(Client, :get, fn "Deployment", "galley", "demo" -> {:ok, dep} end)

      expect(Client, :list, fn "ReplicaSet", "demo", "app=galley" ->
        {:error, {:transport, :closed}}
      end)

      assert {:error, {:rollback, :replicasets_unavailable, {:transport, :closed}}} =
               Rollback.plan("demo", "galley", "3", Client)
    end
  end

  describe "plan_from/3 (pure mechanics)" do
    test "planning to the current revision is mechanically fine" do
      # Whether that is a sensible action is the validator's judgement.
      assert {:ok, plan} = Rollback.plan_from(deployment(), replicasets(), "5")
      assert plan.from_revision == "5"
      assert plan.to_revision == "5"
    end

    test "falls back to owner name matching when the ReplicaSet has no uid reference" do
      dep = deployment()

      revisions =
        Enum.map(replicasets(), fn rs ->
          update_in(rs, ["metadata", "ownerReferences", Access.at(0)], &Map.delete(&1, "uid"))
        end)

      assert {:ok, _plan} = Rollback.plan_from(dep, revisions, "3")
    end
  end
end
