defmodule Kubeybilly.Advisor.TriageAdapter do
  @moduledoc """
  Bridges the machine's advisor seam onto the advisor facade.

  The machine speaks the matcher contract (`advise/1` over a loaded
  bundle, answering `{:match, signature}` or `:no_match`) while the
  facade speaks proposals over a summary map, and this module is the one
  translation between the two so neither side bends its contract. The
  summary is deliberately compact: waiting reasons, restart counts,
  recent event reasons, and capture gaps, never raw logs, because what
  leaves the process here is what may leave the cluster when a real
  provider is enabled (plan/13).

  A `no_action` proposal converts to `:no_match` rather than a
  signature: the machine's no-match path already escalates to a human
  with the evidence attached, which is exactly what declining means.
  Transport errors collapse the same way, because a broken advisor must
  degrade into the safe default, not into a crash inside gating.
  """

  alias Kubeybilly.Advisor
  alias Kubeybilly.Advisor.Proposal
  alias Kubeybilly.Signatures.LoadedBundle
  alias Kubeybilly.Signatures.Signature

  @max_event_reasons 20
  @max_pods 20

  # The parameter vocabulary Intent and the formulary understand. Fixed
  # allowlist, never String.to_atom/1: a hostile response cannot mint
  # atoms, and unknown keys stay strings for validation to reject.
  @param_keys Map.new(
                [:namespace, :name, :kind, :to_revision, :revision, :node, :replicas, :reason],
                &{Atom.to_string(&1), &1}
              )

  @doc """
  Consult the advisor about a bundle no signature matched.

  Returns `{:match, signature}` for a mitigation proposal, with the
  facade's capped confidence, the name `:advisor_proposed`, and the
  rationale prefixed `advisor:` so the logbook always shows where the
  verdict came from. Returns `:no_match` for `no_action` proposals and
  for transport errors.
  """
  @spec advise(LoadedBundle.t()) :: {:match, Signature.t()} | :no_match
  def advise(%LoadedBundle{} = bundle) do
    case Advisor.propose(summarize(bundle)) do
      {:ok, %Proposal{action: :no_action}} -> :no_match
      {:ok, %Proposal{} = proposal} -> {:match, to_signature(proposal)}
      {:error, _reason} -> :no_match
    end
  end

  @doc "The compact summary map the facade sends to the model."
  @spec summarize(LoadedBundle.t()) :: map()
  def summarize(%LoadedBundle{} = bundle) do
    pods = Enum.take(bundle.pods, @max_pods)

    %{
      workload: workload(bundle.baseline),
      namespace: namespace(bundle),
      waiting_reasons: waiting_reasons(pods),
      restart_counts: restart_counts(pods),
      recent_event_reasons: event_reasons(bundle.events),
      gaps: gaps(bundle.manifest)
    }
  end

  ## Proposal conversion

  defp to_signature(%Proposal{} = proposal) do
    Signature.new(%{
      name: :advisor_proposed,
      confidence: proposal.confidence,
      proposed_action: %{action: proposal.action, params: atomize_params(proposal.params)},
      rationale: "advisor: " <> proposal.rationale,
      evidence_refs: []
    })
  end

  defp atomize_params(params) do
    Map.new(params, fn {key, value} ->
      {Map.get(@param_keys, key, key), value}
    end)
  end

  ## Summary parts

  defp workload(%{"workload" => %{"kind" => kind, "name" => name, "namespace" => namespace}}) do
    %{kind: kind, name: name, namespace: namespace}
  end

  defp workload(_baseline), do: nil

  defp namespace(%LoadedBundle{baseline: %{"workload" => %{"namespace" => namespace}}}),
    do: namespace

  defp namespace(%LoadedBundle{pods: [%{namespace: namespace} | _rest]}), do: namespace
  defp namespace(%LoadedBundle{}), do: nil

  defp waiting_reasons(pods) do
    pods
    |> Enum.flat_map(&container_statuses/1)
    |> Enum.map(&get_in(&1, ["state", "waiting", "reason"]))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp restart_counts(pods) do
    Map.new(pods, fn pod ->
      restarts =
        pod
        |> container_statuses()
        |> Enum.map(&(&1["restartCount"] || 0))
        |> Enum.sum()

      {pod.name, restarts}
    end)
  end

  defp container_statuses(%{status: status}) do
    status
    |> Kernel.||(%{})
    |> Map.get("containerStatuses")
    |> List.wrap()
  end

  defp event_reasons(events) do
    events
    |> Enum.sort_by(fn {namespace, _events} -> namespace end)
    |> Enum.flat_map(fn {_namespace, namespace_events} -> namespace_events end)
    |> Enum.map(& &1["reason"])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(@max_event_reasons)
  end

  defp gaps(%{"gaps" => gaps}) when is_list(gaps) do
    Enum.map(gaps, fn
      %{"path" => path} -> path
      other -> inspect(other)
    end)
  end

  defp gaps(_manifest), do: []
end
