defmodule Kubeybilly.Signatures.LoadedBundleTest do
  use ExUnit.Case, async: true

  alias Kubeybilly.Signatures.LoadedBundle

  @real_bundle "test/fixtures/incidents/oomkill-galley"

  describe "load/1 against the real oomkill-galley capture" do
    setup do
      {:ok, bundle} = LoadedBundle.load(@real_bundle)
      %{bundle: bundle}
    end

    test "reads the sealed manifest", %{bundle: bundle} do
      assert bundle.manifest["incident_id"] == "m1-20260724T050431Z"
      assert bundle.manifest["captured_at"] == "2026-07-24T05:04:31Z"
      assert bundle.manifest["complete"] == true
    end

    test "loads every pod with spec, status, and logs", %{bundle: bundle} do
      assert length(bundle.pods) == 3

      names = Enum.map(bundle.pods, & &1.name)
      assert "galley-d7c6bc75c-fs89f" in names

      pod = Enum.find(bundle.pods, &(&1.name == "galley-d7c6bc75c-fs89f"))
      assert pod.namespace == "demo"
      assert get_in(pod.spec, ["kind"]) == "Pod"
      assert get_in(pod.status, ["phase"]) == "Running"
      assert is_binary(pod.logs_current)
      assert is_binary(pod.logs_previous)
    end

    test "a pod whose previous logs were a capture gap carries nil", %{bundle: bundle} do
      pod = Enum.find(bundle.pods, &(&1.name == "galley-d7c6bc75c-drbdd"))
      assert pod.logs_previous == nil
      assert is_binary(pod.logs_current)
    end

    test "loads events keyed by namespace", %{bundle: bundle} do
      assert [_ | _] = bundle.events["demo"]
    end

    test "loads the owner resource and its revision history", %{bundle: bundle} do
      assert [owner] = bundle.owners
      assert owner.namespace == "demo"
      assert owner.name == "galley"
      assert get_in(owner.resource, ["kind"]) == "Deployment"
      assert length(owner.revisions) == 4
    end

    test "loads nodes keyed by name", %{bundle: bundle} do
      assert %{"kubeybilly-control-plane" => node} = bundle.nodes
      assert get_in(node, ["kind"]) == "Node"
    end

    test "loads the baseline snapshot", %{bundle: bundle} do
      assert bundle.baseline["workload"]["name"] == "galley"
      assert bundle.baseline["services"]["galley"]["ready_endpoints"] == 3
    end
  end

  describe "load/1 gap tolerance" do
    @tag :tmp_dir
    test "an empty bundle directory loads with every section absent", %{tmp_dir: tmp_dir} do
      assert {:ok, bundle} = LoadedBundle.load(tmp_dir)
      assert bundle.manifest == nil
      assert bundle.pods == []
      assert bundle.events == %{}
      assert bundle.owners == []
      assert bundle.nodes == %{}
      assert bundle.baseline == nil
    end

    @tag :tmp_dir
    test "a pod directory with only a status file still loads", %{tmp_dir: tmp_dir} do
      pod_dir = Path.join(tmp_dir, "pods/demo/web-abc")
      File.mkdir_p!(pod_dir)
      File.write!(Path.join(pod_dir, "status.json"), ~s({"phase": "Running"}))

      assert {:ok, bundle} = LoadedBundle.load(tmp_dir)
      assert [pod] = bundle.pods
      assert pod.namespace == "demo"
      assert pod.name == "web-abc"
      assert pod.status == %{"phase" => "Running"}
      assert pod.spec == nil
      assert pod.logs_current == nil
      assert pod.logs_previous == nil
    end

    @tag :tmp_dir
    test "an owner without a revisions file loads with nil revisions", %{tmp_dir: tmp_dir} do
      owner_dir = Path.join(tmp_dir, "owners/demo")
      File.mkdir_p!(owner_dir)
      File.write!(Path.join(owner_dir, "web.json"), ~s({"kind": "Deployment"}))

      assert {:ok, bundle} = LoadedBundle.load(tmp_dir)
      assert [owner] = bundle.owners
      assert owner.name == "web"
      assert owner.resource == %{"kind" => "Deployment"}
      assert owner.revisions == nil
    end
  end

  describe "load/1 failures" do
    test "a missing bundle directory is an error" do
      assert {:error, {:not_a_directory, _}} =
               LoadedBundle.load("test/fixtures/incidents/does-not-exist")
    end

    @tag :tmp_dir
    test "malformed JSON in a sealed bundle is corruption, not a gap", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "manifest.json"), "{not json")

      assert {:error, {:invalid_json, "manifest.json"}} = LoadedBundle.load(tmp_dir)
    end
  end
end
