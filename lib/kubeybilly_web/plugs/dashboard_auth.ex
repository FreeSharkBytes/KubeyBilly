defmodule KubeybillyWeb.Plugs.DashboardAuth do
  @moduledoc """
  HTTP basic auth in front of every dashboard page (plan/13).

  The approve button is mutation-adjacent, so nothing behind this plug
  may be anonymous. Credentials come from `config :kubeybilly,
  :dashboard_auth`: billy/billy in development, DASHBOARD_USER and
  DASHBOARD_PASSWORD in production via `config/runtime.exs`, which
  refuses to boot without them. The README limitations section calls
  this what it is: demo-grade, put your SSO proxy in front for real.
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    Plug.BasicAuth.basic_auth(conn, Application.fetch_env!(:kubeybilly, :dashboard_auth))
  end
end
