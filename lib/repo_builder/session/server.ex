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
  alias RepoBuilder.Harness.Registry, as: HarnessRegistry
  alias RepoBuilder.OsPidLedger
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
      field :session_ctx, term(), enforce: false
      field :exec_pid, pid(), enforce: false
      field :os_pid, non_neg_integer(), enforce: false
      field :cwd, Path.t()
      field :marker, String.t()
      field :buf, binary(), default: ""
      field :idle_ref, reference(), enforce: false
      field :idle_ms, non_neg_integer()
      field :max_line_bytes, pos_integer()
      field :saw_output?, boolean(), default: false
      field :saw_terminal?, boolean(), default: false
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
      price_table: Map.get(config, :price_table, %{}),
      cwd: workspace_path(cfg, opts[:orchestrator_db_id], session_id),
      marker: generate_token(),
      idle_ms: cfg_value(opts, cfg, :idle_ms, 300_000),
      max_line_bytes: cfg_value(opts, cfg, :max_line_bytes, 1_048_576),
      orchestrator_ctx: opts[:orchestrator_ctx],
      orchestrator_db_id: opts[:orchestrator_db_id]
    }
  end

  defp cfg_value(opts, cfg, key, default), do: opts[key] || cfg[key] || default

  # Merge runtime-configured per-harness secrets (§6) with any explicit per-session
  # overrides; drop unset (nil) env values so they never reach the child env.
  @spec resolve_secrets(keyword(), String.t()) :: map()
  defp resolve_secrets(opts, harness) do
    configured =
      :repo_builder
      |> Application.get_env(:harness_secrets, %{})
      |> Map.get(harness, %{})
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    Map.merge(configured, opts[:secrets] || %{})
  end

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
      state = dispatch(error_event(state, "stdout overflow", :provider_error), state)
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
    {:noreply, %{state | stderr_tail: append_stderr(state.stderr_tail, chunk)}}
  end

  def handle_info({:stderr, _os_pid, _chunk}, state), do: {:noreply, state}

  def handle_info(:idle_timeout, %State{os_pid: os_pid} = state) do
    _ = if is_integer(os_pid), do: :exec.stop(os_pid)

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
  def terminate(_reason, %State{} = state) do
    _ = if is_integer(state.os_pid), do: :exec.stop(state.os_pid)
    delete_ledger_quietly(state.marker)
    cleanup_workspace(state)
    Admission.release()
    :ok
  end

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
    # Persist the REDACTED event (Logs.persist_event scrubs `raw`); broadcast the FULL
    # event for the live UI (§4.1). Persistence only applies when the session is tied
    # to a durable agent row.
    if state.agent_db_id do
      persist_quietly(event, state)
      update_status_quietly(event, state)
    end

    # Independent orchestrator persistence gate (issue-d): an orchestrator session
    # carries `orchestrator_db_id` (never `agent_db_id`), so its events persist to
    # `agent_logs` keyed by `orchestrator_id` — observability parity with workers,
    # with the worker path above untouched.
    if state.orchestrator_db_id do
      persist_orchestrator_quietly(event, state)
    end

    _ = Phoenix.PubSub.broadcast(@pubsub, "agent:#{agent_id}:events", {:harness_event, event})
    # Additive global feed for the multi-layered console (§9): one unified stream
    # across all agents. Per-agent topic above is unchanged.
    _ = RepoBuilder.Dashboard.broadcast_event(agent_id, event)
    _ = maybe_broadcast_lane(event, state)
    %{state | saw_output?: true, saw_terminal?: state.saw_terminal? or terminal?(event)}
  end

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

  @spec lane(State.t(), atom(), String.t()) :: :ok
  defp lane(state, status, label) do
    RepoBuilder.Dashboard.broadcast_lane(%{
      id: "agent:#{state.agent_id}",
      kind: :agent,
      label: to_string(label),
      status: status,
      harness: to_string(state.harness)
    })
  end

  @spec persist_quietly(Event.t(), State.t()) :: :ok
  defp persist_quietly(event, %State{} = state) do
    _ = Logs.persist_event(event, %{agent_id: state.agent_db_id, session_id: state.session_id})
    :ok
  rescue
    error -> Logger.warning("persist_event failed: #{inspect(error)}")
  catch
    _kind, _reason -> :ok
  end

  @spec persist_orchestrator_quietly(Event.t(), State.t()) :: :ok
  defp persist_orchestrator_quietly(event, %State{} = state) do
    _ =
      Logs.persist_orchestrator_event(event, %{
        orchestrator_id: state.orchestrator_db_id,
        session_id: state.session_id
      })

    :ok
  rescue
    error -> Logger.warning("persist_orchestrator_event failed: #{inspect(error)}")
  catch
    _kind, _reason -> :ok
  end

  @spec update_status_quietly(Event.t(), State.t()) :: :ok
  defp update_status_quietly(event, %State{agent_db_id: agent_id}) do
    status =
      case event do
        %Event.SessionStarted{} -> :running
        %Event.Done{ok: true} -> :idle
        %Event.Done{ok: false} -> :error
        %Event.Error{} -> :error
        _ -> nil
      end

    _ = if status, do: Agents.set_status(agent_id, status)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  @spec terminal?(Event.t()) :: boolean()
  defp terminal?(%Event.Done{}), do: true
  defp terminal?(%Event.Error{}), do: true
  defp terminal?(_event), do: false

  @spec maybe_synthesize_terminal(term(), State.t()) :: State.t()
  defp maybe_synthesize_terminal(reason, %State{saw_terminal?: true} = state) do
    _ = reason
    state
  end

  defp maybe_synthesize_terminal(reason, %State{stderr_tail: tail} = state) do
    if clean_exit?(reason) do
      dispatch(%Event.Done{harness: state.harness, ok: true, reason: :clean_exit}, state)
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

  @spec clean_exit?(term()) :: boolean()
  defp clean_exit?(:normal), do: true

  defp clean_exit?({:exit_status, status}) do
    case :exec.status(status) do
      {:status, 0} -> true
      _ -> false
    end
  end

  defp clean_exit?(_reason), do: false

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
  @spec build_env([{String.t(), String.t()}], String.t()) :: [{charlist(), charlist()}]
  defp build_env(env, marker) do
    System.get_env()
    |> Map.merge(Map.new(env))
    |> Map.put("REPO_BUILDER_SESSION_MARKER", marker)
    |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
  end

  @spec argv_hash([charlist()]) :: String.t()
  defp argv_hash(cmd) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(cmd))
    |> Base.encode16(case: :lower)
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

  # Keep the orchestrator's persistent workspace between turns (its CLI session
  # store is keyed to this cwd); only ephemeral worker workspaces are removed.
  @spec cleanup_workspace(State.t()) :: :ok
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
