defmodule RepoBuilder.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias RepoBuilder.Telemetry.Alerting

  @impl true
  def start(_type, _args) do
    # Attach Oban's telemetry logger + cost/error alerting before events fire (§13).
    _ = Oban.Telemetry.attach_default_logger(level: :info)
    :ok = Alerting.attach()

    children = [
      RepoBuilderWeb.Telemetry,
      RepoBuilder.Repo,
      {DNSCluster, query: Application.get_env(:repo_builder, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: RepoBuilder.PubSub},
      # Durable jobs / cron / webhook triggers (needs Repo).
      {Oban, Application.fetch_env!(:repo_builder, Oban)},
      # --- Live session runtime (BUILD_PROMPT.md §5), after PubSub / before Endpoint ---
      # Maps a live session's agent/session id -> its GenServer pid.
      {Registry, keys: :unique, name: RepoBuilder.SessionRegistry},
      # Live-session concurrency gate (admission control).
      RepoBuilder.Session.Admission,
      # One :temporary child per live harness session; max_children bounds OS pids/fds.
      {DynamicSupervisor,
       name: RepoBuilder.SessionSupervisor,
       strategy: :one_for_one,
       max_children: session_max_children()},
      # One supervised state machine per running ADW; a failed step is isolated to
      # its workflow.
      {DynamicSupervisor, name: RepoBuilder.WorkflowSupervisor, strategy: :one_for_one},
      # Boot-time reconciliation of orphaned OS children via the durable ledger.
      # Runs AFTER Repo (it reads os_pid_ledger). Disabled on boot in tests.
      RepoBuilder.OrphanReaper,
      # Start to serve requests, typically the last entry
      RepoBuilderWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: RepoBuilder.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    RepoBuilderWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  @spec session_max_children() :: pos_integer()
  defp session_max_children do
    get_in(Application.get_env(:repo_builder, :session, []), [:max_children]) || 200
  end
end
