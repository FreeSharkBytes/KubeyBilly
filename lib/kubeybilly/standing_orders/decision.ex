defmodule Kubeybilly.StandingOrders.Decision do
  @moduledoc """
  The outcome of one policy evaluation.

  Every decision names the rule that decided it and the ordered chain of
  rules it passed on the way, so a permit is exactly as auditable as a
  refusal: "why did it act" and "why did it refuse" are answered by the
  same record. The reason is prose for the logbook; the rule ids are the
  stable vocabulary the tests and the documentation share.

  The decision also carries the mode and budget limits it was evaluated
  under. The executor deals only in the structs execute/3 receives, and
  the decision is the policy's voice there: stamping mode and budgets on
  it keeps the persisted record self-contained (which limits applied is
  part of "why did it act") without widening the executor boundary.
  """

  @enforce_keys [:verdict, :rule_id, :chain, :reason]
  defstruct [:verdict, :rule_id, :chain, :reason, mode: nil, budgets: nil]

  @type verdict :: :permit_auto | :needs_approval | :deny

  @type t :: %__MODULE__{
          verdict: verdict(),
          rule_id: String.t(),
          chain: [String.t()],
          reason: String.t(),
          mode: :dry_run | :approve | :auto | nil,
          budgets: map() | nil
        }
end
