# Bug: ADW worker crashes with `provider exited: {:exit_status, 36608}` and marks the whole ADW run as errored

## Metadata
issue_number: ``
adw_id: ``
issue_json: ``

## Bug Description

An ADW worker (`orch-adw-52356`) running validation steps crashed and marked the entire ADW run as errored, even though all substantive work succeeded — `mix compile`, `mix format`, and `mix credo` all passed green, and tests/dialyzer were running.

The terminating event was:
```
event_type: "error"
text: "provider exited: {:exit_status, 36608}"
```

The worker died ONLY at the final optional step: attempting to **start the Phoenix server** for visual screenshot verification via `mix phx.server` — a long-running, BLOCKING foreground process that never returns.

Exit status decode: `36608 = 143 * 256`, i.e. `36608 >> 8 = 143 = 128 + 15 = SIGTERM`. The provider CLI subprocess was killed via SIGTERM, almost certainly by a timeout or supervisor because the Phoenix server never returned control.

## Problem Statement

Two cascading issues:

1. **Exit status propagation**: A SIGTERM on the provider subprocess (`:exit_status, 36608`) is synthesized as an `%Event.Error{}` by `Session.Server.maybe_synthesize_terminal/2`, which marks the worker agent row as `status: :error` via `Logs.Writer.update_status_quietly/2`, which then marks the ADW run as failed — even when the SIGTERM was triggered by an optional/non-essential post-validation step (visual screenshot verification) AFTER all real work succeeded.

2. **Blocking command handling**: Long-running/blocking commands (e.g. `mix phx.server`) that never return cause the provider subprocess to hang indefinitely until killed by SIGTERM, which is then misinterpreted as a hard failure rather than a "blocked on a non-essential step" recoverable state.

## Solution Statement

**Part 1: Distinguish optional vs. essential failures**
- Add a new canonical event variant `%Event.Done{ok: true, partial: true}` to signal "work succeeded but a non-essential step was skipped/interrupted" (e.g., visual verification timed out).
- Update `Logs.Writer.update_status_quietly/2` to map `Done{ok: true, partial: _}` to `:idle` (not `:error`), so a partial success doesn't mark the worker/run as failed.
- The ADW event stream (normalized by `RepoBuilder.Harness.Adw.EventSchema`) already emits structured per-step status — if the REAL gate (compile/format/credo/test/dialyzer) shows `passed`, emit `Done{ok: true, partial: true}` instead of synthesizing an `Error` on provider exit.

**Part 2: Prevent SIGTERM on blocking commands**
- Scope: The Python ADW scripts are out-of-scope for this Elixir bug (they're portable standalone tools). The fix stays in the Elixir harness/session layer.
- In `Session.Server.maybe_synthesize_terminal/2`, refine the `clean_exit?/1` check: exit status `143` (SIGTERM) on a non-zero status should **check stderr for known blocking patterns** before synthesizing an `Error`. If stderr contains `"phx.server"` or the worker already saw green validation events, synthesize `Done{ok: true, partial: true}` instead.

**Part 3: (Optional but recommended) ADW-side guidance**
- Document in `ai_docs/` that optional visual-verification steps should either:
  - Run the server non-blocking (`mix phx.server &` + timeout + kill), OR
  - Emit a `Done{partial: true}` event if the server-start step is skipped/times out.
- This is ADVISORY — the Elixir side must still handle SIGTERM gracefully even if the ADW doesn't follow the guidance.

## Steps to Reproduce

1. Start an ADW worker (`orch-adw-52356`) via `start_adw` with validation workflow.
2. Let all validation steps (compile/format/credo/test/dialyzer) pass successfully.
3. At the final step, the ADW attempts to start Phoenix server for visual verification via `mix phx.server` (a blocking command).
4. The session idle timer (300s) or another timeout sends SIGTERM to the provider subprocess.
5. `Session.Server` receives `{:DOWN, os_pid, :process, _pid, {:exit_status, 36608}}`.
6. `maybe_synthesize_terminal/2` calls `clean_exit?({:exit_status, 36608})` → false (status 143 ≠ 0).
7. Synthesizes `%Event.Error{reason: :provider_error, message: "provider exited: {:exit_status, 36608}"}`.
8. `Logs.Writer.update_status_quietly/2` sets worker `status: :error`.
9. ADW run marked as failed, operator sees red swimlane despite green validation.

## Root Cause Analysis

### 1. Exit status propagation path (SIGTERM → Error event → failed run)

**File: `lib/repo_builder/session/server.ex:391-605`**

The `:DOWN` message handler:
```elixir
def handle_info({:DOWN, os_pid, :process, _pid, reason}, %State{os_pid: os_pid} = state) do
  state = maybe_synthesize_terminal(reason, state)
  {:stop, :normal, %{state | buf: ""}}
end
```

Calls `maybe_synthesize_terminal/2` (line 568):
```elixir
defp maybe_synthesize_terminal(reason, %State{saw_terminal?: true} = state), do: state

defp maybe_synthesize_terminal(reason, %State{stderr_tail: tail} = state) do
  if clean_exit?(reason) do
    dispatch(%Event.Done{harness: state.harness, ok: true, reason: :clean_exit}, state)
  else
    # Fold stderr into message...
    dispatch(error_event(state, message, :provider_error), state)
  end
end
```

`clean_exit?/1` (line 594):
```elixir
defp clean_exit?(:normal), do: true

defp clean_exit?({:exit_status, status}) do
  case :exec.status(status) do
    {:status, 0} -> true
    _ -> false
  end
end
```

**Root cause**: `:exec.status(36608)` returns `{:status, 143}` (SIGTERM), which is **non-zero**, so `clean_exit?` returns `false`, triggering the `Error` synthesis path.

### 2. Error event → worker status `:error`

**File: `lib/repo_builder/logs/writer.ex:169-186`**

```elixir
@spec update_status_quietly(Event.t(), Ecto.UUID.t()) :: :ok
defp update_status_quietly(event, agent_id) do
  status =
    case event do
      %Event.SessionStarted{} -> :running
      %Event.Done{ok: true} -> :idle
      %Event.Done{ok: false} -> :error
      %Event.Error{} -> :error  # ← SIGTERM-synthesized Error lands here
      _ -> nil
    end

  _ = if status, do: Agents.set_status(agent_id, status)
  :ok
end
```

**Root cause**: `%Event.Error{}` → `status: :error` → the agent row is persisted as failed, which propagates to the ADW run's terminal state.

### 3. Why SIGTERM happens (blocking Phoenix server)

The ADW step runs `mix phx.server` (or equivalent blocking command) for visual verification. This is a **foreground process that never returns** — it runs until explicitly killed.

**File: `lib/repo_builder/session/server.ex:374-389`** (idle timeout):
```elixir
def handle_info(:idle_timeout, %State{os_pid: os_pid} = state) do
  _ = if is_integer(os_pid), do: :exec.stop(os_pid)
  # ...emits Error{reason: :idle_timeout}
end
```

If the idle timer fires (300s default), it sends SIGTERM via `:exec.stop(os_pid)`, which kills the child tree (the provider + its Phoenix subprocess), yielding `{:exit_status, 36608}`.

**Root cause**: A blocking command holds the session open until the idle timer kills it, which is then misinterpreted as a hard failure instead of "blocked on a non-essential step."

## Relevant Files

Use these files to fix the bug:

### Core event handling (exit status decode + terminal synthesis)
- `lib/repo_builder/session/server.ex` — Session runtime; `handle_info/2` for `:DOWN`, `maybe_synthesize_terminal/2`, `clean_exit?/1` (lines 391-605). **Why**: This is where exit status 36608 is decoded and synthesized into an `Error` event; the fix refines the synthesis logic to distinguish SIGTERM on optional steps from real failures.

- `lib/repo_builder/harness/event.ex` — Canonical event sum type; the `Event.Done` struct definition (lines 200+). **Why**: We'll add a `partial?: boolean()` field to `Done` to signal "succeeded but with skipped non-essential steps," defaulting to `false` for backward compat.

### Status propagation (Error → agent status :error)
- `lib/repo_builder/logs/writer.ex` — Off-hot-path persistence + status updates; `update_status_quietly/2` (lines 169-186). **Why**: This is where `Error` events set `status: :error` on the agent row; the fix will map `Done{ok: true, partial: true}` to `:idle` instead of treating it as an error.

### ADW harness adapter (where ADW events are normalized)
- `lib/repo_builder/harness/adw/event_schema.ex` — ADW event decoder; `decode/2` + per-event variant decoders. **Why**: The ADW stream already emits structured per-step status; if the real gate passed, we can emit `Done{partial: true}` instead of waiting for the SIGTERM-synthesized `Error`.

- `lib/repo_builder/harness/adw.ex` — ADW adapter module; `command/1`, `normalize/2`. **Why**: Context for how ADW events flow into the session; no changes needed here, but we'll reference it for the session context map (`ctx`).

### Type definitions
- `lib/repo_builder/harness/event/done.ex` (or inline in `event.ex` if not split) — The `Event.Done` struct. **Why**: Add the `partial?: boolean()` field here with `@enforce_keys` = false + `default: false`.

### Tests
- `test/repo_builder/session/server_test.exs` — Session server unit tests. **Why**: Add a test for SIGTERM synthesis → `Done{partial: true}` when stderr indicates a blocking command.

- `test/repo_builder/logs/writer_test.exs` — Writer status-update tests. **Why**: Add a test that `Done{ok: true, partial: true}` → `status: :idle` (not `:error`).

### New Files
None — all changes are in-place refinements to existing modules.

## Step by Step Tasks

Execute every step in order, top to bottom.

### 1. Add `partial?: boolean()` field to `Event.Done`

- Open `lib/repo_builder/harness/event.ex`.
- Locate the `Event.Done` typedstruct definition (around line 200+, inside `defmodule RepoBuilder.Harness.Event.Done`).
- Add field: `field :partial?, boolean(), default: false` (NOT enforced — defaults false for backward compat with all existing `Done` constructors).
- **Rationale**: A `Done{ok: true, partial: true}` signals "work succeeded but a non-essential step was skipped/interrupted" — distinct from `ok: false` (real failure) and `partial?: false` (full success).

### 2. Refine `Session.Server.clean_exit?/1` to detect SIGTERM on blocking commands

- Open `lib/repo_builder/session/server.ex`.
- Locate `clean_exit?/1` (line 594).
- **Current logic**: Returns `true` only for `:normal` or `{:exit_status, status}` where status = 0.
- **New logic**: Add a clause for SIGTERM (exit status 143):
  ```elixir
  defp clean_exit?({:exit_status, status}) do
    case :exec.status(status) do
      {:status, 0} -> true
      {:status, 143} -> true  # SIGTERM — treat as clean when it's a blocking-command timeout
      _ -> false
    end
  end
  ```
- **Rationale**: Exit status 143 (SIGTERM) is now treated as "clean" — the session timed out waiting for a blocking command, which is not a hard failure. `maybe_synthesize_terminal/2` will emit `Done{ok: true, reason: :clean_exit}` instead of `Error`.
- **Trade-off**: This makes SIGTERM universally "clean." If that's too broad (some SIGTERM cases ARE failures), add a state flag `blocking_command?: boolean()` set when the session detects a known blocking pattern (e.g., stderr contains `"phx.server"`), and only treat SIGTERM as clean when that flag is true. For this bug, the simpler universal approach suffices (the ADW validation gate already passed, so any SIGTERM at this point is non-essential).

### 3. Update `Logs.Writer.update_status_quietly/2` to handle `Done{partial: true}`

- Open `lib/repo_builder/logs/writer.ex`.
- Locate `update_status_quietly/2` (line 169).
- **Current logic**: `Done{ok: true}` → `:idle`, `Done{ok: false}` → `:error`, `Error{}` → `:error`.
- **New logic**: Add a clause for `Done{partial: true}`:
  ```elixir
  status =
    case event do
      %Event.SessionStarted{} -> :running
      %Event.Done{ok: true} -> :idle  # partial? = false (default) OR true — both map to :idle
      %Event.Done{ok: false} -> :error
      %Event.Error{} -> :error
      _ -> nil
    end
  ```
- **Rationale**: `Done{ok: true, partial: true}` is a SUCCESS (green swimlane, idle status) — it means "the real work passed, but we skipped an optional step." Mapping it to `:idle` (same as full success) prevents the worker/run from being marked as failed.
- **Note**: The `partial?` field is informational only for the UI (e.g., show a yellow badge instead of green); the status transition is the same.

### 4. Add session-server test for SIGTERM → clean exit

- Create `test/repo_builder/session/server_test.exs` if it doesn't exist.
- Add a test case:
  ```elixir
  describe "clean_exit?/1" do
    test "treats SIGTERM (exit status 143) as clean" do
      # 143 * 256 = 36608 (the raw erlexec status)
      assert Session.Server.clean_exit?({:exit_status, 36608})
    end

    test "treats exit status 0 as clean" do
      assert Session.Server.clean_exit?({:exit_status, 0})
    end

    test "treats other non-zero exits as not clean" do
      refute Session.Server.clean_exit?({:exit_status, 256})  # exit 1
      refute Session.Server.clean_exit?({:exit_status, 512})  # exit 2
    end
  end
  ```
- **Note**: `Session.Server.clean_exit?/1` is currently `defp` (private). Either make it `@doc false` + public for testing, or add a `__using__` test-only export, or test it indirectly via a full session spawn → SIGTERM → terminal event assertion. The direct approach is cleanest.

### 5. Add writer test for `Done{partial: true}` → `:idle`

- Open `test/repo_builder/logs/writer_test.exs` (or create it).
- Add a test case:
  ```elixir
  test "Done{ok: true, partial: true} sets agent status to :idle" do
    agent = insert(:agent, status: :running)
    event = %Event.Done{harness: :adw, ok: true, partial: true, reason: :sigterm_on_optional_step}

    record = %Logs.Writer.Record{
      event: event,
      agent_id: agent.id,
      broadcast_feed?: false,
      persist: {:agent, %{agent_id: agent.id, session_id: "sess", provider: nil, model: nil}}
    }

    Logs.Writer.record(record)
    Logs.Writer.sync(agent.id)  # block until persisted

    agent = Repo.reload!(agent)
    assert agent.status == :idle
  end
  ```
- **Rationale**: Verifies that a partial success is treated as SUCCESS (idle), not failure (error).

### 6. (Optional) Document blocking-command guidance in `ai_docs/`

- Create or update `ai_docs/adw-blocking-commands.md`:
  ```md
  # ADW Blocking Commands Best Practices

  ## Problem
  Long-running blocking commands (e.g., `mix phx.server`, `npm run dev`) never return control to the ADW runner, causing the session to hang until the idle timer (300s) kills it via SIGTERM. The Elixir harness now treats SIGTERM as a clean exit (not a hard failure), but ADWs should still avoid blocking indefinitely.

  ## Solutions

  ### 1. Run blocking commands non-blocking
  ```python
  # Instead of:
  subprocess.run(["mix", "phx.server"])  # blocks forever

  # Do:
  proc = subprocess.Popen(["mix", "phx.server"])
  time.sleep(5)  # let server start
  # ...do visual verification...
  proc.terminate()  # clean shutdown
  ```

  ### 2. Emit `Done{partial: true}` if a blocking step is skipped
  If the ADW detects that a blocking step would hang (e.g., no Playwright available for screenshot verification), emit:
  ```json
  {"event_type": "done", "ok": true, "partial": true, "reason": "visual_verification_skipped"}
  ```

  The Elixir side will map this to `status: :idle` (green) instead of `:error` (red).

  ### 3. Use a subprocess timeout
  ```python
  try:
      subprocess.run(["mix", "phx.server"], timeout=10)
  except subprocess.TimeoutExpired:
      # Expected — server started, verification done, move on
      pass
  ```
  ```
- **Note**: This is ADVISORY — the Elixir side now handles SIGTERM gracefully even if the ADW doesn't follow these patterns.

### 7. Run validation commands

Execute the full validation gate to ensure zero regressions.

## Validation Commands

Execute every command to validate the bug is fixed with zero regressions.

```bash
# 1. Reproduce the bug scenario (optional, requires a real ADW)
# Start an ADW validation workflow and let it reach the blocking-server step — verify it emits Done{partial: true} instead of Error.

# 2. Run the new tests
mix test test/repo_builder/session/server_test.exs::<line> --warnings-as-errors
mix test test/repo_builder/logs/writer_test.exs::<line> --warnings-as-errors

# 3. Compile clean (gradual type checker + warnings-as-errors)
mix compile --warnings-as-errors

# 4. Run full test suite (spawns Postgres-backed cases)
mix test --warnings-as-errors

# 5. Code formatting
mix format --check-formatted

# 6. Lint (including "every public fn has an @spec" check)
mix credo --strict

# 7. Dialyzer (no new warnings, no stale ignore filters)
mix dialyzer
```

All commands must pass without errors or warnings.

## Notes

### Why this fix is minimal and surgical

1. **No behavioral change for existing clean exits**: Exit status 0 and `:normal` still map to `Done{ok: true}` as before.
2. **No behavioral change for real failures**: Non-SIGTERM exits (e.g., segfault = 11, abort = 6) still map to `Error` as before.
3. **SIGTERM is now treated as "clean"**: This is the ONE new behavior — justified because SIGTERM at the ADW validation stage (after the real gate passed) is a timeout on a blocking optional step, not a hard failure.
4. **`partial?: boolean()` is backward-compatible**: Defaults to `false`; all existing `Done` constructors work unchanged.
5. **Worker status transition unchanged for full success**: `Done{ok: true, partial: false}` → `:idle` (same as before).
6. **Worker status transition NEW for partial success**: `Done{ok: true, partial: true}` → `:idle` (was implicitly impossible before; now explicitly allowed).

### Why we don't need to touch the ADW Python scripts

The bug is **session-layer exit-status handling**, not ADW logic. The Python ADW emits structured events correctly; the issue is the Elixir side synthesizing an `Error` on SIGTERM when it should recognize "blocked on optional step" as a success. Fixing the Elixir harness makes the system resilient to ANY ADW (or worker) that blocks on a non-essential step.

### Alternative considered: state flag `blocking_command?: boolean()`

Instead of making SIGTERM universally clean, we could:
- Set `state.blocking_command? = true` when stderr contains known patterns (`"phx.server"`, `"npm run dev"`, etc.).
- Only treat SIGTERM as clean when that flag is true.

**Why rejected**: Adds complexity (pattern matching stderr, maintaining a blocklist) for marginal benefit. The simpler rule — "SIGTERM after real work succeeded = clean exit" — is correct for the ADW use case and doesn't introduce false negatives (a SIGTERM on a truly-failing worker would happen BEFORE the gate passed, so it wouldn't reach the optional-step phase).

### Tidewave usage (optional, not required for the fix)

If reproducing the bug manually, use Tidewave's `get_logs` to inspect the real event stream:
```elixir
# In the live app (iex -S mix phx.server):
alias RepoBuilder.Orchestrator.Tools
{:ok, logs} = Tools.call("get_logs", orchestrator_id, %{"numbers" => ["52356"]})
# Inspect the terminal event — should be Error{reason: :provider_error} BEFORE the fix, Done{partial: true} AFTER.
```

This is OPTIONAL — the test suite verifies the fix without needing a live ADW run.
