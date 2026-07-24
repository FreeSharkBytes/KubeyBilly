import Config

# All Kubernetes access in tests goes through the Mox mock; no test may
# require a live cluster.
config :kubeybilly, :k8s_client, Kubeybilly.K8sClient.Mock

# The executor and verifier boundaries are Mox mocks in test: incidents
# are driven end to end without mutating or watching a cluster.
config :kubeybilly, :executor, Kubeybilly.ExecutorMock
config :kubeybilly, :verifier, Kubeybilly.VerifierMock

# A short correlation window keeps correlator tests fast.
config :kubeybilly, :correlation_window_ms, 50

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :kubeybilly, KubeybillyWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "9+vQSFrCE/yf7ahhdmW1PnE6L6YybN6pO8nj7UHdXZzZW+dAkksVwurVTWUCxwVL",
  server: false

# In test we don't send emails
config :kubeybilly, Kubeybilly.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
