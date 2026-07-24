defmodule Kubeybilly.StandingOrders.Evaluator do
  @moduledoc """
  Deterministic policy evaluation, in the exact order plan/04 documents.

  The evaluator is a pure function so every decision is replayable: same
  policy, same intent, same context, same verdict. It stops at the first
  refusing rule and reports it by its stable id; a permit reports the
  full chain it passed, so acting is as auditable as refusing. Budget
  counts arrive in the context already summed by the caller (reverts
  included, per plan/04); the evaluator only compares.

  `no_action` is the one special case: declining to act cannot be
  refused. It permits through the read tier regardless of kill switch,
  scope, freezes, or budgets, because it writes nothing for any of those
  rules to protect.
  """

  alias Kubeybilly.StandingOrders.Decision
  alias Kubeybilly.StandingOrders.Policy

  @decision_event [:kubeybilly, :standing_orders, :decision]

  @rule_order [
    "kill-switch",
    "scope-namespace",
    "deny-kinds",
    "freeze-rollout",
    "freeze-maintenance",
    "tier-lookup",
    "tier-min-confidence",
    "tier-constraints",
    "budget-actions-per-incident",
    "budget-actions-per-hour",
    "budget-max-pods"
  ]

  @typedoc "A proposed action, as the decision engine emits it."
  @type intent :: %{
          action: Policy.action(),
          params: map(),
          confidence: float(),
          blast_estimate: non_neg_integer(),
          target_kind: String.t(),
          namespace: String.t(),
          owner_kinds: [String.t()]
        }

  @typedoc "The live facts the rules compare against, gathered by the caller."
  @type context :: %{
          kill_switch_engaged: boolean(),
          rollout_in_progress: boolean(),
          expected_rollout: boolean(),
          maintenance_window: boolean(),
          actions_this_incident: non_neg_integer(),
          actions_this_hour: non_neg_integer(),
          mode: :dry_run | :approve | :auto
        }

  @doc """
  Evaluate an intent against the policy in the given context.

  Emits a `[:kubeybilly, :standing_orders, :decision]` telemetry event
  for every decision, permits included.
  """
  @spec evaluate(Policy.t(), intent(), context()) :: Decision.t()
  def evaluate(%Policy{} = policy, intent, context) do
    # Stamped, not re-derived: the executor and the persisted record see
    # exactly the mode and limits this evaluation ran under.
    decision = %{decide(policy, intent, context) | mode: context.mode, budgets: policy.budgets}

    :telemetry.execute(@decision_event, %{rules_passed: length(decision.chain)}, %{
      verdict: decision.verdict,
      rule_id: decision.rule_id,
      action: intent.action,
      namespace: intent.namespace,
      reason: decision.reason
    })

    decision
  end

  # Declining is a result, not a mutation: there is nothing for the kill
  # switch, scope, freezes, or budgets to protect, so no_action permits
  # through the read tier unconditionally and costs nothing.
  defp decide(_policy, %{action: :no_action}, _context) do
    %Decision{
      verdict: :permit_auto,
      rule_id: "tier-auto",
      chain: ["tier-lookup", "tier-auto"],
      reason: "no_action permits through the read tier"
    }
  end

  defp decide(policy, intent, context) do
    run_rules(@rule_order, policy, intent, context, [])
  end

  defp run_rules([], policy, intent, context, passed) do
    tier_auto(policy, intent, context, passed)
  end

  defp run_rules([rule | rest], policy, intent, context, passed) do
    case check(rule, policy, intent, context) do
      :ok ->
        run_rules(rest, policy, intent, context, passed ++ [rule])

      {:deny, reason} ->
        %Decision{verdict: :deny, rule_id: rule, chain: passed, reason: reason}
    end
  end

  ## Rules, in plan/04 order

  defp check("kill-switch", _policy, _intent, context) do
    if context.kill_switch_engaged,
      do: {:deny, "kill switch engaged"},
      else: :ok
  end

  defp check("scope-namespace", policy, intent, _context) do
    %{namespaces_include: include, namespaces_exclude: exclude} = policy.scope

    cond do
      intent.namespace in exclude ->
        {:deny, "namespace #{inspect(intent.namespace)} is excluded from scope"}

      include != [] and intent.namespace not in include ->
        {:deny, "namespace #{inspect(intent.namespace)} is not in scope"}

      true ->
        :ok
    end
  end

  # The target and its whole owner chain are checked: restarting a pod
  # owned by a StatefulSet is a StatefulSet mutation in effect.
  defp check("deny-kinds", policy, intent, _context) do
    case Enum.find([intent.target_kind | intent.owner_kinds], &(&1 in policy.deny_kinds)) do
      nil -> :ok
      kind -> {:deny, "kind #{inspect(kind)} is denied by policy"}
    end
  end

  # A rollout caused by this incident's own action is expected and
  # exempt (plan/09 D7); any foreign rollout freezes.
  defp check("freeze-rollout", policy, _intent, context) do
    if policy.freeze_when.rollout_in_progress and context.rollout_in_progress and
         not context.expected_rollout,
       do: {:deny, "a foreign rollout is in progress"},
       else: :ok
  end

  defp check("freeze-maintenance", policy, _intent, context) do
    if policy.freeze_when.maintenance_window and context.maintenance_window,
      do: {:deny, "a maintenance window is in progress"},
      else: :ok
  end

  defp check("tier-lookup", policy, intent, _context) do
    case find_tier(policy, intent.action) do
      nil -> {:deny, "action #{intent.action} belongs to no tier"}
      {_name, _tier} -> :ok
    end
  end

  defp check("tier-min-confidence", policy, intent, _context) do
    {name, tier} = find_tier(policy, intent.action)

    if tier.min_confidence != nil and intent.confidence < tier.min_confidence,
      do:
        {:deny,
         "confidence #{intent.confidence} is below tier #{inspect(name)} " <>
           "minimum #{tier.min_confidence}"},
      else: :ok
  end

  defp check("tier-constraints", policy, intent, _context) do
    {_name, tier} = find_tier(policy, intent.action)
    check_max_delta(tier.max_delta, intent.params)
  end

  defp check("budget-actions-per-incident", policy, _intent, context) do
    budget = policy.budgets.actions_per_incident

    if context.actions_this_incident >= budget,
      do: {:deny, "actions_per_incident budget of #{budget} is exhausted"},
      else: :ok
  end

  defp check("budget-actions-per-hour", policy, _intent, context) do
    budget = policy.budgets.actions_per_hour

    if context.actions_this_hour >= budget,
      do: {:deny, "actions_per_hour budget of #{budget} is exhausted"},
      else: :ok
  end

  defp check("budget-max-pods", policy, intent, _context) do
    budget = policy.budgets.max_pods_touched

    if intent.blast_estimate > budget,
      do: {:deny, "blast estimate #{intent.blast_estimate} exceeds max_pods_touched #{budget}"},
      else: :ok
  end

  ## Constraints

  # A constraint that cannot be verified refuses rather than waves
  # through: without the current replica count the delta is unknowable.
  defp check_max_delta(nil, _params), do: :ok

  defp check_max_delta(max_delta, %{replicas: replicas, current_replicas: current})
       when is_integer(replicas) and is_integer(current) do
    delta = abs(replicas - current)

    if delta > max_delta,
      do: {:deny, "replica delta #{delta} exceeds max_delta #{max_delta}"},
      else: :ok
  end

  defp check_max_delta(max_delta, _params) do
    {:deny, "max_delta #{max_delta} cannot be verified without current_replicas"}
  end

  ## Final rule: permit auto or route to approval

  defp tier_auto(policy, intent, context, passed) do
    {name, tier} = find_tier(policy, intent.action)
    chain = passed ++ ["tier-auto"]

    {verdict, reason} =
      cond do
        not tier.auto ->
          {:needs_approval, "tier #{inspect(name)} requires approval"}

        context.mode == :approve ->
          {:needs_approval, "mode approve requires a human yes for every action"}

        true ->
          {:permit_auto, "tier #{inspect(name)} permits auto execution"}
      end

    %Decision{verdict: verdict, rule_id: "tier-auto", chain: chain, reason: reason}
  end

  defp find_tier(policy, action) do
    Enum.find(policy.tiers, fn {_name, tier} -> action in tier.actions end)
  end
end
