defmodule Kubeybilly.Executor do
  @moduledoc """
  The boundary behind which all cluster mutation happens.

  The incident state machine never touches the cluster: it hands the
  validated action, the policy decision that permitted it, and the
  incident record to whatever implements this behaviour. Declaring the
  boundary before the real executor exists lets the state machine be
  driven end to end with a Mox mock, and keeps the plan's first safety
  invariant (only the executor mutates) enforceable by the type system
  rather than by convention.
  """

  alias Kubeybilly.Formulary.Action
  alias Kubeybilly.Incident.Record
  alias Kubeybilly.StandingOrders.Decision

  @doc """
  Execute one validated action.

  The result map is executor-specific evidence for the record (patched
  revision, dry-run notice, and so on); an error closes the incident as
  escalated, never retries.
  """
  @callback execute(Action.t(), Decision.t(), Record.t()) ::
              {:ok, exec_result :: map()} | {:error, term()}

  @doc """
  The configured executor implementation.

  Resolved through application config so tests substitute the Mox mock
  while dev and prod mutate the cluster through the real executor.
  """
  @spec impl() :: module()
  def impl do
    Application.get_env(:kubeybilly, :executor, Kubeybilly.Executor.Real)
  end
end
