defmodule Kubeybilly.MixProject do
  use Mix.Project

  def project do
    [
      app: :kubeybilly,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      releases: releases(),
      aliases: aliases(),
      deps: deps(),
      test_coverage: test_coverage(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Kubeybilly.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Coverage is enforced on the unit subset (mix test --exclude integration).
  # Ignored modules fall into two groups: modules whose dedicated tests are
  # tagged :integration (they are exercised by the integration CI job, which
  # does not measure coverage), and web/OTP wiring with no unit-testable
  # logic. The threshold is the floor for everything else.
  defp test_coverage do
    [
      summary: [threshold: 90],
      ignore_modules: [
        # Exercised by :integration-tagged tests only.
        Kubeybilly.Executor.Budgets,
        Kubeybilly.Executor.KillSwitch,
        Kubeybilly.Logbook,
        Kubeybilly.Logbook.Sections,
        Kubeybilly.Soundings.BundleWriter,
        Kubeybilly.Soundings.Collector,
        KubeybillyWeb.AlertController,
        KubeybillyWeb.ApprovalsLive,
        KubeybillyWeb.ErrorHTML,
        KubeybillyWeb.ErrorJSON,
        KubeybillyWeb.Evidence,
        KubeybillyWeb.IncidentDetailLive,
        KubeybillyWeb.IncidentListLive,
        KubeybillyWeb.Plugs.DashboardAuth,
        KubeybillyWeb.Plugs.WebhookAuth,
        # Framework/OTP wiring and test support.
        Kubeybilly.Application,
        Kubeybilly.Mailer,
        KubeybillyWeb,
        KubeybillyWeb.ConnCase,
        KubeybillyWeb.CoreComponents,
        KubeybillyWeb.Endpoint,
        KubeybillyWeb.Gettext,
        KubeybillyWeb.Layouts,
        KubeybillyWeb.Router,
        KubeybillyWeb.Telemetry
      ]
    ]
  end

  # The release that ships in the container image. Unix-only executables
  # because the runtime image is debian-slim; config/runtime.exs is read at
  # boot so the same image serves any cluster.
  defp releases do
    [
      kubeybilly: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent]
      ]
    ]
  end

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.9"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.5.20",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:k8s, "~> 2.8"},
      {:yaml_elixir, "~> 2.11"},
      {:mox, "~> 1.1", only: :test},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind kubeybilly", "esbuild kubeybilly"],
      "assets.deploy": [
        "tailwind kubeybilly --minify",
        "esbuild kubeybilly --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
