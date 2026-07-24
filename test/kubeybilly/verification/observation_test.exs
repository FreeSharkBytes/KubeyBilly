defmodule Kubeybilly.Verification.ObservationTest do
  use ExUnit.Case, async: true

  import Mox

  alias Kubeybilly.K8sClient.Mock, as: Client
  alias Kubeybilly.Verification.Observation

  setup :verify_on_exit!

  @target %{namespace: "demo", workload_kind: "Deployment", workload_name: "web"}

  @deployment %{
    "kind" => "Deployment",
    "metadata" => %{
      "name" => "web",
      "namespace" => "demo",
      "annotations" => %{"deployment.kubernetes.io/revision" => "6"}
    },
    "spec" => %{
      "replicas" => 2,
      "selector" => %{"matchLabels" => %{"app" => "web"}},
      "template" => %{"metadata" => %{"labels" => %{"app" => "web"}}}
    },
    "status" => %{"readyReplicas" => 2, "availableReplicas" => 2}
  }

  defp pod_fixture(name, opts) do
    ready = Keyword.get(opts, :ready, true)

    metadata =
      %{
        "name" => name,
        "labels" => %{"app" => "web", "pod-template-hash" => Keyword.get(opts, :hash, "aaaa")}
      }
      |> then(fn metadata ->
        if Keyword.get(opts, :terminating, false) do
          Map.put(metadata, "deletionTimestamp", "2026-07-24T05:00:00Z")
        else
          metadata
        end
      end)

    %{
      "kind" => "Pod",
      "metadata" => metadata,
      "spec" => %{"nodeName" => Keyword.get(opts, :node, "worker-1")},
      "status" => %{
        "phase" => Keyword.get(opts, :phase, "Running"),
        "conditions" => [%{"type" => "Ready", "status" => if(ready, do: "True", else: "False")}],
        "containerStatuses" => [
          %{"name" => "app", "restartCount" => Keyword.get(opts, :restarts, 0)}
        ]
      }
    }
  end

  defp replica_set_fixture(name, opts) do
    annotations =
      %{"deployment.kubernetes.io/revision" => Keyword.fetch!(opts, :revision)}
      |> then(fn annotations ->
        case Keyword.get(opts, :history) do
          nil -> annotations
          history -> Map.put(annotations, "deployment.kubernetes.io/revision-history", history)
        end
      end)

    %{
      "kind" => "ReplicaSet",
      "metadata" => %{
        "name" => name,
        "annotations" => annotations,
        "labels" => %{"pod-template-hash" => Keyword.get(opts, :hash, "aaaa")}
      },
      "spec" => %{"replicas" => Keyword.get(opts, :spec_replicas, 2)},
      "status" => %{
        "replicas" => Keyword.get(opts, :status_replicas, 2),
        "readyReplicas" => Keyword.get(opts, :ready_replicas, 2),
        "availableReplicas" => Keyword.get(opts, :available_replicas, 2)
      }
    }
  end

  @service %{
    "kind" => "Service",
    "metadata" => %{"name" => "web-svc"},
    "spec" => %{"selector" => %{"app" => "web"}}
  }

  @unrelated_service %{
    "kind" => "Service",
    "metadata" => %{"name" => "other-svc"},
    "spec" => %{"selector" => %{"app" => "other"}}
  }

  @slices [
    %{
      "kind" => "EndpointSlice",
      "endpoints" => [
        %{"conditions" => %{"ready" => true}},
        %{"conditions" => %{"ready" => false}}
      ]
    }
  ]

  describe "observe/2" do
    test "gathers workload, pods, services, and replica sets in baseline shape" do
      expect(Client, :get, fn "Deployment", "web", "demo" -> {:ok, @deployment} end)

      expect(Client, :list, fn "Pod", "demo", "app=web" ->
        {:ok,
         [
           pod_fixture("web-aaaa-1", restarts: 3),
           pod_fixture("web-aaaa-2", ready: false, phase: "Pending", terminating: true, node: nil)
         ]}
      end)

      expect(Client, :list, fn "ReplicaSet", "demo", "app=web" ->
        {:ok,
         [
           replica_set_fixture("web-old", revision: "5", hash: "oooo", spec_replicas: 0),
           replica_set_fixture("web-new", revision: "6", history: "2,4", hash: "aaaa")
         ]}
      end)

      expect(Client, :list, fn "Service", "demo", nil ->
        {:ok, [@service, @unrelated_service]}
      end)

      expect(Client, :list, fn "EndpointSlice", "demo", "kubernetes.io/service-name=web-svc" ->
        {:ok, @slices}
      end)

      assert {:ok, observation} = Observation.observe(Client, @target)

      assert observation["desired_replicas"] == 2
      assert observation["ready_replicas"] == 2
      assert observation["available_replicas"] == 2
      assert observation["revision"] == "6"
      assert observation["newest_revision"] == "6"

      assert observation["pods"] == %{
               "web-aaaa-1" => %{
                 "phase" => "Running",
                 "ready" => true,
                 "restart_counts" => %{"app" => 3},
                 "node" => "worker-1",
                 "template_hash" => "aaaa",
                 "terminating" => false
               },
               "web-aaaa-2" => %{
                 "phase" => "Pending",
                 "ready" => false,
                 "restart_counts" => %{"app" => 0},
                 "node" => nil,
                 "template_hash" => "aaaa",
                 "terminating" => true
               }
             }

      assert observation["services"] == %{"web-svc" => %{"ready_endpoints" => 1}}

      assert [old_rs, new_rs] = observation["replica_sets"]

      assert old_rs == %{
               "name" => "web-old",
               "revision" => "5",
               "revision_history" => [],
               "template_hash" => "oooo",
               "spec_replicas" => 0,
               "status_replicas" => 2,
               "ready_replicas" => 2,
               "available_replicas" => 2
             }

      assert new_rs["revision_history"] == ["2", "4"]
      assert new_rs["template_hash"] == "aaaa"
    end

    test "missing status fields observe as zero, matching the baseline defaults" do
      bare = %{
        "kind" => "Deployment",
        "metadata" => %{"name" => "web"},
        "spec" => %{"selector" => %{"matchLabels" => %{"app" => "web"}}},
        "status" => %{}
      }

      expect(Client, :get, fn "Deployment", "web", "demo" -> {:ok, bare} end)
      expect(Client, :list, fn "Pod", "demo", "app=web" -> {:ok, []} end)
      expect(Client, :list, fn "ReplicaSet", "demo", "app=web" -> {:ok, []} end)
      expect(Client, :list, fn "Service", "demo", nil -> {:ok, []} end)

      assert {:ok, observation} = Observation.observe(Client, @target)
      assert observation["desired_replicas"] == 1
      assert observation["ready_replicas"] == 0
      assert observation["available_replicas"] == 0
      assert observation["revision"] == nil
      assert observation["newest_revision"] == nil
      assert observation["replica_sets"] == []
    end

    test "a failed workload read returns the client error" do
      expect(Client, :get, fn "Deployment", "web", "demo" ->
        {:error, {:transport, :timeout}}
      end)

      assert {:error, {:transport, :timeout}} = Observation.observe(Client, @target)
    end

    test "a failed pod list returns the client error" do
      expect(Client, :get, fn "Deployment", "web", "demo" -> {:ok, @deployment} end)

      expect(Client, :list, fn "Pod", "demo", "app=web" ->
        {:error, {:api, "Forbidden", "denied"}}
      end)

      assert {:error, {:api, "Forbidden", "denied"}} = Observation.observe(Client, @target)
    end

    test "a failed endpoint slice read returns the client error" do
      expect(Client, :get, fn "Deployment", "web", "demo" -> {:ok, @deployment} end)
      expect(Client, :list, fn "Pod", "demo", "app=web" -> {:ok, []} end)
      expect(Client, :list, fn "ReplicaSet", "demo", "app=web" -> {:ok, []} end)
      expect(Client, :list, fn "Service", "demo", nil -> {:ok, [@service]} end)

      expect(Client, :list, fn "EndpointSlice", "demo", _selector ->
        {:error, {:conn, :nxdomain}}
      end)

      assert {:error, {:conn, :nxdomain}} = Observation.observe(Client, @target)
    end
  end
end
