defmodule Kubeybilly.Signatures.Signature do
  @moduledoc """
  The verdict a deterministic matcher hands to the policy gate.

  A signature is the whole audit story in one value: which rule fired, how
  unambiguous its evidence is, what it proposes to do about it, why, and
  which bundle artifacts justify the claim. `proposed_action` stays a plain
  intent map rather than a formulary struct because the formulary lands in
  a parallel build step; keeping the shapes decoupled lets both sides move
  without a shared dependency.

  Construction goes through `new/1` so an impossible verdict (an action no
  formulary will ever accept, a confidence outside the unit interval) blows
  up at the matcher that produced it instead of surfacing later as a
  rejected gate decision with no obvious culprit.
  """

  @enforce_keys [:name, :confidence, :proposed_action, :rationale, :evidence_refs]
  defstruct [:name, :confidence, :proposed_action, :rationale, :evidence_refs]

  @actions [
    :rollback_deployment,
    :restart_workload,
    :restart_pod,
    :scale,
    :cordon_node,
    :no_action
  ]

  @typedoc "Intent names the formulary will accept, mirrored here as a plain enum."
  @type action ::
          :rollback_deployment
          | :restart_workload
          | :restart_pod
          | :scale
          | :cordon_node
          | :no_action

  @typedoc "A plain intent map; the formulary turns this into a validated action."
  @type proposed_action :: %{action: action(), params: map()}

  @type t :: %__MODULE__{
          name: atom(),
          confidence: float(),
          proposed_action: proposed_action(),
          rationale: String.t(),
          evidence_refs: [String.t()]
        }

  @doc """
  Build a signature, rejecting values no downstream stage could honor.

  Raises `ArgumentError` on an unknown action or an out-of-range
  confidence: both are matcher bugs, not runtime conditions to recover
  from.
  """
  @spec new(map()) :: t()
  def new(%{proposed_action: %{action: action}}) when action not in @actions do
    raise ArgumentError,
          "proposed action #{inspect(action)} is not in the intent enum #{inspect(@actions)}"
  end

  def new(%{confidence: confidence}) when confidence < 0.0 or confidence > 1.0 do
    raise ArgumentError,
          "confidence must lie in [0.0, 1.0], got #{inspect(confidence)}"
  end

  def new(fields) when is_map(fields) do
    struct!(__MODULE__, fields)
  end
end
