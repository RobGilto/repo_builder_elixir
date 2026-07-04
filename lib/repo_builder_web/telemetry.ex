defmodule RepoBuilderWeb.Telemetry do
  use Supervisor

  import Telemetry.Metrics

  alias RepoBuilder.Budget.Guard
  alias RepoBuilder.Session.Admission

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://telemetry-metrics.hexdocs.pm
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      # Add reporters as children of your supervision tree.
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # LiveView performance — visible in Phoenix LiveDashboard at /dev/dashboard
      summary("phoenix.live_view.mount.stop.duration",
        tags: [:view],
        unit: {:native, :millisecond},
        description: "Wall-clock time for a LiveView mount (connected phase) to complete"
      ),
      summary("phoenix.live_view.handle_event.stop.duration",
        tags: [:view, :event],
        unit: {:native, :millisecond},
        description: "Wall-clock time for a LiveView handle_event callback to complete"
      ),
      summary("phoenix.live_view.handle_params.stop.duration",
        tags: [:view],
        unit: {:native, :millisecond},
        description: "Wall-clock time for a LiveView handle_params callback to complete"
      ),

      # Database Metrics
      summary("repo_builder.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("repo_builder.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("repo_builder.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("repo_builder.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("repo_builder.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # Oban Metrics (BUILD_PROMPT.md §7/§13)
      summary("oban.job.stop.duration",
        unit: {:native, :millisecond},
        tags: [:queue]
      ),
      summary("oban.job.exception.duration",
        unit: {:native, :millisecond},
        tags: [:queue]
      ),

      # Orchestration Metrics (BUILD_PROMPT.md §9/§13)
      last_value("repo_builder.session.count",
        description: "Live harness sessions currently admitted"
      ),
      summary("repo_builder.cost.recorded.amount",
        description: "Per-run cost increments (USD)"
      ),

      # Budget guardrails (issue-budget-guardrails)
      last_value("repo_builder.budget.state.tripped_count",
        description: "Budget caps currently tripped"
      ),
      last_value("repo_builder.budget.state.max_ratio",
        description: "Highest spend/limit ratio across all caps"
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    [
      {__MODULE__, :measure_live_sessions, []},
      {__MODULE__, :measure_budget, []}
    ]
  end

  @doc "Periodic measurement: the current count of admitted live sessions (§9)."
  @spec measure_live_sessions() :: :ok
  def measure_live_sessions do
    # Telemetry starts before Admission (and the poller may tick during boot), so
    # tolerate Admission not being up yet.
    case Process.whereis(Admission) do
      nil ->
        :ok

      _pid ->
        %{used: used} = Admission.count()
        :telemetry.execute([:repo_builder, :session, :count], %{count: used}, %{})
    end
  end

  @doc "Periodic measurement: tripped-cap count + max spend/limit ratio (§9, budget guardrails)."
  @spec measure_budget() :: :ok
  def measure_budget do
    case Process.whereis(Guard) do
      nil ->
        :ok

      _pid ->
        %{caps: caps} = Guard.snapshot()
        tripped = Enum.count(caps, &(&1.state == :tripped))
        max_ratio = caps |> Enum.map(& &1.ratio) |> Enum.max(fn -> 0.0 end)

        :telemetry.execute(
          [:repo_builder, :budget, :state],
          %{tripped_count: tripped, max_ratio: max_ratio},
          %{}
        )
    end
  end
end
