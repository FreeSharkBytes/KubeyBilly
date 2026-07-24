defmodule KubeybillyWeb.AlertController do
  @moduledoc """
  The ingest door: `POST /api/v4/alerts`.

  Accepts the Alertmanager v4 webhook body and forwards the group map to
  the correlator, which owns all routing and idempotency decisions. The
  same endpoint is the manual trigger path: `billy triage` posts canned
  payloads here, through the same token check, so development never
  waits on a scrape interval. The reply is 202 on purpose: acceptance
  means "queued for correlation," never "acted on."
  """

  use KubeybillyWeb, :controller

  alias Kubeybilly.Alerts.Correlator

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    case validate(params) do
      :ok ->
        Correlator.ingest(correlator(), params)

        conn
        |> put_status(:accepted)
        |> json(%{"status" => "accepted"})

      {:error, detail} ->
        conn
        |> put_status(:bad_request)
        |> json(%{"error" => "malformed_payload", "detail" => detail})
    end
  end

  # Shape checks only: the correlator and Target.extract judge content.
  defp validate(params) do
    cond do
      params["version"] != "4" ->
        {:error, "version must be \"4\""}

      not (is_binary(params["groupKey"]) and params["groupKey"] != "") ->
        {:error, "groupKey must be a non-empty string"}

      params["status"] not in ["firing", "resolved"] ->
        {:error, "status must be \"firing\" or \"resolved\""}

      not is_list(params["alerts"]) ->
        {:error, "alerts must be a list"}

      true ->
        :ok
    end
  end

  # Tests point this at a process of their own to observe the forward.
  defp correlator, do: Application.get_env(:kubeybilly, :correlator, Correlator)
end
