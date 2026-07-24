defmodule Kubeybilly.Incident.RegistryTest do
  use ExUnit.Case, async: false

  alias Kubeybilly.Incident.Registry, as: IncidentRegistry

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  test "a process is addressable via its incident id" do
    id = unique("incident")

    {:ok, agent} = Agent.start_link(fn -> :ok end, name: IncidentRegistry.via(id))

    assert {:ok, ^agent} = IncidentRegistry.whereis_incident(id)
    Agent.stop(agent)
    wait_until(fn -> IncidentRegistry.whereis_incident(id) == :error end)
  end

  test "workload registration is unique per namespace and uid" do
    uid = unique("uid")

    task =
      Task.async(fn ->
        {:ok, _} = IncidentRegistry.register_workload("demo", uid)

        receive do
          :release -> :ok
        end
      end)

    wait_until(fn -> IncidentRegistry.whereis_workload("demo", uid) != :error end)
    assert {:ok, pid} = IncidentRegistry.whereis_workload("demo", uid)

    assert {:error, {:already_registered, ^pid}} =
             IncidentRegistry.register_workload("demo", uid)

    send(task.pid, :release)
    Task.await(task)

    wait_until(fn -> IncidentRegistry.whereis_workload("demo", uid) == :error end)
  end

  test "group key registration resolves to the registering process" do
    group_key = unique("gk")

    task =
      Task.async(fn ->
        {:ok, _} = IncidentRegistry.register_group_key(group_key)

        receive do
          :release -> :ok
        end
      end)

    wait_until(fn -> IncidentRegistry.whereis_group_key(group_key) != :error end)
    assert {:ok, pid} = IncidentRegistry.whereis_group_key(group_key)
    assert pid == task.pid

    send(task.pid, :release)
    Task.await(task)
  end

  defp wait_until(fun, tries \\ 100)

  defp wait_until(fun, 0), do: assert(fun.())

  defp wait_until(fun, tries) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, tries - 1)
    end
  end
end
