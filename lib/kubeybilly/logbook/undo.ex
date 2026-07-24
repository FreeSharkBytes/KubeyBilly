defmodule Kubeybilly.Logbook.Undo do
  @moduledoc """
  Renders the recorded inverse as a copy-pastable kubectl command.

  The system itself never runs kubectl; the executor speaks the API.
  But the human reading the log at 3am does run kubectl, so the log
  translates the recorded inverse into the one command that undoes the
  action, taken from the facts recorded before mutation (the revision
  and replica counts as they were). Restarts and `no_action` state
  plainly that there is nothing to undo, because an absent inverse is
  always a declared class, never an oversight.
  """

  alias Kubeybilly.Logbook.Fields

  @nothing "nothing to undo"

  @doc "The undo command for an executed action, or a plain statement that none exists."
  @spec command(term()) :: String.t()
  def command(nil), do: @nothing

  def command(action) do
    case Fields.text(Fields.get(action, :name)) do
      "rollback_deployment" -> rollback(Fields.get(action, :inverse))
      "scale" -> scale(Fields.get(action, :inverse))
      "cordon_node" -> uncordon(Fields.get(action, :params))
      _restart_or_no_action -> @nothing
    end
  end

  defp rollback(nil), do: @nothing

  defp rollback(inverse) do
    params = Fields.get(inverse, :params)
    name = Fields.text(Fields.get(params, :name))
    revision = Fields.text(Fields.get(params, :to_revision))
    namespace = Fields.text(Fields.get(params, :namespace))
    "kubectl rollout undo deployment/#{name} --to-revision=#{revision} -n #{namespace}"
  end

  defp scale(nil), do: @nothing

  defp scale(inverse) do
    params = Fields.get(inverse, :params)
    kind = params |> Fields.get(:kind) |> Fields.text() |> String.downcase()
    name = Fields.text(Fields.get(params, :name))
    replicas = Fields.text(Fields.get(params, :replicas))
    namespace = Fields.text(Fields.get(params, :namespace))
    "kubectl scale #{kind}/#{name} --replicas=#{replicas} -n #{namespace}"
  end

  defp uncordon(params) do
    "kubectl uncordon #{Fields.text(Fields.get(params, :name))}"
  end
end
