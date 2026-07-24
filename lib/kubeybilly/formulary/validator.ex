defmodule Kubeybilly.Formulary.Validator do
  @moduledoc """
  Checks an action against the live cluster before anything may act on it.

  A validation failure is data for a decline, never an exception: every
  failure is `{:error, {:validation, rule, detail}}` so the pipeline can
  log, report, and count the reason. Success carries the facts gathered
  while checking (current revision, current replicas, live pod count),
  because the same reads feed the inverse construction and the blast
  estimate, and re-reading the cluster later would race the incident.

  Every outcome, pass or decline, emits telemetry so declines are counted
  as results rather than disappearing as absences of behaviour.
  """

  alias Kubeybilly.Formulary.Action
  alias Kubeybilly.Formulary.Rollback
  alias Kubeybilly.K8sClient
  alias Kubeybilly.Soundings.LabelSelector

  @validate_event [:kubeybilly, :formulary, :validate]

  @typedoc "A validated action plus the cluster facts gathered proving it."
  @type validated :: %{action: Action.t(), facts: map()}

  @typedoc "Why validation declined the action."
  @type error :: {:validation, rule :: atom(), detail :: term()}

  @doc """
  Validate the action's parameters against the live cluster.

  The returned action carries its blast estimate (pods touched); the
  facts map carries whatever the per-action preconditions had to read.
  """
  @spec validate(Action.t(), module()) :: {:ok, validated()} | {:error, error()}
  def validate(action, client \\ K8sClient.impl())

  def validate(%Action{} = action, client) do
    action
    |> check(client)
    |> emit(action)
  end

  defp check(%Action{name: :no_action} = action, _client),
    do: {:ok, %{action: action, facts: %{}}}

  defp check(%Action{name: :rollback_deployment} = action, client) do
    %{namespace: namespace, name: name, to_revision: to_revision} = action.params

    with {:ok, deployment} <- fetch(client, "Deployment", name, namespace),
         selector = LabelSelector.workload_selector(deployment),
         {:ok, replicasets} <- list(client, "ReplicaSet", namespace, selector),
         {:ok, pods} <- list(client, "Pod", namespace, selector),
         {:ok, plan} <- plan_rollback(deployment, replicasets, to_revision) do
      facts = %{
        current_revision: plan.from_revision,
        live_pod_count: length(pods),
        patch: plan.patch
      }

      {:ok, %{action: %{action | blast_estimate: length(pods)}, facts: facts}}
    end
  end

  defp check(%Action{name: :scale} = action, client) do
    %{namespace: namespace, kind: kind, name: name, replicas: replicas} = action.params

    with {:ok, workload} <- fetch(client, kind, name, namespace) do
      current = get_in(workload, ["spec", "replicas"]) || 0
      delta = abs(replicas - current)

      {:ok,
       %{
         action: %{action | blast_estimate: delta},
         facts: %{current_replicas: current, delta: delta}
       }}
    end
  end

  defp check(%Action{name: :restart_workload} = action, client) do
    %{namespace: namespace, kind: kind, name: name} = action.params

    with {:ok, workload} <- fetch(client, kind, name, namespace),
         {:ok, pods} <- list(client, "Pod", namespace, LabelSelector.workload_selector(workload)) do
      {:ok,
       %{
         action: %{action | blast_estimate: length(pods)},
         facts: %{live_pod_count: length(pods)}
       }}
    end
  end

  defp check(%Action{name: :restart_pod} = action, client) do
    %{namespace: namespace, name: name} = action.params

    with {:ok, _pod} <- fetch(client, "Pod", name, namespace) do
      {:ok, %{action: %{action | blast_estimate: 1}, facts: %{live_pod_count: 1}}}
    end
  end

  defp check(%Action{name: :cordon_node} = action, client) do
    with {:ok, false} <- node_unschedulable(client, action.params.name) do
      {:ok, %{action: action, facts: %{unschedulable: false}}}
    else
      {:ok, true} -> {:error, {:validation, :already_cordoned, %{node: action.params.name}}}
      {:error, _reason} = error -> error
    end
  end

  defp check(%Action{name: :uncordon_node} = action, client) do
    with {:ok, true} <- node_unschedulable(client, action.params.name) do
      {:ok, %{action: action, facts: %{unschedulable: true}}}
    else
      {:ok, false} -> {:error, {:validation, :not_cordoned, %{node: action.params.name}}}
      {:error, _reason} = error -> error
    end
  end

  ## Per-action preconditions

  defp plan_rollback(deployment, replicasets, to_revision) do
    case Rollback.plan_from(deployment, replicasets, to_revision) do
      {:ok, %{from_revision: revision, to_revision: revision}} ->
        {:error, {:validation, :noop_rollback, %{revision: revision}}}

      {:ok, plan} ->
        {:ok, plan}

      {:error, {:rollback, :revision_not_found, detail}} ->
        {:error, {:validation, :revision_not_found, detail}}
    end
  end

  defp node_unschedulable(client, name) do
    with {:ok, node} <- fetch(client, "Node", name, nil) do
      {:ok, get_in(node, ["spec", "unschedulable"]) == true}
    end
  end

  ## Cluster reads, mapped to validation outcomes

  defp fetch(client, kind, name, namespace) do
    case client.get(kind, name, namespace) do
      {:ok, resource} ->
        check_kind(resource, kind, name, namespace)

      {:error, {:api, "NotFound", _message} = error} ->
        {:error,
         {:validation, :target_missing,
          %{kind: kind, name: name, namespace: namespace, error: error}}}

      {:error, error} ->
        {:error, {:validation, :cluster_unavailable, error}}
    end
  end

  # Typed API responses sometimes omit kind; only an explicit contradiction
  # between what was asked for and what came back is a mismatch.
  defp check_kind(resource, kind, name, namespace) do
    case Map.get(resource, "kind", kind) do
      ^kind ->
        {:ok, resource}

      found ->
        {:error,
         {:validation, :kind_mismatch,
          %{expected: kind, found: found, name: name, namespace: namespace}}}
    end
  end

  defp list(client, kind, namespace, selector) do
    case client.list(kind, namespace, selector) do
      {:ok, resources} -> {:ok, resources}
      {:error, error} -> {:error, {:validation, :cluster_unavailable, error}}
    end
  end

  ## Telemetry

  defp emit({:ok, %{action: validated}} = result, _action) do
    :telemetry.execute(@validate_event, %{blast_estimate: validated.blast_estimate}, %{
      action: validated.name,
      outcome: :ok
    })

    result
  end

  defp emit({:error, {:validation, rule, _detail}} = result, action) do
    :telemetry.execute(@validate_event, %{blast_estimate: 0}, %{
      action: action.name,
      outcome: :error,
      rule: rule
    })

    result
  end
end
