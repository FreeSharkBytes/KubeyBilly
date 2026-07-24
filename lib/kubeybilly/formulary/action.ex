defmodule Kubeybilly.Formulary.Action do
  @moduledoc """
  One entry in the closed formulary of allowed actions.

  Signatures and the advisor select a name from this enum and fill
  parameters; nothing in the system ever emits kubectl, YAML, or shell.
  Construction is the first gate: an unknown name or malformed parameters
  never becomes a struct, so every module downstream can trust the shape
  without re-checking it.

  The irreversibility class is part of the action's definition, not a
  runtime decision, so the log always states whether an action carries a
  concrete inverse (`:invertible`), touches only runtime state that
  Kubernetes converges back on its own (`:irreversible_benign`), or has
  nothing to invert (`:null` for `no_action`).

  `:uncordon_node` exists only as the recorded inverse of `:cordon_node`.
  It is deliberately absent from the public enum so matchers and the
  advisor can never select it; only `internal_new/2` builds it.

  `facts` holds what validation read off the live cluster while proving
  the action (the rollback merge patch, the current revision and replica
  counts). They ride on the action because the executor receives only
  the structs the machine hands it, and re-reading the cluster at
  execution time would race the incident.
  """

  @enforce_keys [:name, :params, :inverse_class]
  defstruct [:name, :params, :inverse_class, inverse: nil, blast_estimate: 0, facts: %{}]

  @typedoc "A publicly selectable action name."
  @type name ::
          :rollback_deployment
          | :restart_workload
          | :restart_pod
          | :scale
          | :cordon_node
          | :no_action

  @typedoc "An action name only constructible as an inverse."
  @type internal_name :: :uncordon_node

  @typedoc "How the action relates to its inverse."
  @type inverse_class :: :invertible | :irreversible_benign | :null

  @type t :: %__MODULE__{
          name: name() | internal_name(),
          params: map(),
          inverse: t() | nil,
          inverse_class: inverse_class(),
          blast_estimate: non_neg_integer(),
          facts: map()
        }

  @public_names [
    :rollback_deployment,
    :restart_workload,
    :restart_pod,
    :scale,
    :cordon_node,
    :no_action
  ]

  @required_params %{
    rollback_deployment: [:namespace, :name, :to_revision],
    restart_workload: [:namespace, :kind, :name],
    restart_pod: [:namespace, :name],
    scale: [:namespace, :kind, :name, :replicas],
    cordon_node: [:name],
    no_action: [:reason],
    uncordon_node: [:name]
  }

  @classes %{
    rollback_deployment: :invertible,
    scale: :invertible,
    cordon_node: :invertible,
    uncordon_node: :invertible,
    restart_workload: :irreversible_benign,
    restart_pod: :irreversible_benign,
    no_action: :null
  }

  # The only kind the RBAC manifest grants mutating verbs on; rejecting
  # anything else at construction keeps policy and capability aligned.
  @workload_kinds ["Deployment"]

  @doc "The public formulary, in the order the plan defines it."
  @spec names() :: [name()]
  def names, do: @public_names

  @doc """
  Build a publicly selectable action.

  Unknown names, missing keys, unknown keys, and malformed values are all
  `{:error, {:invalid_action, details}}`; a struct is proof of validity.
  """
  @spec new(atom(), map()) :: {:ok, t()} | {:error, {:invalid_action, map()}}
  def new(name, params) when name in @public_names and is_map(params) do
    build(name, params)
  end

  def new(name, params) when is_map(params) do
    {:error, {:invalid_action, %{action: name, reason: :unknown_action}}}
  end

  def new(name, _params) do
    {:error, {:invalid_action, %{action: name, reason: :params_not_a_map}}}
  end

  @doc """
  Build an internal-only action.

  `:uncordon_node` is constructible here and nowhere else: it may appear
  as a recorded inverse but never as a selected mitigation.
  """
  @spec internal_new(internal_name(), map()) :: {:ok, t()} | {:error, {:invalid_action, map()}}
  def internal_new(:uncordon_node = name, params) when is_map(params), do: build(name, params)

  def internal_new(name, _params) do
    {:error, {:invalid_action, %{action: name, reason: :params_not_a_map}}}
  end

  defp build(name, params) do
    required = Map.fetch!(@required_params, name)
    keys = Map.keys(params)
    missing = Enum.sort(required -- keys)
    unknown = Enum.sort(keys -- required)

    invalid =
      for {key, value} <- Enum.sort(params), key in required, not valid?(key, value), do: key

    if missing == [] and unknown == [] and invalid == [] do
      {:ok, %__MODULE__{name: name, params: params, inverse_class: Map.fetch!(@classes, name)}}
    else
      {:error,
       {:invalid_action, %{action: name, missing: missing, unknown: unknown, invalid: invalid}}}
    end
  end

  defp valid?(:replicas, value), do: is_integer(value) and value >= 0
  defp valid?(:kind, value), do: value in @workload_kinds

  defp valid?(:to_revision, value) do
    non_empty_binary?(value) or (is_integer(value) and value > 0)
  end

  defp valid?(key, value) when key in [:namespace, :name, :reason], do: non_empty_binary?(value)

  defp non_empty_binary?(value), do: is_binary(value) and value != ""
end
