defmodule Kubeybilly.Incident.SupervisorTest do
  use ExUnit.Case, async: false

  alias Kubeybilly.Incident.Registry, as: IncidentRegistry
  alias Kubeybilly.Incident.Supervisor, as: IncidentSupervisor
  alias Kubeybilly.StandingOrders.Policy

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "kubeybilly-supervisor-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    previous = Application.get_env(:kubeybilly, :incidents_dir)
    Application.put_env(:kubeybilly, :incidents_dir, root)

    on_exit(fn ->
      Application.put_env(:kubeybilly, :incidents_dir, previous)
      File.rm_rf(root)
    end)

    :ok
  end

  defp machine_opts do
    suffix = System.unique_integer([:positive])

    [
      group_key: "gk-sup-#{suffix}",
      namespace: "demo",
      workload: %{kind: "Deployment", name: "web", uid: "uid-sup-#{suffix}"},
      policy: %Policy{tiers: %{"read" => Policy.default_read_tier()}},
      collector: fn _target, _opts ->
        Process.sleep(1_000)
        {:error, :idle}
      end
    ]
  end

  test "starts a temporary machine under the application supervisor" do
    opts = machine_opts()

    assert {:ok, pid} = IncidentSupervisor.start_incident(opts)
    assert {:ok, ^pid} = IncidentRegistry.whereis_group_key(opts[:group_key])

    Process.exit(pid, :shutdown)
  end

  test "max_children caps concurrent incidents" do
    supervisor =
      start_supervised!(
        {IncidentSupervisor, name: :"incident_sup_#{System.unique_integer()}", max_children: 1}
      )

    assert {:ok, pid} = IncidentSupervisor.start_incident(supervisor, machine_opts())

    assert {:error, :max_children} =
             IncidentSupervisor.start_incident(supervisor, machine_opts())

    Process.exit(pid, :shutdown)
  end
end
