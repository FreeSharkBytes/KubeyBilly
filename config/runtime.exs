import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/kubeybilly start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :kubeybilly, KubeybillyWeb.Endpoint, server: true
end

config :kubeybilly, KubeybillyWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Where incident evidence bundles are written. In the container this points
# at the writable emptyDir mount (the root filesystem is read-only).
if incidents_dir = System.get_env("INCIDENTS_DIR") do
  config :kubeybilly, :incidents_dir, incidents_dir
end

# Where the standing orders policy file is mounted (the standing-orders
# ConfigMap key, plan/04). Unset means no orders: the correlator falls
# back to the read-only default tier and nothing mutates.
if standing_orders_path = System.get_env("STANDING_ORDERS_PATH") do
  config :kubeybilly, :standing_orders_path, standing_orders_path
end

# Where the kill switch file is mounted (the killswitch ConfigMap key
# "engaged", plan/04). Unset means no switch is mounted: disengaged.
if killswitch_path = System.get_env("KILLSWITCH_PATH") do
  config :kubeybilly, :killswitch_path, killswitch_path
end

# Shared bearer token for the alert webhook and the manual trigger
# (plan/13). Unset outside prod disables the check with a startup
# warning; prod refuses to boot without it further below.
if webhook_token = System.get_env("WEBHOOK_TOKEN") do
  config :kubeybilly, :webhook_token, webhook_token
end

# HTTP basic auth for the dashboard, which also guards the approve
# button (plan/13). Dev defaults live in config/dev.exs; prod refuses
# to boot without both variables further below.
dashboard_user = System.get_env("DASHBOARD_USER")
dashboard_password = System.get_env("DASHBOARD_PASSWORD")

if dashboard_user && dashboard_password do
  config :kubeybilly, :dashboard_auth, username: dashboard_user, password: dashboard_password
end

# The LLM advisor stays on the stub unless switched explicitly at
# runtime (plan/14). ADVISOR_ADAPTER=openai_compat enables the real
# provider; ADVISOR_BASE_URL and ADVISOR_MODEL retarget it without a
# rebuild. Unset vars leave the compile-time defaults untouched.
advisor_adapter =
  case System.get_env("ADVISOR_ADAPTER") do
    nil -> nil
    "stub" -> Kubeybilly.Advisor.Stub
    "openai_compat" -> Kubeybilly.Advisor.OpenAICompat
    other -> raise "unknown ADVISOR_ADAPTER #{inspect(other)}, expected stub or openai_compat"
  end

advisor_overrides =
  [
    adapter: advisor_adapter,
    base_url: System.get_env("ADVISOR_BASE_URL"),
    model: System.get_env("ADVISOR_MODEL")
  ]
  |> Enum.reject(fn {_key, value} -> is_nil(value) end)

if advisor_overrides != [] do
  config :kubeybilly, :advisor, advisor_overrides
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :kubeybilly, KubeybillyWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/kubeybilly_web/router\.ex$"E,
        ~r"lib/kubeybilly_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # In prod the webhook check is mandatory: an unauthenticated trigger
  # path on a tool that mutates clusters is not a configuration choice.
  System.get_env("WEBHOOK_TOKEN") ||
    raise """
    environment variable WEBHOOK_TOKEN is missing.
    The alert webhook and manual trigger require a shared bearer token in production.
    """

  # Same rule for the dashboard: approving an action is mutation-adjacent
  # and must not be anonymous (plan/13).
  (dashboard_user && dashboard_password) ||
    raise """
    environment variables DASHBOARD_USER and DASHBOARD_PASSWORD are missing.
    The dashboard (and its approve button) requires basic auth credentials in production.
    """

  host = System.get_env("PHX_HOST") || "example.com"

  config :kubeybilly, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :kubeybilly, KubeybillyWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :kubeybilly, KubeybillyWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :kubeybilly, KubeybillyWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :kubeybilly, Kubeybilly.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
