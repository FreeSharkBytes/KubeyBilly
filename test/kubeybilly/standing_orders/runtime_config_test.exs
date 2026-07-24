defmodule Kubeybilly.StandingOrders.RuntimeConfigTest do
  # Reads config/runtime.exs through Config.Reader under controlled env
  # vars; env vars are process-global, so no async.
  use ExUnit.Case, async: false

  @runtime Path.expand("../../../config/runtime.exs", __DIR__)
  @env_vars ["STANDING_ORDERS_PATH", "KILLSWITCH_PATH"]

  setup do
    on_exit(fn -> Enum.each(@env_vars, &System.delete_env/1) end)
    :ok
  end

  defp runtime_config(env_vars) do
    Enum.each(env_vars, fn {name, value} -> System.put_env(name, value) end)

    @runtime
    |> Config.Reader.read!(env: :test)
    |> Keyword.get(:kubeybilly, [])
  end

  test "without env vars, neither path is configured" do
    config = runtime_config([])

    refute Keyword.has_key?(config, :standing_orders_path)
    refute Keyword.has_key?(config, :killswitch_path)
  end

  test "STANDING_ORDERS_PATH lands in :standing_orders_path" do
    config =
      runtime_config([
        {"STANDING_ORDERS_PATH", "/etc/kubeybilly/standing-orders/standing-orders.yaml"}
      ])

    assert config[:standing_orders_path] ==
             "/etc/kubeybilly/standing-orders/standing-orders.yaml"
  end

  test "KILLSWITCH_PATH lands in :killswitch_path" do
    config = runtime_config([{"KILLSWITCH_PATH", "/etc/kubeybilly/killswitch/engaged"}])

    assert config[:killswitch_path] == "/etc/kubeybilly/killswitch/engaged"
  end
end
