defmodule RepoBuilder.Orchestrator.Driver do
  @moduledoc """
  The autonomous drive loop (self-healing orchestrator, Phase 4) — the engine of
  fire-and-walk-away.

  On `drive_interval_ms` (and once on boot, the Durable-Checkpoint resume) it sweeps every
  drivable orchestrator — `Orchestrators.list_drivable/0` (an `:active` goal, row `:idle`/
  `:error`) further gated on a live `Budget.Guard` check and a NON-busy Queue — and for each
  enqueues ONE low-priority drive turn that runs a single inner-loop iteration. Operator turns
  always front-run drive turns (the Queue's priority ordering).

  The failure ladder runs at the head of each orchestrator's tick by reconciling the latest
  Progress entry against the prior:

    * real progress (`made_progress` and not `looping`) → `reset_stall`;
    * a `transient` entry (a turn that died on a transient provider condition — rate limit /
      overload) → ladder-NEUTRAL (neither bump nor reset; the tick cadence is the backoff);
    * otherwise → `bump_stall`;
    * `stall_count` in `[max_stall, escalate_after_stall)` → the next turn is a REPLAN turn
      (revise the Task Ledger, don't push the same step — Magentic-One stagnation rule);
    * `stall_count >= escalate_after_stall` → escalate: mark the ledger `:escalated`, set the
      orchestrator's holding-reason for the console banner, notify the away human, and STOP
      driving until an operator re-engages.

  A `:done` ledger is terminal (excluded by `list_drivable/0`). The Driver tracks the last
  Progress entry it acted on per orchestrator so the same entry is never counted twice across
  ticks. Disabled on boot + interval in tests (`drive_on_boot: false`,
  `drive_interval_ms: :infinity`); tests drive `tick/0` explicitly — mirroring the
  `LivenessReaper` test contract.
  """
  use GenServer

  require Logger

  alias RepoBuilder.Budget
  alias RepoBuilder.Budget.Scope
  alias RepoBuilder.Orchestrator.{Ledgers, Queue, Reflections, TaskLedger, WorkerFleet}
  alias RepoBuilder.Orchestrator.Orchestrator
  alias RepoBuilder.Orchestrators

  # The drive loop is now a BACKSTOP, not the engine: the event-driven holding pattern is
  # the primary re-engagement path, and the deterministic `WorkerFleet` gate stops the loop
  # from polling an orchestrator that has live, progressing workers. So the default tick is
  # slow and a per-orchestrator cooldown floors the cadence regardless of fleet edge cases.
  @default_interval_ms 120_000
  @default_min_drive_interval_ms 120_000
  @default_max_stall 2
  @default_escalate_after_stall 3

  # GenServer state:
  #   * `acted` maps orchestrator_id => the last Progress entry id whose stall verdict we
  #     already applied, so a stall is counted exactly once per turn.
  #   * `last_drive` maps orchestrator_id => the monotonic-ms timestamp it was last driven,
  #     so the `min_drive_interval_ms` cooldown deterministically bounds drive spend.
  @type state :: %{
          acted: %{optional(Ecto.UUID.t()) => Ecto.UUID.t()},
          last_drive: %{optional(Ecto.UUID.t()) => integer()}
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)

  @doc "Run ONE drive sweep across all drivable orchestrators; returns the count driven/escalated."
  @spec tick(GenServer.server()) :: non_neg_integer()
  def tick(server \\ __MODULE__), do: GenServer.call(server, :tick)

  @doc "Clear the per-orchestrator acted-state (test isolation helper)."
  @spec reset(GenServer.server()) :: :ok
  def reset(server \\ __MODULE__), do: GenServer.call(server, :reset)

  @impl true
  def init(_opts) do
    _ = if interval_enabled?(), do: schedule_tick()

    if drive_on_boot?() do
      {:ok, initial_state(), {:continue, :boot}}
    else
      {:ok, initial_state()}
    end
  end

  @spec initial_state() :: state()
  defp initial_state, do: %{acted: %{}, last_drive: %{}}

  @impl true
  def handle_continue(:boot, state) do
    {_count, state} = do_tick(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    {_count, state} = do_tick(state)
    _ = if interval_enabled?(), do: schedule_tick()
    {:noreply, state}
  end

  @impl true
  def handle_call(:tick, _from, state) do
    {count, state} = do_tick(state)
    {:reply, count, state}
  end

  def handle_call(:reset, _from, _state) do
    {:reply, :ok, initial_state()}
  end

  # --- drive sweep ---

  @spec do_tick(state()) :: {non_neg_integer(), state()}
  defp do_tick(state) do
    Orchestrators.list_drivable()
    |> Enum.filter(&drivable_now?(&1, state))
    |> Enum.reduce({0, state}, fn orchestrator, {count, st} ->
      {acted?, st} = drive_one(orchestrator, st)
      {count + if(acted?, do: 1, else: 0), st}
    end)
  rescue
    error ->
      Logger.warning("Orchestrator.Driver tick failed: #{inspect(error)}")
      {0, state}
  end

  # The per-orchestrator inner loop: run the failure ladder against the latest Progress entry,
  # then drive / replan / escalate. Returns whether an action was taken (for the count).
  @spec drive_one(Orchestrator.t(), state()) :: {boolean(), state()}
  defp drive_one(%Orchestrator{} = orchestrator, state) do
    id = orchestrator.id
    state = maybe_apply_stall(id, state)

    case Ledgers.current(id) do
      %TaskLedger{} = ledger ->
        # `act_on/3` always takes an action (drive / replan / escalate), so stamp the
        # per-orchestrator drive cooldown whenever there is an active ledger to act on.
        {acted?, state} = act_on(orchestrator, ledger, state)
        {acted?, stamp_drive(state, id)}

      nil ->
        {false, state}
    end
  end

  # Apply the stall verdict for a NEW Progress entry exactly once (idempotent across ticks).
  @spec maybe_apply_stall(Ecto.UUID.t(), state()) :: state()
  defp maybe_apply_stall(id, state) do
    latest = Ledgers.latest_progress(id)

    cond do
      is_nil(latest) ->
        state

      Map.get(state.acted, id) == latest.id ->
        state

      # A transient provider failure (rate limit / overload; issue rate-limit-stall) is
      # ladder-NEUTRAL: neither bump nor reset. Mark it acted so it is never re-processed;
      # the tick cadence (`min_drive_interval_ms`) is the backoff and the next tick retries.
      latest.transient ->
        put_in(state.acted[id], latest.id)

      true ->
        _ =
          if latest.made_progress and not latest.looping do
            Ledgers.reset_stall(id)
          else
            Ledgers.bump_stall(id)
          end

        put_in(state.acted[id], latest.id)
    end
  end

  @spec act_on(Orchestrator.t(), TaskLedger.t(), state()) :: {boolean(), state()}
  defp act_on(%Orchestrator{} = orchestrator, %TaskLedger{} = ledger, state) do
    cond do
      ledger.stall_count >= escalate_after_stall() ->
        _ = escalate(orchestrator, ledger)
        {true, state}

      ledger.stall_count >= max_stall() ->
        _ = Queue.enqueue_drive(orchestrator.id, replan_prompt(ledger))
        {true, state}

      focus_gate_enabled?() and blank?(ledger.focus) ->
        _ = Queue.enqueue_drive(orchestrator.id, focus_prompt(ledger))
        {true, state}

      true ->
        _ =
          Queue.enqueue_drive(
            orchestrator.id,
            drive_prompt(ledger, Ledgers.latest_progress(orchestrator.id))
          )

        {true, state}
    end
  end

  # The away-human last resort: end the goal `:escalated`, surface a banner reason, notify.
  @spec escalate(Orchestrator.t(), TaskLedger.t()) :: :ok
  defp escalate(%Orchestrator{id: id, project_id: project_id}, %TaskLedger{} = ledger) do
    stall = ledger.stall_count

    reason =
      "No progress after #{stall} attempts (replan exhausted) — awaiting operator input."

    # Record the reason as a final Progress entry while the ledger is still active, THEN end it.
    _ =
      Ledgers.record_progress(id, %{
        "made_progress" => false,
        "on_track" => false,
        "summary" => reason
      })

    _ = Ledgers.mark_escalated(id, reason)
    _ = Orchestrators.set_holding_reason(id, reason)

    # Verbal reflection (Reflexion) so the next run for this project starts ahead of the blocker.
    _ =
      Reflections.record(%{
        lesson: "escalated to the operator: #{reason} (goal: #{ledger.goal})",
        goal: ledger.goal,
        orchestrator_id: id,
        project_id: project_id
      })

    # The away-human notification seam (PushNotification): telemetry + an audit log. A real
    # push integration can attach to this event without touching the drive loop.
    :telemetry.execute([:repo_builder, :orchestrator, :escalated], %{stall: stall}, %{
      orchestrator_id: id,
      reason: reason
    })

    Logger.warning("Orchestrator.Driver escalated orchestrator=#{id}: #{reason}")
    :ok
  end

  # --- gates ---

  # The full drive-eligibility gate for one tick, evaluated against the PRE-tick state:
  #   * within the budget guard,
  #   * the orchestrator's own turn queue is not busy,
  #   * the deterministic worker-fleet gate allows it (no live, progressing workers —
  #     those are re-engaged event-driven by the holding pattern, never polled), and
  #   * the per-orchestrator drive cooldown has elapsed.
  @spec drivable_now?(Orchestrator.t(), state()) :: boolean()
  defp drivable_now?(%Orchestrator{id: id} = orchestrator, state) do
    within_budget?(orchestrator) and queue_free?(orchestrator) and
      WorkerFleet.drivable?(id) and cooldown_elapsed?(id, state)
  end

  @spec within_budget?(Orchestrator.t()) :: boolean()
  defp within_budget?(%Orchestrator{id: id, project_id: project_id}) do
    Budget.Guard.check(Scope.scopes_for(%{orchestrator_id: id, project_id: project_id})) == :ok
  end

  @spec queue_free?(Orchestrator.t()) :: boolean()
  defp queue_free?(%Orchestrator{id: id}), do: not Queue.snapshot(id).busy?

  # Deterministic per-orchestrator cooldown: never drive the same orchestrator faster than
  # `min_drive_interval_ms`, bounding worst-case spend regardless of fleet-classification
  # edge cases. Uses monotonic time (immune to wall-clock jumps). Unstamped => eligible.
  @spec cooldown_elapsed?(Ecto.UUID.t(), state()) :: boolean()
  defp cooldown_elapsed?(id, %{last_drive: last_drive}) do
    case Map.get(last_drive, id) do
      nil -> true
      last -> now_ms() - last >= min_drive_interval_ms()
    end
  end

  @spec stamp_drive(state(), Ecto.UUID.t()) :: state()
  defp stamp_drive(state, id), do: put_in(state.last_drive[id], now_ms())

  @spec now_ms() :: integer()
  defp now_ms, do: System.monotonic_time(:millisecond)

  # --- prompts ---

  @spec drive_prompt(TaskLedger.t(), term()) :: String.t()
  defp drive_prompt(%TaskLedger{} = ledger, progress) do
    """
    [AUTONOMOUS DRIVE] You are driving this goal to completion on your own — the operator has \
    walked away. Take ONE concrete step this turn.

    GOAL: #{ledger.goal}
    DEFINITION OF DONE: #{ledger.definition_of_done}
    FOCUS: #{focus_line(ledger.focus)}
    #{progress_line(progress)}

    1. Re-orient with get_ledger if needed.
    2. Drive a worker (command_agent), fan out a new worker (create_agent), or — only if the \
    definition of done is VERIFIED against the actual tree (inspect_repo) — report_complete.
    3. record_progress before you finish (made_progress / looping / next_agent / summary).
    """
    |> String.trim()
  end

  @spec replan_prompt(TaskLedger.t()) :: String.t()
  defp replan_prompt(%TaskLedger{} = ledger) do
    """
    [REPLAN] The last attempts made no progress — do NOT push the same step again. Revise your \
    Task Ledger: reconsider the facts and the plan, then set_goal again with an updated plan (or \
    a sharper definition of done) and take a DIFFERENT next step.

    GOAL: #{ledger.goal}
    DEFINITION OF DONE: #{ledger.definition_of_done}

    record_progress at the end so the loop can tell whether the new approach is working.
    """
    |> String.trim()
  end

  # The focus-first nudge (focus discipline): an active goal with no focus is BLOCKED from
  # spending budget on workers, so nudge the brain to declare its focus before it acts — the
  # durable, server-side analogue of tilldone's `agent_end` nudge.
  @spec focus_prompt(TaskLedger.t()) :: String.t()
  defp focus_prompt(%TaskLedger{} = ledger) do
    """
    [FOCUS FIRST] Before spending budget on any worker, declare your FOCUS — the single concrete \
    thing you will pursue this stretch. `command_agent` / `create_agent` / `start_adw` are BLOCKED \
    until you do.

    GOAL: #{ledger.goal}
    DEFINITION OF DONE: #{ledger.definition_of_done}

    Call set_focus naming that one concrete thing (or set_focus with a `workstream` to focus a \
    specific parallel stream), then take your ONE step.
    """
    |> String.trim()
  end

  # Inference-only spec — narrows the nil/string focus below a `String.t() | nil` contract.
  defp focus_line(focus) when is_binary(focus) and focus != "", do: focus
  defp focus_line(_focus), do: "(none set — declare it with set_focus before commanding workers)"

  @spec blank?(String.t() | nil) :: boolean()
  defp blank?(nil), do: true
  defp blank?(focus) when is_binary(focus), do: String.trim(focus) == ""

  # Inference-only spec — the input narrows to the progress map/nil below a `term()` contract.
  defp progress_line(%{summary: summary}) when is_binary(summary) and summary != "",
    do: "LAST PROGRESS: " <> summary

  defp progress_line(_progress), do: "LAST PROGRESS: (none yet — this is the first step)"

  # --- config ---

  @spec schedule_tick() :: reference()
  defp schedule_tick, do: Process.send_after(self(), :tick, interval_ms())

  @spec config() :: keyword()
  defp config, do: Application.get_env(:repo_builder, :orchestrator, [])

  @spec interval_enabled?() :: boolean()
  defp interval_enabled?, do: is_integer(interval_ms())

  @spec interval_ms() :: pos_integer() | :infinity
  defp interval_ms, do: config()[:drive_interval_ms] || @default_interval_ms

  @spec min_drive_interval_ms() :: non_neg_integer()
  defp min_drive_interval_ms,
    do: config()[:min_drive_interval_ms] || @default_min_drive_interval_ms

  @spec drive_on_boot?() :: boolean()
  defp drive_on_boot?, do: Keyword.get(config(), :drive_on_boot, true)

  @spec max_stall() :: non_neg_integer()
  defp max_stall, do: config()[:max_stall] || @default_max_stall

  @spec escalate_after_stall() :: non_neg_integer()
  defp escalate_after_stall, do: config()[:escalate_after_stall] || @default_escalate_after_stall

  @spec focus_gate_enabled?() :: boolean()
  defp focus_gate_enabled?, do: Keyword.get(config(), :focus_gate, true)
end
