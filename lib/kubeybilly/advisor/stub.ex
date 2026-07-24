defmodule Kubeybilly.Advisor.Stub do
  @moduledoc """
  The canned adapter: deterministic answers, zero network.

  This is the default in every environment (plan/14): dev, test, and the
  stage demo must never depend on a model round trip, and enabling a real
  provider has to be an explicit config change. Proposing `no_action` is
  the honest canned answer, because a stub that invented mitigations
  would poison the audit log.
  """

  @behaviour Kubeybilly.Advisor

  @impl Kubeybilly.Advisor
  def propose(_summary) do
    {:ok,
     %{
       action: :no_action,
       params: %{reason: "advisor_stub_active"},
       confidence: 0.0,
       rationale:
         "The stub advisor is active; no model was consulted. " <>
           "Escalating with the evidence bundle attached."
     }}
  end

  @impl Kubeybilly.Advisor
  def narrate(_incident_record) do
    {:ok,
     "Narrative unavailable: the stub advisor is active and no model was consulted. " <>
       "The factual sections of this record are complete without it."}
  end
end
