defmodule RepoBuilder.Orchestrator.Server do
  @moduledoc """
  Runs one orchestrator TURN as a harness session (issue-c).

  An orchestrator turn = one harness invocation, resumed across turns via the
  stored CLI `session_id` (Claude `--resume`, pi `--session`). `run_turn/2` mints a
  scoped tool token, builds the per-harness tool binding context + system prompt,
  and starts a `Session.Server` for the orchestrator — reusing the EXACT
  spawning/streaming/normalize/broadcast path workers use, so the orchestrator's
  canonical events stream to the console identically.

  This GenServer is a `:temporary` per-turn monitor under
  `RepoBuilder.OrchestratorSupervisor`. It subscribes to the orchestrator session's
  event topic to:

    * capture the resumable `session_id` and accumulate cost on the orchestrator row;
    * track status (`:running` → `:idle`/`:error`);
    * for a harness with NO external tool binding (e.g. Fake), dispatch the
      orchestrator's `tool_call` events in-process to `Orchestrator.Tools` — the
      same logic the MCP endpoint runs for Claude/pi out-of-band.
  """
  use GenServer, restart: :temporary

  require Logger

  alias RepoBuilder.{Dashboard, Logs, Orchestrators, Session}
  alias RepoBuilder.Harness.Event
  alias RepoBuilder.Harness.Registry, as: HarnessRegistry
  alias RepoBuilder.Orchestrator.{Ledgers, Queue, SystemPrompt, Tools}

  @sup RepoBuilder.OrchestratorSupervisor
  @pubsub RepoBuilder.PubSub

  defmodule State do
    @moduledoc false
    use TypedStruct

    typedstruct enforce: true do
      field :orchestrator_id, Ecto.UUID.t()
      # The orchestrator's bound project (issue per-project-cost-tracking) — threaded into
      # the cost telemetry metadata so Budget.Guard can attribute spend to the project.
      field :project_id, Ecto.UUID.t(), enforce: false
      field :agent_id, String.t()
      field :prompt, String.t()
      field :harness, String.t()
      field :in_process?, boolean()
      # Per-turn cost/usage accumulator (issue hot-path-writes Part B): the Usage
      # handler folds each streamed frame into these in-memory fields and emits the
      # live cost telemetry, then ONE coalesced row write flushes on Done/Error/
      # terminate — instead of ~6 DB round-trips per Usage frame.
      field :acc_cost, Decimal.t(), default: Decimal.new(0)
      field :in_tokens, non_neg_integer(), default: 0
      field :out_tokens, non_neg_integer(), default: 0
      field :last_context, non_neg_integer() | nil, default: nil
      field :last_estimate, float() | Decimal.t() | nil, default: nil
      # Guards against a double flush: set once a terminal event flushed, so the
      # terminate/2 crash-safety flush becomes a no-op.
      field :flushed?, boolean(), default: false
      # When this turn started (self-healing Phase 3): the auto-record backstop writes a
      # minimal Progress entry on flush IFF the brain recorded none since this instant, so
      # the ledger never gaps regardless of harness (in-process Fake or out-of-band MCP).
      field :turn_started_at, DateTime.t(), enforce: false
      # Set when this turn saw a transient provider condition (rate limit / overload;
      # issue rate-limit-stall). A not-ok terminal then auto-records `:transient` instead of
      # `:error`, so the drive-loop stall ladder treats throttling as ladder-neutral.
      field :transient_error?, boolean(), default: false
    end
  end

  @doc """
  Run `prompt` as one orchestrator turn, routed through the per-orchestrator FIFO
  `Queue` (issue message-queue): when a turn is already in flight the prompt is
  appended instead of racing the same resumable CLI session. Returns the started
  turn's `agent_id` (used by the console for attribution) when it ran immediately,
  the sentinel `"queued"` when it was appended, or `{:error, reason}` when the
  orchestrator is missing or its harness is not orchestrator-capable.

  Kept as the back-compatible entry point; the queue is the serialization backbone.
  """
  @spec run_turn(Ecto.UUID.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def run_turn(orchestrator_id, prompt) do
    case Queue.enqueue(orchestrator_id, prompt) do
      {:ok, :started, agent_id} -> {:ok, agent_id}
      {:ok, :queued, _position} -> {:ok, "queued"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Compact the orchestrator's OWN context (orchestration-adw-loop, task 8) — the brain's
  durable swap. Analogous to `compact_agent` for workers: it schedules a `/compact` turn on
  the orchestrator's own resumable session through the `Queue`, which then reseeds the NEXT
  turn with the `list_workstreams` index (rehydrate-on-resume). Returns `{:ok, :compacting}`
  once scheduled; safe to call mid-turn (the compact turn runs when the queue next drains).
  """
  @spec compact_self(Ecto.UUID.t()) :: {:ok, :compacting} | {:error, term()}
  def compact_self(orchestrator_id) do
    case Queue.request_compaction(orchestrator_id) do
      :ok -> {:ok, :compacting}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec ensure_orchestrating(RepoBuilder.Orchestrator.Orchestrator.t()) ::
          :ok | {:error, :not_orchestrator_capable}
  defp ensure_orchestrating(orchestrator) do
    if HarnessRegistry.orchestrating?(orchestrator.harness),
      do: :ok,
      else: {:error, :not_orchestrator_capable}
  end

  # Refuse to run with no model selected, and surface it in the observability
  # system (a persisted Error event on the console feed) — not just a flash.
  @spec ensure_model(RepoBuilder.Orchestrator.Orchestrator.t()) ::
          :ok | {:error, :no_model_selected}
  defp ensure_model(orchestrator) do
    if blank?(orchestrator.model) do
      emit_no_model_error(orchestrator)
    else
      :ok
    end
  end

  @spec emit_no_model_error(RepoBuilder.Orchestrator.Orchestrator.t()) ::
          {:error, :no_model_selected}
  defp emit_no_model_error(orchestrator) do
    agent_id = "orch-#{orchestrator.id}-#{System.unique_integer([:positive])}"

    event = %Event.Error{
      harness: String.to_atom(orchestrator.harness),
      message: "no model selected — pick a model in the console header before running",
      reason: :no_model_selected,
      retryable: false
    }

    # Persist first so the global feed broadcast can carry the persisted row's durable
    # `log_no` (the `log-<n>` drilldown number) — parity with the session path.
    log_no =
      case Logs.persist_orchestrator_event(event, %{
             orchestrator_id: orchestrator.id,
             project_id: orchestrator.project_id,
             session_id: agent_id,
             provider: orchestrator.provider,
             model: orchestrator.model
           }) do
        {:ok, log} -> log.log_no
        {:error, _changeset} -> nil
      end

    _ = Dashboard.broadcast_event(agent_id, event, log_no)

    _ = Orchestrators.set_status(orchestrator.id, :error)
    {:error, :no_model_selected}
  end

  @spec blank?(String.t() | nil) :: boolean()
  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""

  @doc """
  Start ONE orchestrator turn and return the started per-turn process pid plus its
  `agent_id`, so the `Queue` can `Process.monitor/1` it and dequeue the next item
  when it stops (on `Done`/`Error`). Validates the orchestrator can run
  (orchestrator-capable harness + a selected model) exactly as `run_turn/2` did,
  surfacing `{:error, :not_orchestrator_capable}` / `{:error, :no_model_selected}`.
  """
  @spec start_turn(Ecto.UUID.t(), String.t()) ::
          {:ok, pid(), String.t()} | {:error, term()}
  def start_turn(orchestrator_id, prompt) do
    with {:ok, orchestrator} <- Orchestrators.fetch(orchestrator_id),
         :ok <- ensure_orchestrating(orchestrator),
         :ok <- ensure_model(orchestrator) do
      do_start_turn(orchestrator, prompt)
    end
  end

  @spec do_start_turn(RepoBuilder.Orchestrator.Orchestrator.t(), String.t()) ::
          {:ok, pid(), String.t()} | {:error, term()}
  defp do_start_turn(orchestrator, prompt) do
    agent_id = "orch-#{orchestrator.id}-#{System.unique_integer([:positive])}"

    child =
      {__MODULE__, orchestrator: orchestrator, agent_id: agent_id, prompt: prompt}

    case DynamicSupervisor.start_child(@sup, child) do
      {:ok, pid} -> {:ok, pid, agent_id}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  # --- server ---

  @impl true
  def init(opts) do
    orchestrator = Keyword.fetch!(opts, :orchestrator)
    adapter = adapter_for(orchestrator.harness)

    state = %State{
      orchestrator_id: orchestrator.id,
      project_id: orchestrator.project_id,
      agent_id: Keyword.fetch!(opts, :agent_id),
      prompt: Keyword.fetch!(opts, :prompt),
      harness: orchestrator.harness,
      in_process?: not function_exported?(adapter, :orchestrator_spawn, 2),
      turn_started_at: DateTime.utc_now()
    }

    {:ok, {state, orchestrator}, {:continue, :launch}}
  end

  @impl true
  def handle_continue(:launch, {%State{} = state, orchestrator}) do
    _ = Phoenix.PubSub.subscribe(@pubsub, "agent:#{state.agent_id}:events")
    {:ok, token} = Orchestrators.mint_token(orchestrator.id)
    _ = Orchestrators.set_status(orchestrator.id, :running)

    opts = [
      agent_id: state.agent_id,
      harness: state.harness,
      prompt: state.prompt,
      session_id: orchestrator.session_id,
      # A Claude orchestrator with no explicit model still runs Opus (per-harness
      # orchestrator default); pi leaves it nil (operator-chosen).
      model:
        orchestrator.model ||
          HarnessRegistry.orchestrator_defaults(orchestrator.harness)[:default_model],
      provider: orchestrator.provider,
      reasoning_effort: orchestrator.reasoning_effort,
      # Operator-chosen working directory (nil ⇒ managed per-orchestrator workspace).
      # The runtime writes `.mcp.json`/per-session config here and resumes turns in it.
      # Deliberately NO `isolation_mode` here: worktree-by-default applies to WORKERS
      # only (agent_ops/adw dispatch). The orchestrator brain must keep observing the
      # operator's real tree — isolating it would blind it to in-flight work.
      cwd: orchestrator.working_dir,
      # Interactive orchestrator turns get a shorter idle watchdog than the worker-grade
      # session default (5 min): a byte-silent orchestrator turn beyond this is treated as
      # stalled and surfaced/recovered via the session's idle-timeout → Event.Error path.
      idle_ms: orchestrator_idle_ms(),
      config: %{orchestrator: true},
      # Threaded for completeness; the session gates project secrets OUT for the
      # orchestrator brain (config[:orchestrator] == true), so plaintext lives only in
      # worker children (issue-per-project-encrypted-secrets-vault).
      project_id: orchestrator.project_id,
      orchestrator_ctx: tool_ctx(orchestrator, token),
      orchestrator_db_id: orchestrator.id
    ]

    case Session.Supervisor.start_session(opts) do
      {:ok, _pid} ->
        # Hard per-turn ceiling (self-healing Phase 4): a turn that trickles keep-alive bytes
        # never trips the byte-idle `turn_idle_ms` watchdog, so arm a HARD deadline from turn
        # start (NOT reset per frame). On fire we force-flush to :error and stop the session so
        # the Driver re-engages. The process dying cancels the timer on a normal terminal.
        _ = arm_turn_deadline()
        {:noreply, state}

      {:error, reason} ->
        _ = Orchestrators.set_status(orchestrator.id, :error)
        Logger.warning("orchestrator turn failed to start: #{inspect(reason)}")
        {:stop, :normal, state}
    end
  end

  @impl true
  def handle_info({:harness_event, %Event.SessionStarted{session_id: sid}}, %State{} = state)
      when is_binary(sid) and sid != "" do
    _ = Orchestrators.set_session(state.orchestrator_id, sid)
    {:noreply, state}
  end

  def handle_info({:harness_event, %Event.ToolCall{} = event}, %State{in_process?: true} = state) do
    _ = Tools.call(event.name, state.orchestrator_id, event.input)
    {:noreply, state}
  end

  def handle_info({:harness_event, %Event.Usage{} = event}, %State{} = state) do
    # Coalesce the per-Usage write storm (issue hot-path-writes Part B): accumulate
    # in-memory and emit the live cost telemetry per frame (so Budget.Guard enforces
    # caps on every increment), but DO NOT write the `orchestrators` row here — the
    # single flush happens on the terminal event / terminate.
    ni = non_neg(event.input_tokens)
    no = non_neg(event.output_tokens)

    delta =
      Orchestrators.emit_cost_recorded(state.orchestrator_id, event.cost_usd, state.project_id)

    state = %State{
      state
      | acc_cost: Decimal.add(state.acc_cost, delta),
        in_tokens: state.in_tokens + ni,
        out_tokens: state.out_tokens + no,
        last_context: ni + no,
        last_estimate: replace_latest(state.last_estimate, event.estimated_cost_usd)
    }

    {:noreply, state}
  end

  def handle_info({:harness_event, %Event.Done{} = event}, %State{} = state) do
    # Fold the terminal frame's billed cost (still emitting telemetry) into the
    # accumulator, then flush the whole turn in ONE write with the final status.
    delta =
      Orchestrators.emit_cost_recorded(state.orchestrator_id, event.cost_usd, state.project_id)

    state = %State{state | acc_cost: Decimal.add(state.acc_cost, delta)}
    _ = flush(state, if(event.ok, do: :idle, else: :error))
    _ = auto_record_progress(state, if(event.ok, do: :ok, else: not_ok_outcome(state)))
    {:stop, :normal, %State{state | flushed?: true}}
  end

  def handle_info({:harness_event, %Event.Error{}}, %State{} = state) do
    _ = flush(state, :error)
    _ = auto_record_progress(state, not_ok_outcome(state))
    {:stop, :normal, %State{state | flushed?: true}}
  end

  # A transient provider condition (rate limit / overload; issue rate-limit-stall) surfaced
  # by the harness adapter. Flag the turn so its not-ok terminal auto-records `:transient`,
  # keeping throttling ladder-neutral in the drive loop rather than counting it as a stall.
  def handle_info({:harness_event, %Event.Status{kind: :rate_limit}}, %State{} = state) do
    {:noreply, %State{state | transient_error?: true}}
  end

  # Hard turn-deadline fired (self-healing Phase 4): a turn already flushed is a no-op; an
  # in-flight turn is force-flushed to :error and its harness session stopped so it can't keep
  # running. The Driver re-engages the orchestrator (now :error, still drivable) on its next tick.
  def handle_info(:turn_deadline, %State{flushed?: true} = state), do: {:noreply, state}

  def handle_info(:turn_deadline, %State{} = state) do
    _ = Session.Supervisor.stop_session(state.agent_id)
    _ = flush(state, :error)
    _ = auto_record_progress(state, not_ok_outcome(state))

    Logger.warning(
      "orchestrator turn #{state.agent_id} hit the hard turn deadline; force-flushed"
    )

    {:stop, :normal, %State{state | flushed?: true}}
  end

  def handle_info({:harness_event, _event}, %State{} = state), do: {:noreply, state}
  def handle_info(_msg, %State{} = state), do: {:noreply, state}

  @impl true
  # Pre-launch crash safety: a turn that dies while still inside `handle_continue(:launch)`
  # carries init's `{state, orchestrator}` continue payload as its GenServer state, which the
  # bare-`%State{}` clauses below don't match (a FunctionClauseError during sandbox-teardown
  # races). Unwrap to the State so the flush/reconcile still runs.
  def terminate(reason, {%State{} = state, _orchestrator}), do: terminate(reason, state)

  def terminate(_reason, %State{flushed?: true}), do: :ok

  def terminate(_reason, %State{} = state) do
    # Crash safety (issue hot-path-writes Part B): a turn that dies before a terminal
    # event still persists its accumulated cost — matching the old incremental-write
    # durability. Best-effort + guarded so a flush failure never masks the original
    # crash reason.
    #
    # Status reconcile (issue orchestrator-stuck): a turn that reaches terminate/2
    # WITHOUT having flushed a terminal `:idle|:error` (the `flushed?: true` clause
    # above short-circuits those) has, by definition, no live turn left — the harness
    # session died silently or this Server was stopped. Reconcile to `:idle` so the
    # `orchestrators` row never wedges at `:running`; the orchestrator stays usable and
    # can auto-resume again. Cost/usage still flush exactly as before.
    _ = flush(state, :idle)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  # --- helpers ---

  # One coalesced row write for the whole turn: accumulated cost/usage + replace-latest
  # context/estimate + final status (nil status ⇒ leave as-is). Replaces the three
  # separate get+update pairs that ran per Usage frame.
  @spec flush(State.t(), :idle | :error | nil) :: :ok
  defp flush(%State{} = state, status) do
    _ =
      Orchestrators.flush_turn(state.orchestrator_id, %{
        cost: state.acc_cost,
        input: state.in_tokens,
        output: state.out_tokens,
        context: state.last_context,
        estimate: state.last_estimate,
        status: status
      })

    :ok
  end

  # Backstop the Progress Ledger (self-healing Phase 3): if the brain recorded no progress
  # entry since this turn started, write a minimal one so the ledger never gaps. A no-op when
  # no goal is set, or when the brain already recorded explicitly. Best-effort.
  @spec auto_record_progress(State.t(), :ok | :error | :transient) :: :ok
  defp auto_record_progress(%State{turn_started_at: nil}, _outcome), do: :ok

  defp auto_record_progress(%State{} = state, outcome) do
    Ledgers.auto_record_progress(
      state.orchestrator_id,
      state.agent_id,
      outcome,
      state.turn_started_at
    )
  end

  # A not-ok terminal is `:transient` when this turn saw a transient provider condition
  # (rate limit / overload), else `:error` (issue rate-limit-stall).
  @spec not_ok_outcome(State.t()) :: :error | :transient
  defp not_ok_outcome(%State{transient_error?: true}), do: :transient
  defp not_ok_outcome(%State{}), do: :error

  # Mirror Orchestrators.add_usage's nil/negative-safe token clamp so coalescing keeps
  # identical cumulative/context semantics.
  @spec non_neg(integer() | nil) :: non_neg_integer()
  defp non_neg(value) when is_integer(value) and value > 0, do: value
  defp non_neg(_value), do: 0

  # set_estimated_cost was replace-latest with a nil no-op: a nil frame leaves the prior
  # estimate in place; a present value supersedes it.
  @spec replace_latest(term(), term()) :: term()
  defp replace_latest(prior, nil), do: prior
  defp replace_latest(_prior, value), do: value

  @spec tool_ctx(RepoBuilder.Orchestrator.Orchestrator.t(), String.t()) ::
          RepoBuilder.Harness.Orchestrating.tool_ctx()
  defp tool_ctx(orchestrator, token) do
    %{
      orchestrator_id: orchestrator.id,
      mcp_base_url: mcp_base_url(),
      token: token,
      resume_session_id: orchestrator.session_id,
      system_prompt: orchestrator.system_prompt || SystemPrompt.build(orchestrator),
      system_prompt_mode: orchestrator.system_prompt_mode,
      # Placeholder: the session runtime overwrites this with the real session cwd
      # (where `.mcp.json` etc. get written) before calling `orchestrator_spawn/2`.
      cwd: ""
    }
  end

  @spec mcp_base_url() :: String.t()
  defp mcp_base_url do
    Application.get_env(:repo_builder, :orchestrator, [])[:mcp_base_url] ||
      "http://127.0.0.1:4000"
  end

  # Byte-idle watchdog window (ms) for orchestrator turns — shorter than the worker-grade
  # `:session` `idle_ms` (5 min) because an interactive turn byte-silent this long is
  # stalled. Threaded into the session start opts so the existing idle-timeout recovery
  # fires promptly and visibly instead of hanging until an operator intervenes.
  @spec orchestrator_idle_ms() :: pos_integer()
  defp orchestrator_idle_ms do
    Application.get_env(:repo_builder, :orchestrator, [])[:turn_idle_ms] || 120_000
  end

  # Hard per-turn ceiling (self-healing Phase 4). Armed ONCE at turn start (not per frame);
  # `nil`/`:infinity` config disables it (no timer). Default 180 s — longer than the byte-idle
  # `turn_idle_ms` (120 s), so it only catches a turn that stays byte-active but never finishes.
  @spec arm_turn_deadline() :: reference() | nil
  defp arm_turn_deadline do
    case Application.get_env(:repo_builder, :orchestrator, [])[:turn_deadline_ms] || 180_000 do
      ms when is_integer(ms) -> Process.send_after(self(), :turn_deadline, ms)
      _disabled -> nil
    end
  end

  @spec adapter_for(String.t()) :: module()
  defp adapter_for(harness) do
    case HarnessRegistry.fetch(harness) do
      {:ok, module} -> module
      {:error, :unknown_harness} -> __MODULE__
    end
  end
end
