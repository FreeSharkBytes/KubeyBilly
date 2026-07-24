defmodule Kubeybilly.Incident.Registry do
  @moduledoc """
  Names every incident machine three ways, so the concurrency invariants
  are lookups instead of scans.

  Each machine registers under its incident id (for addressing), its
  Alertmanager group key (so webhook redelivery routes to the open
  incident instead of spawning a second), and its target workload's
  namespace and UID (so two state machines can never act on the same
  workload). Keys are unique, and the Registry unregisters automatically
  when a machine closes, which is what makes "open incident" and
  "registered" the same fact.
  """

  @doc "Child spec: a unique-keyed Registry under this module's name."
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: __MODULE__)
  end

  @doc "The via tuple a machine starts under, keyed by incident id."
  @spec via(String.t()) :: {:via, Registry, {module(), {:incident, String.t()}}}
  def via(incident_id) do
    {:via, Registry, {__MODULE__, {:incident, incident_id}}}
  end

  @doc "Register the calling machine as the open incident for a workload."
  @spec register_workload(String.t(), String.t()) ::
          {:ok, pid()} | {:error, {:already_registered, pid()}}
  def register_workload(namespace, workload_uid) do
    Registry.register(__MODULE__, {:workload, namespace, workload_uid}, nil)
  end

  @doc "Register the calling machine as the open incident for a group key."
  @spec register_group_key(String.t()) ::
          {:ok, pid()} | {:error, {:already_registered, pid()}}
  def register_group_key(group_key) do
    Registry.register(__MODULE__, {:group_key, group_key}, nil)
  end

  @doc "Find the open incident machine by incident id."
  @spec whereis_incident(String.t()) :: {:ok, pid()} | :error
  def whereis_incident(incident_id), do: lookup({:incident, incident_id})

  @doc "Find the open incident machine for a workload."
  @spec whereis_workload(String.t(), String.t()) :: {:ok, pid()} | :error
  def whereis_workload(namespace, workload_uid) do
    lookup({:workload, namespace, workload_uid})
  end

  @doc "Find the open incident machine for an Alertmanager group key."
  @spec whereis_group_key(String.t()) :: {:ok, pid()} | :error
  def whereis_group_key(group_key), do: lookup({:group_key, group_key})

  defp lookup(key) do
    case Registry.lookup(__MODULE__, key) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end
end
