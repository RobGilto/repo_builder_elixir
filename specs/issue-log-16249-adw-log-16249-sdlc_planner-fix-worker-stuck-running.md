# Bug: Worker agent stuck `:running` forever after its session dies without emitting a terminal event

## Metadata
issue_number: `log-16249`
adw_id: `log-16249`
issue_json: `{"title":"Worker shows still running after a Done event (log-16249 to log-16261)","body":"In the console drilldown log-16249 through log-16261, worker skill-scaffolder reaches a terminal Done event (log-16261) but the agent is still shown as running."}`

## Bug Description
An orchestrator‑spawned **worker** agent (`skill-scaffolder`, id `dc010c06-e3b9-4b17-91bd-105e860f8371`) reaches a terminal `%RepoBuilder.Harness.Event.Done{ok: true}` event — persisted as **log-16261** — yet the dashboard keeps showing it as **running** indefinitely.

- **Expected:** once a worker's session emits a terminal event (`Done`/`Error`), the worker's `agents.status` settles on a terminal value (`:idle` on success, `:error` on failure) and the swimlane/agent card stops showing "running".
- **Actual:** `agents.status` is `"running"` permanently. There are **no `agent_logs` rows after log-16261** for this worker and **no `os_pid_ledger` row**, i.e. nothing more ever happens for it — it is simply wedged in `:running`.

This is the **graceful‑handover / wind‑down** path (recent commits `9ea54ab`, `9d90fcf`, `852c30e`): the worker had `config["winding_down"] = true`, so when it returned, the orchestrator Queue issued **one more `command_agent` directive** to it. That re‑dispatched session is what got stuck.

## Problem Statement
A worker's `agents.status` is moved **off** `:running` **only** by a canonical terminal event flowing through `RepoBuilder.Logs.Writer.update_status_quietly/2`. `RepoBuilder.Orchestrator.Tools.command_agent/2` sets the worker to `:running` the moment `Session.Supervisor.start_session/1` returns `{:ok, pid}` (`lib/repo_builder/orchestrator/tools.ex:323`). If the freshly‑started `Session.Server` then **terminates without ever emitting a terminal event**, no code reconciles the worker's status, nothing monitors that worker session, and the worker is stuck `:running` forever — and the orchestrator Queue, which expected a follow‑up "handover terminal", waits forever too.

## Solution Statement
Guarantee that **every** `Session.Server` exit produces a terminal outcome for its worker, so status always reconciles:

1. **Primary (durable, covers all silent‑death paths):** in `RepoBuilder.Session.Server.terminate/2`, if this is a worker session (`agent_db_id` set) that **never saw a terminal event** (`saw_terminal? == false`), synthesize and `dispatch/2` a terminal `%Event.Error{reason: :spawn_failed}` before cleanup. Routing it through the normal `dispatch/2` machinery (a) persists a terminal `agent_logs` row, (b) reconciles `agents.status` to `:error` via `Logs.Writer.update_status_quietly/2`, and (c) broadcasts the worker‑terminal so the orchestrator Queue's existing **force‑retire** branch (`lib/repo_builder/orchestrator/queue.ex:422`) cleans the worker up instead of hanging.

2. **Complementary (surfaces a real message for the observed crash):** wrap the pre‑`dispatch` prelude of `handle_continue(:spawn)` (`File.mkdir_p!/1`, `adapter.command/1`, `maybe_orchestrator_spawn/4`) in `try/rescue/catch` and convert any failure into a dispatched `%Event.Error{reason: :spawn_failed, message: …}` + `{:stop, :normal}`, mirroring the existing "executable not found" / "spawn failed" branches. This turns today's silent GenServer crash into a meaningful, persisted terminal error.

Both changes are surgical and stay within the typed `Session.Server`/`Event` contracts; neither touches the wind‑down decision logic (firing the wind‑down was correct).

## Steps to Reproduce
1. Run an orchestrator with auto‑resume enabled that spawns a worker whose context occupancy crosses the wind‑down threshold (so `config["winding_down"]` gets set).
2. The worker returns a `%Done{ok: true}`; the Queue issues a `command_agent` wind‑down directive to it (`queue.ex:404` `wind_down/3`).
3. Make the re‑dispatched worker session fail **inside `handle_continue(:spawn)` before its first `dispatch/2`** — e.g. an `adapter.command/1` that raises, or a `cwd` that `File.mkdir_p!/1` cannot create.
4. Observe: `command_agent` logged `ok`, `agents.status` flips to `:running`, then **no further `agent_logs`** and **no `os_pid_ledger` row** appear; the worker stays `:running` forever and the dashboard never settles it.

Observed in production data (verified via Tidewave `execute_sql_query`):
- `agent_logs` log-16261 = `done`/`claude` for `worker-Us6y7s4ih-bwsrrS`; no rows after it.
- `agents` row: `status = "running"`, `config["winding_down"] = true`, `updated_at = 23:43:50.318990` (= `command_agent`'s `set_status(:running)`).
- `system_logs`: `command_agent: ok` (23:43:50.322) then `wind_down: issued wind-down directive to skill-scaffolder` (23:43:50.326).
- `os_pid_ledger`: **0 rows** for this agent ⇒ the wind‑down session never reached `:exec.run` success.

## Root Cause Analysis
Status reconciliation is **entirely event‑driven**. The only writer of a worker's terminal status is `Logs.Writer.update_status_quietly/2` (`lib/repo_builder/logs/writer.ex:169-186`), invoked from `dispatch/2` → `Logs.Writer.record/1` for **each canonical event**:

```elixir
%Event.SessionStarted{} -> :running
%Event.Done{ok: true}   -> :idle
%Event.Done{ok: false}  -> :error
%Event.Error{}          -> :error
_                       -> nil
```

`command_agent/2` sets `:running` optimistically as soon as `start_session/1` returns `{:ok, pid}` (`lib/repo_builder/orchestrator/tools.ex:321-324`). The contract that brings it back down is "a terminal canonical event will eventually be dispatched." That contract is **violated** when the session dies before dispatching anything:

- `Session.Server.handle_continue(:spawn)` (`lib/repo_builder/session/server.ex:233-259`) runs `File.mkdir_p!(state.cwd)` (line 234), `state.adapter.command(start_opts)` (line 248) and `maybe_orchestrator_spawn/4` (line 249) **before** the first `dispatch/2`. A raise on any of these crashes the GenServer with **no event emitted** — no `agent_logs` row, no `os_pid_ledger` row (the ledger insert is at `server.ex:318`, after `:exec.run` success), no terminal, no worker‑terminal broadcast.
- `Session.Server.terminate/2` (`lib/repo_builder/session/server.ex:432-438`) stops the child, deletes the ledger row, cleans the workspace and releases the admission slot — but **never reconciles `agents.status`** and never emits a terminal event.
- Nothing monitors the worker `Session.Server` for the purpose of status (the Queue subscribes to the `orchestrator:<id>:workers` PubSub topic and reacts only to a broadcast that, here, never fires — `queue.ex:263-265`).

The empty `os_pid_ledger` + absence of any post‑Done `agent_logs` is the fingerprint that the re‑dispatched session crashed in the `handle_continue(:spawn)` prelude. The wind‑down code even documents that it deliberately does **no** resume bookkeeping because "the handover terminal that follows is the actionable one" (`queue.ex:416-418`) — so when that follow‑up terminal never comes, both the worker status and the orchestrator are wedged.

**Why `updated_at` (`.318990`) is newer than the Done log's `inserted_at` (`.294318`):** the Done's `update_status_quietly` set `:idle` first; then `command_agent` set `:running` a few ms later (`.318990`), which is the value now stuck in the DB.

## Relevant Files
Use these files to fix the bug:

- `lib/repo_builder/session/server.ex` — **primary fix site.** `handle_continue(:spawn)` (233‑259) can crash before any `dispatch/2`; `terminate/2` (432‑438) does cleanup but no status reconciliation; `dispatch/2` (474‑499), `error_event/3` (721‑724), `terminal?/1` (615‑618), and the `State` fields `agent_db_id` (49) and `saw_terminal?` (76) are the pieces the fix composes.
- `lib/repo_builder/logs/writer.ex` — `update_status_quietly/2` (169‑186) is the single status‑reconciliation seam; confirms a dispatched terminal `Error` will set `:error`. No change expected here; relied upon.
- `lib/repo_builder/orchestrator/tools.ex` — `command_agent/2` (285‑333), specifically the optimistic `Agents.set_status(worker.id, :running)` at line 323 that the missing terminal fails to undo. (No change required; documents the invariant the fix restores.)
- `lib/repo_builder/orchestrator/queue.ex` — `wind_down/3` (404‑420) and `force_retire/3` (422‑433): shows the orchestrator relies on a follow‑up terminal and that emitting a worker‑terminal Error on silent death routes into the existing `force_retire` recovery.
- `lib/repo_builder/agents.ex` — `set_status/2` and `Agent.status` enum (`:idle | :running | :error`); confirms `:error` is the correct terminal value for an abnormal worker death.
- `BUILD_PROMPT.md` §4.1 (terminal‑event semantics), §6 (session runtime / `terminate/2` contract), §9 (status surfaced on the dashboard) — keep the canonical‑event and typed‑style contracts intact.

### New Files
- `test/repo_builder/session/test_worker_stuck_running_test.exs` — a session‑runtime regression test proving a worker whose spawn prelude fails ends at `agents.status == :error` (not stuck `:running`) and emits a terminal event. (See note in Step 4 on why the session layer, not LiveView, is the deterministic test seam.)

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Add the durable status reconciliation in `Session.Server.terminate/2`
- In `lib/repo_builder/session/server.ex`, before the existing cleanup in `terminate/2` (`:exec.stop`, `delete_ledger_quietly`, `cleanup_workspace`, `Admission.release`), add a guarded reconciliation:
  - If `is_binary(state.agent_db_id)` **and** `state.saw_terminal? == false`, call `dispatch(error_event(state, "session ended without a terminal event: #{inspect(reason)}", :spawn_failed), state)` (ignore the returned state).
  - Keep it fail‑soft: wrap in a small private helper with `rescue`/`catch -> :ok` so a DB/PubSub hiccup during shutdown never turns `terminate/2` into a second crash (mirror `delete_ledger_quietly/1`).
- Rationale: `dispatch/2` from `terminate/2` is safe — `Phoenix.PubSub.broadcast` and the `Logs.Writer.record/1` **cast** target other processes that outlive this one. This persists a terminal `agent_logs` row, drives `update_status_quietly/2` → `:error`, fires `maybe_emit_worker_terminal/2` → the Queue's `force_retire/3` recovery, and emits the swimlane `:failed` lane.
- Note the known gap in a code comment: a hard `Process.exit(pid, :kill)` bypasses `terminate/2`; that path is out of scope here (see Notes).

### 2. Make `handle_continue(:spawn)` fail loud, not silent
- Wrap the prelude of `handle_continue(:spawn)` — `File.mkdir_p!(state.cwd)`, `state.adapter.command(start_opts)`, and `maybe_orchestrator_spawn/4` — in `try/rescue/catch`.
- On any raise/throw/exit, build a descriptive message (e.g. `"spawn preparation failed: #{Exception.message(e)}"` / `inspect(reason)`), `dispatch(error_event(state, message, :spawn_failed), state)`, and return `{:stop, :normal, state}` — exactly like the existing `nil ->` (executable not found) and `{:error, reason} ->` (spawn failed) branches at lines 251‑258 and 337‑341.
- This guarantees the observed failure surfaces a real, persisted terminal `Error` (with `saw_terminal? == true`), so Step 1's `terminate/2` reconciliation is a backstop rather than the primary surface for this specific crash.
- Keep `@spec`s intact; `handle_continue/2` keeps its existing return type. No new public functions; if you extract a private helper, it may rely on inference (or add a `@spec` for Dialyzer precision).

### 3. Confirm the reconciliation interplay (no double‑terminal)
- Verify `saw_terminal?` is set to `true` whenever a terminal event is dispatched (`dispatch/2` already does `saw_terminal? or terminal?(event)` at line 497), so:
  - Normal completion / interrupt (`{:DOWN}` → `maybe_synthesize_terminal/2`) ⇒ `saw_terminal? == true` ⇒ Step 1 does nothing (no duplicate terminal).
  - Step 2's dispatched error ⇒ `saw_terminal? == true` ⇒ Step 1 does nothing.
  - Only a genuinely silent death ⇒ `saw_terminal? == false` ⇒ Step 1 emits exactly one terminal.

### 4. Add the regression test
- Create `test/repo_builder/session/test_worker_stuck_running_test.exs`.
- Drive a **worker** `Session.Server` (set `agent_db_id` to a real `agents` row created in setup, give it a registered `agent_id`) whose spawn prelude fails deterministically. Prefer overriding the `:harnesses` registry entry (the §13 single test seam) to point at a tiny adapter whose `command/1` **raises**, OR set `cwd` to a path that `File.mkdir_p!/1` cannot create. Use `RepoBuilder.SessionCase`/the existing session test support and `Logs.Writer.drain/0`/`sync/1` to await async persistence.
- Assert (these FAIL before the fix, PASS after):
  - The worker session process is gone (it stopped).
  - `RepoBuilder.Agents.get_agent(agent_db_id).status == :error` (today: stuck `:running`).
  - A terminal `agent_logs` row (`event_type: :error`) exists for the worker after the drain (today: none).
  - Optionally: subscribing to `"agent:#{agent_id}:events"` receives a `{:harness_event, %Event.Error{}}`.
- **Why a session‑runtime test, not `test/repo_builder_web/live/...`:** the dashboard "still running" symptom is a faithful *render* of `agents.status`; the defect and its fix live entirely in the session runtime's status reconciliation. The deterministic, fast, regression‑proof seam is `Session.Server` + `agents.status`. (Optional supplementary: a `Phoenix.LiveViewTest` that mounts the agent/swimlane view and asserts the card is not "running" after the same failure — include only if the dashboard test support makes it cheap; the session test is the authoritative gate.)

### 5. Run the validation commands
- Execute every command in **Validation Commands** and ensure all are green with zero regressions.

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- `mix test test/repo_builder/session/test_worker_stuck_running_test.exs` — the new regression test (fails before the fix, passes after).
- `mix compile --warnings-as-errors` — clean compile; gradual set‑theoretic checker + `warnings_as_errors` pass.
- `mix test --warnings-as-errors` — full ExUnit suite, zero failures.
- `mix format --check-formatted` — formatting.
- `mix credo --strict` — lint, incl. the "every public function has an `@spec`" gate.
- `mix dialyzer` — `@spec`/contract checking, no new warnings, no stale ignore filters.

Optional runtime confirmation (Tidewave, on a live dev server): re‑run a wind‑down worker whose spawn fails and confirm via `execute_sql_query` that `agents.status` settles to `:error` and a terminal `agent_logs` row exists (vs. the wedged `:running` today).

## Notes
- **Scope is deliberately the silent‑death class, not the wind‑down decision.** The wind‑down firing (`config["winding_down"] = true`, `command_agent` re‑dispatch) was correct behavior for a worker over the context‑window threshold (commits `9d90fcf`, `9ea54ab`). The defect is purely the unreconciled status when the re‑dispatched session dies before emitting a terminal.
- **`set_status(:running)` stays optimistic.** Moving the `:running` write to depend on `%SessionStarted{}` was considered but rejected: it would leave a brief `:idle`→spawn window and complicate `command_agent`'s success contract. Guaranteeing a terminal on every exit (this fix) is the smaller, more robust change.
- **Known residual gap (out of scope, note for follow‑up):** a hard `Process.exit(pid, :kill)` / brutal supervisor shutdown bypasses `terminate/2`, so a worker killed that way could still leave `agents.status == :running`. A durable sweep — a boot/periodic reconciler that sets `:running` workers with no live `SessionRegistry` entry to `:error` (sibling to `OrphanReaper`, §5/§6) — would close it. Not required to fix the reported bug; flag it if the team wants belt‑and‑suspenders coverage.
- **No new dependencies.** All changes are within `Session.Server` and a new test file. No `mix.exs` edits.
- **Tidewave was used to root‑cause this** (per the build prompt's preference): `execute_sql_query` against `agent_logs` (log-16249..16261), `agents`, `os_pid_ledger`, `projects`, and `system_logs` confirmed the empty ledger + missing post‑Done logs + `winding_down` config + the `command_agent ok` / `wind_down` audit trail that together pin the silent‑spawn‑death root cause.
