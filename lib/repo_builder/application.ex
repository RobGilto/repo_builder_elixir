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
      # File-driven prompt palette (issue-prompt-adw-palette): scans slash commands /
      # agents / ADWs from the merged (app + working-dir) root, watches them via
      # FileSystem, and broadcasts changes over PubSub. After PubSub (it broadcasts),
      # independent of Repo. The watcher/poll loop is disabled in test config.
      RepoBuilder.Definitions,
      # Off-hot-path canonical-event persistence (issue hot-path-writes Part A): a
      # PartitionSupervisor of Logs.Writer GenServers. Session.Server.dispatch/2 fans
      # out the per-agent broadcast synchronously then casts persistence here, so a slow
      # `agent_logs` insert never head-of-line-blocks the next event. After Repo/PubSub
      # (it persists + broadcasts), before the session runtime that casts to it.
      {PartitionSupervisor,
       child_spec: RepoBuilder.Logs.Writer, name: RepoBuilder.LogsWriterSupervisor},
      # Durable jobs / cron / webhook triggers (needs Repo).
      {Oban, Application.fetch_env!(:repo_builder, Oban)},
      # --- Live session runtime (BUILD_PROMPT.md §5), after PubSub / before Endpoint ---
      # Maps a live session's agent/session id -> its GenServer pid.
      {Registry, keys: :unique, name: RepoBuilder.SessionRegistry},
      # Live-session concurrency gate (admission control).
      RepoBuilder.Session.Admission,
      # Live budget circuit breaker (issue-budget-guardrails): loads caps + reconciles
      # spent-so-far from CostCenter on init, so it starts AFTER Repo and before the
      # Endpoint. Enforcement fails open if it is mid-restart.
      RepoBuilder.Budget.Guard,
      # One :temporary child per live harness session; max_children bounds OS pids/fds.
      {DynamicSupervisor,
       name: RepoBuilder.SessionSupervisor,
       strategy: :one_for_one,
       max_children: session_max_children()},
      # One supervised state machine per running ADW; a failed step is isolated to
      # its workflow.
      {DynamicSupervisor, name: RepoBuilder.WorkflowSupervisor, strategy: :one_for_one},
      # One :temporary monitor per orchestrator turn (issue-c): subscribes to the
      # orchestrator session's events, captures session_id/cost, and dispatches
      # in-process tool calls for harnesses without an external (MCP/extension)
      # binding. A crashed turn is isolated, never restarted.
      {DynamicSupervisor, name: RepoBuilder.OrchestratorSupervisor, strategy: :one_for_one},
      # Per-orchestrator FIFO turn queue (issue message-queue): serializes operator
      # turns so a second message during an in-flight turn queues instead of racing
      # the same resumable CLI session. One long-lived Queue per orchestrator id,
      # registered by id and started on demand under this DynamicSupervisor.
      {Registry, keys: :unique, name: RepoBuilder.OrchestratorQueueRegistry},
      {DynamicSupervisor, name: RepoBuilder.OrchestratorQueueSupervisor, strategy: :one_for_one},
      # One :temporary runner per ephemeral "explain logs" request (issue-explain):
      # a one-shot Fast-tier session that never persists and never hits the global
      # feed. A crashed/finished run is isolated, never restarted.
      {DynamicSupervisor, name: RepoBuilder.ExplainSupervisor, strategy: :one_for_one},
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
