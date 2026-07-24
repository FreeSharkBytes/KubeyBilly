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

  @doc """
  Watch the verification window and judge the outcome.

  The baseline is the pre-action snapshot from the evidence bundle
  (`metrics/baseline.json`), nil when the bundle recorded a gap there.
  Options carry at least `:window_seconds` from the policy. The machine
  holds its own state timeout as a backstop, so an implementation that
  never returns still cannot wedge an incident.
  """
  @callback verify(Record.t(), baseline :: map() | nil, opts :: keyword()) ::
              {:ok, :recovered | :unchanged | :worse}

  @doc """
  The configured verifier implementation.

  Resolved through application config so tests substitute the Mox mock;
  the real verifier arrives in a later build step.
  """
  @spec impl() :: module() | nil
  def impl do
    Application.get_env(:kubeybilly, :verifier)
  end
end
