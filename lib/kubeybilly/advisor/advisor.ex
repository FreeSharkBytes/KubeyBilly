defmodule Kubeybilly.Advisor do
  @moduledoc """
  The advisor boundary: a behaviour, a facade, and the guardrails.

  Layer 2 of the decision engine (plan/02) consults a model only when no
  signature matched, and never trusts what comes back. Adapters merely
  transport a question and an answer; every safety property lives here in
  the facade so no provider can bypass it: the answer must validate
  against the strict proposal schema, its confidence is capped at 0.7 in
  our code regardless of the model's claim (so a model proposal can never
  clear an auto tier), and anything malformed collapses into a
  `no_action` fallback with reason `model_output_invalid` once the
  adapter has spent its single retry. Which adapter answers is pure
  config, so dev, test, and the stage demo run the stub and never touch
  the network.
  """

  alias Kubeybilly.Advisor.Proposal

  @propose_event [:kubeybilly, :advisor, :propose]
  @narrate_event [:kubeybilly, :advisor, :narrate]

  # A model proposal may never clear an auto tier (plan/02, Layer 2).
  @confidence_cap 0.7

  @doc "Propose an action for an unmatched incident from its bundle summary."
  @callback propose(summary :: map()) :: {:ok, proposal :: term()} | {:error, term()}

  @doc "Turn a closed incident record into a readable narrative."
  @callback narrate(incident_record :: map()) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Ask the configured adapter for a proposal, then apply the guardrails.

  A well-formed answer comes back as `{:ok, %Proposal{}}` with its
  confidence capped at #{@confidence_cap}. A malformed answer, including
  an adapter that exhausted its retry with `{:error,
  {:model_output_invalid, detail}}`, comes back as a `no_action`
  fallback rather than an error, because declining with a reason is a
  result. Transport-level errors pass through for the caller to escalate.
  """
  @spec propose(map()) :: {:ok, Proposal.t()} | {:error, term()}
  def propose(summary) when is_map(summary) do
    adapter = adapter()

    summary
    |> adapter.propose()
    |> guard()
    |> emit_propose(adapter)
  end

  @doc """
  Ask the configured adapter to narrate a closed incident record.

  Narration has zero authority (plan/02, Layer 3): a failure here is
  reported, never retried into the factual log.
  """
  @spec narrate(map()) :: {:ok, String.t()} | {:error, term()}
  def narrate(incident_record) when is_map(incident_record) do
    adapter = adapter()

    incident_record
    |> adapter.narrate()
    |> check_narrative()
    |> emit_narrate(adapter)
  end

  ## Guardrails

  defp guard({:ok, raw}) do
    case Proposal.validate(raw) do
      {:ok, proposal} -> {:ok, cap(proposal), :ok}
      {:error, details} -> {:ok, fallback(details), :fallback}
    end
  end

  defp guard({:error, {:model_output_invalid, detail}}),
    do: {:ok, fallback(detail), :fallback}

  defp guard({:error, reason}), do: {:error, reason}

  defp cap(%Proposal{confidence: confidence} = proposal),
    do: %{proposal | confidence: min(confidence, @confidence_cap)}

  defp fallback(detail) do
    %Proposal{
      action: :no_action,
      params: %{reason: "model_output_invalid"},
      confidence: 0.0,
      rationale: "model output failed schema validation: #{inspect(detail)}"
    }
  end

  defp check_narrative({:ok, narrative}) when is_binary(narrative), do: {:ok, narrative}
  defp check_narrative({:ok, other}), do: {:error, {:invalid_narrative, other}}
  defp check_narrative({:error, reason}), do: {:error, reason}

  ## Telemetry

  defp emit_propose({:ok, proposal, outcome}, adapter) do
    :telemetry.execute(@propose_event, %{confidence: proposal.confidence}, %{
      outcome: outcome,
      action: proposal.action,
      adapter: adapter
    })

    {:ok, proposal}
  end

  defp emit_propose({:error, reason} = error, adapter) do
    :telemetry.execute(@propose_event, %{confidence: 0.0}, %{
      outcome: :error,
      reason: reason,
      adapter: adapter
    })

    error
  end

  defp emit_narrate({:ok, narrative} = result, adapter) do
    :telemetry.execute(@narrate_event, %{bytes: byte_size(narrative)}, %{
      outcome: :ok,
      adapter: adapter
    })

    result
  end

  defp emit_narrate({:error, reason} = error, adapter) do
    :telemetry.execute(@narrate_event, %{bytes: 0}, %{
      outcome: :error,
      reason: reason,
      adapter: adapter
    })

    error
  end

  defp adapter do
    :kubeybilly
    |> Application.fetch_env!(:advisor)
    |> Keyword.fetch!(:adapter)
  end
end
