defmodule Kubeybilly.Executor.Real do
  @moduledoc """
  The one module that mutates the cluster, running the seven-step
  sequence from plan/03 for every action it is handed.

  Kill switch, then mode, then budgets, then evidence, then the inverse
  assertion, then exactly one mutating call, then telemetry and the
  PubSub event. Keeping the whole sequence in this file keeps the entire
  mutation policy reviewable in one place, which is the point of the
  executor boundary.

  Two deliberate asymmetries. A dry run returns before budgets are even
  consulted, because a mode that promises "nothing mutates" must also
  spend nothing. A client error, by contrast, leaves the budget spent:
  once the call left the process the cluster may have acted on it, and
  an unspent budget after an ambiguous write would let the system retry
  its way past its own limits.
  """

  @behaviour Kubeybilly.Executor

  require Logger

  alias Kubeybilly.Executor.Budgets
  alias Kubeybilly.Executor.KillSwitch
  alias Kubeybilly.Formulary.Action
  alias Kubeybilly.Incident.Record
  alias Kubeybilly.K8sClient
  alias Kubeybilly.Soundings.Bundle
  alias Kubeybilly.StandingOrders.Decision

  @execute_event [:kubeybilly, :executor, :execute]
  @topic "incidents"
  @restarted_at_annotation "kubectl.kubernetes.io/restartedAt"

  @impl Kubeybilly.Executor
  def execute(%Action{} = action, %Decision{} = decision, %Record{} = record) do
    cond do
      KillSwitch.engaged?() ->
        conclude({:error, :kill_switch_engaged}, action, record)

      decision.mode == :dry_run ->
        dry_run(action, record)

      true ->
        perform(action, decision, record)
    end
  end

  ## Steps 3 to 7

  defp perform(action, decision, record) do
    with {:ok, counts} <- consume(record, decision),
         :ok <- check_evidence(record),
         :ok <- check_inverse(action, record),
         {:ok, _response} <- mutate(K8sClient.impl(), action) do
      broadcast(record, action)

      conclude(
        {:ok,
         %{
           action: action.name,
           params: action.params,
           inverse_class: action.inverse_class,
           budget: counts
         }},
        action,
        record
      )
    else
      {:error, _reason} = error -> conclude(error, action, record)
    end
  end

  defp consume(record, decision) do
    case Budgets.consume(Budgets.server(), record.id, decision.budgets) do
      {:ok, counts} -> {:ok, counts}
      {:error, :budget_exceeded, which} -> {:error, {:budget_exceeded, which}}
    end
  end

  # An incident whose bundle manifest never landed has no evidence to
  # justify a mutation; acting on it would be acting on a hunch.
  defp check_evidence(record) do
    manifest =
      record.id
      |> Bundle.new()
      |> Bundle.absolute(Bundle.manifest_path())

    if File.exists?(manifest), do: :ok, else: {:error, :evidence_missing}
  end

  # An invertible action must carry its recorded inverse, with one
  # exception: the recorded inverse itself, executed as a revert. Its own
  # inverse would be the mitigation that just verified as worse, which is
  # deliberately not re-recorded.
  defp check_inverse(%Action{inverse_class: :invertible, inverse: nil} = action, record) do
    case record.action do
      %Action{inverse: ^action} -> :ok
      _other -> {:error, :inverse_missing}
    end
  end

  defp check_inverse(%Action{}, _record), do: :ok

  ## Step 6: the single mutating call

  defp mutate(client, %Action{name: :rollback_deployment} = action) do
    %{namespace: namespace, name: name} = action.params
    call(client.patch("Deployment", name, namespace, Map.fetch!(action.facts, :patch)))
  end

  defp mutate(client, %Action{name: :restart_workload} = action) do
    %{namespace: namespace, kind: kind, name: name} = action.params

    stamp = DateTime.utc_now(:second) |> DateTime.to_iso8601()

    patch = %{
      "spec" => %{
        "template" => %{"metadata" => %{"annotations" => %{@restarted_at_annotation => stamp}}}
      }
    }

    call(client.patch(kind, name, namespace, patch))
  end

  defp mutate(client, %Action{name: :restart_pod} = action) do
    call(client.delete_pod(action.params.namespace, action.params.name))
  end

  defp mutate(client, %Action{name: :scale} = action) do
    %{namespace: namespace, kind: kind, name: name, replicas: replicas} = action.params
    call(client.scale(kind, name, namespace, replicas))
  end

  defp mutate(client, %Action{name: :cordon_node} = action) do
    call(client.patch("Node", action.params.name, nil, unschedulable(true)))
  end

  defp mutate(client, %Action{name: :uncordon_node} = action) do
    call(client.patch("Node", action.params.name, nil, unschedulable(false)))
  end

  defp unschedulable(engaged), do: %{"spec" => %{"unschedulable" => engaged}}

  # The budget stays spent on a client error: the call left the process,
  # so the cluster may have acted even though the answer was an error.
  defp call({:ok, response}), do: {:ok, response}
  defp call({:error, reason}), do: {:error, {:execute, reason}}

  ## Step 2: dry run

  defp dry_run(action, record) do
    Logger.info(
      "dry run: incident #{record.id} would execute #{inspect(action.name)} " <>
        "#{inspect(action.params)} (inverse: #{describe_inverse(action)})"
    )

    conclude({:ok, %{dry_run: true, would_execute: action}}, action, record)
  end

  defp describe_inverse(%Action{inverse: %Action{} = inverse}) do
    "#{inspect(inverse.name)} #{inspect(inverse.params)}"
  end

  defp describe_inverse(%Action{inverse_class: class}), do: inspect(class)

  ## Step 7: telemetry and PubSub

  defp broadcast(record, action) do
    Phoenix.PubSub.broadcast(Kubeybilly.PubSub, @topic, {:executed, record.id, action.name})
  end

  defp conclude(result, action, record) do
    :telemetry.execute(@execute_event, %{system_time: System.system_time()}, %{
      outcome: outcome(result),
      action: action.name,
      incident_id: record.id
    })

    result
  end

  defp outcome({:ok, %{dry_run: true}}), do: :dry_run
  defp outcome({:ok, _result}), do: :ok
  defp outcome({:error, :kill_switch_engaged}), do: :kill_switch_engaged
  defp outcome({:error, {:budget_exceeded, _which}}), do: :budget_exceeded
  defp outcome({:error, :evidence_missing}), do: :evidence_missing
  defp outcome({:error, :inverse_missing}), do: :inverse_missing
  defp outcome({:error, {:execute, _reason}}), do: :execute_failed
end
