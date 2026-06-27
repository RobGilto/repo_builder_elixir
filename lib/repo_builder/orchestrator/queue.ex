defmodule RepoBuilder.Orchestrator.Queue do
  @moduledoc """
  Per-orchestrator FIFO turn queue (issue message-queue).

  A long-lived GenServer (one per orchestrator id, registered on
  `RepoBuilder.OrchestratorQueueRegistry`, started on demand under
  `RepoBuilder.OrchestratorQueueSupervisor`) that SERIALIZES orchestrator turns so a
  second operator message sent mid-turn does not start a concurrent turn racing the
  same resumable CLI session (Claude `--resume`, pi `--session`).

  Lifecycle:

    * `enqueue/2` — when idle, start a turn immediately via `Server.start_turn/2`,
      `Process.monitor/1` the per-turn pid, and reply `{:ok, :started, agent_id}`.
      When busy, append the prompt and reply `{:ok, :queued, position}`.
    * the per-turn `Server` stops on `Done`/`Error`; its monitor `:DOWN` pops the head
      of the FIFO and starts it — guaranteeing only ONE turn resumes the session at a
      time, in operator order.
    * `cancel/2` removes a still-queued item (never the in-flight turn).
    * holding pattern — when `Orchestrators.auto_resume?/0` is enabled, a worker-terminal
      signal re-engages the orchestrator with ONE low-priority auto-resume turn so it
      reviews the returned work. If the queue is idle the resume starts immediately; if a
      turn is still in flight (the worker returned mid-dispatch) the resume is recorded in
      `pending_resume?` and started when the queue next drains to idle — so a return at an
      inconvenient moment is never lost (anti-amnesia) yet a burst coalesces to one resume
      (anti-spam). Operator messages always front-run and supersede it.

  The queue is in-memory runtime state (it does not survive a process restart), matching
  OTP norms — see the spec's Notes.
  """
  use GenServer

  alias RepoBuilder.Agents
  alias RepoBuilder.Agents.Handover
  alias RepoBuilder.Agents.Holding
  alias RepoBuilder.Dashboard
  alias RepoBuilder.Logs
  alias RepoBuilder.Orchestrator.Breaker
  alias RepoBuilder.Orchestrator.Ledgers
  alias RepoBuilder.Orchestrator.Server
  alias RepoBuilder.Orchestrator.Tools
  alias RepoBuilder.Orchestrators

  @registry RepoBuilder.OrchestratorQueueRegistry
  @sup RepoBuilder.OrchestratorQueueSupervisor

  @type kind :: :operator | :auto_resume | :drive
  @type item :: %{id: String.t(), prompt: String.t(), kind: kind()}
  @type snapshot :: %{
          busy?: boolean(),
          current: String.t() | nil,
          queued: [%{id: String.t(), preview: String.t(), kind: kind()}],
          depth: non_neg_integer()
        }
  @type enqueue_result ::
          {:ok, :started, String.t()} | {:ok, :queued, pos_integer()} | {:error, term()}
  @type starter :: (Ecto.UUID.t(), String.t() -> {:ok, pid(), String.t()} | {:error, term()})

  defmodule State do
    @moduledoc false
    use TypedStruct

    typedstruct enforce: true do
      field :orchestrator_id, Ecto.UUID.t()
      # FIFO of queued-item maps awaiting their turn.
      field :queue, :queue.queue()
      # The in-flight turn: {per-turn pid, monitor ref, agent_id}, or nil when idle.
      field :current, {pid(), reference(), String.t()} | nil
      # The pluggable turn launcher (defaults to Server.start_turn/2; tests inject a
      # controllable starter so the busy/idle state machine is fully deterministic).
      field :starter, (Ecto.UUID.t(), String.t() -> {:ok, pid(), String.t()} | {:error, term()})
      # One-bit holding-pattern memory (issue holding-pattern-followup): a worker
      # returned while the queue was busy/backlogged, so a single auto-resume turn is
      # OWED once the queue next drains to idle. Bursts coalesce to one flag; operator
      # messages clear it (they supersede the owed resume).
      field :pending_resume?, boolean()
      # The returned-worker info backing a pending resume, so the consumed auto-resume
      # prompt can name which worker to review (nil when no resume is owed; a burst
      # keeps the most recent return).
      field :pending_info, map() | nil
      # Dedup set: worker_ids that already triggered a resume in the current operator
      # context (issue holding-pattern-duplicate-resumes). A duplicate signal (same
      # worker_id) is dropped so spurious multi-fire from Path A + Path B can't cause
      # the orchestrator to waste turns dismissing "already handled" wakeups. Cleared
      # only when an operator message arrives (which represents a new dispatch context).
      field :seen_worker_ids, MapSet.t()
      # Monitored dispatched workers (self-healing Phase 2): `worker_id => %{ref, saw_terminal?}`.
      # `Process.monitor` pushes a `:DOWN` the instant a worker pid dies; a DOWN for a worker
      # whose row is still optimistically `:running` (no terminal landed) is authoritative
      # proof of an un-signaled death, so the Queue synthesizes `worker_terminal{ok?: false}`
      # immediately — milliseconds, not a ≤60 s reaper sweep. In-memory only: a Queue/BEAM
      # restart loses the monitors, which is exactly the reaper's surviving backstop role.
      field :workers, %{optional(String.t()) => %{ref: reference(), saw_terminal?: boolean()}},
        default: %{}

      # The pluggable tool entrypoint for handover side effects (wind-down `command_agent`
      # + self-delete `delete_agent`). Defaults to `Tools.call/3` (the same logged path the
      # brain uses, so budget/session/cwd handling + system-log rows come for free); tests
      # inject a fake to assert which tool was issued without spawning real sessions.
      field :tools, (String.t(), Ecto.UUID.t(), map() -> Tools.result())
    end
  end

  # --- client API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    orchestrator_id = Keyword.fetch!(opts, :orchestrator_id)
    GenServer.start_link(__MODULE__, opts, name: via(orchestrator_id))
  end

  @doc "Resolve the queue pid for `orchestrator_id`, starting it on demand."
  @spec start_or_get(Ecto.UUID.t()) :: {:ok, pid()} | {:error, term()}
  def start_or_get(orchestrator_id) do
    case whereis(orchestrator_id) do
      nil ->
        case DynamicSupervisor.start_child(@sup, {__MODULE__, orchestrator_id: orchestrator_id}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end

      pid ->
        {:ok, pid}
    end
  end

  @doc """
  Enqueue an operator `prompt` for `orchestrator_id`. Starts the queue on demand,
  runs the turn immediately when idle (`{:ok, :started, agent_id}`) or appends it
  (`{:ok, :queued, position}`). Rejects with `{:error, :queue_full}` past
  `Orchestrators.max_queue_depth/0` and surfaces start errors verbatim.
  """
  @spec enqueue(Ecto.UUID.t(), String.t()) :: enqueue_result()
  def enqueue(orchestrator_id, prompt) do
    with {:ok, pid} <- start_or_get(orchestrator_id) do
      # Durably record the operator turn so the chat transcript survives reconnect /
      # restart (specs/issue-operator-persist-operator-chat-messages.md). This public
      # path is operator-only (always `:operator` kind); internal holding-pattern
      # resume turns never call it, so resume prompts are never mislabeled as operator
      # turns. Persistence is best-effort (non-fatal): the turn must run regardless,
      # and we do NOT broadcast — the LiveView already echoes via push_user_message/2,
      # so broadcasting would double-render on the originating console.
      persist_operator_message(orchestrator_id, prompt)
      GenServer.call(pid, {:enqueue, prompt, :operator})
    end
  end

  @spec persist_operator_message(Ecto.UUID.t(), String.t()) :: :ok
  defp persist_operator_message(orchestrator_id, prompt) do
    case Logs.persist_operator_message(prompt, %{orchestrator_id: orchestrator_id}) do
      {:ok, _log} -> :ok
      {:error, _reason} -> :ok
    end
  end

  @doc """
  Register a freshly-dispatched worker so the Queue `Process.monitor`s its pid (self-healing
  Phase 2). A subsequent `:DOWN` with no preceding worker-terminal — and a row still
  optimistically `:running` — is authoritative proof of an un-signaled death; the Queue then
  synthesizes `worker_terminal{ok?: false}` instantly. Fire-and-forget cast so the dispatching
  turn never blocks; a no-op when the Queue isn't running (the reaper covers that path).
  """
  @spec monitor_worker(Ecto.UUID.t(), Ecto.UUID.t(), pid()) :: :ok
  def monitor_worker(orchestrator_id, worker_id, pid) when is_pid(pid) do
    case whereis(orchestrator_id) do
      nil -> :ok
      qpid -> GenServer.cast(qpid, {:monitor_worker, worker_id, pid})
    end
  end

  def monitor_worker(_orchestrator_id, _worker_id, _pid), do: :ok

  @doc """
  Enqueue ONE autonomous drive turn (self-healing Phase 4) — but ONLY when the queue is idle.
  A drive turn never piles up: if a turn is already in flight or queued the call returns
  `{:ok, :skipped}` and the next Driver tick re-evaluates. Starts the queue on demand.
  """
  @spec enqueue_drive(Ecto.UUID.t(), String.t()) ::
          {:ok, :started, String.t()} | {:ok, :skipped} | {:error, term()}
  def enqueue_drive(orchestrator_id, prompt) do
    with {:ok, pid} <- start_or_get(orchestrator_id) do
      GenServer.call(pid, {:enqueue_drive, prompt})
    end
  end

  @doc "Cancel a still-queued item by id (never the in-flight turn)."
  @spec cancel(Ecto.UUID.t(), String.t()) :: {:ok, snapshot()} | {:error, :not_found}
  def cancel(orchestrator_id, id) do
    case whereis(orchestrator_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:cancel, id})
    end
  end

  @doc "The current queue snapshot for the console (busy?/current/queued/depth)."
  @spec snapshot(Ecto.UUID.t()) :: snapshot()
  def snapshot(orchestrator_id) do
    case whereis(orchestrator_id) do
      nil -> empty_snapshot()
      pid -> GenServer.call(pid, :snapshot)
    end
  end

  @doc "Resolve the queue pid for an orchestrator id, or nil when not running."
  @spec whereis(Ecto.UUID.t()) :: pid() | nil
  def whereis(orchestrator_id) do
    case Registry.lookup(@registry, orchestrator_id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @spec via(Ecto.UUID.t()) :: {:via, Registry, {module(), Ecto.UUID.t()}}
  defp via(orchestrator_id), do: {:via, Registry, {@registry, orchestrator_id}}

  # --- server ---

  @impl true
  def init(opts) do
    orchestrator_id = Keyword.fetch!(opts, :orchestrator_id)
    _ = Dashboard.subscribe_orchestrator_workers(orchestrator_id)

    state = %State{
      orchestrator_id: orchestrator_id,
      queue: :queue.new(),
      current: nil,
      starter: opts[:starter] || (&Server.start_turn/2),
      pending_resume?: false,
      pending_info: nil,
      seen_worker_ids: MapSet.new(),
      workers: %{},
      tools: opts[:tools] || (&Tools.call/3)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:enqueue, prompt, kind}, _from, %State{current: nil} = state) do
    state = clear_pending_resume_for(state, kind)

    case start_item(state, build_item(prompt, kind)) do
      {:started, agent_id, state} ->
        log(state, "start", "started turn #{agent_id}")
        broadcast(state)
        {:reply, {:ok, :started, agent_id}, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:enqueue, prompt, kind}, _from, %State{} = state) do
    if :queue.len(state.queue) >= Orchestrators.max_queue_depth() do
      {:reply, {:error, :queue_full}, state}
    else
      item = build_item(prompt, kind)
      # Operator messages always front-run any pending auto-resume holding-pattern item
      # AND clear any owed (mid-turn) resume — operator work supersedes the resume.
      queue = item |> append_with_priority(state.queue)
      state = clear_pending_resume_for(%{state | queue: queue}, kind)
      position = :queue.len(queue)
      log(state, "enqueue", "queued #{kind} at position #{position}")
      broadcast(state)
      {:reply, {:ok, :queued, position}, state}
    end
  end

  def handle_call({:enqueue_drive, prompt}, _from, %State{} = state) do
    # Drive turns are issued only when fully idle and never queued — a backlog of stale drive
    # turns would defeat the "one inner-loop iteration per tick" contract.
    if idle?(state) do
      case start_item(state, build_item(prompt, :drive)) do
        {:started, agent_id, state} ->
          log(state, "drive", "started drive turn #{agent_id}")
          broadcast(state)
          {:reply, {:ok, :started, agent_id}, state}

        {:error, reason, state} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:ok, :skipped}, state}
    end
  end

  def handle_call({:cancel, id}, _from, %State{} = state) do
    list = :queue.to_list(state.queue)

    if Enum.any?(list, &(&1.id == id)) do
      queue = list |> Enum.reject(&(&1.id == id)) |> :queue.from_list()
      state = %{state | queue: queue}
      log(state, "cancel", "cancelled queued item #{id}")
      broadcast(state)
      {:reply, {:ok, to_snapshot(state)}, state}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:snapshot, _from, %State{} = state) do
    {:reply, to_snapshot(state), state}
  end

  @impl true
  def handle_cast({:monitor_worker, worker_id, pid}, %State{} = state)
      when is_binary(worker_id) do
    # Re-dispatch: drop any prior monitor for this worker so we track only the live pid.
    state = demonitor_worker(state, worker_id)
    ref = Process.monitor(pid)
    workers = Map.put(state.workers, worker_id, %{ref: ref, saw_terminal?: false})
    {:noreply, %{state | workers: workers}}
  end

  def handle_cast({:monitor_worker, _worker_id, _pid}, %State{} = state), do: {:noreply, state}

  @impl true
  def handle_info(
        {:DOWN, ref, :process, _down_pid, _reason},
        %State{current: {_pid, ref, _id}} = state
      ) do
    # The in-flight turn finished dispatching (Server stopped on Done/Error). Advance,
    # then honour any holding-pattern resume owed from a mid-turn worker return.
    state = %{state | current: nil}
    state = state |> advance() |> maybe_consume_pending_resume()
    broadcast(state)
    {:noreply, state}
  end

  # A monitored WORKER pid died (self-healing Phase 2), or a dangling monitor fired.
  def handle_info({:DOWN, ref, :process, _down_pid, reason}, %State{} = state) do
    case pop_worker_by_ref(state, ref) do
      # Clean exit: a real worker-terminal already drove the resume; the DOWN is just the
      # pid dying. Drop the monitor entry, nothing else to do.
      {_worker_id, %{saw_terminal?: true}, state} ->
        {:noreply, state}

      # Death with no terminal seen — synthesize one IFF the row is still `:running`.
      {worker_id, %{saw_terminal?: false}, state} ->
        {:noreply, maybe_synthesize_worker_terminal(state, worker_id, reason)}

      # Dangling monitor (e.g. after a queue-process restart) — ignore, never wedge.
      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:worker_terminal, info}, %State{} = state) do
    # A real terminal landed: mark the monitored worker so its trailing `:DOWN` does not
    # also synthesize one (de-dup with the Phase 2 push-liveness path), and feed the breaker.
    state = mark_terminal_seen(state, Map.get(info, :worker_id))
    _ = record_breaker_outcome(info)
    {:noreply, maybe_auto_resume(state, info)}
  end

  def handle_info(_msg, %State{} = state), do: {:noreply, state}

  # --- internals ---

  # Pop the head of the FIFO and start it, looping past items that fail to start so a
  # single bad turn never wedges the queue. Leaves :current nil when the queue drains.
  @spec advance(State.t()) :: State.t()
  defp advance(%State{} = state) do
    case :queue.out(state.queue) do
      {{:value, item}, rest} ->
        state = %{state | queue: rest}

        case start_item(state, item) do
          {:started, agent_id, state} ->
            log(state, "start", "started turn #{agent_id}")
            state

          {:error, _reason, state} ->
            advance(state)
        end

      {:empty, _queue} ->
        state
    end
  end

  # Launch one item via the (pluggable) starter, monitoring the per-turn pid on
  # success so its terminal :DOWN advances the queue.
  @spec start_item(State.t(), item()) ::
          {:started, String.t(), State.t()} | {:error, term(), State.t()}
  defp start_item(%State{} = state, item) do
    case state.starter.(state.orchestrator_id, item.prompt) do
      {:ok, pid, agent_id} ->
        ref = Process.monitor(pid)
        {:started, agent_id, %{state | current: {pid, ref, agent_id}}}

      {:error, reason} ->
        log(state, "error", "turn failed to start: #{inspect(reason)}")
        {:error, reason, state}
    end
  end

  # Holding pattern (event-driven, coalesced single-resume): a worker returned.
  #   * disabled          → unchanged (fully opt-out via config).
  #   * duplicate worker  → dropped (same worker_id already triggered a resume in this
  #     operator context — prevents spurious multi-fire from the same worker wasting
  #     billed turns; see issue holding-pattern-duplicate-resumes).
  #   * enabled + idle    → start the resume turn now.
  #   * enabled + busy/backlogged → record the OWED resume in `pending_resume?` rather
  #     than dropping it (anti-amnesia); a burst coalesces to one flag, keeping the most
  #     recent worker for the prompt. The owed resume is consumed when the queue next
  #     drains to idle (see `maybe_consume_pending_resume/1`).
  #
  # Layered ON TOP of the holding pattern (issue graceful-agent-handover), in precedence:
  #   1. handover signal present (`:handover <path>` in `final_text`) → self-delete the
  #      worker and resume the orchestrator naming it retired + linking the doc. ALWAYS
  #      actionable: bypasses the dedup check (a wind-down already added the worker to
  #      `seen_worker_ids`, but its follow-up handover terminal MUST be acted on).
  #   2. over threshold + not already winding down → issue ONE wind-down `command_agent`
  #      directive and flag the worker `winding_down`; the orchestrator is NOT resumed for
  #      this terminal. Also bypasses dedup (occupancy-driven, not a spurious multi-fire).
  #   3. already `winding_down` but returned without a signal → force-retire (delete +
  #      resume), so a worker can never get stuck over budget. Bypasses dedup too.
  #   4. otherwise → the existing duplicate-aware idle/pending holding-pattern behavior.
  @spec maybe_auto_resume(State.t(), map()) :: State.t()
  defp maybe_auto_resume(%State{} = state, info) do
    enabled? = Orchestrators.auto_resume?()

    case Handover.parse_signal(Map.get(info, :final_text)) do
      {:ok, path} ->
        # The worker asked to retire: delete it regardless of auto-resume; only enqueue the
        # orchestrator notice when auto-resume is on (matching the existing opt-out).
        handle_handover(state, info, path, enabled?)

      :none ->
        cond do
          # Branch 0 (issue holding-status-for-blocked-agents): the worker stopped HELD
          # pending external input. It must SURVIVE (no reap, no wind-down) and be resumed
          # via command_agent once unblocked. Checked before resume_or_wind_down so a held
          # worker is never collapsed into "completed and returned".
          Map.get(info, :holding?) == true -> hold(state, info)
          enabled? -> resume_or_wind_down(state, info)
          true -> state
        end
    end
  end

  # --- push liveness (self-healing Phase 2) ---

  # Find the monitored worker whose ref matches `ref` and pop it out of the tracking map.
  # `workers` holds only the few in-flight dispatched workers, so the linear scan is cheap.
  @spec pop_worker_by_ref(State.t(), reference()) ::
          {String.t(), %{ref: reference(), saw_terminal?: boolean()}, State.t()} | :error
  defp pop_worker_by_ref(%State{workers: workers} = state, ref) do
    case Enum.find(workers, fn {_id, %{ref: r}} -> r == ref end) do
      {worker_id, entry} ->
        {worker_id, entry, %{state | workers: Map.delete(workers, worker_id)}}

      nil ->
        :error
    end
  end

  # Mark a monitored worker's terminal as SEEN so its trailing `:DOWN` is a no-op. A worker
  # not currently monitored (reaper-fired / workflow-resume terminal) is left untouched.
  @spec mark_terminal_seen(State.t(), term()) :: State.t()
  defp mark_terminal_seen(%State{workers: workers} = state, worker_id)
       when is_binary(worker_id) do
    case Map.get(workers, worker_id) do
      %{} = entry ->
        %{state | workers: Map.put(workers, worker_id, %{entry | saw_terminal?: true})}

      nil ->
        state
    end
  end

  defp mark_terminal_seen(%State{} = state, _worker_id), do: state

  # Drop and flush a worker's monitor (re-dispatch / cleanup) so a stale `:DOWN` can't fire.
  @spec demonitor_worker(State.t(), String.t()) :: State.t()
  defp demonitor_worker(%State{workers: workers} = state, worker_id) do
    case Map.pop(workers, worker_id) do
      {%{ref: ref}, rest} ->
        _ = Process.demonitor(ref, [:flush])
        %{state | workers: rest}

      {nil, _rest} ->
        state
    end
  end

  # A monitored worker died with no terminal seen. The authoritative test for "no terminal
  # landed" is the agent row: a real Done/Error moved it OFF `:running` (via Logs.Writer), so
  # a still-`:running` row means the death was un-signaled. Reconcile to `:error` FIRST
  # (status-flip-first, so a later reaper sweep finds nothing — monitor is authoritative,
  # reaper a backstop), then feed the SAME synthetic payload the reaper uses into the holding
  # pattern so the leader re-engages exactly as it would for any failed return.
  @spec maybe_synthesize_worker_terminal(State.t(), String.t(), term()) :: State.t()
  defp maybe_synthesize_worker_terminal(%State{} = state, worker_id, reason) do
    case safe_get_agent(worker_id) do
      %Agents.Agent{status: :running} = worker ->
        _ = reconcile_worker_error(worker)
        _ = breaker_fail(worker)
        log(state, "worker_down", "synthetic terminal for #{worker_id} (#{inspect(reason)})")
        maybe_auto_resume(state, synthetic_terminal_info(worker))

      _other ->
        # A terminal already moved the row off `:running` — nothing to synthesize.
        state
    end
  end

  @spec synthetic_terminal_info(Agents.Agent.t()) :: map()
  defp synthetic_terminal_info(%Agents.Agent{} = worker) do
    %{
      worker_id: worker.id,
      name: worker.name,
      ok?: false,
      holding?: false,
      holding_reason: nil,
      context_tokens: 0,
      final_text: nil
    }
  end

  # Flip a still-`:running` worker to `:error` and refresh its console card. Fail-soft
  # (mirrors the reaper's reconcile_phantom/1): a DB/PubSub hiccup must not crash the Queue.
  @spec reconcile_worker_error(Agents.Agent.t()) :: :ok
  defp reconcile_worker_error(%Agents.Agent{} = worker) do
    case Agents.set_status(worker.id, :error) do
      {:ok, updated} -> Dashboard.broadcast_agent_updated(updated)
      _ -> :ok
    end

    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  # Feed the circuit breaker from a worker terminal (self-healing Phase 4): a clean/holding/
  # handover return (`ok?: true`) closes the harness/model path; a failed return opens it
  # toward tripping. A non-worker terminal (workflow/legacy signal) is a no-op. Fail-soft.
  @spec record_breaker_outcome(map()) :: :ok
  defp record_breaker_outcome(info) do
    case resolve_worker(info) do
      %Agents.Agent{} = worker ->
        key = Breaker.key(worker.harness, worker.model)
        if Map.get(info, :ok?), do: Breaker.succeed(key), else: Breaker.fail(key)

      _absent ->
        :ok
    end
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  @spec breaker_fail(Agents.Agent.t()) :: :ok
  defp breaker_fail(%Agents.Agent{} = worker),
    do: Breaker.fail(Breaker.key(worker.harness, worker.model))

  # `worker_id` is always a binary monitor-map key here; fail-soft so a DB hiccup never crashes
  # the Queue. Inference-only spec (the success typing narrows the input to a binary).
  defp safe_get_agent(worker_id) do
    Agents.get_agent(worker_id)
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  # Branch 0: a worker is HOLDING (blocked pending external input). NEVER reap it and
  # NEVER wind it down — a held worker must survive so it can be resumed. When auto-resume
  # is enabled, enqueue ONE holding-aware resume turn (deduped like `normal_resume`, so a
  # held worker does not spam resumes) telling the orchestrator the worker is blocked (not
  # done) and resumable via `command_agent`. When disabled, leave it holding for the
  # operator — the persistent `:holding` status + console badge make it discoverable.
  @spec hold(State.t(), map()) :: State.t()
  defp hold(%State{} = state, info) do
    worker_id = Map.get(info, :worker_id)
    duplicate? = is_binary(worker_id) and MapSet.member?(state.seen_worker_ids, worker_id)

    cond do
      not Orchestrators.auto_resume?() ->
        state

      duplicate? ->
        state

      true ->
        name = worker_name(info) || "a worker"
        reason = holding_reason(info)
        prompt = Holding.holding_resume_prompt(name, reason)
        seen = add_seen(state.seen_worker_ids, worker_id)
        %{state | seen_worker_ids: seen} |> resume_with(info, prompt)
    end
  end

  @spec holding_reason(map()) :: String.t()
  defp holding_reason(info) do
    case Map.get(info, :holding_reason) do
      reason when is_binary(reason) and reason != "" -> reason
      _ -> "blocked pending external input"
    end
  end

  # The occupancy-aware fork (auto-resume enabled, no handover signal): wind down a worker
  # over threshold, force-retire one that ignored a prior wind-down, else the normal
  # duplicate-aware holding pattern.
  @spec resume_or_wind_down(State.t(), map()) :: State.t()
  defp resume_or_wind_down(%State{} = state, info) do
    worker = resolve_worker(info)

    cond do
      over_threshold?(worker, info) and not winding_down?(worker) ->
        wind_down(state, info, worker)

      winding_down?(worker) ->
        force_retire(state, info)

      true ->
        normal_resume(state, info)
    end
  end

  # The pre-existing duplicate-aware holding pattern (branch 4) — unchanged behavior.
  @spec normal_resume(State.t(), map()) :: State.t()
  defp normal_resume(%State{} = state, info) do
    worker_id = Map.get(info, :worker_id)
    duplicate? = is_binary(worker_id) and MapSet.member?(state.seen_worker_ids, worker_id)

    cond do
      duplicate? ->
        state

      idle?(state) ->
        seen = add_seen(state.seen_worker_ids, worker_id)
        %{state | seen_worker_ids: seen} |> start_auto_resume(info) |> clear_pending()

      true ->
        seen = add_seen(state.seen_worker_ids, worker_id)
        %{state | pending_resume?: true, pending_info: info, seen_worker_ids: seen}
    end
  end

  # Branch 1: a worker handed over. Self-delete it (reaps the session + drops the agent row
  # + the rail card via `broadcast_agent_deleted`), then resume the orchestrator naming it
  # retired and linking the doc — unless auto-resume is off (then delete only). Fail-soft:
  # a delete failure logs and falls through (never crashes the Queue).
  @spec handle_handover(State.t(), map(), String.t(), boolean()) :: State.t()
  defp handle_handover(%State{} = state, info, path, enabled?) do
    name = worker_name(info)
    _ = delete_worker(state, name)

    if enabled? and is_binary(name) do
      resume_with(state, info, Handover.retired_resume_prompt(name, path))
    else
      state
    end
  end

  # Branch 2: issue exactly one wind-down directive and flag the worker `winding_down`. The
  # orchestrator is NOT resumed for this terminal (it returns when the worker hands over).
  @spec wind_down(State.t(), map(), Agents.Agent.t()) :: State.t()
  defp wind_down(%State{} = state, info, worker) do
    _ = Agents.merge_config(worker, %{"winding_down" => true})
    prompt = Handover.wind_down_prompt(blank_to_nil(worker.config["original_ask"]))

    case call_tool(state, "command_agent", %{"name" => worker.name, "prompt" => prompt}) do
      {:ok, _result} ->
        log(state, "wind_down", "issued wind-down directive to #{worker.name}")

      {:error, reason} ->
        log(state, "error", "wind-down failed for #{worker.name}: #{inspect(reason)}")
    end

    # No resume, no seen bookkeeping — the handover terminal that follows is the actionable
    # one (and bypasses the dedup set). Suppress the normal resume for this terminal.
    _ = info
    state
  end

  # Branch 3: a `winding_down` worker returned without a handover doc — force-retire it.
  @spec force_retire(State.t(), map()) :: State.t()
  defp force_retire(%State{} = state, info) do
    name = worker_name(info)
    _ = delete_worker(state, name)

    if is_binary(name) do
      resume_with(state, info, Handover.forced_retire_resume_prompt(name))
    else
      state
    end
  end

  # Resolve the worker row backing a terminal (nil when the terminal carries no worker_id —
  # e.g. workflow/ADW resume signals — so occupancy is 0 and the wind-down never fires).
  @spec resolve_worker(map()) :: Agents.Agent.t() | nil
  defp resolve_worker(info) do
    case Map.get(info, :worker_id) do
      id when is_binary(id) -> Agents.get_agent(id)
      _ -> nil
    end
  rescue
    # A non-UUID worker_id (legacy/workflow/test signal) can't back a worker row — treat
    # as "no worker", so occupancy is 0 and the normal holding pattern applies unchanged.
    _error -> nil
  end

  @spec over_threshold?(Agents.Agent.t() | nil, map()) :: boolean()
  defp over_threshold?(%Agents.Agent{} = worker, info) do
    context_tokens = Map.get(info, :context_tokens, 0)
    Handover.over_threshold?(Handover.occupancy(worker.harness, worker.model, context_tokens))
  end

  defp over_threshold?(_worker, _info), do: false

  @spec winding_down?(Agents.Agent.t() | nil) :: boolean()
  defp winding_down?(%Agents.Agent{config: config}), do: config["winding_down"] == true
  defp winding_down?(_worker), do: false

  @spec worker_name(map()) :: String.t() | nil
  defp worker_name(info), do: info[:name]

  # Self-delete a worker via the logged `delete_agent` tool entrypoint (reuses session
  # reaping + the `broadcast_agent_deleted` rail update). Fail-soft.
  @spec delete_worker(State.t(), String.t() | nil) :: :ok
  defp delete_worker(_state, nil), do: :ok

  defp delete_worker(%State{} = state, name) do
    case call_tool(state, "delete_agent", %{"name" => name}) do
      {:ok, _result} -> log(state, "handover", "retired worker #{name}")
      {:error, reason} -> log(state, "error", "retire failed for #{name}: #{inspect(reason)}")
    end

    :ok
  end

  # Start a handover-aware orchestrator resume with a custom prompt (idle-now or owed),
  # mirroring `maybe_auto_resume`'s idle/pending split but with the supplied text.
  @spec resume_with(State.t(), map(), String.t()) :: State.t()
  defp resume_with(%State{} = state, info, prompt) do
    info = Map.put(info, :resume_prompt, prompt)

    if idle?(state) do
      state |> start_auto_resume(info) |> clear_pending()
    else
      %{state | pending_resume?: true, pending_info: info}
    end
  end

  @spec call_tool(State.t(), String.t(), map()) :: Tools.result()
  defp call_tool(%State{tools: tools, orchestrator_id: id}, tool, args),
    do: tools.(tool, id, args)

  @spec blank_to_nil(term()) :: String.t() | nil
  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp blank_to_nil(_value), do: nil

  @spec add_seen(MapSet.t(), term()) :: MapSet.t()
  defp add_seen(seen, worker_id) when is_binary(worker_id), do: MapSet.put(seen, worker_id)
  defp add_seen(seen, _worker_id), do: seen

  # Consume an owed holding-pattern resume once the queue has drained to idle. The flag
  # is cleared BEFORE starting the resume so an auto-resume turn that dispatches no new
  # worker cannot retrigger itself — a fresh `{:worker_terminal, …}` is required to owe
  # another (loop-safety).
  @spec maybe_consume_pending_resume(State.t()) :: State.t()
  defp maybe_consume_pending_resume(%State{pending_resume?: true} = state) do
    if Orchestrators.auto_resume?() and idle?(state) do
      info = state.pending_info || %{}
      state |> clear_pending() |> start_auto_resume(info)
    else
      state
    end
  end

  defp maybe_consume_pending_resume(%State{} = state), do: state

  # The queue is fully idle: no in-flight turn and nothing waiting.
  @spec idle?(State.t()) :: boolean()
  defp idle?(%State{current: nil} = state), do: :queue.is_empty(state.queue)
  defp idle?(%State{}), do: false

  # Operator work supersedes an owed auto-resume AND resets the dedup set: an operator
  # message starts a new dispatch context, so the same worker returning again is fresh.
  @spec clear_pending_resume_for(State.t(), kind()) :: State.t()
  defp clear_pending_resume_for(%State{} = state, :operator), do: clear_pending_operator(state)
  defp clear_pending_resume_for(%State{} = state, _kind), do: state

  # Full reset for operator context: clears pending flags AND the dedup seen-set.
  @spec clear_pending_operator(State.t()) :: State.t()
  defp clear_pending_operator(%State{} = state),
    do: %{state | pending_resume?: false, pending_info: nil, seen_worker_ids: MapSet.new()}

  # Clears only the pending flags (used after a non-operator turn drains — does NOT
  # reset seen_worker_ids so subsequent duplicate fires are still suppressed).
  @spec clear_pending(State.t()) :: State.t()
  defp clear_pending(%State{} = state), do: %{state | pending_resume?: false, pending_info: nil}

  @spec start_auto_resume(State.t(), map()) :: State.t()
  defp start_auto_resume(%State{} = state, info) do
    item = build_item(auto_resume_prompt(state.orchestrator_id, info), :auto_resume)

    case start_item(state, item) do
      {:started, agent_id, state} ->
        log(state, "auto_resume", "holding-pattern resume #{agent_id}")
        broadcast(state)
        state

      {:error, _reason, state} ->
        state
    end
  end

  # A handover/holding path supplies a specific `resume_prompt` — pass it through untouched.
  @spec auto_resume_prompt(Ecto.UUID.t(), map()) :: String.t()
  defp auto_resume_prompt(_orchestrator_id, %{resume_prompt: prompt}) when is_binary(prompt),
    do: prompt

  # The generic worker-return resume, now SEEDED WITH INTENT (self-healing Phase 3): when a
  # goal is set, lead with the goal + definition-of-done + last progress so the leader resumes
  # reconciling against the ledger instead of re-deriving intent from CLI memory.
  defp auto_resume_prompt(orchestrator_id, info) do
    name = Map.get(info, :name) || "a worker"
    outcome = if Map.get(info, :ok?), do: "completed successfully", else: "finished with errors"

    base =
      "Worker #{name} #{outcome} and returned. Review its work and decide the next steps " <>
        "(report back, dispatch follow-up work, or stop)."

    prepend_goal_context(orchestrator_id, base)
  end

  @spec prepend_goal_context(Ecto.UUID.t(), String.t()) :: String.t()
  defp prepend_goal_context(orchestrator_id, base) do
    case Ledgers.current(orchestrator_id) do
      %{goal: goal, definition_of_done: dod} ->
        progress = Ledgers.latest_progress(orchestrator_id)

        """
        GOAL: #{goal}
        DEFINITION OF DONE: #{dod}
        #{progress_line(progress)}
        #{base}
        Reconcile against the goal: record_progress this turn, verify against the actual tree \
        with inspect_repo, and report_complete only once the definition of done is met.
        """
        |> String.trim()

      _none ->
        base
    end
  rescue
    _error -> base
  catch
    _kind, _reason -> base
  end

  # Inference-only spec — the input narrows to the ledger/progress map below the contract.
  defp progress_line(%{summary: summary}) when is_binary(summary) and summary != "",
    do: "LAST PROGRESS: " <> summary

  defp progress_line(_progress), do: "LAST PROGRESS: (none recorded yet)"

  # Operator items go to the back, but ahead of any pending auto-resume / drive item(s):
  # drop pending auto-resume + drive entries (they re-trigger when idle) so operators win.
  @spec append_with_priority(item(), :queue.queue()) :: :queue.queue()
  defp append_with_priority(%{kind: kind} = item, queue) when kind in [:auto_resume, :drive],
    do: :queue.in(item, queue)

  defp append_with_priority(%{kind: :operator} = item, queue) do
    queue
    |> :queue.to_list()
    |> Enum.reject(&(&1.kind in [:auto_resume, :drive]))
    |> :queue.from_list()
    |> then(&:queue.in(item, &1))
  end

  @spec build_item(String.t(), kind()) :: item()
  defp build_item(prompt, kind) do
    %{id: gen_id(), prompt: prompt, kind: kind}
  end

  @spec gen_id() :: String.t()
  defp gen_id, do: "q-" <> (8 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))

  @spec broadcast(State.t()) :: :ok
  defp broadcast(%State{orchestrator_id: id} = state) do
    Dashboard.broadcast_orchestrator_queue(id, to_snapshot(state))
  end

  @spec snapshot(State.t()) :: snapshot()
  defp to_snapshot(%State{} = state) do
    %{
      busy?: state.current != nil,
      current: current_agent_id(state.current),
      queued:
        state.queue
        |> :queue.to_list()
        |> Enum.map(&%{id: &1.id, preview: preview(&1.prompt), kind: &1.kind}),
      depth: :queue.len(state.queue)
    }
  end

  @spec current_agent_id({pid(), reference(), String.t()} | nil) :: String.t() | nil
  defp current_agent_id({_pid, _ref, agent_id}), do: agent_id
  defp current_agent_id(nil), do: nil

  # Inference-only spec — the fully-concrete idle map narrows below the hand-written
  # `snapshot()` contract, which Dialyzer rejects as a supertype.
  defp empty_snapshot, do: %{busy?: false, current: nil, queued: [], depth: 0}

  @spec preview(String.t()) :: String.t()
  defp preview(prompt) do
    trimmed = String.trim(prompt)

    if String.length(trimmed) > 80 do
      String.slice(trimmed, 0, 80) <> "…"
    else
      trimmed
    end
  end

  # Queue lifecycle observability (parity with Tools). Wrapped quietly so a DB blip
  # (e.g. test sandbox teardown) never crashes the queue process.
  @spec log(State.t(), String.t(), String.t()) :: :ok
  defp log(%State{orchestrator_id: id}, action, message) do
    _ =
      Logs.create_system_log(%{
        level: :info,
        message: "orchestrator queue #{action}: #{message}",
        metadata: %{"orchestrator_id" => id, "action" => action}
      })

    :ok
  rescue
    _error -> :ok
  catch
    _kind, _value -> :ok
  end
end
