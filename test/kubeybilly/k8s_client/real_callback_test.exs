defmodule Kubeybilly.K8sClient.RealCallbackTest do
  # Not async: repoints the :k8s_conn_server config the callbacks resolve.
  use ExUnit.Case, async: false

  alias Kubeybilly.K8sClient.Conn
  alias Kubeybilly.K8sClient.Real

  setup do
    start_supervised!(
      {Conn,
       name: :real_callback_test_conn,
       service_account_dir: "/nonexistent-sa-dir",
       env: %{"KUBECONFIG" => "/nonexistent/kubeconfig"}}
    )

    Application.put_env(:kubeybilly, :k8s_conn_server, :real_callback_test_conn)
    on_exit(fn -> Application.delete_env(:kubeybilly, :k8s_conn_server) end)
    :ok
  end

  test "every callback degrades to a conn error without a cluster" do
    assert {:error, {:conn, _}} = Real.get("Pod", "web-abc", "demo")
    assert {:error, {:conn, _}} = Real.list("Pod", "demo", "app=web")
    assert {:error, {:conn, _}} = Real.pod_logs("demo", "web-abc", nil, previous: true)
    assert {:error, {:conn, _}} = Real.patch("Deployment", "web", "demo", %{"spec" => %{}})
    assert {:error, {:conn, _}} = Real.delete_pod("demo", "web-abc")
    assert {:error, {:conn, _}} = Real.scale("Deployment", "web", "demo", 2)
  end
end
