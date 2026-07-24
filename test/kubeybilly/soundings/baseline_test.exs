defmodule Kubeybilly.Soundings.BaselineTest do
  use ExUnit.Case, async: true

  import Mox

  alias Kubeybilly.K8sClient.Mock, as: Client
  alias Kubeybilly.Soundings.Baseline

  setup :verify_on_exit!

  @target %{namespace: "demo", workload_kind: "Deployment", workload_name: "web"}

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
      "selector" => %{"matchLabels" => %{"app" => "web"}},
      "template" => %{"metadata" => %{"labels" => %{"app" => "web", "tier" => "frontend"}}}
    },
    "status" => %{"replicas" => 2, "readyReplicas" => 1, "availableReplicas" => 1}
  }

  defp pod_fixture(name, opts) do
    ready = Keyword.get(opts, :ready, true)
    restarts = Keyword.get(opts, :restarts, 0)

    %{
      "kind" => "Pod",
      "metadata" => %{"name" => name, "labels" => %{"app" => "web"}},
      "spec" => %{"nodeName" => Keyword.get(opts, :node, "worker-1")},
      "status" => %{
        "phase" => Keyword.get(opts, :phase, "Running"),
        "conditions" => [
          %{"type" => "Ready", "status" => if(ready, do: "True", else: "False")}
        ],
        "containerStatuses" => [
          %{"name" => "app", "restartCount" => restarts, "ready" => ready}
        ]
      }
    }
  end

  @selecting_service %{
    "kind" => "Service",
    "metadata" => %{"name" => "web-svc"},
    "spec" => %{"selector" => %{"app" => "web"}}
  }

  @unrelated_service %{
    "kind" => "Service",
    "metadata" => %{"name" => "other-svc"},
    "spec" => %{"selector" => %{"app" => "other"}}
  }

  @selectorless_service %{
    "kind" => "Service",
    "metadata" => %{"name" => "external-svc"},
    "spec" => %{}
  }

  @endpoint_slices [
    %{
      "kind" => "EndpointSlice",
      "endpoints" => [
        %{"conditions" => %{"ready" => true}},
        %{"conditions" => %{"ready" => false}},
        %{"conditions" => %{"ready" => true}}
      ]
    }
  ]

  describe "build/2 happy path" do
    test "captures replicas, pods, services, ready set, and revision" do
      expect(Client, :get, fn "Deployment", "web", "demo" -> {:ok, @deployment} end)

      expect(Client, :list, fn "Pod", "demo", "app=web" ->
        {:ok,
         [
           pod_fixture("web-abc", ready: true, restarts: 3),
           pod_fixture("web-def", ready: false, phase: "Pending", node: "worker-2")
         ]}
      end)

      expect(Client, :list, fn "Service", "demo", nil ->
        {:ok, [@selecting_service, @unrelated_service, @selectorless_service]}
      end)

      expect(Client, :list, fn "EndpointSlice", "demo", "kubernetes.io/service-name=web-svc" ->
        {:ok, @endpoint_slices}
      end)

      assert {:ok, baseline} = Baseline.build(Client, @target)

      assert baseline["workload"] == %{
               "kind" => "Deployment",
               "name" => "web",
               "namespace" => "demo"
             }

      assert baseline["desired_replicas"] == 2
      assert baseline["ready_replicas"] == 1
      assert baseline["available_replicas"] == 1
      assert baseline["revision"] == "4"

      assert baseline["pods"] == %{
               "web-abc" => %{
                 "phase" => "Running",
                 "ready" => true,
                 "restart_counts" => %{"app" => 3},
                 "node" => "worker-1"
               },
               "web-def" => %{
                 "phase" => "Pending",
                 "ready" => false,
                 "restart_counts" => %{"app" => 0},
                 "node" => "worker-2"
               }
             }

      assert baseline["ready_pods"] == ["web-abc"]
      assert baseline["services"] == %{"web-svc" => %{"ready_endpoints" => 2}}
    end

    test "defaults missing status counters to zero" do
      deployment =
        @deployment
        |> Map.put("status", %{})
        |> put_in(["metadata", "annotations"], %{})

      expect(Client, :get, fn "Deployment", "web", "demo" -> {:ok, deployment} end)
      expect(Client, :list, fn "Pod", "demo", "app=web" -> {:ok, []} end)
      expect(Client, :list, fn "Service", "demo", nil -> {:ok, []} end)

      assert {:ok, baseline} = Baseline.build(Client, @target)

      assert baseline["ready_replicas"] == 0
      assert baseline["available_replicas"] == 0
      assert baseline["revision"] == nil
      assert baseline["pods"] == %{}
      assert baseline["ready_pods"] == []
      assert baseline["services"] == %{}
    end
  end

  describe "build/2 failure propagation" do
    test "a failed workload fetch fails the baseline" do
      expect(Client, :get, fn "Deployment", "web", "demo" ->
        {:error, {:api, "NotFound", "gone"}}
      end)

      assert {:error, {:api, "NotFound", "gone"}} = Baseline.build(Client, @target)
    end

    test "a failed pod listing fails the baseline" do
      expect(Client, :get, fn "Deployment", "web", "demo" -> {:ok, @deployment} end)
      expect(Client, :list, fn "Pod", "demo", "app=web" -> {:error, {:transport, :timeout}} end)

      assert {:error, {:transport, :timeout}} = Baseline.build(Client, @target)
    end

    test "a failed endpoint listing fails the baseline" do
      expect(Client, :get, fn "Deployment", "web", "demo" -> {:ok, @deployment} end)
      expect(Client, :list, fn "Pod", "demo", "app=web" -> {:ok, []} end)
      expect(Client, :list, fn "Service", "demo", nil -> {:ok, [@selecting_service]} end)

      expect(Client, :list, fn "EndpointSlice", "demo", _selector ->
        {:error, {:transport, :closed}}
      end)

      assert {:error, {:transport, :closed}} = Baseline.build(Client, @target)
    end
  end
end
