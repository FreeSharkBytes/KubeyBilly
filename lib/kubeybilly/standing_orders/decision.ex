defmodule Kubeybilly.StandingOrders.Decision do
  @moduledoc """
  The outcome of one policy evaluation.

  Every decision names the rule that decided it and the ordered chain of
  rules it passed on the way, so a permit is exactly as auditable as a
  refusal: "why did it act" and "why did it refuse" are answered by the
  same record. The reason is prose for the logbook; the rule ids are the
  stable vocabulary the tests and the documentation share.
  """

  @enforce_keys [:verdict, :rule_id, :chain, :reason]
  defstruct [:verdict, :rule_id, :chain, :reason]

  @type verdict :: :permit_auto | :needs_approval | :deny

  @type t :: %__MODULE__{
          verdict: verdict(),
          rule_id: String.t(),
          chain: [String.t()],
          reason: String.t()
        }
end
