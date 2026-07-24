defmodule Kubeybilly.Incident.Recovery do
  @moduledoc """
  The boot pass over the incidents directory.

  Any record still open on disk at boot describes an incident whose
  process died with the node, possibly mid-mutation, and the plan's rule
  is absolute: KubeyBilly never resumes a mutation it cannot prove the
  state of. Each such record is closed as `:interrupted` and escalated
  on disk before ingest wiring starts, so nothing can route new alerts
  into a ghost and the dashboard reports the interruption honestly.

  Runs synchronously from the supervision tree: the child start function
  performs the scan and then returns `:ignore`, which guarantees every
  child after it in the tree boots against a clean directory.
  """

  alias Kubeybilly.Incident.Record

  @recovery_event [:kubeybilly, :incident, :boot_recovery]

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :worker
    }
  end

  @doc "Run the scan during supervisor start; no process is left behind."
  @spec start_link(keyword()) :: :ignore
  def start_link(opts) do
    {:ok, _closed} =
      opts
      |> Keyword.get_lazy(:root, fn ->
        Application.get_env(:kubeybilly, :incidents_dir, "incidents")
      end)
      |> run()

    :ignore
  end

  @doc """
  Close every open record under the root as interrupted.

  Returns the incident ids that were closed. A missing directory is a
  fresh install, not an error; unreadable or foreign entries are
  skipped, because recovery must never prevent boot.
  """
  @spec run(Path.t()) :: {:ok, [String.t()]}
  def run(root) do
    closed =
      case File.ls(root) do
        {:ok, entries} -> entries |> Enum.sort() |> Enum.filter(&close_if_open(root, &1))
        {:error, _reason} -> []
      end

    {:ok, closed}
  end

  defp close_if_open(root, id) do
    case Record.from_disk(id, root: root) do
      {:ok, record} -> Record.open?(record) and close_interrupted(root, record)
      {:error, _reason} -> false
    end
  end

  defp close_interrupted(root, record) do
    :ok =
      record
      |> Record.close(:interrupted)
      |> Record.append(:interrupted, %{by: :boot_recovery})
      |> Record.to_disk(root: root)

    :telemetry.execute(@recovery_event, %{system_time: System.system_time()}, %{
      incident_id: record.id
    })

    true
  end
end
