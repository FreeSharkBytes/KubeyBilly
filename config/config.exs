# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :kubeybilly,
  generators: [timestamp_type: :utc_datetime]

# The Kubernetes client boundary: the real client everywhere except test,
# where config/test.exs swaps in the Mox mock.
config :kubeybilly, :k8s_client, Kubeybilly.K8sClient.Real

# Root directory for incident evidence bundles.
config :kubeybilly, :incidents_dir, "incidents"

# The verification boundary: the polling verifier everywhere except test,
# where config/test.exs swaps in the Mox mock.
config :kubeybilly, :verifier, Kubeybilly.Verification.Real

# The executor boundary: the real executor everywhere except test,
# where config/test.exs swaps in the Mox mock.
config :kubeybilly, :executor, Kubeybilly.Executor.Real

# The kill switch file (plan/04): the Helm chart mounts the killswitch
# ConfigMap key "engaged" here. nil means no switch is mounted, which
# reads as disengaged; config/runtime.exs overrides via KILLSWITCH_PATH.
config :kubeybilly, :killswitch_path, nil

# The LLM advisor boundary (plan/14): the stub is the default in every
# environment, so nothing depends on a network round trip unless a real
# adapter is enabled explicitly (see config/runtime.exs). The endpoint
# defaults target Scaleway Generative APIs; the model is picked from the
# live catalog at deploy time. The key is named by env var, never stored.
config :kubeybilly, :advisor,
  adapter: Kubeybilly.Advisor.Stub,
  base_url: "https://api.scaleway.ai/v1",
  # Picked by probing the live Scaleway catalog with the real propose
  # prompt: it returns schema-valid JSON with correct formulary parameter
  # names, answers in under two seconds, and declines when the evidence is
  # ambiguous, which is the behaviour this project wants. Reasoning models
  # such as qwen3.6-35b-a3b spend their token budget on a reasoning field
  # and can return null content, which degrades to no_action here.
  model: "mistral-small-3.2-24b-instruct-2506",
  api_key_env: "ADVISOR_API_KEY",
  timeout_ms: 10_000

# The LLM advisor fallback for unmatched signatures is off by default:
# a no_match escalates to a human instead (plan/02, plan/14). When
# enabled, the machine consults :advisor_module, which bridges the
# bundle onto the facade above and its guardrails.
config :kubeybilly, :advisor_enabled, false
config :kubeybilly, :advisor_module, Kubeybilly.Advisor.TriageAdapter

# How long the correlator buffers alert groups before routing them.
config :kubeybilly, :correlation_window_ms, 3000

# Shared bearer token for the alert webhook and manual trigger (plan/13).
# nil disables the check with a startup warning; config/runtime.exs fills
# it from WEBHOOK_TOKEN and requires it in prod.
config :kubeybilly, :webhook_token, nil

# Configure the endpoint
config :kubeybilly, KubeybillyWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: KubeybillyWeb.ErrorHTML, json: KubeybillyWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Kubeybilly.PubSub,
  live_view: [signing_salt: "UVMNM5/e"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :kubeybilly, Kubeybilly.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  kubeybilly: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  kubeybilly: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
