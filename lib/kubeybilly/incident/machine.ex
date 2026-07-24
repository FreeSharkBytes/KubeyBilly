defmodule Kubeybilly.Incident.Machine do
  @moduledoc """
  One `:gen_statem` per incident, walking the pipeline from evidence to
  outcome: `collecting`, `gating`, `awaiting_approval`, `acting`,
  `verifying`, `reverting`, `closed`.

  The machine owns sequencing and timeouts, nothing else: collection and
  verification run in tasks so the process stays responsive to resolved
  notifications and alert updates; mutation happens only behind the
  `Kubeybilly.Executor` behaviour; judgment happens only behind
  `Kubeybilly.Verifier`. The approval timeout and the verification
  window are state timeouts, not scheduled jobs, and the approval
  timeout escalates rather than proceeds (plan/04). Every transition
  appends to the record's timeline, persists it to disk, and emits
  `[:kubeybilly, :incident, :transition]`, so a crash at any instant
  leaves a record that tells the truth up to its last write.
  """

  @behaviour :gen_statem

  alias Kubeybilly.Executor
  alias Kubeybilly.Formulary.Inverse
  alias Kubeybilly.Formulary.Validator
  alias Kubeybilly.Incident.Intent
  alias Kubeybilly.Incident.Monitor
  alias Kubeybilly.Incident.Record
  alias Kubeybilly.Incident.Registry, as: IncidentRegistry
  alias Kubeybilly.K8sClient
  alias Kubeybilly.Signatures.LoadedBundle
  alias Kubeybilly.Signatures.Triage
  alias Kubeybilly.Soundings.Bundle
  alias Kubeybilly.Soundings.Collector
  alias Kubeybilly.StandingOrders.Evaluator
  alias Kubeybilly.Verifier

  @transition_event [:kubeybilly, :incident, :transition]
  @task_supervisor Kubeybilly.Soundings.TaskSupervisor
  @kill_switch_key {:kubeybilly, :kill_switch}

  ## Client API

  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts) do
    id =
      Keyword.get_lazy(opts, :id, fn ->
        Bundle.incident_id(Keyword.fetch!(opts, :group_key), DateTime.utc_now())
      end)

    :gen_statem.start_link(IncidentRegistry.via(id), __MODULE__, Keyword.put(opts, :id, id), [])
  end

  @doc "Temporary on purpose: a crashed incident is never restarted (plan/01)."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  @doc "Route a resolved notification for the incident's alert group."
  @spec resolve(:gen_statem.server_ref(), String.t()) :: :ok
  def resolve(server, group_key), do: :gen_statem.cast(server, {:resolved, group_key})

  @doc "Route a redelivered or grown alert group to the open incident."
  @spec alerts(:gen_statem.server_ref(), map()) :: :ok
  def alerts(server, group), do: :gen_statem.cast(server, {:alerts, group})

  @doc "A human said yes while the incident awaited approval."
  @spec approve(:gen_statem.server_ref()) :: :ok
  def approve(server), do: :gen_statem.cast(server, {:approval, :granted})

  @doc "A human said no while the incident awaited approval."
  @spec deny(:gen_statem.server_ref()) :: :ok
  def deny(server), do: :gen_statem.cast(server, {:approval, :denied})

  ## gen_statem callbacks

  @impl :gen_statem
  def callback_mode, do: :handle_event_function

  @impl :gen_statem
  def init(opts) do
    policy = Keyword.fetch!(opts, :policy)

    record =
      Record.new(%{
        id: Keyword.fetch!(opts, :id),
        group_key: Keyword.fetch!(opts, :group_key),
        namespace: Keyword.fetch!(opts, :namespace),
        workload: Keyword.fetch!(opts, :workload),
        pods: Keyword.get(opts, :pods, []),
        nodes: Keyword.get(opts, :nodes, [])
      })

    data = %{
      record: record,
      policy: policy,
      collector: Keyword.get(opts, :collector, &Collector.collect/2),
      executor: Keyword.get_lazy(opts, :executor, &Executor.impl/0),
      verifier: Keyword.get_lazy(opts, :verifier, &Verifier.impl/0),
      client: Keyword.get_lazy(opts, :client, &K8sClient.impl/0),
      context: Keyword.get(opts, :context, %{}),
      approval_timeout_ms:
        Keyword.get(opts, :approval_timeout_ms, :timer.seconds(policy.approval.timeout_seconds)),
      verification_timeout_ms:
        Keyword.get(
          opts,
          :verification_timeout_ms,
          :timer.seconds(policy.verification.window_seconds)
        ),
      task: nil,
      baseline: nil
    }

    with {:ok, _} <- IncidentRegistry.register_workload(record.namespace, record.workload.uid),
         {:ok, _} <- IncidentRegistry.register_group_key(record.group_key) do
      Monitor.watch(record.id)
      data = persist(update_record(data, &Record.append(&1, :opened, %{})))
      emit(record, nil, :collecting, :opened)
      {:ok, :collecting, data, [{:next_event, :internal, :start_collect}]}
    else
      {:error, {:already_registered, pid}} -> {:stop, {:already_open, pid}}
    end
  end

  ## Resolved-before-action and alert updates (any state)

  @impl :gen_statem
  def handle_event(:cast, {:resolved, _group_key}, state, data)
      when state in [:collecting, :gating] do
    close(shutdown_task(data), state, :resolved_before_action, :resolved_before_action, %{})
  end

  def handle_event(:cast, {:resolved, _group_key}, _state, data) do
    # Too late to matter for the outcome (plan/05: alert latency means a
    # resolve here proves nothing), but the timeline keeps the fact.
    {:keep_state, persist(update_record(data, &Record.append(&1, :resolved_notification, %{})))}
  end

  def handle_event(:cast, {:alerts, group}, _state, data) do
    detail = %{
      group_key: group["groupKey"],
      alerts: length(List.wrap(group["alerts"]))
    }

    {:keep_state, persist(update_record(data, &Record.append(&1, :alerts_update, detail)))}
  end

  ## collecting

  def handle_event(:internal, :start_collect, :collecting, data) do
    %{record: record, collector: collector} = data

    target = %{
      incident_id: record.id,
      namespace: record.namespace,
      workload_kind: record.workload.kind,
      workload_name: record.workload.name,
      pods: record.pods,
      nodes: record.nodes
    }

    task = Task.Supervisor.async_nolink(@task_supervisor, fn -> collector.(target, []) end)
    {:keep_state, %{data | task: task}}
  end

  def handle_event(:info, {ref, result}, :collecting, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    data = %{data | task: nil}

    case result do
      {:ok, %{"complete" => true}} ->
        transition(data, :collecting, :gating, :evidence_sealed, %{}, [
          {:next_event, :internal, :gate}
        ])

      {:ok, manifest} ->
        close(data, :collecting, :escalated, :evidence_incomplete, %{
          gaps: List.wrap(manifest["gaps"])
        })

      {:error, reason} ->
        close(data, :collecting, :escalated, :evidence_incomplete, %{reason: inspect(reason)})
    end
  end

  def handle_event(
        :info,
        {:DOWN, ref, :process, _pid, reason},
        :collecting,
        %{
          task: %Task{ref: ref}
        } = data
      ) do
    close(%{data | task: nil}, :collecting, :escalated, :evidence_incomplete, %{
      reason: inspect(reason)
    })
  end

  ## gating

  def handle_event(:internal, :gate, :gating, data) do
    case gate(data) do
      {:permit_auto, data} ->
        transition(data, :gating, :acting, :permitted, decision_detail(data), [
          {:next_event, :internal, :execute}
        ])

      {:needs_approval, data} ->
        transition(
          data,
          :gating,
          :awaiting_approval,
          :approval_requested,
          decision_detail(data),
          [
            {:state_timeout, data.approval_timeout_ms, :approval_timeout}
          ]
        )

      {:deny, data} ->
        close(data, :gating, :declined, :policy_denied, decision_detail(data))

      {:no_action, data, detail} ->
        close(data, :gating, :escalated, :no_action, detail)

      {:escalate, data, event, detail} ->
        close(data, :gating, :escalated, event, detail)
    end
  end

  ## awaiting_approval

  def handle_event(:cast, {:approval, :granted}, :awaiting_approval, data) do
    transition(data, :awaiting_approval, :acting, :approval_granted, %{}, [
      {:next_event, :internal, :execute}
    ])
  end

  def handle_event(:cast, {:approval, :denied}, :awaiting_approval, data) do
    close(data, :awaiting_approval, :declined, :approval_denied, %{})
  end

  def handle_event(:state_timeout, :approval_timeout, :awaiting_approval, data) do
    close(data, :awaiting_approval, :escalated, :approval_timeout, %{
      timeout_ms: data.approval_timeout_ms
    })
  end

  ## acting

  def handle_event(:internal, :execute, :acting, data) do
    %{record: record} = data

    case data.executor.execute(record.action, record.decision, record) do
      {:ok, exec_result} ->
        transition(data, :acting, :verifying, :executed, %{result: exec_result}, [
          {:next_event, :internal, :start_verify},
          {:state_timeout, data.verification_timeout_ms, :verification_timeout}
        ])

      {:error, reason} ->
        close(data, :acting, :escalated, :execution_failed, %{reason: inspect(reason)})
    end
  end

  ## verifying

  def handle_event(:internal, :start_verify, :verifying, data) do
    %{record: record, baseline: baseline, verifier: verifier, policy: policy} = data
    opts = [window_seconds: policy.verification.window_seconds]

    task =
      Task.Supervisor.async_nolink(@task_supervisor, fn ->
        verifier.verify(record, baseline, opts)
      end)

    {:keep_state, %{data | task: task}}
  end

  def handle_event(:info, {ref, {:ok, outcome}}, :verifying, %{task: %Task{ref: ref}} = data)
      when outcome in [:recovered, :unchanged, :worse] do
    Process.demonitor(ref, [:flush])
    data = update_record(%{data | task: nil}, &%{&1 | verification_outcome: outcome})

    case outcome do
      :recovered -> close(data, :verifying, :recovered, :verified_recovered, %{})
      :unchanged -> close(data, :verifying, :escalated, :verified_unchanged, %{})
      :worse -> handle_worse(data)
    end
  end

  def handle_event(
        :info,
        {:DOWN, ref, :process, _pid, reason},
        :verifying,
        %{
          task: %Task{ref: ref}
        } = data
      ) do
    close(%{data | task: nil}, :verifying, :escalated, :verifier_crashed, %{
      reason: inspect(reason)
    })
  end

  # The backstop: a verifier that never answers inside the window is an
  # unchanged outcome, and unchanged escalates.
  def handle_event(:state_timeout, :verification_timeout, :verifying, data) do
    data =
      data
      |> shutdown_task()
      |> update_record(&%{&1 | verification_outcome: :unchanged})

    close(data, :verifying, :escalated, :verification_window_expired, %{
      window_ms: data.verification_timeout_ms
    })
  end

  ## reverting

  def handle_event(:internal, :revert, :reverting, data) do
    %{record: record} = data

    detail =
      case data.executor.execute(record.action.inverse, record.decision, record) do
        {:ok, _exec_result} -> %{reverted: true}
        {:error, reason} -> %{reverted: false, reason: inspect(reason)}
      end

    # Hard stop regardless of remaining budget (plan/05): after a revert
    # the incident escalates, it never tries a second mitigation.
    close(data, :reverting, :escalated, :reverted_hard_stop, detail)
  end

  ## closed

  def handle_event(:internal, :halt, :closed, _data) do
    {:stop, :normal}
  end

  # Late task replies, stale timeouts, and casts that no longer apply
  # are recorded facts elsewhere; here they must simply not crash.
  def handle_event(_type, _event, _state, data), do: {:keep_state, data}

  ## The gate pipeline

  defp gate(data) do
    bundle = Bundle.new(data.record.id)

    case LoadedBundle.load(Bundle.dir(bundle)) do
      {:error, reason} ->
        {:escalate, data, :evidence_unreadable, %{reason: inspect(reason)}}

      {:ok, loaded} ->
        triage(%{data | baseline: loaded.baseline}, loaded)
    end
  end

  defp triage(data, loaded) do
    case Triage.run(loaded) do
      {:match, signature} ->
        gate_signature(data, signature)

      :no_match ->
        case advise(loaded) do
          {:match, signature} -> gate_signature(data, signature)
          :no_match -> {:escalate, data, :no_signature_match, %{advisor: advisor_enabled?()}}
        end
    end
  end

  # The advisor arrives in a later build step (plan/14); until enabled,
  # an unmatched bundle escalates to a human, which is the safe default.
  defp advise(loaded) do
    advisor = Application.get_env(:kubeybilly, :advisor)

    if advisor_enabled?() and is_atom(advisor) and not is_nil(advisor) do
      advisor.advise(loaded)
    else
      :no_match
    end
  end

  defp advisor_enabled? do
    Application.get_env(:kubeybilly, :advisor_enabled, false)
  end

  defp gate_signature(data, signature) do
    data = update_record(data, &%{&1 | signature: signature})

    with {:action, {:ok, action}} <- {:action, Intent.to_action(signature)},
         {:validate, {:ok, %{action: action, facts: facts}}} <-
           {:validate, Validator.validate(action, data.client)},
         {:inverse, {:ok, action}} <- {:inverse, Inverse.construct(action, facts)} do
      decision =
        Evaluator.evaluate(
          data.policy,
          evaluator_intent(data, signature, action, facts),
          evaluator_context(data)
        )

      data = update_record(data, &%{&1 | action: action, decision: decision})
      route_decision(data, decision, signature)
    else
      {:action, {:error, detail}} ->
        {:escalate, data, :invalid_intent, %{detail: inspect(detail)}}

      {:validate, {:error, {:validation, rule, detail}}} ->
        {:escalate, data, :validation_failed, %{rule: rule, detail: inspect(detail)}}

      {:inverse, {:error, :inverse_unconstructible}} ->
        {:escalate, data, :inverse_unconstructible, %{action: signature.proposed_action.action}}
    end
  end

  # Declining to act is itself an escalation: the signature explains why
  # nothing should be done, and a human takes it from there (plan/02).
  defp route_decision(%{record: %{action: %{name: :no_action}}} = data, _decision, signature) do
    {:no_action, data, %{rationale: signature.rationale}}
  end

  defp route_decision(data, decision, _signature) do
    case decision.verdict do
      :permit_auto -> {:permit_auto, data}
      :needs_approval -> {:needs_approval, data}
      :deny -> {:deny, data}
    end
  end

  defp evaluator_intent(data, signature, action, facts) do
    %{
      action: action.name,
      params: Map.merge(action.params, Map.take(facts, [:current_replicas])),
      confidence: signature.confidence,
      blast_estimate: action.blast_estimate,
      target_kind: data.record.workload.kind,
      namespace: data.record.namespace,
      owner_kinds: []
    }
  end

  # Budget counters and freeze detection arrive with the executor build
  # step; until then the context carries the honest static facts, and
  # tests override via :context.
  defp evaluator_context(data) do
    defaults = %{
      kill_switch_engaged: :persistent_term.get(@kill_switch_key, false),
      rollout_in_progress: false,
      expected_rollout: false,
      maintenance_window: false,
      actions_this_incident: 0,
      actions_this_hour: 0,
      mode: data.policy.mode
    }

    Map.merge(defaults, data.context)
  end

  defp decision_detail(%{record: %{decision: nil}}), do: %{}

  defp decision_detail(%{record: %{decision: decision}}) do
    %{verdict: decision.verdict, rule_id: decision.rule_id, reason: decision.reason}
  end

  ## Worse routing

  # A worse outcome runs the recorded inverse, except where plan/03
  # freezes instead: a rollback's inverse redeploys a known-bad revision,
  # and irreversible actions have nothing to run.
  defp handle_worse(data) do
    action = data.record.action

    if action.inverse != nil and action.name != :rollback_deployment do
      transition(
        data,
        :verifying,
        :reverting,
        :worse_reverting,
        %{inverse: action.inverse.name},
        [
          {:next_event, :internal, :revert}
        ]
      )
    else
      close(data, :verifying, :escalated, :frozen_after_worse, %{
        action: action.name,
        inverse_class: action.inverse_class
      })
    end
  end

  ## Transition plumbing

  defp transition(data, from, to, event, detail, actions) do
    data = persist(update_record(data, &Record.append(&1, event, detail)))
    emit(data.record, from, to, event)
    {:next_state, to, data, actions}
  end

  defp close(data, from, outcome, event, detail) do
    data =
      persist(
        update_record(data, fn record ->
          record |> Record.close(outcome) |> Record.append(event, detail)
        end)
      )

    emit(data.record, from, :closed, event)
    {:next_state, :closed, data, [{:next_event, :internal, :halt}]}
  end

  defp update_record(data, fun), do: %{data | record: fun.(data.record)}

  # A record that cannot be written may not carry the incident further:
  # crashing here is the evidence-before-anything rule applied to state.
  defp persist(data) do
    :ok = Record.to_disk(data.record)
    data
  end

  defp emit(record, from, to, event) do
    :telemetry.execute(@transition_event, %{system_time: System.system_time()}, %{
      incident_id: record.id,
      from: from,
      to: to,
      event: event,
      status: record.status,
      outcome: record.outcome
    })
  end

  defp shutdown_task(%{task: nil} = data), do: data

  defp shutdown_task(%{task: task} = data) do
    Task.shutdown(task, :brutal_kill)
    %{data | task: nil}
  end
end
