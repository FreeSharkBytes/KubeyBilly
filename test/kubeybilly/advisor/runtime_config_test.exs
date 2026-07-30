defmodule Kubeybilly.Advisor.RuntimeConfigTest do
  # Reads config/runtime.exs through Config.Reader under controlled env
  # vars; env vars are process-global, so no async.
  use ExUnit.Case, async: false

  @runtime Path.expand("../../../config/runtime.exs", __DIR__)
  @env_vars ["ADVISOR_ADAPTER", "ADVISOR_BASE_URL", "ADVISOR_MODEL", "ADVISOR_ENABLED"]

  setup do
    on_exit(fn -> Enum.each(@env_vars, &System.delete_env/1) end)
    :ok
  end

  defp runtime_config(env_vars) do
    Enum.each(env_vars, fn {name, value} -> System.put_env(name, value) end)

    Config.Reader.read!(@runtime, env: :test)
  end

  defp advisor_config(env_vars) do
    get_in(runtime_config(env_vars), [:kubeybilly, :advisor])
  end

  defp advisor_enabled(env_vars) do
    get_in(runtime_config(env_vars), [:kubeybilly, :advisor_enabled])
  end

  test "without env vars, runtime config leaves the advisor untouched" do
    assert advisor_config([]) == nil
  end

  test "ADVISOR_ADAPTER=openai_compat switches to the real adapter" do
    config = advisor_config([{"ADVISOR_ADAPTER", "openai_compat"}])

    assert config[:adapter] == Kubeybilly.Advisor.OpenAICompat
    refute Keyword.has_key?(config, :base_url)
    refute Keyword.has_key?(config, :model)
  end

  test "ADVISOR_ADAPTER=stub names the stub explicitly" do
    assert advisor_config([{"ADVISOR_ADAPTER", "stub"}])[:adapter] == Kubeybilly.Advisor.Stub
  end

  test "base URL and model override independently of the adapter" do
    config =
      advisor_config([
        {"ADVISOR_BASE_URL", "https://other.example/v1"},
        {"ADVISOR_MODEL", "some-instruct-model"}
      ])

    assert config[:base_url] == "https://other.example/v1"
    assert config[:model] == "some-instruct-model"
    refute Keyword.has_key?(config, :adapter)
  end

  test "an unknown adapter name raises instead of guessing" do
    assert_raise RuntimeError, ~r/ADVISOR_ADAPTER/, fn ->
      advisor_config([{"ADVISOR_ADAPTER", "anthropic"}])
    end
  end

  test "without ADVISOR_ENABLED, runtime config leaves the fallback flag untouched" do
    assert advisor_enabled([]) == nil
  end

  test "ADVISOR_ENABLED=true turns the unmatched-incident fallback on" do
    assert advisor_enabled([{"ADVISOR_ENABLED", "1"}]) == true
    assert advisor_enabled([{"ADVISOR_ENABLED", "true"}]) == true
    assert advisor_enabled([{"ADVISOR_ENABLED", " TRUE "}]) == true
  end

  test "ADVISOR_ENABLED=false turns the fallback off explicitly" do
    assert advisor_enabled([{"ADVISOR_ENABLED", "false"}]) == false
  end

  test "an unrecognised ADVISOR_ENABLED value reads as off instead of raising" do
    assert advisor_enabled([{"ADVISOR_ENABLED", "yes please"}]) == false
    assert advisor_enabled([{"ADVISOR_ENABLED", ""}]) == false
  end
end
