defmodule Kubeybilly.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # An open ingest door must never be a silent surprise (plan/13).
    KubeybillyWeb.Plugs.WebhookAuth.warn_if_disabled()

    children = [
      KubeybillyWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:kubeybilly, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Kubeybilly.PubSub},
      {Kubeybilly.K8sClient.Conn, []},
      # Mirrors the kill switch file into :persistent_term before anything
      # that could reach a write path starts.
      {Kubeybilly.Executor.KillSwitch, []},
      {Task.Supervisor, name: Kubeybilly.Soundings.TaskSupervisor},
      Kubeybilly.Incident.Registry,
      Kubeybilly.Incident.Monitor,
      {Kubeybilly.Incident.Supervisor, []},
      # Closes stale open records before any ingest wiring starts.
      {Kubeybilly.Incident.Recovery, []},
      # Rebuilds the spent hourly budget from disk before ingest can act.
      {Kubeybilly.Executor.Budgets, []},
      {Kubeybilly.Alerts.Correlator, []},
      # Start to serve requests, typically the last entry
      KubeybillyWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Kubeybilly.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    KubeybillyWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
