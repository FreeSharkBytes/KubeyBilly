defmodule Kubeybilly.Verification.Real do
  @moduledoc """
  The polling verifier: watches the window and lands on one of the three
  documented outcomes.

  Composition, not judgment: `Poller` owns the cadence, `Observation`
  owns the cluster reads, `Predicates` owns the meaning; this module
  wires them to the `Kubeybilly.Verifier` contract. It exits early on
  `worse` and on `recovered` sustained for two consecutive polls; window
  expiry is `unchanged`. Failed cluster reads are inconclusive polls, and
  more than three in a row concede `unchanged` (reason `polls_failed`)
  rather than guessing.

  The behaviour's return is deliberately just `{:ok, outcome}`, so the
  richer story (which recovery conditions were unmet, why a poll was
  worse, how many polls ran) travels through the
  `[:kubeybilly, :verification, :poll]` and
  `[:kubeybilly, :verification, :outcome]` telemetry events and the log,
  where the escalation path already listens.
  """

  @behaviour Kubeybilly.Verifier

  require Logger

  alias Kubeybilly.Incident.Record
  alias Kubeybilly.K8sClient
  alias Kubeybilly.Soundings.Bundle
  alias Kubeybilly.Verification.Observation
  alias Kubeybilly.Verification.Poller
  alias Kubeybilly.Verification.Predicates

  @poll_event [:kubeybilly, :verification, :poll]
  @outcome_event [:kubeybilly, :verification, :outcome]

  # Plan/05: recovery must hold for two consecutive polls in every
  # window configuration.
  @stability_polls 2

  # Consecutive failed reads tolerated before conceding the window.
  @max_consecutive_failures 3

  @default_window_seconds 90

  @impl Kubeybilly.Verifier
  def verify(%Record{} = record, baseline, opts) do
    case baseline || load_baseline(record, opts) do
      nil ->
        # Nothing to judge against: recovered and worse are both
        # comparisons, so an absent baseline can only escalate.
        conclude(record, :unchanged, %{reason: :no_baseline, unmet: [], polls: 0})

      baseline ->
        watch(record, baseline, opts)
    end
  end

  @doc """
  Container restarts the bundle recorded in an equivalent pre-incident
  window.

  The worse predicate's restart clause compares in-window restarts to the
  rate before the incident; kubelet `BackOff` events in the bundle whose
  timestamp falls inside `window_seconds` before the manifest's
  `captured_at` are that rate's best sealed evidence. An explicit
  `:pre_incident_restarts` option short-circuits the derivation, and an
  unreadable bundle derives zero, the strictest reading.
  """
  @spec pre_incident_restarts(Record.t(), keyword()) :: non_neg_integer()
  def pre_incident_restarts(%Record{} = record, opts \\ []) do
    case Keyword.fetch(opts, :pre_incident_restarts) do
      {:ok, count} -> count
      :error -> derive_pre_incident_restarts(record, opts)
    end
  end

  ## The window

  defp watch(record, baseline, opts) do
    window_seconds = Keyword.get(opts, :window_seconds, @default_window_seconds)
    window_ms = Keyword.get(opts, :window_ms, :timer.seconds(window_seconds))
    poller_opts = [window_ms: window_ms] ++ Keyword.take(opts, [:poll_interval_ms])

    env = %{
      record: record,
      baseline: baseline,
      action: record.action,
      client: Keyword.get_lazy(opts, :client, &K8sClient.impl/0),
      target: %{
        namespace: record.namespace,
        workload_kind: record.workload.kind,
        workload_name: record.workload.name
      },
      worse_opts: [
        pre_incident_restarts:
          pre_incident_restarts(record, Keyword.put(opts, :window_seconds, window_seconds)),
        alert_check: Keyword.get(opts, :alert_check, fn -> false end)
      ]
    }

    initial = %{
      settle: Predicates.initial_settle_state(),
      failures: 0,
      stable: 0,
      unmet: [:no_successful_poll]
    }

    case Poller.run(initial, &poll(env, &1, &2), poller_opts) do
      {:halted, {outcome, detail}, polls} ->
        conclude(record, outcome, Map.put(detail, :polls, polls))

      {:expired, state, polls} ->
        conclude(record, :unchanged, %{
          reason: :window_expired,
          unmet: state.unmet,
          polls: polls
        })
    end
  end

  defp poll(env, poll, state) do
    case Observation.observe(env.client, env.target) do
      {:error, reason} -> inconclusive(env, poll, state, reason)
      {:ok, observation} -> judge(env, poll, state, observation)
    end
  end

  # A failed read proves nothing either way; it only counts against the
  # patience budget. Persistent blindness concedes the window as
  # unchanged instead of judging a cluster it cannot see.
  defp inconclusive(env, poll, state, reason) do
    failures = state.failures + 1

    emit_poll(env.record, poll, :inconclusive, %{
      reason: inspect(reason),
      consecutive_failures: failures
    })

    if failures > @max_consecutive_failures do
      {:halt, {:unchanged, %{reason: :polls_failed, unmet: state.unmet}}}
    else
      {:cont, %{state | failures: failures}}
    end
  end

  defp judge(env, poll, state, observation) do
    settle = Predicates.settle(state.settle, observation, env.action)
    state = %{state | settle: settle, failures: 0}

    case Predicates.worse(env.baseline, observation, env.action, settle, env.worse_opts) do
      {:worse, reason} ->
        emit_poll(env.record, poll, :worse, %{reason: reason})
        {:halt, {:worse, %{reason: reason, unmet: []}}}

      :ok ->
        recovery(env, poll, state, observation)
    end
  end

  defp recovery(env, poll, state, observation) do
    case Predicates.unmet(env.baseline, observation, env.action, state.settle) do
      [] ->
        stable = state.stable + 1
        emit_poll(env.record, poll, :recovered_candidate, %{stable_polls: stable})

        if stable >= @stability_polls do
          {:halt, {:recovered, %{reason: :sustained, unmet: []}}}
        else
          {:cont, %{state | stable: stable, unmet: []}}
        end

      unmet ->
        emit_poll(env.record, poll, :continue, %{unmet: unmet})
        {:cont, %{state | stable: 0, unmet: unmet}}
    end
  end

  ## Outcome plumbing

  defp conclude(record, outcome, detail) do
    reason = Map.get(detail, :reason)
    unmet = Map.get(detail, :unmet, [])

    :telemetry.execute(
      @outcome_event,
      %{system_time: System.system_time(), polls: detail.polls},
      %{incident_id: record.id, outcome: outcome, reason: reason, unmet: unmet}
    )

    Logger.info(
      "verification of incident #{record.id} landed on #{outcome} " <>
        "(reason: #{inspect(reason)}, unmet: #{inspect(unmet)}, polls: #{detail.polls})"
    )

    {:ok, outcome}
  end

  defp emit_poll(record, poll, status, metadata) do
    :telemetry.execute(
      @poll_event,
      %{poll: poll},
      Map.merge(%{incident_id: record.id, status: status}, metadata)
    )
  end

  ## The bundle

  defp load_baseline(record, opts) do
    case read_json(bundle_path(record, opts, Bundle.baseline_path())) do
      {:ok, %{} = baseline} ->
        baseline

      _missing_or_invalid ->
        Logger.warning("incident #{record.id} has no readable baseline snapshot")
        nil
    end
  end

  defp derive_pre_incident_restarts(record, opts) do
    window_seconds = Keyword.get(opts, :window_seconds, @default_window_seconds)

    with {:ok, %{"captured_at" => stamp}} <-
           read_json(bundle_path(record, opts, Bundle.manifest_path())),
         {:ok, captured_at, _offset} <- DateTime.from_iso8601(stamp),
         {:ok, events} <-
           read_json(bundle_path(record, opts, Bundle.events_path(record.namespace))) do
      cutoff = DateTime.add(captured_at, -window_seconds, :second)

      events
      |> List.wrap()
      |> Enum.count(&backoff_within?(&1, cutoff, captured_at))
    else
      _unreadable -> 0
    end
  end

  # A kubelet BackOff event is the sealed trace of a container restart
  # loop; one inside the pre-incident window counts once (deduplicated
  # counts span the event's whole lifetime, not this window, so they
  # would overstate the rate).
  defp backoff_within?(%{"reason" => "BackOff"} = event, cutoff, captured_at) do
    with stamp when is_binary(stamp) <- event_timestamp(event),
         {:ok, at, _offset} <- DateTime.from_iso8601(stamp) do
      DateTime.compare(at, cutoff) != :lt and DateTime.compare(at, captured_at) != :gt
    else
      _unparseable -> false
    end
  end

  defp backoff_within?(_event, _cutoff, _captured_at), do: false

  defp event_timestamp(event) do
    event["lastTimestamp"] || event["eventTime"] || event["firstTimestamp"]
  end

  defp bundle_path(record, opts, relative) do
    bundle =
      case Keyword.fetch(opts, :incidents_root) do
        {:ok, root} -> Bundle.new(record.id, root: root)
        :error -> Bundle.new(record.id)
      end

    Bundle.absolute(bundle, relative)
  end

  defp read_json(path) do
    with {:ok, binary} <- File.read(path) do
      Jason.decode(binary)
    end
  end
end
