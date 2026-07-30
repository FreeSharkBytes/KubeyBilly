defmodule Kubeybilly.Verifier do
  @moduledoc """
  The boundary behind which post-action verification happens.

  After the executor acts, the state machine asks an implementation of
  this behaviour to watch the cluster against the baseline snapshot and
  land on one of the three documented outcomes. Declaring the boundary
  now lets the machine's outcome routing (recovered closes, unchanged
  escalates, worse reverts or freezes) be tested with a Mox mock before
  the real polling verifier exists.
  """

  alias Kubeybilly.Incident.Record

  @typedoc "One of the three documented verification outcomes."
  @type outcome :: :recovered | :unchanged | :worse

  @typedoc """
  Why the verifier landed where it did, in the log's vocabulary.

  An outcome alone cannot be handed to a human: "unchanged" is a verdict,
  not an explanation. The diagnosis crosses the boundary with the outcome
  so the incident record and `log.md` say the same thing the verifier's
  own telemetry says. Keys an implementation is expected to supply:

    * `:reason` - the deciding clause, for example `:window_expired`,
      `:recovered_sustained`, `:restart_rate_exceeded`,
      `:ready_replicas_dropped`, `:polls_failed`, `:no_baseline`
    * `:unmet` - recovery conditions still unmet, empty on recovery
    * `:polls` - how many polls ran inside the window

  The map may be empty: a verifier with nothing to add is allowed, and
  every reader treats a missing key as "not recorded" rather than
  failing.
  """
  @type detail :: map()

  @doc """
  Watch the verification window and judge the outcome, with the reasoning.

  The baseline is the pre-action snapshot from the evidence bundle
  (`metrics/baseline.json`), nil when the bundle recorded a gap there.
  Options carry at least `:window_seconds` from the policy. The machine
  holds its own state timeout as a backstop, so an implementation that
  never returns still cannot wedge an incident.
  """
  @callback verify(Record.t(), baseline :: map() | nil, opts :: keyword()) ::
              {:ok, outcome(), detail()}

  @doc """
  The configured verifier implementation.

  Resolved through application config so tests substitute the Mox mock
  while dev and prod poll the cluster through the real verifier.
  """
  @spec impl() :: module()
  def impl do
    Application.get_env(:kubeybilly, :verifier, Kubeybilly.Verification.Real)
  end
end
