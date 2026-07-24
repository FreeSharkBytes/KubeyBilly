defmodule Kubeybilly.K8sClient.ConnGlobalTest do
  # Not async: exercises the application-global connection holder.
  use ExUnit.Case, async: false

  alias Kubeybilly.K8sClient.Conn

  test "source/0 resolves from the process environment" do
    assert {kind, path} = Conn.source()
    assert kind in [:service_account, :kubeconfig]
    assert is_binary(path)
  end

  test "the application's connection holder accepts injection" do
    conn = %K8s.Conn{cluster_name: "app-global"}

    assert :ok = Conn.put(conn)
    assert {:ok, ^conn} = Conn.get()
  end
end
