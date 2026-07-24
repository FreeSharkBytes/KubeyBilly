defmodule Kubeybilly.K8sClient.MockWiringTest do
  use ExUnit.Case, async: true

  import Mox

  alias Kubeybilly.K8sClient

  setup :verify_on_exit!

  test "the test environment resolves the Mox mock" do
    assert K8sClient.impl() == Kubeybilly.K8sClient.Mock
  end

  test "the mock satisfies the behaviour end to end" do
    expect(Kubeybilly.K8sClient.Mock, :get, fn "Pod", "web-abc", "demo" ->
      {:ok, %{"kind" => "Pod", "metadata" => %{"name" => "web-abc"}}}
    end)

    assert {:ok, %{"kind" => "Pod"}} = K8sClient.impl().get("Pod", "web-abc", "demo")
  end
end
