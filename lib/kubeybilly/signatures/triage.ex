defmodule Kubeybilly.Signatures.Triage do
  @moduledoc """
  Runs the deterministic decision layer over one frozen bundle.

  Order is the whole point of this module. The upstream dependency check
  runs first because it is a veto, not a vote: a dead upstream forces
  `no_action` no matter what any signature would propose. Then matchers
  run in a fixed priority list, post-rollout signatures before their
  stable counterparts, because a rollout correlation is the stronger claim
  and must win when both shapes are present. First match wins, keeping the
  verdict deterministic and the audit log readable; `:no_match` routes the
  incident to the advisor fallback.

  Every matcher evaluation and every triage outcome emits telemetry, so
  the dashboard can show which rules fired and how long deciding took.
  """

  alias Kubeybilly.Signatures.LoadedBundle
  alias Kubeybilly.Signatures.Signature
  alias Kubeybilly.Signatures.UpstreamCheck
  alias Kubeybilly.Soundings.Bundle

  @matcher_event [:kubeybilly, :signatures, :matcher]
  @triage_event [:kubeybilly, :signatures, :triage]

  @matchers [
    Kubeybilly.Signatures.ImagepullPostRollout,
    Kubeybilly.Signatures.CrashloopPostRollout,
    Kubeybilly.Signatures.ReadinessPostRollout,
    Kubeybilly.Signatures.NodeNotReady,
    Kubeybilly.Signatures.Oomkilled,
    Kubeybilly.Signatures.Unschedulable,
    Kubeybilly.Signatures.MissingConfig,
    Kubeybilly.Signatures.ImagepullNoRollout,
    Kubeybilly.Signatures.CrashloopStable
  ]

  @doc "The fixed priority order matchers run in."
  @spec matchers() :: [module()]
  def matchers, do: @matchers

  @doc """
  Triage a bundle: upstream veto first, then matchers in priority order.
  """
  @spec run(LoadedBundle.t()) :: {:match, Signature.t()} | :no_match
  def run(%LoadedBundle{} = bundle) do
    case UpstreamCheck.check(bundle) do
      {:upstream_down, reason} ->
        signature = upstream_signature(reason)
        emit_triage(bundle, signature.name, 0)
        {:match, signature}

      :clear ->
        match_in_priority_order(bundle)
    end
  end

  defp match_in_priority_order(bundle) do
    total = length(@matchers)

    @matchers
    |> Enum.with_index(1)
    |> Enum.reduce_while(:no_match, fn {matcher, evaluated}, :no_match ->
      case evaluate(matcher, bundle) do
        {:match, signature} ->
          emit_triage(bundle, signature.name, evaluated)
          {:halt, {:match, signature}}

        :no_match ->
          continue_or_close(bundle, evaluated, total)
      end
    end)
  end

  # The last no_match closes triage with its telemetry event; earlier ones
  # just move on to the next matcher in the priority list.
  defp continue_or_close(bundle, total, total) do
    emit_triage(bundle, :no_match, total)
    {:cont, :no_match}
  end

  defp continue_or_close(_bundle, _evaluated, _total), do: {:cont, :no_match}

  defp evaluate(matcher, bundle) do
    started = System.monotonic_time()
    result = matcher.match(bundle)

    :telemetry.execute(@matcher_event, %{duration: System.monotonic_time() - started}, %{
      matcher: matcher,
      result: result_tag(result),
      incident_id: incident_id(bundle)
    })

    result
  end

  defp result_tag({:match, _signature}), do: :match
  defp result_tag(:no_match), do: :no_match

  defp emit_triage(bundle, matched, evaluated) do
    :telemetry.execute(@triage_event, %{matchers_evaluated: evaluated}, %{
      matched: matched,
      incident_id: incident_id(bundle)
    })
  end

  defp incident_id(%LoadedBundle{manifest: %{"incident_id" => id}}), do: id
  defp incident_id(%LoadedBundle{}), do: nil

  # The forced verdict carries the veto's reason verbatim; its confidence
  # is high because zero ready endpoints in the baseline is not a guess.
  defp upstream_signature(reason) do
    Signature.new(%{
      name: :upstream_down,
      confidence: 0.9,
      proposed_action: %{action: :no_action, params: %{}},
      rationale: reason,
      evidence_refs: [Bundle.baseline_path()]
    })
  end
end
