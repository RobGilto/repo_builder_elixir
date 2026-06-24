defmodule RepoBuilderWeb.Router do
  use RepoBuilderWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {RepoBuilderWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", RepoBuilderWeb do
    pipe_through :browser

    live "/", ConsoleLive

    live "/dashboard", DashboardLive
    live "/agents/:id", AgentLive
    live "/workflows/:id", WorkflowLive
    live "/system-logs", SystemLogsLive

    # Agentic-layer adaptor: target-repo management + the planning-mode wizard.
    live "/projects", ProjectsLive, :index
    live "/projects/:id", ProjectsLive, :show
    live "/plan", PlanningLive, :new
    live "/plans/:id", PlanningLive, :show

    # Agentic plugin system: the plugin store / management UI.
    live "/plugins", PluginsLive
  end

  scope "/webhooks", RepoBuilderWeb do
    pipe_through :api

    post "/trigger", WebhookController, :trigger
  end

  # Internal, per-orchestrator-token-scoped MCP-over-HTTP tool surface (issue-c).
  # Both harness bindings (Claude's native MCP via .mcp.json, the pi extension)
  # reach this one endpoint. Bind to localhost in dev (config/runtime).
  pipeline :orchestrator_mcp do
    plug :accepts, ["json"]
    plug RepoBuilderWeb.Plugs.OrchestratorToken
  end

  scope "/orchestrator", RepoBuilderWeb do
    pipe_through :orchestrator_mcp

    post "/:orchestrator_id/mcp", OrchestratorMCPController, :rpc
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:repo_builder, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: RepoBuilderWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
