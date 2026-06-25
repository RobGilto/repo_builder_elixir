defmodule RepoBuilder.Session.Server do
  @moduledoc """
  One supervised GenServer per LIVE harness session (BUILD_PROMPT.md §6).

  Owns exactly one harness CLI child process (spawned via erlexec) and is the
  single writer of that session's canonical events. Responsibilities, in order:

    1. resolve adapter + secrets, provision an isolated cwd, spawn via the adapter's
       `command/1`, write the durable os_pid ledger row BEFORE consuming output;
    2. buffer partial NDJSON (split on "\\n" / 0x0A ONLY, carry the trailing partial,
       multibyte-safe), enforcing a hard per-line byte cap (overflow ⇒ Error + stop);
    3. decode + normalize each complete line — a bad line is `:skip`/`{:error, _}`,
       NEVER a crash;
    4. broadcast each canonical event on `"agent:<id>:events"` (M2 broadcasts the
       FULL event; M3 adds redact-then-persist);
    5. arm/reset an idle timer; on idle fire kill the child and emit
       `%Error{reason: :idle_timeout}`; on a clean process exit with output and no
       terminal event, synthesize `%Done{reason: :clean_exit}` (zai/GLM);
    6. idempotent `terminate/2`: stop the child (SIGTERM→SIGKILL), delete the ledger
       row, clean the workspace, release the admission slot.

  Live children are `:temporary` — a finished/crashed run is NOT auto-restarted.
  """
  use GenServer, restart: :temporary

  require Logger

  alias RepoBuilder.{Agents, Logs}
  alias RepoBuilder.Harness.Event
  alias RepoBuilder.Harness.McpTools
  alias RepoBuilder.Harness.Registry, as: HarnessRegistry
  alias RepoBuilder.OsPidLedger
  alias RepoBuilder.Projects.Worktree
  alias RepoBuilder.Session.Admission

  @pubsub RepoBuilder.PubSub

  # Bounded tail of the child's stderr, kept so a non-zero exit can surface the
  # provider's real diagnostic (e.g. pi's `Failed to load extension …`) instead of
  # a bare `provider exited` — see issue-fix-pi-orchestrator-extension-load.
  @stderr_tail_bytes 2_048

  defmodule State do
    @moduledoc false
    use TypedStruct

    typedstruct enforce: true do
      field :agent_id, String.t()
      field :agent_db_id, Ecto.UUID.t(), enforce: false
      field :session_id, String.t()
      field :harness, atom()
      field :adapter, module()
      field :prompt, String.t()
      field :model, String.t(), enforce: false
      field :provider, String.t(), enforce: false
      field :config, map(), default: %{}
      field :secrets, map(), default: %{}
      field :price_table, map(), default: %{}
      # Operator-chosen reasoning effort (issue-reasoning-effort). :default ⇒ the
      # adapter emits no effort/thinking flag (worker sessions also default here).
      field :reasoning_effort, atom(), default: :default
      field :session_ctx, term(), enforce: false
      field :exec_pid, pid(), enforce: false
      field :os_pid, non_neg_integer(), enforce: false
      field :cwd, Path.t()
      # false when `cwd` is an operator-provided working directory (the user's
      # project): it is NEVER created-then-deleted by this session. true (default)
      # for the ephemeral per-session scratch workspace, which is cleaned on exit.
      field :managed_workspace?, boolean(), default: true
      field :marker, String.t()
      field :buf, binary(), default: ""
      field :idle_ref, reference(), enforce: false
      field :idle_ms, non_neg_integer()
      field :max_line_bytes, pos_integer()
      field :saw_output?, boolean(), default: false
      field :saw_terminal?, boolean(), default: false
      # Latest-turn context-window occupancy (issue graceful-agent-handover): the prompt
      # side of the most recent `%Event.Usage{}` (input + cache_read + cache_creation,
      # mirroring `Logs.context_size/1`). Carried into the worker-terminal broadcast so the
      # surviving Queue can decide the handover/wind-down without re-querying.
      field :context_tokens, non_neg_integer(), default: 0
      # Bounded tail of child stderr (process diagnostics, not stdout output);
      # folded into a synthesized terminal Error so the real cause is never lost.
      field :stderr_tail, binary(), default: ""
      # When set (issue-c), this session is an ORCHESTRATOR: the adapter's optional
      # `orchestrator_spawn/2` merges extra argv/env onto the base command. nil for
      # every worker session (the worker spawn path is untouched).
      field :orchestrator_ctx, map(), enforce: false
      # When set (issue-d), canonical events also persist to `agent_logs` keyed by
      # this orchestrator id (parallel to the worker `agent_db_id` gate). nil for
      # every worker session.
      field :orchestrator_db_id, Ecto.UUID.t(), enforce: false
      # Ephemeral contract (issue-explain): when false, `dispatch/2` suppresses the
      # global console feed + swimlane broadcasts so the run stays private to its
      # per-agent topic (the only channel the ephemeral Explain runner observes).
      # Defaults true — workers and the orchestrator keep their current behavior.
      field :broadcast_feed?, boolean(), default: true
      # Set true when stderr contains known blocking-command patterns (e.g. "phx.server");
      # used to gate SIGTERM (exit 143) as a clean exit vs error (issue-adw-sigterm).
      field :blocking_command?, boolean(), default: false
      # Set (issue agentic-layer adaptor, Phase 4) when this session runs in a git
      # worktree provisioned for project `isolation_mode == :worktree`. Carries
      # `%{path, branch, repo}`; nil for every direct/managed session. Drives the
      # git-aware cleanup (`git worktree remove`, not `rm -rf`).
      field :worktree, map(), enforce: false
    end
  end

  # --- client API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via(opts[:agent_id]))
  end

  @doc "Send data to the child's stdin (deliberately not `send/2`)."
  @spec send_stdin(String.t(), iodata()) :: :ok
  def send_stdin(agent_id, data), do: GenServer.cast(via(agent_id), {:stdin, data})

  @doc "Interrupt the live child (SIGTERM→SIGKILL via erlexec)."
  @spec interrupt(String.t()) :: :ok
  def interrupt(agent_id), do: GenServer.cast(via(agent_id), :interrupt)

  @spec via(String.t()) :: {:via, Registry, {module(), String.t()}}
  defp via(agent_id), do: {:via, Registry, {RepoBuilder.SessionRegistry, agent_id}}

  # --- server callbacks ---

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    harness = to_string(opts[:harness])

    case HarnessRegistry.fetch_config(harness) do
      {:ok, config} -> {:ok, build_state(opts, harness, config), {:continue, :spawn}}
      {:error, :unknown_harness} -> {:stop, {:unknown_harness, harness}}
    end
  end

  @spec build_state(keyword(), String.t(), map()) :: State.t()
  defp build_state(opts, harness, config) do
    cfg = Application.get_env(:repo_builder, :session, [])
    session_id = opts[:session_id] || generate_token()
    {base_cwd, base_managed?} = resolve_workspace(opts, cfg, session_id)
    {cwd, managed?, worktree} = maybe_worktree(opts, base_cwd, base_managed?, session_id)

    %State{
      agent_id: to_string(opts[:agent_id]),
      agent_db_id: opts[:agent_db_id],
      session_id: session_id,
      harness: String.to_atom(harness),
      adapter: Map.fetch!(config, :module),
      prompt: opts[:prompt] || "",
      model: opts[:model] || Map.get(config, :default_model),
      provider: opts[:provider],
      config: opts[:config] || %{},
      secrets: resolve_secrets(opts, harness),
      reasoning_effort: opts[:reasoning_effort] || :default,
      price_table: resolve_price_table(harness, config),
      cwd: cwd,
      managed_workspace?: managed?,
      worktree: worktree,
      marker: generate_token(),
      idle_ms: cfg_value(opts, cfg, :idle_ms, 300_000),
      max_line_bytes: cfg_value(opts, cfg, :max_line_bytes, 1_048_576),
      orchestrator_ctx: opts[:orchestrator_ctx],
      orchestrator_db_id: opts[:orchestrator_db_id],
      broadcast_feed?: opts[:broadcast_feed?] != false
    }
  end

  defp cfg_value(opts, cfg, key, default), do: opts[key] || cfg[key] || default

  # The price table that derives `cost_usd` for unpriced harnesses (pi): the config
  # default, with the operator-editable `model_prices` catalog merged OVER it so edits
  # in the Cost Center tab affect future cost without a redeploy (issue-cost-center). A
  # pure read; any error falls back to the config table so a session start never crashes.
  @spec resolve_price_table(String.t(), map()) :: RepoBuilder.Harness.Pricing.price_table()
  defp resolve_price_table(harness, config) do
    config_table = Map.get(config, :price_table, %{})

    catalog_table =
      try do
        RepoBuilder.CostCenter.price_table_for(harness)
      rescue
        _error -> %{}
      catch
        _kind, _reason -> %{}
      end

    Map.merge(config_table, catalog_table)
  end

  # Merge runtime-configured per-harness secrets (§6) with the per-tool secrets the
  # worker's config actually enables (issue firecrawl-grant), then any explicit
  # per-session overrides (which win last); drop unset (nil) env values so they never
  # reach the child env. Public (`@doc false`) as the hermetic test seam — it is a
  # pure read with no process state.
  @doc false
  @spec resolve_secrets(keyword(), String.t()) :: map()
  def resolve_secrets(opts, harness) do
    configured =
      :repo_builder
      |> Application.get_env(:harness_secrets, %{})
      |> Map.get(harness, %{})
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    configured
    |> Map.merge(tool_secrets(opts[:config] || %{}))
    |> Map.merge(opts[:secrets] || %{})
  end

  # Fold in the env keys for the research tools enabled in this worker's config
  # (`config["tools"]`), pulling each value from the `:tool_secrets` runtime block.
  # Only enabled tools contribute, and unset (nil) values are dropped — so the key
  # reaches firecrawl-granted workers and no others.
  @spec tool_secrets(map()) :: %{optional(String.t()) => String.t()}
  defp tool_secrets(config) when is_map(config) do
    catalog = Application.get_env(:repo_builder, :tool_secrets, %{})
    enabled = McpTools.enabled(config["tools"])

    for {tool, env_key} <- McpTools.secret_keys(enabled),
        value = get_in(catalog, [tool, env_key]),
        not is_nil(value),
        into: %{},
        do: {env_key, value}
  end

  defp tool_secrets(_config), do: %{}

  @impl true
  def handle_continue(:spawn, %State{} = state) do
    File.mkdir_p!(state.cwd)

    start_opts = %{
      prompt: state.prompt,
      model: state.model,
      provider: state.provider,
      cwd: state.cwd,
      sink: self(),
      config: state.config,
      secrets: state.secrets,
      reasoning_effort: state.reasoning_effort,
      price_table: state.price_table
    }

    {exe, args, env, ctx} = state.adapter.command(start_opts)
    {args, env} = maybe_orchestrator_spawn(state, start_opts, args, env)

    case resolve_exe(exe) do
      nil ->
        state = dispatch(error_event(state, "executable not found: #{exe}", :spawn_failed), state)
        {:stop, :normal, state}

      abs_exe ->
        spawn_child(abs_exe, args, env, ctx, state)
    end
  rescue
    # Turn a silent crash in the spawn prelude (File.mkdir_p!, adapter.command/1,
    # maybe_orchestrator_spawn/4) into a loud, persisted terminal Error — mirroring the
    # "executable not found" / "spawn failed" branches above. Without this the GenServer
    # would die with no event dispatched, leaving a worker stuck `:running` (issue-log-16249).
    e ->
      message = "spawn preparation failed: #{Exception.message(e)}"
      state = dispatch(error_event(state, message, :spawn_failed), state)
      {:stop, :normal, state}
  catch
    kind, reason ->
      message = "spawn preparation failed: #{inspect({kind, reason})}"
      state = dispatch(error_event(state, message, :spawn_failed), state)
      {:stop, :normal, state}
  end

  # When this is an orchestrator session AND the adapter implements the optional
  # `Orchestrating` behaviour, merge its extra argv/env onto the base command. The
  # worker path (orchestrator_ctx == nil) returns the base args/env unchanged.
  @spec maybe_orchestrator_spawn(State.t(), map(), [String.t()], [{String.t(), String.t()}]) ::
          {[String.t()], [{String.t(), String.t()}]}
  defp maybe_orchestrator_spawn(%State{orchestrator_ctx: nil}, _start_opts, args, env),
    do: {args, env}

  defp maybe_orchestrator_spawn(
         %State{orchestrator_ctx: ctx, adapter: adapter} = state,
         opts,
         args,
         env
       ) do
    if function_exported?(adapter, :orchestrator_spawn, 2) do
      # The runtime owns the real session cwd (where per-session config files like
      # `.mcp.json` are written); fill it in before the adapter binds tools.
      {extra_args, extra_env} = adapter.orchestrator_spawn(opts, %{ctx | cwd: state.cwd})
      {args ++ extra_args, env ++ extra_env}
    else
      # Orchestrator on a harness with no external binding (e.g. Fake): tool calls
      # are dispatched in-process by Orchestrator.Server. No argv/env changes.
      {args, env}
    end
  end

  @spec spawn_child(String.t(), [String.t()], [{String.t(), String.t()}], term(), State.t()) ::
          {:noreply, State.t()} | {:stop, :normal, State.t()}
  defp spawn_child(abs_exe, args, env, ctx, %State{} = state) do
    # erlexec's argv-list form does NOT search PATH, so the runtime resolves the
    # executable to an absolute path before spawning (secrets stay in env, never argv).
    cmd = Enum.map([abs_exe | args], &String.to_charlist/1)

    run_opts = [
      :stdin,
      :stdout,
      :stderr,
      :monitor,
      {:group, 0},
      :kill_group,
      {:kill_timeout, 5},
      {:env, build_env(env, state.marker)},
      {:cd, String.to_charlist(state.cwd)}
    ]

    case :exec.run(cmd, run_opts) do
      {:ok, exec_pid, os_pid} ->
        ledger = %{
          agent_id: state.agent_db_id,
          session_id: state.session_id,
          os_pid: os_pid,
          marker: state.marker,
          argv_hash: argv_hash(cmd),
          node: to_string(node()),
          started_at: DateTime.utc_now()
        }

        case OsPidLedger.insert(ledger) do
          {:ok, _row} ->
            # The prompt is delivered via argv (every harness), never over stdin, so
            # close the child's stdin immediately. Without EOF, a CLI that drains a
            # non-TTY stdin before finishing (e.g. pi `--mode json`) blocks forever on
            # the open erlexec pipe and never emits a terminal event (§6 headless rule).
            _ = :exec.send(os_pid, :eof)
            state = %{state | exec_pid: exec_pid, os_pid: os_pid, session_ctx: ctx}
            {:noreply, arm_idle(state)}

          {:error, _changeset} ->
            _ = :exec.stop(os_pid)

            state =
              dispatch(error_event(state, "os_pid ledger insert failed", :spawn_failed), state)

            {:stop, :normal, state}
        end

      {:error, reason} ->
        state =
          dispatch(error_event(state, "spawn failed: #{inspect(reason)}", :spawn_failed), state)

        {:stop, :normal, state}
    end
  end

  @impl true
  def handle_cast({:stdin, data}, %State{os_pid: os_pid} = state) when is_integer(os_pid) do
    _ = :exec.send(os_pid, data)
    {:noreply, state}
  end

  def handle_cast({:stdin, _data}, state), do: {:noreply, state}

  def handle_cast(:interrupt, %State{os_pid: os_pid} = state) when is_integer(os_pid) do
    _ = :exec.stop(os_pid)
    {:noreply, state}
  end

  def handle_cast(:interrupt, state), do: {:noreply, state}

  @impl true
  def handle_info({:stdout, os_pid, chunk}, %State{os_pid: os_pid} = state) do
    state = reset_idle(state)
    bin = state.buf <> chunk

    if no_newline?(bin) and byte_size(bin) > state.max_line_bytes do
      Logger.warning(
        "session #{state.session_id}: stdout overflow — single line exceeded " <>
          "#{state.max_line_bytes} bytes; killing child"
      )

      message = "stdout overflow (line exceeded #{state.max_line_bytes} bytes)"
      state = dispatch(error_event(state, message, :provider_error), state)
      _ = :exec.stop(os_pid)
      {:stop, :normal, %{state | buf: ""}}
    else
      {lines, rest} = split_lines(bin)
      state = Enum.reduce(lines, state, &process_line/2)
      {:noreply, %{state | buf: rest}}
    end
  end

  def handle_info({:stderr, os_pid, chunk}, %State{os_pid: os_pid} = state) do
    # stderr is process diagnostics, NOT stream output: keep it out of stdout line
    # framing and the idle timer, but retain a bounded tail for the terminal error.
    tail = append_stderr(state.stderr_tail, chunk)
    blocking? = state.blocking_command? or blocking_command_detected?(tail)
    {:noreply, %{state | stderr_tail: tail, blocking_command?: blocking?}}
  end

  def handle_info({:stderr, _os_pid, _chunk}, state), do: {:noreply, state}

  def handle_info(:idle_timeout, %State{os_pid: os_pid, blocking_command?: blocking?} = state) do
    _ = if is_integer(os_pid), do: :exec.stop(os_pid)

    # If this is a blocking command, the :DOWN handler will synthesize a clean
    # Done{partial?: true} when it sees the SIGTERM exit. Otherwise, idle timeout
    # on a normal command is a genuine error (hung without progress).
    if blocking? do
      {:noreply, state}
    else
      state =
        dispatch(
          %Event.Error{
            harness: state.harness,
            message: "idle timeout",
            reason: :idle_timeout,
            retryable: true
          },
          state
        )

      {:stop, :normal, state}
    end
  end

  def handle_info({:DOWN, os_pid, :process, _pid, reason}, %State{os_pid: os_pid} = state) do
    state =
      if state.buf != "" do
        line = state.buf
        process_line(line, %{state | buf: ""})
      else
        state
      end

    state = maybe_synthesize_terminal(reason, state)
    {:stop, :normal, %{state | buf: ""}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(reason, %State{} = state) do
    reconcile_status_quietly(reason, state)
    _ = if is_integer(state.os_pid), do: :exec.stop(state.os_pid)
    delete_ledger_quietly(state.marker)
    cleanup_workspace(state)
    Admission.release()
    :ok
  end

  # Durable backstop (issue-log-16249): a WORKER Session.Server that exits WITHOUT ever
  # dispatching a terminal event leaves `agents.status` stuck `:running` forever — the
  # optimistic `command_agent` :running write (orchestrator/tools.ex) has no terminal to
  # undo it, and nothing else monitors the worker's status. Synthesize and dispatch a
  # terminal Error here so the normal machinery (a) persists a terminal `agent_logs` row,
  # (b) reconciles status to :error via Logs.Writer.update_status_quietly/2, and (c) fires
  # the worker-terminal broadcast the orchestrator Queue's force_retire/3 recovery awaits.
  # dispatch/2 from terminate/2 is safe: the PubSub broadcast and the Logs.Writer cast
  # target other processes that outlive this one. Fail-soft (mirrors delete_ledger_quietly/1)
  # so a DB/PubSub hiccup during shutdown never turns terminate/2 into a second crash.
  # KNOWN GAP (out of scope): a hard Process.exit(pid, :kill) / brutal supervisor shutdown
  # bypasses terminate/2 entirely, so it cannot reconcile that path — a boot/periodic sweep
  # (sibling to OrphanReaper) would be needed to close it.
  @spec reconcile_status_quietly(term(), State.t()) :: :ok
  defp reconcile_status_quietly(reason, %State{agent_db_id: id, saw_terminal?: false} = state)
       when is_binary(id) do
    message = "session ended without a terminal event: #{inspect(reason)}"
    _ = dispatch(error_event(state, message, :spawn_failed), state)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp reconcile_status_quietly(_reason, _state), do: :ok

  # The ledger delete must not crash terminate/2 if the DB is momentarily
  # unavailable during shutdown — any undeleted row is reclaimed by the boot-time
  # OrphanReaper (§6). (Also keeps test teardown quiet once the sandbox owner exits.)
  @spec delete_ledger_quietly(String.t()) :: :ok
  defp delete_ledger_quietly(marker) do
    OsPidLedger.delete_by_marker(marker)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  # --- line framing / dispatch ---

  @spec process_line(binary(), State.t()) :: State.t()
  defp process_line("", state), do: state

  defp process_line(line, %State{adapter: adapter, session_ctx: ctx} = state) do
    line = String.trim_trailing(line, "\r")

    with {:ok, raw} <- Jason.decode(line),
         {:ok, events} <- adapter.normalize(raw, ctx) do
      Enum.reduce(events, state, &dispatch/2)
    else
      :skip ->
        state

      {:error, _reason} ->
        Logger.debug("session #{state.session_id}: unhandled line: #{inspect(line)}")
        state
    end
  end

  @spec dispatch(Event.t(), State.t()) :: State.t()
  defp dispatch(event, %State{agent_id: agent_id} = state) do
    # The per-agent topic broadcast is UNCONDITIONAL and FIRST: it serves the
    # timing-sensitive subscribers (Orchestrator.Server + the focused agent view) and
    # the ephemeral run (issue-explain, `broadcast_feed?: false`) observing its own
    # output — none of which need the DB. It must never wait on a write.
    _ = Phoenix.PubSub.broadcast(@pubsub, "agent:#{agent_id}:events", {:harness_event, event})

    # Persistence (REDACTED row via Logs.persist_event) + the `log_no`-bearing global
    # feed broadcast move OFF this hot path to a per-row async writer (issue
    # hot-path-writes Part A): a slow/contended `agent_logs` insert no longer
    # head-of-line-blocks this serial session's next event. Same durable row → same
    # writer partition → FIFO `log_no`; different rows persist in parallel. The
    # broadcast_feed? gate is applied inside the writer.
    _ = Logs.Writer.record(record_for(event, state))

    # Lifecycle-only swimlane updates stay synchronous here (start/terminal, rare).
    if state.broadcast_feed? do
      _ = maybe_broadcast_lane(event, state)
    end

    _ = maybe_emit_worker_terminal(event, state)

    %{state | saw_output?: true, saw_terminal?: state.saw_terminal? or terminal?(event)}
    |> track_context(event)
  end

  # Fold a usage event's prompt-side occupancy into State so the worker-terminal broadcast
  # carries the latest occupancy (issue graceful-agent-handover). Non-usage events pass
  # through unchanged; a terminal event (Done/Error) is never a usage event, so the value
  # observed at the terminal is the most recent usage row's occupancy.
  @spec track_context(State.t(), Event.t()) :: State.t()
  defp track_context(state, %Event.Usage{} = usage),
    do: %{state | context_tokens: usage_context_tokens(usage)}

  defp track_context(state, _event), do: state

  # Prompt occupancy = input + cache_read + cache_creation (nil-safe), excluding output —
  # the single source-of-truth math shared with `Logs.context_size/1`.
  @spec usage_context_tokens(Event.Usage.t()) :: non_neg_integer()
  defp usage_context_tokens(%Event.Usage{} = u),
    do: nz(u.input_tokens) + nz(u.cache_read) + nz(u.cache_creation)

  @spec nz(integer() | nil) :: non_neg_integer()
  defp nz(n) when is_integer(n) and n >= 0, do: n
  defp nz(_n), do: 0

  # Build the deferred-persistence Record cast to the per-row Logs.Writer. The durable
  # target is an agent row (`agent_db_id`) OR an orchestrator row (`orchestrator_db_id`)
  # — exactly one is present (app-enforced); a session with neither (ephemeral) persists
  # nothing but may still broadcast to the global feed.
  @spec record_for(Event.t(), State.t()) :: Logs.Writer.Record.t()
  defp record_for(event, %State{} = state) do
    %Logs.Writer.Record{
      event: event,
      agent_id: state.agent_id,
      broadcast_feed?: state.broadcast_feed?,
      persist: persist_target(state)
    }
  end

  @spec persist_target(State.t()) :: {:agent | :orchestrator, map()} | nil
  defp persist_target(%State{agent_db_id: id} = state) when is_binary(id) do
    {:agent,
     %{agent_id: id, session_id: state.session_id, provider: state.provider, model: state.model}}
  end

  defp persist_target(%State{orchestrator_db_id: id} = state) when is_binary(id) do
    {:orchestrator,
     %{
       orchestrator_id: id,
       session_id: state.session_id,
       provider: state.provider,
       model: state.model
     }}
  end

  defp persist_target(_state), do: nil

  # Holding pattern (issue message-queue): when a WORKER session (one tied to a durable
  # agent row) reaches a terminal event, signal the owning orchestrator's Queue on
  # `orchestrator:<id>:workers` so it can auto-resume if idle. Scoped to workers that
  # carry an `orchestrator_id`; quiet (a DB blip never breaks the dispatch path).
  @spec maybe_emit_worker_terminal(Event.t(), State.t()) :: :ok
  defp maybe_emit_worker_terminal(event, %State{agent_db_id: agent_id} = state)
       when is_binary(agent_id) do
    if terminal?(event) do
      case Agents.get_agent(agent_id) do
        %{orchestrator_id: orchestrator_id, name: name} when is_binary(orchestrator_id) ->
          ok? = match?(%Event.Done{ok: true}, event)

          RepoBuilder.Dashboard.broadcast_worker_terminal(orchestrator_id, %{
            worker_id: agent_id,
            name: name,
            ok?: ok?,
            # Enriched (issue graceful-agent-handover): the latest-turn occupancy and the
            # terminal message text, so the Queue can detect a wind-down / parse a handover
            # signal without the terminating session starting a new turn.
            context_tokens: state.context_tokens,
            final_text: terminal_text(event)
          })

        _ ->
          :ok
      end
    end

    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp maybe_emit_worker_terminal(_event, _state), do: :ok

  # Publish a swimlane update on lifecycle transitions only (start/terminal), §9.
  @spec maybe_broadcast_lane(Event.t(), State.t()) :: :ok
  defp maybe_broadcast_lane(%Event.SessionStarted{session_id: id}, state),
    do: lane(state, :running, id)

  defp maybe_broadcast_lane(%Event.Done{ok: true}, state),
    do: lane(state, :succeeded, state.session_id)

  defp maybe_broadcast_lane(%Event.Done{ok: false}, state),
    do: lane(state, :failed, state.session_id)

  defp maybe_broadcast_lane(%Event.Error{}, state), do: lane(state, :failed, state.session_id)
  defp maybe_broadcast_lane(_event, _state), do: :ok

  @spec lane(State.t(), :running | :succeeded | :failed, String.t()) :: :ok
  defp lane(state, status, label) do
    RepoBuilder.Dashboard.broadcast_lane(%{
      id: "agent:#{state.agent_id}",
      kind: :agent,
      label: to_string(label),
      status: status,
      harness: to_string(state.harness)
    })
  end

  @spec terminal?(Event.t()) :: boolean()
  defp terminal?(%Event.Done{}), do: true
  defp terminal?(%Event.Error{}), do: true
  defp terminal?(_event), do: false

  # The worker's terminal message text (issue graceful-agent-handover): the `Done.final_text`
  # the handover signal would ride in. An Error terminal carries no handover signal → nil.
  @spec terminal_text(Event.t()) :: String.t() | nil
  defp terminal_text(%Event.Done{final_text: text}) when is_binary(text), do: text
  defp terminal_text(_event), do: nil

  @spec maybe_synthesize_terminal(term(), State.t()) :: State.t()
  defp maybe_synthesize_terminal(reason, %State{saw_terminal?: true} = state) do
    _ = reason
    state
  end

  defp maybe_synthesize_terminal(reason, %State{stderr_tail: tail} = state) do
    if clean_exit?(reason, state) do
      # SIGTERM on a blocking command is a clean partial success
      event =
        if sigterm?(reason) and state.blocking_command? do
          %Event.Done{
            harness: state.harness,
            ok: true,
            partial?: true,
            reason: :sigterm_on_blocking_step
          }
        else
          %Event.Done{harness: state.harness, ok: true, reason: :clean_exit}
        end

      dispatch(event, state)
    else
      # Fold the captured stderr tail into the message so the provider's real
      # diagnostic (e.g. pi's `Failed to load extension …`) is visible in the UI
      # and persisted payload instead of a bare `provider exited`.
      # `replace_invalid/1` guards a multibyte char split by the byte-bounded tail.
      base = "provider exited: #{inspect(reason)}"

      message =
        case tail |> String.replace_invalid() |> String.trim() do
          "" -> base
          trimmed -> base <> "\nstderr: " <> trimmed
        end

      dispatch(error_event(state, message, :provider_error), state)
    end
  end

  @doc false
  @spec clean_exit?(term(), State.t()) :: boolean()
  def clean_exit?(:normal, _state), do: true

  def clean_exit?({:exit_status, status}, state) do
    case :exec.status(status) do
      {:status, 0} -> true
      {:status, 143} -> state.blocking_command?
      _ -> false
    end
  end

  def clean_exit?(_reason, _state), do: false

  @doc false
  @spec sigterm?(term()) :: boolean()
  def sigterm?({:exit_status, status}) do
    case :exec.status(status) do
      {:status, 143} -> true
      _ -> false
    end
  end

  def sigterm?(_reason), do: false

  @doc false
  @spec blocking_command_detected?(binary()) :: boolean()
  def blocking_command_detected?(stderr) do
    String.contains?(stderr, "phx.server")
  end

  # --- idle timer ---

  @spec arm_idle(State.t()) :: State.t()
  defp arm_idle(%State{idle_ms: ms} = state) do
    %{state | idle_ref: Process.send_after(self(), :idle_timeout, ms)}
  end

  @spec reset_idle(State.t()) :: State.t()
  defp reset_idle(%State{idle_ref: ref} = state) do
    _ = if ref, do: Process.cancel_timer(ref)
    arm_idle(state)
  end

  # --- helpers ---

  @spec split_lines(binary()) :: {[binary()], binary()}
  defp split_lines(bin) do
    parts = String.split(bin, "\n")
    {complete, [partial]} = Enum.split(parts, length(parts) - 1)
    {complete, partial}
  end

  @spec no_newline?(binary()) :: boolean()
  defp no_newline?(bin), do: not String.contains?(bin, "\n")

  @spec error_event(State.t(), String.t(), atom()) :: Event.Error.t()
  defp error_event(%State{harness: harness}, message, reason) do
    %Event.Error{harness: harness, message: message, reason: reason}
  end

  @spec append_stderr(binary(), binary()) :: binary()
  defp append_stderr(tail, chunk) do
    combined = tail <> chunk
    size = byte_size(combined)

    if size > @stderr_tail_bytes do
      binary_part(combined, size - @stderr_tail_bytes, @stderr_tail_bytes)
    else
      combined
    end
  end

  @spec resolve_exe(String.t()) :: String.t() | nil
  defp resolve_exe(exe) do
    if String.contains?(exe, "/"), do: exe, else: System.find_executable(exe)
  end

  # erlexec's {:env, ...} REPLACES the child's environment (it does not inherit), so
  # we must carry the parent OS env (PATH/HOME/…) forward, overlay the harness
  # secrets, and inject the orphan-reaper marker.
  #
  # EMPTY values are dropped: erlexec's C port cannot decode an empty-string env value
  # (it encodes as NIL, desyncing the port's sequential parse and rejecting a LATER
  # entry with "invalid env argument #N" — a whole-spawn failure). An empty value is
  # equivalent to "unset" for a child CLI, so dropping it is safe. (Real example: a
  # shell exporting `ANTHROPIC_API_KEY=` broke EVERY session spawn.)
  @spec build_env([{String.t(), String.t()}], String.t()) :: [{charlist(), charlist()}]
  defp build_env(env, marker) do
    System.get_env()
    |> Map.merge(Map.new(env))
    |> Map.put("REPO_BUILDER_SESSION_MARKER", marker)
    |> Enum.reject(fn {_k, v} -> v == "" end)
    |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
  end

  @spec argv_hash([charlist()]) :: String.t()
  defp argv_hash(cmd) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(cmd))
    |> Base.encode16(case: :lower)
  end

  # Resolve the session cwd. An explicit operator working directory (`opts[:cwd]`)
  # wins — both the orchestrator and the workers it commands run there, and it is
  # NEVER deleted on exit (managed? == false). With none, fall back to the managed
  # per-session/orchestrator workspace under `workspace_base` (managed? == true).
  @spec resolve_workspace(keyword(), keyword(), String.t()) :: {Path.t(), boolean()}
  defp resolve_workspace(opts, cfg, session_id) do
    case blank_to_nil(opts[:cwd]) do
      nil -> {workspace_path(cfg, opts[:orchestrator_db_id], session_id), true}
      dir -> {dir, false}
    end
  end

  @spec blank_to_nil(term()) :: String.t() | nil
  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp blank_to_nil(_value), do: nil

  # Project worktree isolation (agentic-layer adaptor, Phase 4). Opt-in via
  # `opts[:isolation_mode] == :worktree` on a git-backed cwd: provision a worktree+branch
  # and run there with MANAGED cleanup (git worktree remove). A non-git repo or any git
  # failure falls through to the resolved direct cwd, unchanged (`:direct` behaviour).
  @spec maybe_worktree(keyword(), Path.t(), boolean(), String.t()) ::
          {Path.t(), boolean(), map() | nil}
  defp maybe_worktree(opts, cwd, managed?, session_id) do
    if opts[:isolation_mode] == :worktree and is_binary(cwd) do
      run_id = to_string(opts[:run_id] || opts[:agent_id] || session_id)

      case Worktree.checkout(cwd, run_id: run_id, default_branch: opts[:default_branch]) do
        {:ok, info} -> {info.path, true, info}
        _ -> {cwd, managed?, nil}
      end
    else
      {cwd, managed?, nil}
    end
  end

  # Workers get a fresh per-session workspace (ephemeral, cleaned on exit). An
  # ORCHESTRATOR is a long-lived conversation resumed across turns via the harness
  # CLI's cwd-scoped session store (pi keys sessions by project cwd), so it MUST
  # reuse ONE stable directory keyed by its id — otherwise every turn lands in a
  # new cwd and `--session` resume sees a "different project" and stalls on the
  # interactive fork prompt, emitting no inference.
  @spec workspace_path(keyword(), Ecto.UUID.t() | nil, String.t()) :: Path.t()
  defp workspace_path(session_cfg, nil, session_id) do
    base = session_cfg[:workspace_base] || "priv/workspaces"
    Path.join(base, session_id)
  end

  defp workspace_path(session_cfg, orchestrator_id, _session_id) do
    base = session_cfg[:workspace_base] || "priv/workspaces"
    Path.join(base, "orchestrator-" <> to_string(orchestrator_id))
  end

  # NEVER remove an operator-provided working directory (the user's project), and
  # keep the orchestrator's persistent managed workspace between turns (its CLI
  # session store is keyed to this cwd). Only ephemeral worker workspaces are removed.
  @spec cleanup_workspace(State.t()) :: :ok
  # A worktree-backed session cleans via `git worktree remove` (keeping the branch for
  # review), regardless of the managed flag — checked first.
  defp cleanup_workspace(%State{worktree: %{} = info}) do
    Worktree.cleanup(info)
    :ok
  end

  defp cleanup_workspace(%State{managed_workspace?: false}), do: :ok
  defp cleanup_workspace(%State{orchestrator_db_id: id}) when not is_nil(id), do: :ok

  defp cleanup_workspace(%State{cwd: cwd}) do
    _ = File.rm_rf(cwd)
    :ok
  end

  @spec generate_token() :: String.t()
  defp generate_token do
    16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
