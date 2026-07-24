defmodule Kubeybilly.Soundings.CollectorTest do
  # Collector fans out under Task.Supervisor, so the mock must be global.
  use ExUnit.Case, async: false

  import Mox

  alias Kubeybilly.K8sClient.Mock, as: Client
  alias Kubeybilly.Soundings.Bundle
  alias Kubeybilly.Soundings.Collector

  setup :set_mox_global
  setup :verify_on_exit!

  @incident_id "20260725T031500Z-a1b2c3d4"

  @deployment %{
    "apiVersion" => "apps/v1",
    "kind" => "Deployment",
    "metadata" => %{
      "name" => "web",
      "namespace" => "demo",
      "annotations" => %{"deployment.kubernetes.io/revision" => "4"}
    },
    "spec" => %{
      "replicas" => 2,
      "selector" => %{"matchLabels" => %{"app" => "web"}}
    },
    "status" => %{"replicas" => 2, "readyReplicas" => 1, "availableReplicas" => 1}
  }

  @replicasets [
    %{
      "kind" => "ReplicaSet",
      "metadata" => %{
        "name" => "web-6d4b",
        "annotations" => %{"deployment.kubernetes.io/revision" => "4"}
      }
    }
  ]

  @events [
    %{
      "kind" => "Event",
      "reason" => "BackOff",
      "involvedObject" => %{"kind" => "Pod", "name" => "web-abc"}
    }
  ]

  @node %{
    "apiVersion" => "v1",
    "kind" => "Node",
    "metadata" => %{"name" => "worker-1"},
    "status" => %{"conditions" => [%{"type" => "Ready", "status" => "True"}]}
  }

  defp pod_fixture(name) do
    %{
      "apiVersion" => "v1",
      "kind" => "Pod",
      "metadata" => %{"name" => name, "namespace" => "demo", "labels" => %{"app" => "web"}},
      "spec" => %{"nodeName" => "worker-1", "containers" => [%{"name" => "app"}]},
      "status" => %{
        "phase" => "Running",
        "conditions" => [%{"type" => "Ready", "status" => "True"}],
        "containerStatuses" => [%{"name" => "app", "restartCount" => 3, "ready" => true}]
      }
    }
  end

  defp target(pods) do
    %{
      incident_id: @incident_id,
      namespace: "demo",
      workload_kind: "Deployment",
      workload_name: "web",
      pods: pods,
      nodes: ["worker-1"]
    }
  end

  defp tmp_root do
    root =
      Path.join(System.tmp_dir!(), "kubeybilly-collect-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp stub_happy_cluster(recorder \\ nil) do
    record = fn entry ->
      if recorder, do: Agent.update(recorder, &(&1 ++ [entry]))
    end

    stub(Client, :pod_logs, fn "demo", pod, nil, opts ->
      previous = Keyword.get(opts, :previous, false)
      record.({:pod_logs, pod, previous})
      {:ok, if(previous, do: "previous logs of #{pod}", else: "current logs of #{pod}")}
    end)

    stub(Client, :get, fn
      "Pod", pod, "demo" ->
        record.({:get_pod, pod})
        {:ok, pod_fixture(pod)}

      "Deployment", "web", "demo" ->
        {:ok, @deployment}

      "Node", "worker-1", nil ->
        {:ok, @node}
    end)

    stub(Client, :list, fn
      "Event", "demo", nil -> {:ok, @events}
      "ReplicaSet", "demo", "app=web" -> {:ok, @replicasets}
    end)
  end

  describe "collect/2 happy path" do
    test "captures every artifact and seals a complete manifest" do
      root = tmp_root()
      stub_happy_cluster()

      assert {:ok, manifest} = Collector.collect(target(["web-abc", "web-def"]), root: root)

      assert manifest["complete"] == true
      assert manifest["gaps"] == []

      bundle = Bundle.new(@incident_id, root: root)

      for pod <- ["web-abc", "web-def"] do
        assert File.read!(Bundle.absolute(bundle, Bundle.pod_logs_previous_path("demo", pod))) ==
                 "previous logs of #{pod}"

        assert File.read!(Bundle.absolute(bundle, Bundle.pod_logs_current_path("demo", pod))) ==
                 "current logs of #{pod}"

        status =
          bundle
          |> Bundle.absolute(Bundle.pod_status_path("demo", pod))
          |> File.read!()
          |> Jason.decode!()

        assert status["phase"] == "Running"

        spec =
          bundle
          |> Bundle.absolute(Bundle.pod_spec_path("demo", pod))
          |> File.read!()
          |> Jason.decode!()

        assert spec["metadata"]["name"] == pod
        refute Map.has_key?(spec, "status")
      end

      events =
        bundle
        |> Bundle.absolute(Bundle.events_path("demo"))
        |> File.read!()
        |> Jason.decode!()

      assert [%{"reason" => "BackOff"}] = events

      owner =
        bundle
        |> Bundle.absolute(Bundle.owner_path("demo", "web"))
        |> File.read!()
        |> Jason.decode!()

      assert owner["kind"] == "Deployment"

      revisions =
        bundle
        |> Bundle.absolute(Bundle.owner_revisions_path("demo", "web"))
        |> File.read!()
        |> Jason.decode!()

      assert [%{"kind" => "ReplicaSet"}] = revisions

      node =
        bundle
        |> Bundle.absolute(Bundle.node_path("worker-1"))
        |> File.read!()
        |> Jason.decode!()

      assert node["kind"] == "Node"
    end

    test "requests previous logs before current logs for every pod" do
      root = tmp_root()
      {:ok, recorder} = Agent.start_link(fn -> [] end)
      stub_happy_cluster(recorder)

      assert {:ok, _manifest} = Collector.collect(target(["web-abc", "web-def"]), root: root)

      calls = Agent.get(recorder, & &1)

      for pod <- ["web-abc", "web-def"] do
        previous_at = Enum.find_index(calls, &(&1 == {:pod_logs, pod, true}))
        current_at = Enum.find_index(calls, &(&1 == {:pod_logs, pod, false}))
        pod_get_at = Enum.find_index(calls, &(&1 == {:get_pod, pod}))

        assert previous_at < current_at,
               "previous logs of #{pod} must be requested before current logs"

        assert current_at < pod_get_at,
               "logs of #{pod} must be requested before its spec and status"
      end
    end
  end

  describe "collect/2 gap recording" do
    test "missing previous logs are a gap but the bundle stays complete" do
      root = tmp_root()
      stub_happy_cluster()

      stub(Client, :pod_logs, fn "demo", pod, nil, opts ->
        if Keyword.get(opts, :previous, false) do
          {:error, {:api, "BadRequest", "previous terminated container not found"}}
        else
          {:ok, "current logs of #{pod}"}
        end
      end)

      assert {:ok, manifest} = Collector.collect(target(["web-abc"]), root: root)

      assert manifest["complete"] == true
      assert [gap] = manifest["gaps"]
      assert gap["path"] == Bundle.pod_logs_previous_path("demo", "web-abc")
      assert gap["reason"] =~ "BadRequest"
    end

    test "a failed pod fetch gaps both spec and status and breaks completeness" do
      root = tmp_root()
      stub_happy_cluster()

      stub(Client, :get, fn
        "Pod", "web-abc", "demo" -> {:error, {:api, "NotFound", "pod deleted mid-capture"}}
        "Deployment", "web", "demo" -> {:ok, @deployment}
        "Node", "worker-1", nil -> {:ok, @node}
      end)

      assert {:ok, manifest} = Collector.collect(target(["web-abc"]), root: root)

      assert manifest["complete"] == false
      gap_paths = Enum.map(manifest["gaps"], & &1["path"])
      assert Bundle.pod_status_path("demo", "web-abc") in gap_paths
      assert Bundle.pod_spec_path("demo", "web-abc") in gap_paths
    end

    test "a failed owner fetch gaps the owner and its revisions" do
      root = tmp_root()
      stub_happy_cluster()

      stub(Client, :get, fn
        "Pod", pod, "demo" -> {:ok, pod_fixture(pod)}
        "Deployment", "web", "demo" -> {:error, {:transport, :timeout}}
        "Node", "worker-1", nil -> {:ok, @node}
      end)

      assert {:ok, manifest} = Collector.collect(target(["web-abc"]), root: root)

      assert manifest["complete"] == false
      gap_paths = Enum.map(manifest["gaps"], & &1["path"])
      assert Bundle.owner_path("demo", "web") in gap_paths
      assert Bundle.owner_revisions_path("demo", "web") in gap_paths
    end

    test "failed events and node fetches become gaps, never crashes" do
      root = tmp_root()
      stub_happy_cluster()

      stub(Client, :list, fn
        "Event", "demo", nil -> {:error, {:transport, :closed}}
        "ReplicaSet", "demo", "app=web" -> {:ok, @replicasets}
      end)

      stub(Client, :get, fn
        "Pod", pod, "demo" -> {:ok, pod_fixture(pod)}
        "Deployment", "web", "demo" -> {:ok, @deployment}
        "Node", "worker-1", nil -> {:error, {:api, "NotFound", "node gone"}}
      end)

      assert {:ok, manifest} = Collector.collect(target(["web-abc"]), root: root)

      assert manifest["complete"] == false
      gap_paths = Enum.map(manifest["gaps"], & &1["path"])
      assert Bundle.events_path("demo") in gap_paths
      assert Bundle.node_path("worker-1") in gap_paths
    end
  end

  test "collect/2 rejects a malformed target" do
    assert {:error, :invalid_target} = Collector.collect(%{namespace: "demo"})
  end
end
