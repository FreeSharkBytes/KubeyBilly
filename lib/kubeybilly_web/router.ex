defmodule KubeybillyWeb.Router do
  use KubeybillyWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {KubeybillyWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # The webhook and manual trigger share one door and one token check
  # (plan/13): bearer token, never the dashboard's basic auth.
  pipeline :webhook_auth do
    plug KubeybillyWeb.Plugs.WebhookAuth
  end

  # Every dashboard page sits behind basic auth (plan/13): the approve
  # button is mutation-adjacent and must not be anonymous.
  pipeline :dashboard_auth do
    plug KubeybillyWeb.Plugs.DashboardAuth
  end

  scope "/", KubeybillyWeb do
    pipe_through [:browser, :dashboard_auth]

    live "/", IncidentListLive
    live "/incidents/:id", IncidentDetailLive
    live "/approvals", ApprovalsLive
  end

  scope "/api", KubeybillyWeb do
    pipe_through [:api, :webhook_auth]

    post "/v4/alerts", AlertController, :create
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:kubeybilly, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: KubeybillyWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
