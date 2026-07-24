defmodule Kubeybilly.K8sClientTest do
  use ExUnit.Case, async: true

  alias Kubeybilly.K8sClient

  describe "behaviour surface" do
    test "declares every read callback the soundings pipeline needs" do
      callbacks = K8sClient.behaviour_info(:callbacks)

      assert {:get, 3} in callbacks
      assert {:list, 3} in callbacks
      assert {:pod_logs, 4} in callbacks
    end

    test "declares the mutating callbacks reserved for later build steps" do
      callbacks = K8sClient.behaviour_info(:callbacks)

      assert {:patch, 4} in callbacks
      assert {:delete_pod, 2} in callbacks
      assert {:scale, 4} in callbacks
    end
  end
end
