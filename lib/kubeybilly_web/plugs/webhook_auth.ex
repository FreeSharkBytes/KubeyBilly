defmodule KubeybillyWeb.Plugs.WebhookAuth do
  @moduledoc """
  Bearer token check for the alert webhook and the manual trigger.

  The token comes from `config :kubeybilly, :webhook_token`, which
  `config/runtime.exs` fills from `WEBHOOK_TOKEN`. In production the
  variable is required; in development it may be unset, which disables
  the check entirely and logs a startup warning, because a laptop
  posting canned payloads should not need a shared secret. Comparison
  is constant time so the token cannot be guessed byte by byte.
  """

  import Plug.Conn

  require Logger

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case configured_token() do
      nil -> conn
      token -> verify(conn, token)
    end
  end

  @doc "Whether the check is switched off (no token configured)."
  @spec disabled?() :: boolean()
  def disabled?, do: is_nil(configured_token())

  @doc "Log the boot-time warning when the check is disabled."
  @spec warn_if_disabled() :: :ok
  def warn_if_disabled do
    if disabled?() do
      Logger.warning(
        "WEBHOOK_TOKEN is not set: webhook and manual trigger authentication is disabled"
      )
    end

    :ok
  end

  defp configured_token, do: Application.get_env(:kubeybilly, :webhook_token)

  defp verify(conn, token) do
    with ["Bearer " <> presented] <- get_req_header(conn, "authorization"),
         true <- Plug.Crypto.secure_compare(presented, token) do
      conn
    else
      _mismatch -> reject(conn)
    end
  end

  defp reject(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{"error" => "invalid_token"}))
    |> halt()
  end
end
