defmodule Kubeybilly.Formulary.Inverse do
  @moduledoc """
  Records what would undo an action, before anything executes.

  Every action either carries a concrete inverse built from facts read
  off the live cluster before mutation (the revision and replica counts
  as they were), or belongs to a declared irreversibility class. The rule
  from the plan is strict in one direction: an invertible action whose
  inverse cannot be constructed from the gathered facts is not permitted
  at all. The absence of an inverse in the log is therefore always a
  stated class, never an oversight.

  Recording an inverse is not a promise to run it. Whether a recorded
  inverse executes on a worse outcome is executor policy; in particular a
  rollback that verified worse is never auto-inverted, because its
  inverse means redeploying a known-bad revision.
  """

  alias Kubeybilly.Formulary.Action

  @doc """
  Record the action's inverse from validated facts.

  Returns the action with its `inverse` field filled: a concrete inverse
  action for the `:invertible` class, nil for `:irreversible_benign` and
  `:null`, whose classes already say why nothing is recorded.
  """
  @spec construct(Action.t(), map()) :: {:ok, Action.t()} | {:error, :inverse_unconstructible}
  def construct(action, facts)

  def construct(%Action{inverse_class: class} = action, _facts)
      when class in [:irreversible_benign, :null] do
    {:ok, %{action | inverse: nil}}
  end

  def construct(%Action{name: :rollback_deployment} = action, facts) do
    # The inverse rolls back to the revision that is current now, before
    # the patch lands; recording it later would read the wrong revision.
    params = %{
      namespace: action.params.namespace,
      name: action.params.name,
      to_revision: Map.get(facts, :current_revision)
    }

    record(action, Action.new(:rollback_deployment, params))
  end

  def construct(%Action{name: :scale} = action, facts) do
    params =
      action.params
      |> Map.take([:namespace, :kind, :name])
      |> Map.put(:replicas, Map.get(facts, :current_replicas))

    record(action, Action.new(:scale, params))
  end

  def construct(%Action{name: :cordon_node} = action, _facts) do
    record(action, Action.internal_new(:uncordon_node, %{name: action.params.name}))
  end

  def construct(%Action{name: :uncordon_node} = action, _facts) do
    record(action, Action.new(:cordon_node, %{name: action.params.name}))
  end

  # Constructor failure here means the facts could not produce a valid
  # inverse (a missing revision, a nonsense replica count), which per the
  # plan forbids the action outright.
  defp record(action, {:ok, inverse}), do: {:ok, %{action | inverse: inverse}}
  defp record(_action, {:error, _details}), do: {:error, :inverse_unconstructible}
end
