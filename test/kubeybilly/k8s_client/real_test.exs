defmodule Kubeybilly.K8sClient.RealTest do
  use ExUnit.Case, async: true

  alias Kubeybilly.K8sClient.Real

  describe "map_error/1" do
    test "maps an API error to {:api, status, message}" do
      error = %K8s.Client.APIError{reason: "NotFound", message: "pods \"web-abc\" not found"}

      assert Real.map_error(error) == {:api, "NotFound", "pods \"web-abc\" not found"}
    end

    test "maps an HTTP error to {:transport, message}" do
      error = %K8s.Client.HTTPError{message: "connection refused"}

      assert Real.map_error(error) == {:transport, "connection refused"}
    end

    test "maps any other failure to {:transport, reason}" do
      assert Real.map_error(:timeout) == {:transport, :timeout}
    end
  end

  describe "operation building" do
    test "get targets the right group version per kind" do
      op = Real.build_get("Deployment", "web", "demo")

      assert op.verb == :get
      assert op.api_version == "apps/v1"
      assert op.name == "Deployment"
      assert op.path_params[:name] == "web"
      assert op.path_params[:namespace] == "demo"
    end

    test "get omits the namespace for cluster-scoped kinds" do
      op = Real.build_get("Node", "worker-1", nil)

      assert op.api_version == "v1"
      assert op.path_params[:name] == "worker-1"
      refute Keyword.has_key?(op.path_params, :namespace)
    end

    test "list carries the label selector as a K8s.Selector struct" do
      op = Real.build_list("Pod", "demo", "app=web,tier=front")

      assert op.verb == :list

      assert op.query_params[:labelSelector] == %K8s.Selector{
               match_labels: %{"app" => "web", "tier" => "front"}
             }
    end

    test "list without a selector has no labelSelector param" do
      op = Real.build_list("Event", "demo", nil)

      refute Keyword.has_key?(op.query_params, :labelSelector)
    end

    test "pod_logs addresses the log subresource with previous and container params" do
      op = Real.build_pod_logs("demo", "web-abc", "app", previous: true)

      assert op.name == "pods/log"
      assert op.path_params[:name] == "web-abc"
      assert op.path_params[:namespace] == "demo"
      assert op.query_params[:container] == "app"
      assert op.query_params[:previous] == true
    end

    test "pod_logs omits optional params when absent" do
      op = Real.build_pod_logs("demo", "web-abc", nil, previous: false)

      refute Keyword.has_key?(op.query_params, :container)
      refute Keyword.has_key?(op.query_params, :previous)
    end

    test "a list patch becomes a JSON patch operation" do
      patch = [%{"op" => "replace", "path" => "/spec/replicas", "value" => 2}]
      op = Real.build_patch("Deployment", "web", "demo", patch)

      assert op.verb == :patch
      assert op.header_params[:"Content-Type"] == "application/json-patch+json"
      assert op.data == patch
    end

    test "a map patch becomes a merge patch operation" do
      patch = %{"spec" => %{"replicas" => 2}}
      op = Real.build_patch("Deployment", "web", "demo", patch)

      assert op.header_params[:"Content-Type"] == "application/merge-patch+json"
      assert op.data == patch
    end

    test "delete_pod builds a namespaced pod deletion" do
      op = Real.build_delete_pod("demo", "web-abc")

      assert op.verb == :delete
      assert op.name == "Pod"
      assert op.path_params[:namespace] == "demo"
      assert op.path_params[:name] == "web-abc"
    end

    test "scale merge-patches the scale subresource" do
      op = Real.build_scale("Deployment", "web", "demo", 3)

      assert op.verb == :patch
      assert op.name == "deployments/scale"
      assert op.data == %{"spec" => %{"replicas" => 3}}
      assert op.header_params[:"Content-Type"] == "application/merge-patch+json"
    end
  end

  describe "result unwrapping" do
    test "unwrap_list extracts the items of a list response" do
      assert Real.unwrap_list({:ok, %{"items" => [%{"kind" => "Pod"}]}}) ==
               {:ok, [%{"kind" => "Pod"}]}
    end

    test "unwrap_list wraps a bare resource and passes errors through" do
      assert Real.unwrap_list({:ok, %{"kind" => "Pod"}}) == {:ok, [%{"kind" => "Pod"}]}
      assert Real.unwrap_list({:error, {:transport, :closed}}) == {:error, {:transport, :closed}}
    end

    test "unwrap_logs keeps binaries, stringifies others, passes errors through" do
      assert Real.unwrap_logs({:ok, "log line"}) == {:ok, "log line"}
      assert Real.unwrap_logs({:ok, 42}) == {:ok, "42"}

      assert Real.unwrap_logs({:error, {:api, "NotFound", "gone"}}) ==
               {:error, {:api, "NotFound", "gone"}}
    end
  end

  describe "run plumbing" do
    test "a missing connection surfaces as a conn error" do
      pid =
        start_supervised!(
          {Kubeybilly.K8sClient.Conn,
           name: :real_test_conn,
           service_account_dir: "/nonexistent-sa-dir",
           env: %{"KUBECONFIG" => "/nonexistent/kubeconfig"}}
        )

      assert {:error, {:conn, _reason}} =
               Real.run(Real.build_get("Pod", "web-abc", "demo"), pid)
    end
  end
end
