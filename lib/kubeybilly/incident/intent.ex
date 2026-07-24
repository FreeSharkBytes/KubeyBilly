defmodule Kubeybilly.Incident.Intent do
  @moduledoc """
  Adapts a signature's proposed intent into a formulary action.

  Signatures speak in evidence terms (the `revision` they matched, the
  `node` that went unready) while the formulary demands its own strict
  parameter names, so the two vocabularies meet here in one pure,
  testable function instead of leaking translation into the state
  machine. `no_action` gets the signature's rationale as its reason,
  which is exactly what the logbook wants a decline to say.
  """

  alias Kubeybilly.Formulary.Action
  alias Kubeybilly.Signatures.Signature

  @doc "Build the formulary action a signature proposes."
  @spec to_action(Signature.t()) :: {:ok, Action.t()} | {:error, {:invalid_action, map()}}
  def to_action(%Signature{proposed_action: %{action: name, params: params}} = signature) do
    Action.new(name, adapt(name, params, signature))
  end

  defp adapt(:rollback_deployment, %{revision: revision} = params, _signature) do
    params |> Map.delete(:revision) |> Map.put(:to_revision, revision)
  end

  defp adapt(:cordon_node, %{node: node} = params, _signature) do
    params |> Map.delete(:node) |> Map.put(:name, node)
  end

  defp adapt(:no_action, params, signature) do
    Map.put_new(params, :reason, signature.rationale)
  end

  defp adapt(_name, params, _signature), do: params
end
