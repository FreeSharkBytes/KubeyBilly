defmodule Kubeybilly.Signatures.MissingConfig do
  @moduledoc """
  Detects workloads blocked on a ConfigMap or Secret that does not exist.

  `CreateContainerConfigError` and `FailedMount` events that name a
  ConfigMap or Secret mean the container cannot start until someone
  creates or fixes that object. KubeyBilly does not create resources, on
  principle: conjuring a ConfigMap from nothing would be guessing at
  configuration. So the proposal is `no_action` quoting the event message,
  which already names exactly what is missing.
  """

  @behaviour Kubeybilly.Signatures.Matcher

  alias Kubeybilly.Signatures.LoadedBundle
  alias Kubeybilly.Signatures.Signature
  alias Kubeybilly.Soundings.Bundle

  @event_reasons ["CreateContainerConfigError", "FailedMount"]
  @named_object ~r/(configmap|secret)s?\s+"[^"]+"/i

  @impl true
  def match(%LoadedBundle{} = bundle) do
    bundle.events
    |> Enum.sort_by(fn {namespace, _events} -> namespace end)
    |> Enum.find_value(fn {namespace, events} ->
      case Enum.find(events, &config_event?/1) do
        nil -> nil
        event -> {namespace, event}
      end
    end)
    |> case do
      nil -> :no_match
      {namespace, event} -> {:match, signature(namespace, event)}
    end
  end

  defp config_event?(event) do
    event["reason"] in @event_reasons and is_binary(event["message"]) and
      event["message"] =~ @named_object
  end

  defp signature(namespace, event) do
    subject = get_in(event, ["involvedObject", "name"]) || "unknown object"

    Signature.new(%{
      name: :missing_config,
      confidence: 0.85,
      proposed_action: %{action: :no_action, params: %{}},
      rationale:
        "#{event["reason"]} on #{namespace}/#{subject}: #{event["message"]}. " <>
          "KubeyBilly does not create resources; the named ConfigMap or Secret " <>
          "must be supplied by a human.",
      evidence_refs: [Bundle.events_path(namespace)]
    })
  end
end
