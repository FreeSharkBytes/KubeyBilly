defmodule Kubeybilly.K8sClient.ConnTest do
  use ExUnit.Case, async: true

  alias Kubeybilly.K8sClient.Conn

  describe "source/1" do
    test "selects the service account when the token file exists" do
      dir = Path.join(System.tmp_dir!(), "kubeybilly-conn-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "token"), "sa-token")
      on_exit(fn -> File.rm_rf!(dir) end)

      assert {:service_account, ^dir} = Conn.source(service_account_dir: dir)
    end

    test "falls back to the KUBECONFIG environment variable" do
      assert {:kubeconfig, "/kc/config"} =
               Conn.source(
                 service_account_dir: "/nonexistent-sa-dir",
                 env: %{"KUBECONFIG" => "/kc/config"}
               )
    end

    test "defaults to the user kubeconfig when nothing else applies" do
      assert {:kubeconfig, path} =
               Conn.source(service_account_dir: "/nonexistent-sa-dir", env: %{})

      assert path == Path.join(System.user_home!(), ".kube/config")
    end
  end

  describe "get/1 and put/2" do
    test "returns an injected connection without touching disk" do
      pid = start_supervised!({Conn, name: :conn_injected_test})
      conn = %K8s.Conn{cluster_name: "injected"}

      assert :ok = Conn.put(pid, conn)
      assert {:ok, ^conn} = Conn.get(pid)
    end

    test "reports a conn error when no kubeconfig can be resolved" do
      pid =
        start_supervised!(
          {Conn,
           name: :conn_missing_test,
           service_account_dir: "/nonexistent-sa-dir",
           env: %{"KUBECONFIG" => "/nonexistent/kubeconfig"}}
        )

      assert {:error, {:conn, _reason}} = Conn.get(pid)
    end

    test "does not cache a resolution failure" do
      dir = Path.join(System.tmp_dir!(), "kubeybilly-conn-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      kubeconfig = Path.join(dir, "kubeconfig")

      pid =
        start_supervised!(
          {Conn,
           name: :conn_retry_test,
           service_account_dir: "/nonexistent-sa-dir",
           env: %{"KUBECONFIG" => kubeconfig}}
        )

      assert {:error, {:conn, _reason}} = Conn.get(pid)

      conn = %K8s.Conn{cluster_name: "late-arrival"}
      assert :ok = Conn.put(pid, conn)
      assert {:ok, ^conn} = Conn.get(pid)
    end
  end
end
