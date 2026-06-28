# Bug: Quiescent-worker idle demotion never re-engages the owning orchestrator

## Metadata
issue_number: `got`
adw_id: `orchestrator`
issue_json: `to`

## Bug Description

The operator had the orchestrator dispatch a worker. The worker did its work and its
console card flipped from **running → idle**, but the orchestrator was never informed,
so it never reviewed the worker's report and never took the next action. The
"programmatic watchdog" the operator expected to notice the worker finishing and wake
the orchestrator did notice (it demoted the worker to `:idle`) — but it stayed silent.

- **Expected:** when the watchdog observes a dispatched worker go quiet / finish and
  demotes it to `:idle`, the owning orchestrator is re-engaged exactly once so it can
  read the worker's output and decide next steps (harvest the report, resume the
  worker, dispatch follow-up work, or report complete).
- **Actual:** the soft quiescence demotion (`:running → :idle`) is a SILENT status
  change — it broadcasts only `agent_updated` (the console card) and never the
  worker-terminal re-engagement signal. The orchestrator sits idle indefinitely.

### Live evidence (verified via Tidewave + SQL against the running app)

Worker `mech-facing-builder` (`db334847-20ef-494a-b9c5-b203dfe22f3f`, orchestrator
`orch:DroneCommander` `bb2ca162-…`):

- `agent_logs` for the worker contain **only `session_started`** — **no `done`, no
  `error`** ever. Its last real events (`text_delta`/`usage`) are at `13:02:05`.
- `Session.Supervisor.whereis/1` ⇒ **the session process is still alive**; the worker
  row is `status: :idle` (demoted at `updated_at 12:58:16`, while `heartbeat_at` kept
  advancing to `13:01:50`).
- The orchestrator's last activity is `command_agent: ok` (12:55:17) + `record_progress`
  (12:55:22). **No `auto_resume` / holding / drive turn afterwards** — it was never
  re-engaged.
- `Agents.live_workers_for(oid) == []` and `WorkerFleet.classify(oid) == :empty` — the
  `:idle`-demoted worker is invisible to the new fleet gate too (see Root Cause).

## Problem Statement

A dispatched worker that goes quiet and is soft-demoted `:running → :idle` (kept alive +
resumable) without emitting a clean terminal `Event.Done` strands its output: the owning
orchestrator is never notified and never follows up. Re-engagement is entirely
event-driven off the worker-terminal broadcast, and the quiescence demotion does not
emit it.

## Solution Statement

Make the soft quiescence idle-demotion **inform the owning orchestrator**, reusing the
existing event-driven holding-pattern seam (`Dashboard.broadcast_worker_terminal/2` →
`orchestrator:<id>:workers` → `Queue.maybe_auto_resume/2`). When
`Session.Server` demotes an **orchestrator-owned** worker to `:idle`, it broadcasts ONE
idle-flavored worker-terminal signal (`ok?: true`, `holding?: false`, plus an `idle?:
true` marker) so the Queue enqueues a single low-priority review turn telling the
orchestrator the worker went idle after producing output — review it and decide next
steps. This is cheap, event-driven, deduped/coalesced by the existing Queue machinery,
and consistent with the "deterministic watchdog informs the orchestrator, never an LLM
poll" doctrine.

A worker that is quiet because it is **blocked pending external input** is a different
path (it sets `:holding`, already re-engages) and must remain unaffected; the demotion
signal is the "finished/idle, here is the work" flavor, not the holding flavor.

## Steps to Reproduce

1. Have an orchestrator (with an active goal) `command_agent` a worker to do a task.
2. Let the worker do its work and then go quiet on meaningful events for
   `quiescence_ms` (90 s) **without** the session emitting a clean terminal `Event.Done`
   (the common lingering-resumable-session case; reproduced live with the Claude harness).
3. Observe the worker card flip running → idle.
4. Observe the orchestrator is never re-engaged: no `auto_resume` turn, no review of the
   worker's report (confirm via `system_logs` for the orchestrator id and the absence of
   any `{:worker_terminal, …}`-driven turn).

Deterministic reproduction (test): start a worker `Session.Server` bound to an
orchestrator, subscribe to `orchestrator:<id>:workers`, send the `:quiescence` message,
and assert NO `{:worker_terminal, …}` arrives (pre-fix) / exactly one idle-flavored one
arrives (post-fix).

## Root Cause Analysis

`RepoBuilder.Session.Server.handle_info(:quiescence, …)` calls
`demote_to_idle_quietly/1` for a worker session (`lib/repo_builder/session/server.ex`
~490–502, ~999–1011). That function sets the agent `:idle` and broadcasts
`broadcast_agent_updated/1` (console card) **only** — it does NOT call
`broadcast_worker_terminal/2`. Re-engagement of an idle orchestrator is exclusively
event-driven off the worker-terminal broadcast (`Queue.maybe_auto_resume/2`,
`lib/repo_builder/orchestrator/queue.ex` ~349–442), which is emitted only by
`maybe_emit_worker_terminal/2` on a **terminal `Event.Done`/`Event.Error`**
(`server.ex` ~768–806). A worker that goes idle without a terminal therefore produces no
re-engagement signal.

Contributing exposure: with the worker-fleet drive-loop gate
(`specs/issue-plan-adw-plan-sdlc_planner-deterministic-worker-fleet-gate.md`), the
autonomous `Driver` no longer polls aggressively, so the previously-incidental safety
net (a 30 s drive tick eventually driving the idle orchestrator) is gone. Worse, the
`:idle`-demoted worker is excluded from `Agents.live_workers_for/1` (only
`:running`/`:holding`), so `WorkerFleet.classify/1` reports `:empty` and the Driver
backstop has nothing to react to. The correct, cheap fix is event-driven re-engagement
at the demotion point, not re-introducing polling.

## Relevant Files

Use these files to fix the bug:

- `lib/repo_builder/session/server.ex` — **primary fix.** `handle_info(:quiescence, …)`
  (~490) / `demote_to_idle_quietly/1` (~999): after setting `:idle`, emit the
  idle-flavored worker-terminal signal for an orchestrator-owned worker. Reuse
  `resolve_worker_owner/1` (already present) and the `State` fields `orchestrator_id`,
  `agent_db_id`, `agent_name`, `context_tokens`. Mirror the shape built in
  `maybe_emit_worker_terminal/2` (~768) so the Queue handles it through the existing path.
- `lib/repo_builder/orchestrator/queue.ex` — the holding-pattern consumer
  (`maybe_auto_resume/2` ~421, `normal_resume/2` ~627, `auto_resume_prompt/2` ~819). An
  idle-flavored signal (`ok?: true`, `holding?: false`, not over-threshold, not
  winding-down) already routes to `normal_resume → start_auto_resume`. Add a small
  idle-aware resume prompt branch so the orchestrator is told the worker went **idle**
  after producing output (review/resume/move on), rather than the generic "completed
  successfully". Also clear the worker from `seen_worker_ids` on **re-dispatch**
  (`handle_cast({:monitor_worker, …})` ~307) so a worker re-dispatched after an idle
  follow-up can re-engage again on its next cycle (otherwise the dedup set strands it on
  cycle ≥ 2 — a latent gap that also affects the terminal path).
- `lib/repo_builder/dashboard.ex` — `broadcast_worker_terminal/2` (the seam; no change,
  referenced so the signal shape matches what `Queue` subscribes to).
- `lib/repo_builder/agents.ex` — `set_status/2`, `live_workers_for/1` (no change;
  referenced for the `:idle` exclusion that explains why the Driver backstop can't cover
  this).
- `lib/repo_builder/orchestrator/worker_fleet.ex` — no change; documents that the
  event-driven fix (not the fleet gate) is the correct mechanism for an idle worker.
- `test/repo_builder/session/worker_proactive_idle_test.exs` — existing quiescence test
  harness (`SessionCase`, drives `:quiescence` by hand). Extend it / model the new test
  on it.
- `test/repo_builder/orchestrator/queue_holding_pattern_test.exs` — existing holding-
  pattern test patterns to mirror for the idle-flavored resume + the re-dispatch dedup
  clear.
- `.claude/commands/conditional_docs.md` routes: `BUILD_PROMPT.md` §6 +
  `ai_docs/adw-primitives.md` (session runtime / OS-process lifecycle); `BUILD_PROMPT.md`
  §7 + `ai_docs/adw-orchestration.md` (re-engagement / holding pattern);
  `ai_docs/typed-elixir-standard.md` (the always-on typed standard).

### New Files

- `test/repo_builder/session/quiescent_worker_reengage_test.exs` — a `SessionCase`
  integration test: a worker session bound to an orchestrator, subscribed to
  `orchestrator:<id>:workers`; sending `:quiescence` broadcasts exactly one
  `{:worker_terminal, %{worker_id: …, idle?: true, ok?: true, holding?: false}}` (and a
  non-orchestrator/ephemeral session broadcasts none). This is the regression test that
  fails before the fix and passes after.

## Step by Step Tasks

IMPORTANT: Execute every step in order, top to bottom.

### 1. Reproduce deterministically (red)

- Add `test/repo_builder/session/quiescent_worker_reengage_test.exs` modeled on
  `worker_proactive_idle_test.exs`: start a worker session with an `orchestrator_id`,
  `Dashboard.subscribe_orchestrator_workers(orch_id)`, set the row `:running`, send
  `:quiescence`, and `assert_receive {:worker_terminal, %{worker_id: ^id, idle?: true}}`.
  Confirm it FAILS against current code (no broadcast).

### 2. Emit the idle re-engagement signal at the demotion point (the fix)

- In `lib/repo_builder/session/server.ex`, change the `:quiescence` handler so that when
  it demotes an orchestrator-owned worker it ALSO emits the re-engagement signal. Keep it
  fail-soft (a DB/PubSub blip must never crash the live session) and idempotent (fire
  once per quiescence firing; `quiescence_ref` is already cleared after).
- Add a private `@spec`'d helper (e.g. `maybe_emit_worker_idle/1`) that uses
  `resolve_worker_owner/1` and, when `{orchestrator_id, name}` resolves, calls
  `Dashboard.broadcast_worker_terminal(orchestrator_id, %{worker_id: agent_db_id, name:
  name, ok?: true, holding?: false, idle?: true, context_tokens: state.context_tokens,
  final_text: nil, holding_reason: nil})`. Only fire for `worker_session?/1` (never an
  orchestrator/ephemeral turn) — i.e. exactly where `demote_to_idle_quietly/1` runs.
- Precise types, no `any()`/bare `map()` on new public helpers; `@spec` per the standard
  (private helpers may rely on inference but spec them for clarity/Dialyzer as the file
  already does).

### 3. Make the Queue resume idle-aware (and robust across cycles)

- In `lib/repo_builder/orchestrator/queue.ex`:
  - In `auto_resume_prompt/2`, add a branch for `idle?: true` that frames the resume as
    "Worker <name> went IDLE after producing output (it did not emit a clean completion).
    Review its work and decide next steps: harvest its report, resume it via
    `command_agent` if more is needed, or move on." Keep the existing goal-context
    prepend (`prepend_goal_context/2`).
  - In `handle_cast({:monitor_worker, worker_id, pid}, …)`, drop `worker_id` from
    `seen_worker_ids` (a fresh dispatch is a new work cycle) so a re-dispatched worker can
    re-engage on its next idle/terminal. Keep the existing re-monitor behavior.
  - Verify an idle-flavored signal flows `maybe_auto_resume → resume_or_wind_down →
    normal_resume` (not hold/wind-down/force-retire) given `holding?: false`,
    not-over-threshold, not winding-down.

### 4. Tests — idle re-engagement + dedup/coalesce + holding unaffected

- Make the Step 1 test pass (green). Add a case asserting a NON-orchestrator session
  (ephemeral / orchestrator turn) emits NO idle signal.
- In `test/repo_builder/orchestrator/queue_holding_pattern_test.exs` (or a sibling), add:
  an idle-flavored `{:worker_terminal, %{idle?: true, ok?: true}}` enqueues exactly one
  auto-resume review turn when idle (and coalesces/records pending when busy); a holding
  signal (`holding?: true`) is still routed to the holding resume unchanged; a
  re-dispatched worker (`monitor_worker`) can re-engage again after a prior follow-up
  (seen-set cleared).

### 5. Regression guard for the existing quiescence behavior

- Confirm `worker_proactive_idle_test.exs` still passes: the worker is still demoted
  `:running → :idle`, stays ALIVE + resumable, no `:exec.stop`, blocking-command and
  orchestrator/ephemeral sessions are unaffected. Only the added broadcast is new.

### 6. Run the Validation Commands

- Run every command in **Validation Commands**; fix any regression until all green.

## Validation Commands

Execute every command to validate the bug is fixed with zero regressions.

- `mix test test/repo_builder/session/quiescent_worker_reengage_test.exs` - The new
  regression test (fails before the fix, passes after).
- `mix test test/repo_builder/session/worker_proactive_idle_test.exs test/repo_builder/orchestrator/queue_holding_pattern_test.exs test/repo_builder/orchestrator/queue_holding_test.exs test/repo_builder/orchestrator/queue_handover_test.exs` -
  Re-engagement / quiescence / holding / handover paths, zero regressions.
- `mix compile --warnings-as-errors` - Compile clean; gradual checker + warnings-as-errors pass.
- `mix test --warnings-as-errors` - Full ExUnit suite, zero failures.
- `mix format --check-formatted` - Formatting.
- `mix credo --strict` - Lint incl. the `@spec` convention.
- `mix dialyzer` - Contract checking, no new warnings, no stale ignore filters.

## Notes

- **Why event-driven, not a fleet-gate tweak.** Including `:idle`-but-alive workers in
  `WorkerFleet`/`live_workers_for` to let the Driver backstop them would re-introduce
  LLM drive-turn polling and only works when the orchestrator has an active ledger +
  budget. Emitting the re-engagement at the demotion point is cheaper, immediate, and
  consistent with the holding-pattern design (push on a state transition, coalesced to a
  single resume).
- **Anti-spam / anti-amnesia are already handled** by the Queue: `seen_worker_ids`
  dedup, mid-turn `pending_resume?` coalescing, and operator-message supersession. The
  fix adds one signal source and one prompt flavor; it does not add a timer/poll. The
  `:quiescence` timer fires once per quiet window (`quiescence_ref` cleared after), so no
  storm.
- **No UI/LiveView change required** — this is session-runtime/orchestration logic. The
  console already reflects the worker `:idle` card via the existing `agent_updated`
  broadcast; the new behavior is the orchestrator taking a follow-up turn.
- **Reproduced live** via Tidewave `project_eval` (`session_alive?: true`,
  `worker_status: :idle`, no `done` event) and `execute_sql_query` against
  `repo_builder_dev` (worker `db334847…`, orchestrator `bb2ca162…`).
- **No new dependency.**
