defmodule Kubeybilly.Verification.Predicates do
  @moduledoc """
  The plan's outcome predicates as pure functions over frozen data.

  This is the headline safety judgment (revert hinges on `worse`, closing
  hinges on `recovered`), so every clause from plan/05 is a function of
  `(baseline, observation, action, settle_state)` with no clock, no
  client, and no process state; the verifier owns polling and stability
  counting, this module owns meaning.

  Self-rollout awareness lives in the settle state: a rollback is itself
  a rollout, so restart counting starts only when the rolled-to
  ReplicaSet reports its pods created and scheduled, and the reference
  restart counts are frozen at that instant. The rollback's own pods
  (everything the workload ran at baseline) are targets of the action,
  which is why their churn never reads as blast-radius spread; spread
  means something the action did not touch started failing.

  The new-alert clause is injectable (`:alert_check`, default
  always-false) because alert routing wires into verification in a later
  build step; the predicate's seam exists now so the clause is testable.
  """

  @typedoc """
  Whether the action's own rollout has settled, and the restart counts
  frozen at that instant (`%{pod => %{container => count}}`).
  """
  @type settle_state :: %{settled: boolean(), reference_restarts: map() | nil}

  @typedoc "A recovery condition still unmet, named for the escalation log."
  @type unmet_condition ::
          :action_settled
          | :ready_replicas
          | :no_restarts_since_settle
          | :rolled_to_available
          | :bad_replica_set_scaled_down
          | :service_endpoints

  @typedoc "Why an observation reads as worse."
  @type worse_reason ::
          :ready_replicas_dropped
          | :blast_radius_spread
          | :restart_rate_exceeded
          | :new_alert_signature

  @doc "The settle state before any observation: nothing settled, nothing frozen."
  @spec initial_settle_state() :: settle_state()
  def initial_settle_state, do: %{settled: false, reference_restarts: nil}

  @doc """
  Advance the settle state with a fresh observation.

  Non-rollback actions settle on their first observation. A rollback
  settles when the rolled-to ReplicaSet reports all its pods created and
  scheduled onto nodes; until then its churn is the action's own rollout,
  not evidence. Settling freezes the observation's restart counts as the
  reference every later delta is measured against; a settled state never
  unsettles.
  """
  @spec settle(settle_state(), map(), map()) :: settle_state()
  def settle(%{settled: true} = state, _observation, _action), do: state

  def settle(state, observation, %{name: :rollback_deployment, params: %{to_revision: revision}}) do
    if rollout_scheduled?(observation, revision) do
      mark_settled(state, observation)
    else
      state
    end
  end

  def settle(state, observation, _action), do: mark_settled(state, observation)

  @doc "Whether the action's own rollout has settled."
  @spec settled?(settle_state()) :: boolean()
  def settled?(%{settled: settled}), do: settled

  @doc """
  The recovered predicate: every plan/05 condition holds at this poll.

  Sustaining it for the stability period is the verifier's job; a single
  true here is a candidate, not an outcome.
  """
  @spec recovered?(map(), map(), map(), settle_state()) :: boolean()
  def recovered?(baseline, observation, action, state) do
    unmet(baseline, observation, action, state) == []
  end

  @doc """
  Which recovery conditions the observation has not met.

  The unchanged outcome escalates with exactly this list, so the names
  are the log's vocabulary, not internals.
  """
  @spec unmet(map(), map(), map(), settle_state()) :: [unmet_condition()]
  def unmet(baseline, observation, action, state) do
    conditions = [
      {:action_settled, settled?(state)},
      {:ready_replicas, observation["ready_replicas"] >= observation["desired_replicas"]},
      {:no_restarts_since_settle,
       settled?(state) and restarts_since_settle(observation, state) == 0},
      {:service_endpoints, services_ready?(baseline, observation)}
    ]

    conditions = conditions ++ rollback_conditions(baseline, observation, action)

    for {condition, met} <- conditions, not met, do: condition
  end

  @doc """
  The worse predicate: `:ok`, or the first reason the plan calls worse.

  Options:

    * `:pre_incident_restarts` - container restarts the bundle recorded
      in an equivalent period before the incident (default 0, meaning a
      previously restart-free workload tolerates none)
    * `:alert_check` - zero-arity function; truthy means a new distinct
      alert signature arrived for this incident scope (default never)
  """
  @spec worse(map(), map(), map(), settle_state(), keyword()) :: :ok | {:worse, worse_reason()}
  def worse(baseline, observation, action, state, opts \\ []) do
    cond do
      ready_dropped?(baseline, observation) ->
        {:worse, :ready_replicas_dropped}

      blast_radius_spread?(baseline, observation, action) ->
        {:worse, :blast_radius_spread}

      restart_rate_exceeded?(observation, state, opts) ->
        {:worse, :restart_rate_exceeded}

      new_alert?(opts) ->
        {:worse, :new_alert_signature}

      true ->
        :ok
    end
  end

  @doc """
  Container restarts observed since the action settled.

  Positive deltas against the frozen reference counts, summed across all
  currently observed pods; a pod born after settling contributes every
  restart it has, because nothing before the action explains them. Zero
  while unsettled, since there is no reference to measure against.
  """
  @spec restarts_since_settle(map(), settle_state()) :: non_neg_integer()
  def restarts_since_settle(_observation, %{settled: false}), do: 0

  def restarts_since_settle(observation, %{reference_restarts: reference}) do
    observation
    |> Map.get("pods", %{})
    |> Enum.flat_map(fn {pod, snapshot} ->
      Enum.map(snapshot["restart_counts"] || %{}, fn {container, count} ->
        max(count - (reference |> Map.get(pod, %{}) |> Map.get(container, 0)), 0)
      end)
    end)
    |> Enum.sum()
  end

  ## Settling

  defp mark_settled(state, observation) do
    %{state | settled: true, reference_restarts: restart_reference(observation)}
  end

  defp restart_reference(observation) do
    observation
    |> Map.get("pods", %{})
    |> Map.new(fn {pod, snapshot} -> {pod, snapshot["restart_counts"] || %{}} end)
  end

  # The rolled-to ReplicaSet reports pods scheduled: every replica it
  # wants exists, and every pod carrying its template hash has a node.
  defp rollout_scheduled?(observation, to_revision) do
    case rolled_to_replica_set(observation, to_revision) do
      nil ->
        false

      replica_set ->
        replica_set["spec_replicas"] > 0 and
          replica_set["status_replicas"] >= replica_set["spec_replicas"] and
          pods_scheduled?(observation, replica_set["template_hash"])
    end
  end

  defp pods_scheduled?(observation, template_hash) do
    observation
    |> Map.get("pods", %{})
    |> Map.values()
    |> Enum.filter(&(&1["template_hash"] == template_hash))
    |> Enum.all?(&(&1["node"] != nil))
  end

  ## Recovered conditions

  # Every Service selecting the workload needs at least one ready
  # endpoint; the union with the baseline's Services catches a Service
  # that vanished from observation, which is not recovery either.
  defp services_ready?(baseline, observation) do
    observed = observation["services"] || %{}
    known = Map.keys(baseline["services"] || %{}) ++ Map.keys(observed)

    Enum.all?(known, fn name ->
      (get_in(observed, [name, "ready_endpoints"]) || 0) >= 1
    end)
  end

  defp rollback_conditions(baseline, observation, %{
         name: :rollback_deployment,
         params: %{to_revision: revision}
       }) do
    rolled_to = rolled_to_replica_set(observation, revision)

    [
      {:rolled_to_available, replica_set_available?(rolled_to)},
      {:bad_replica_set_scaled_down, bad_scaled_down?(baseline, observation, rolled_to)}
    ]
  end

  defp rollback_conditions(_baseline, _observation, _action), do: []

  # A rollback reuses the rolled-to ReplicaSet and renumbers it, so the
  # target revision is found either as the current annotation (before the
  # controller renumbers) or in the revision history (after).
  defp rolled_to_replica_set(observation, to_revision) do
    target = to_string(to_revision)

    Enum.find(observation["replica_sets"] || [], fn replica_set ->
      replica_set["revision"] == target or target in (replica_set["revision_history"] || [])
    end)
  end

  defp replica_set_available?(nil), do: false

  defp replica_set_available?(replica_set) do
    replica_set["spec_replicas"] > 0 and
      replica_set["available_replicas"] >= replica_set["spec_replicas"]
  end

  # The bad ReplicaSet is the one at the baseline's revision: the state
  # the rollback moved away from. Absent means the controller already
  # deleted it, which is as scaled-down as it gets.
  defp bad_scaled_down?(baseline, observation, rolled_to) do
    bad_revision = baseline["revision"]

    bad =
      Enum.find(observation["replica_sets"] || [], fn replica_set ->
        is_binary(bad_revision) and replica_set["revision"] == bad_revision and
          (rolled_to == nil or replica_set["name"] != rolled_to["name"])
      end)

    bad == nil or (bad["spec_replicas"] == 0 and bad["status_replicas"] == 0)
  end

  ## Worse clauses

  defp ready_dropped?(baseline, observation) do
    observation["ready_replicas"] < baseline["ready_replicas"]
  end

  # A pod that was Ready at baseline, was not something the action
  # deliberately touched, and is now failing means the blast radius
  # spread beyond the action. Terminating pods are deletions, not
  # failures, and a vanished pod is indistinguishable from an intended
  # scale-down, so neither counts.
  defp blast_radius_spread?(baseline, observation, action) do
    targets = action_targets(action, baseline)
    pods = observation["pods"] || %{}

    baseline
    |> Map.get("ready_pods", [])
    |> Enum.reject(&targeted?(&1, targets))
    |> Enum.any?(fn name -> failing?(Map.get(pods, name)) end)
  end

  defp failing?(nil), do: false
  defp failing?(%{"terminating" => true}), do: false
  defp failing?(%{"phase" => "Failed"}), do: true
  defp failing?(%{"ready" => ready}), do: ready == false

  # What the action deliberately touched. A rollback or workload restart
  # replaces every pod the workload ran, so the baseline's pods are all
  # targets (their churn is the action, and the plan's settle exemption
  # for rollback churn falls out of this); a scale or cordon changes no
  # existing pod's runtime state, so it targets none.
  defp action_targets(%{name: :restart_pod, params: %{name: pod}}, _baseline), do: [pod]

  defp action_targets(%{name: name}, baseline)
       when name in [:rollback_deployment, :restart_workload] do
    baseline |> Map.get("pods", %{}) |> Map.keys()
  end

  defp action_targets(_action, _baseline), do: []

  defp targeted?(pod, targets), do: pod in targets

  defp restart_rate_exceeded?(observation, state, opts) do
    settled?(state) and
      restarts_since_settle(observation, state) > Keyword.get(opts, :pre_incident_restarts, 0)
  end

  defp new_alert?(opts) do
    check = Keyword.get(opts, :alert_check, fn -> false end)

    case check.() do
      false -> false
      nil -> false
      _new_alert -> true
    end
  end
end
