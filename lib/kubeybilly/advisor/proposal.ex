defmodule Kubeybilly.Advisor.Proposal do
  @moduledoc """
  The one shape an advisor answer is allowed to take.

  Model output is untrusted input, so nothing downstream ever touches a
  raw response: `validate/1` is the single funnel that turns a loosely
  keyed map (string or atom keys, string or atom action names) into a
  struct, and anything that does not fit the strict schema is an error
  with named faults rather than a crash. Holding a struct is proof the
  shape was checked, exactly as with `Kubeybilly.Formulary.Action`.

  String action names are matched against a fixed list, never converted
  with `String.to_atom/1`, so a hostile response cannot mint atoms.
  """

  @enforce_keys [:action, :params, :confidence, :rationale]
  defstruct [:action, :params, :confidence, :rationale]

  @typedoc "A validated advisor proposal."
  @type t :: %__MODULE__{
          action: atom(),
          params: map(),
          confidence: float(),
          rationale: String.t()
        }

  @typedoc "Named schema faults: which keys were missing, unknown, or invalid."
  @type details :: %{missing: [atom()], unknown: [term()], invalid: [atom()]}

  # Mirrors the public enum in Kubeybilly.Formulary.Action (plan/03): the
  # six names an advisor may select. :uncordon_node is internal-only there
  # and therefore absent here too.
  @formulary [
    :rollback_deployment,
    :restart_workload,
    :restart_pod,
    :scale,
    :cordon_node,
    :no_action
  ]

  @actions_by_string Map.new(@formulary, &{Atom.to_string(&1), &1})

  @fields [:action, :params, :confidence, :rationale]
  @fields_by_string Map.new(@fields, &{Atom.to_string(&1), &1})

  @doc "The action names an advisor may propose, mirrored from the formulary."
  @spec formulary() :: [atom()]
  def formulary, do: @formulary

  @doc """
  Validate a raw advisor answer into a proposal.

  Accepts atom- or string-keyed maps and atom or string action names;
  rejects everything else with a map naming the missing, unknown, and
  invalid keys.
  """
  @spec validate(term()) :: {:ok, t()} | {:error, details()}
  def validate(%__MODULE__{} = proposal) do
    with {:ok, revalidated} <- proposal |> Map.from_struct() |> validate() do
      {:ok, %{revalidated | params: proposal.params}}
    end
  end

  def validate(raw) when is_map(raw) do
    {fields, unknown} = normalize_keys(raw)
    missing = Enum.sort(@fields -- Map.keys(fields))
    invalid = for field <- @fields, Map.has_key?(fields, field), fault(fields)[field], do: field

    if missing == [] and unknown == [] and invalid == [] do
      {:ok, build(fields)}
    else
      {:error, %{missing: missing, unknown: Enum.sort(unknown), invalid: invalid}}
    end
  end

  def validate(_raw), do: {:error, %{missing: [], unknown: [], invalid: [:proposal]}}

  defp normalize_keys(raw) do
    Enum.reduce(raw, {%{}, []}, fn {key, value}, {fields, unknown} ->
      case normalize_key(key) do
        {:ok, field} -> {Map.put(fields, field, value), unknown}
        :error -> {fields, [key | unknown]}
      end
    end)
  end

  defp normalize_key(key) when key in @fields, do: {:ok, key}
  defp normalize_key(key) when is_binary(key), do: Map.fetch(@fields_by_string, key)
  defp normalize_key(_key), do: :error

  defp fault(fields) do
    %{
      action: normalize_action(fields[:action]) == :error,
      params: not is_map(fields[:params]),
      confidence: not confidence?(fields[:confidence]),
      rationale: not is_binary(fields[:rationale])
    }
  end

  defp build(fields) do
    {:ok, action} = normalize_action(fields.action)

    %__MODULE__{
      action: action,
      params: fields.params,
      confidence: fields.confidence * 1.0,
      rationale: fields.rationale
    }
  end

  defp normalize_action(action) when action in @formulary, do: {:ok, action}
  defp normalize_action(action) when is_binary(action), do: Map.fetch(@actions_by_string, action)
  defp normalize_action(_action), do: :error

  defp confidence?(value), do: is_number(value) and value >= 0 and value <= 1
end
