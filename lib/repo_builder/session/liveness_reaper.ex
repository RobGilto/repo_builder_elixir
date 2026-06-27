defmodule RepoBuilder.Session.LivenessReaper do
  @moduledoc """
  Periodic + boot liveness sweep for phantom `:running` workers AND orchestrator turns
  (issue worker-terminal Part B + issue orchestrator-stuck). Sibling to
  `RepoBuilder.OrphanReaper`.

  ## Workers (`agents` table)

  A worker `Session.Server` that dies WITHOUT ever dispatching a terminal event — a hard
  `Process.exit(pid, :kill)`, a brutal supervisor shutdown, or a BEAM/node restart —
  bypasses `terminate/2`'s synthesized-terminal backstop (`server.ex:507-530`). The
  optimistic `command_agent` `:running` write is never undone, so the `agents` row wedges
  at `:running` forever, no worker-terminal broadcast is ever sent, and the owning
  orchestrator never re-engages. This is the gap the runtime documents at
  `server.ex:517-519` ("a boot/periodic sweep, sibling to OrphanReaper, would be needed").

  On boot and on an interval this reaper finds non-archived agents stuck `:running`/
  `:holding` past a staleness grace whose `SessionRegistry` process is NOT alive, and for
  each reconciles status to `:error`, broadcasts `agent_updated` (so the console card
  flips), and — when the agent carries an `orchestrator_id` — fires the worker-terminal
  broadcast so the orchestrator Queue re-engages via its existing failed-return recovery.

  ## Orchestrators (`orchestrators` table)

  The orchestrator-level twin of the worker phantom: an orchestrator turn that ends
  WITHOUT a terminal frame reaching its `Orchestrator.Server` (hard kill, brutal
  shutdown, BEAM/node restart — the paths `terminate/2`'s `:idle` reconcile can't reach)
  leaves the `orchestrators` row wedged at `:running`. Once wedged the console shows it
  "running" with nothing running and `auto_resume`/operator turns can't cleanly start. A
  second sweep pass finds orchestrators stuck `:running` past the grace with NO live turn
  (no `Orchestrator.Server` / Queue turn and no live `"orch-<id>-…"` session) and
  reconciles each to `:idle`, broadcasting `orchestrator_updated` so the console flips.
  `:idle` (not `:error`) keeps the long-lived brain usable — a wedged orchestrator has no
  in-flight unit of work to fail.

  ## Staleness grace

  Load-bearing for both passes: it prevents reaping in the brief window between the
  optimistic `:running` write (`command_agent` for workers, `handle_continue(:launch)` at
  `server.ex:194` for orchestrators) and the `Session.Server` registering its session. A
  live registered worker/orchestrator is mid-turn and left alone.

  Started after `Repo` and the `SessionRegistry`/`Session.Supervisor` (so liveness
  lookups are valid). Disabled on boot in tests (`sweep_on_boot: false`,
  `interval_ms: :infinity`); tests drive `sweep/0` explicitly.
  """
  use GenServer

  require Logger

  alias RepoBuilder.{Agents, Dashboard, Orchestrators}
  alias RepoBuilder.Agents.Agent
  alias RepoBuilder.Orchestrator.Orchestrator
  alias RepoBuilder.Orchestrator.Queue

  @default_interval_ms 60_000
  @default_min_stale_ms 120_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    _ = if interval_enabled?(), do: schedule_sweep()

    if sweep_on_boot?() do
      {:ok, opts, {:continue, :sweep}}
    else
      {:ok, opts}
    end
  end

  @impl true
  def handle_continue(:sweep, state) do
    _ = sweep()
    {:noreply, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    _ = sweep()
    _ = if interval_enabled?(), do: schedule_sweep()
    {:noreply, state}
  end

  @doc """
  Reconcile every phantom across THREE passes and return the combined count touched:

    1. phantom `:running`/`:holding` WORKERS (dead process) → `:error` + re-engage owner;
    2. stuck `:running` ORCHESTRATOR turns (no live turn) → `:idle`;
    3. live-but-stale `:running` workers (self-healing Phase 1) → `:idle` — the safety net
       that catches a worker whose per-session quiescence timer was missed (e.g. a
       BEAM/node restart between arm and fire), demoting it WITHOUT killing it.

  Each candidate is stale past the same grace. Tests drive this directly.
  """
  @spec sweep() :: non_neg_integer()
  def sweep do
    stale_before = DateTime.add(DateTime.utc_now(), -min_stale_ms(), :millisecond)

    sweep_agents(stale_before) + sweep_orchestrators(stale_before) +
      sweep_idle_workers(stale_before)
  end

  # Pass 1 — phantom worker sessions (issue worker-terminal Part B).
  @spec sweep_agents(DateTime.t()) :: non_neg_integer()
  defp sweep_agents(stale_before) do
    stale_before
    |> Agents.list_stuck_running()
    |> Enum.reject(&session_alive?/1)
    |> Enum.reduce(0, fn agent, count ->
      _ = reconcile_phantom(agent)
      count + 1
    end)
  end

  # Pass 2 — phantom orchestrator turns (issue orchestrator-stuck): a stuck `:running`
  # orchestrator with no live turn is reconciled to `:idle` so the brain stays usable.
  @spec sweep_orchestrators(DateTime.t()) :: non_neg_integer()
  defp sweep_orchestrators(stale_before) do
    stale_before
    |> Orchestrators.list_stuck_running()
    |> Enum.reject(&orchestrator_turn_alive?/1)
    |> Enum.reduce(0, fn orchestrator, count ->
      _ = reconcile_phantom_orchestrator(orchestrator)
      count + 1
    end)
  end

  # Pass 3 — live-but-stale workers (self-healing Phase 1): a worker still `:running` past
  # the grace by HEARTBEAT (not `updated_at`) whose session process IS alive is demoted to
  # `:idle` — the catch-all for a missed per-session quiescence timer. Phantoms (dead
  # process) are NOT here: they were already reaped to `:error` by `sweep_agents/1`, and the
  # heartbeat query re-runs after that pass so a just-reconciled row (now `:error`) is gone.
  @spec sweep_idle_workers(DateTime.t()) :: non_neg_integer()
  defp sweep_idle_workers(stale_before) do
    if idle_demotion_enabled?() do
      stale_before
      |> Agents.list_stale_live_running()
      |> Enum.filter(&session_alive?/1)
      |> Enum.reduce(0, fn agent, count ->
        _ = demote_idle(agent)
        count + 1
      end)
    else
      0
    end
  end

  # A live registered worker is mid-turn and must be left alone — this is what prevents
  # reaping a healthy worker that simply hasn't emitted a terminal yet.
  @spec session_alive?(Agent.t()) :: boolean()
  defp session_alive?(%Agent{id: id}) do
    Registry.lookup(RepoBuilder.SessionRegistry, id) != []
  end

  # Fail-soft (mirrors OrphanReaper/`delete_ledger_quietly`): a DB/PubSub hiccup must not
  # turn the sweep into a crash that takes out the rest of the batch.
  @spec reconcile_phantom(Agent.t()) :: :ok
  defp reconcile_phantom(%Agent{} = agent) do
    {:ok, updated} = Agents.set_status(agent.id, :error)
    Dashboard.broadcast_agent_updated(updated)

    if is_binary(agent.orchestrator_id) do
      Dashboard.broadcast_worker_terminal(agent.orchestrator_id, %{
        worker_id: agent.id,
        name: agent.name,
        ok?: false,
        holding?: false,
        holding_reason: nil,
        context_tokens: 0,
        final_text: nil
      })
    end

    Logger.info("LivenessReaper reconciled phantom :running agent=#{agent.id}")
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  # Soft demotion (self-healing Phase 1): flip a live-but-stale worker `:running → :idle`
  # WITHOUT killing it (no `:error`, no worker-terminal) and refresh the console card. The
  # session stays alive and resumable — the leader re-engages it with one `command_agent`.
  # Fail-soft (mirrors reconcile_phantom/1).
  @spec demote_idle(Agent.t()) :: :ok
  defp demote_idle(%Agent{} = agent) do
    {:ok, updated} = Agents.set_status(agent.id, :idle)
    Dashboard.broadcast_agent_updated(updated)
    Logger.info("LivenessReaper demoted live-stale :running agent=#{agent.id} to :idle")
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  # A live orchestrator turn must be left alone: a long Claude orchestrator turn is
  # legitimately `:running` for minutes. Alive iff EITHER the per-orchestrator Queue is
  # mid-turn (a monitored in-flight turn), OR the session registry holds a live process
  # whose key starts with `"orch-<id>-"` (the turn's harness `Session.Server`).
  @spec orchestrator_turn_alive?(Orchestrator.t()) :: boolean()
  defp orchestrator_turn_alive?(%Orchestrator{id: id}) do
    Queue.snapshot(id).busy? or orchestrator_session_alive?(id)
  end

  @spec orchestrator_session_alive?(Ecto.UUID.t()) :: boolean()
  defp orchestrator_session_alive?(id) do
    prefix = "orch-#{id}-"

    RepoBuilder.SessionRegistry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.any?(fn key -> is_binary(key) and String.starts_with?(key, prefix) end)
  end

  # Fail-soft (mirrors reconcile_phantom/1): reconcile a wedged orchestrator to `:idle`
  # and flip any open console via `orchestrator_updated`. A DB/PubSub hiccup must not
  # crash the sweep and take out the rest of the batch.
  @spec reconcile_phantom_orchestrator(Orchestrator.t()) :: :ok
  defp reconcile_phantom_orchestrator(%Orchestrator{} = orchestrator) do
    {:ok, updated} = Orchestrators.set_status(orchestrator.id, :idle)
    Dashboard.broadcast_orchestrator_updated(updated)
    Logger.info("LivenessReaper reconciled phantom :running orchestrator=#{orchestrator.id}")
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  @spec schedule_sweep() :: reference()
  defp schedule_sweep, do: Process.send_after(self(), :sweep, interval_ms())

  @spec interval_enabled?() :: boolean()
  defp interval_enabled?, do: is_integer(interval_ms())

  @spec config() :: keyword()
  defp config, do: Application.get_env(:repo_builder, :session_liveness_reaper, [])

  @spec sweep_on_boot?() :: boolean()
  defp sweep_on_boot?, do: Keyword.get(config(), :sweep_on_boot, true)

  @spec interval_ms() :: pos_integer() | :infinity
  defp interval_ms, do: Keyword.get(config(), :interval_ms, @default_interval_ms)

  @spec min_stale_ms() :: non_neg_integer()
  defp min_stale_ms, do: Keyword.get(config(), :min_stale_ms, @default_min_stale_ms)

  # Pass 3 toggle (self-healing Phase 1): defaults ON. Set `idle_demotion: false` to disable
  # the live-stale `:idle` demotion (e.g. if process-count headroom is the binding concern
  # and a clean stop is preferred instead).
  @spec idle_demotion_enabled?() :: boolean()
  defp idle_demotion_enabled?, do: Keyword.get(config(), :idle_demotion, true)
end
