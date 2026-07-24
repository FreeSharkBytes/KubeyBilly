defmodule Kubeybilly.StandingOrders.Policy do
  @moduledoc """
  The standing orders policy: what may be handled alone, what needs the
  captain.

  This struct mirrors the YAML schema in plan/04 one to one so that a
  reviewer can diff the policy file against the running configuration
  without translation. Every field carries a documented default, which is
  what an omitted section means; the parser fills them in so the evaluator
  never has to guess.
  """

  @typedoc "An action name from the formulary (plan/03)."
  @type action ::
          :rollback_deployment
          | :restart_workload
          | :restart_pod
          | :scale
          | :cordon_node
          | :no_action

  @typedoc "One tier: its actions, auto flag, and optional constraints."
  @type tier :: %{
          actions: [action()],
          auto: boolean(),
          min_confidence: float() | nil,
          max_delta: pos_integer() | nil
        }

  @type t :: %__MODULE__{
          scope: %{namespaces_include: [String.t()], namespaces_exclude: [String.t()]},
          tiers: %{String.t() => tier()},
          budgets: %{
            actions_per_incident: pos_integer(),
            actions_per_hour: pos_integer(),
            max_pods_touched: pos_integer()
          },
          deny_kinds: [String.t()],
          freeze_when: %{rollout_in_progress: boolean(), maintenance_window: boolean()},
          verification: %{window_seconds: pos_integer()},
          approval: %{timeout_seconds: pos_integer()},
          mode: :dry_run | :approve | :auto
        }

  defstruct scope: %{namespaces_include: [], namespaces_exclude: []},
            tiers: %{},
            budgets: %{actions_per_incident: 2, actions_per_hour: 10, max_pods_touched: 20},
            deny_kinds: [],
            freeze_when: %{rollout_in_progress: true, maintenance_window: false},
            verification: %{window_seconds: 90},
            approval: %{timeout_seconds: 300},
            mode: :dry_run

  @formulary_actions [
    :rollback_deployment,
    :restart_workload,
    :restart_pod,
    :scale,
    :cordon_node,
    :no_action
  ]

  @doc "The closed set of selectable actions, from the formulary (plan/03)."
  @spec formulary_actions() :: [action()]
  def formulary_actions, do: @formulary_actions

  @doc """
  The tier a policy gets when the tiers section is omitted entirely:
  declining to act stays possible under any policy.
  """
  @spec default_read_tier() :: tier()
  def default_read_tier do
    %{actions: [:no_action], auto: true, min_confidence: nil, max_delta: nil}
  end
end
