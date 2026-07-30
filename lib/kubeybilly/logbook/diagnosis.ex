defmodule Kubeybilly.Logbook.Diagnosis do
  @moduledoc """
  Turns the verifier's vocabulary into sentences a woken human can read.

  `Kubeybilly.Verification.Predicates` names its outcomes and unmet
  conditions for the log rather than for internals, but a bare
  `:no_restarts_since_settle` at 3am still costs the reader a trip into
  the source. Every line here keeps the name (it is what telemetry, the
  tests and the operator's grep all speak) and puts the sentence beside
  it.

  Unrecognised names degrade to their own text instead of vanishing: a
  log that prints a reason it cannot explain is still a log that told the
  truth, whereas one that omits it hides the only clue there was.
  """

  alias Kubeybilly.Logbook.Fields

  @reasons %{
    "recovered_sustained" => "recovery held for two consecutive polls",
    "window_expired" => "the window expired before recovery was reached",
    "polls_failed" =>
      "the cluster could not be read for several polls in a row, so the window was " <>
        "conceded rather than guessed at",
    "no_baseline" => "no baseline snapshot was readable, so there was nothing to compare against",
    "verifier_timed_out" => "the verifier did not answer inside the window",
    "ready_replicas_dropped" => "ready replicas fell below the baseline",
    "blast_radius_spread" => "pods the action never touched started failing",
    "restart_rate_exceeded" =>
      "containers restarted more often than they did before the incident",
    "new_alert_signature" => "a new alert signature arrived for this scope"
  }

  @unmet_conditions %{
    "action_settled" => "the action's own rollout never settled",
    "ready_replicas" => "ready replicas never reached the desired count",
    "no_restarts_since_settle" =>
      "containers kept restarting after the action's own rollout had settled",
    "service_endpoints" => "a Service selecting the workload still had no ready endpoints",
    "rolled_to_available" => "the ReplicaSet the rollback moved to never became fully available",
    "bad_replica_set_scaled_down" =>
      "the ReplicaSet the rollback moved away from was never scaled down",
    "no_successful_poll" => "no poll ever read the cluster successfully"
  }

  @doc """
  The verifier's reason as a sentence, or nil when none was recorded.

  Callers decide whether to print a "Why" line at all, which is why an
  absent reason answers nil rather than a placeholder.
  """
  @spec reason_sentence(term()) :: String.t() | nil
  def reason_sentence(reason) do
    case Fields.text(reason) do
      "" -> nil
      name -> Map.get(@reasons, name, name)
    end
  end

  @doc "One `name: sentence` line per unmet recovery condition."
  @spec unmet_lines(term()) :: [String.t()]
  def unmet_lines(unmet) do
    unmet
    |> List.wrap()
    |> Enum.map(&Fields.text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn name ->
      case Map.fetch(@unmet_conditions, name) do
        {:ok, sentence} -> name <> ": " <> sentence
        :error -> name
      end
    end)
  end

  @doc """
  How many polls ran, phrased for prose, or nil when there were none.

  Zero polls is not worth a clause: it happens when the window never
  opened, and the reason already says so.
  """
  @spec poll_count(term()) :: String.t() | nil
  def poll_count(polls) do
    case Integer.parse(Fields.text(polls)) do
      {0, _rest} -> nil
      {1, _rest} -> "1 poll"
      {count, _rest} -> "#{count} polls"
      :error -> nil
    end
  end
end
