defmodule Kubeybilly.Executor.KillSwitchTest do
  # async: false: the kill switch mirrors into a single global
  # :persistent_term key, shared with the application-started instance.
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Kubeybilly.Executor.KillSwitch

  @key {Kubeybilly, :killswitch}

  setup do
    dir =
      System.tmp_dir!()
      |> Path.join("kubeybilly-killswitch-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    previous = :persistent_term.get(@key, false)

    on_exit(fn ->
      :persistent_term.put(@key, previous)
      File.rm_rf(dir)
    end)

    %{path: Path.join(dir, "engaged")}
  end

  defp start_switch(opts) do
    start_supervised!(
      {KillSwitch, Keyword.merge([name: nil, poll_ms: 20], opts)},
      id: :"kill_switch_#{System.unique_integer([:positive])}"
    )
  end

  defp await(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries > 0 -> Process.sleep(10) && await(fun, tries - 1)
      true -> flunk("condition never held")
    end
  end

  test "engaged?/0 is a free read defaulting to disengaged" do
    :persistent_term.erase(@key)
    refute KillSwitch.engaged?()
  end

  test "a nil path means the switch is disengaged and nothing polls" do
    :persistent_term.put(@key, true)
    start_switch(path: nil)
    refute KillSwitch.engaged?()
  end

  test "a missing file means disengaged", %{path: path} do
    start_switch(path: path)
    refute KillSwitch.engaged?()
  end

  test "a file containing true engages the switch at startup", %{path: path} do
    File.write!(path, "true\n")
    start_switch(path: path)
    assert KillSwitch.engaged?()
  end

  test "anything but a trimmed true reads as disengaged", %{path: path} do
    File.write!(path, "yes please")
    start_switch(path: path)
    refute KillSwitch.engaged?()
  end

  test "flipping the file flips the mirror within a poll", %{path: path} do
    File.write!(path, "false")
    start_switch(path: path)
    refute KillSwitch.engaged?()

    File.write!(path, "true")
    await(fn -> KillSwitch.engaged?() end)

    File.write!(path, "false")
    await(fn -> not KillSwitch.engaged?() end)
  end

  test "deleting the file disengages the switch", %{path: path} do
    File.write!(path, "true")
    start_switch(path: path)
    assert KillSwitch.engaged?()

    File.rm!(path)
    await(fn -> not KillSwitch.engaged?() end)
  end

  test "every flip emits telemetry", %{path: path} do
    parent = self()
    handler_id = "kill-switch-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:kubeybilly, :executor, :kill_switch],
      fn _event, _measurements, metadata, _config -> send(parent, {:kill_switch, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :persistent_term.put(@key, false)
    File.write!(path, "true")
    start_switch(path: path)

    assert_receive {:kill_switch, %{engaged: true}}, 1000

    File.write!(path, "false")
    assert_receive {:kill_switch, %{engaged: false}}, 1000
  end
end
