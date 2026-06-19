# Bug: Orchestrator turn stalls silently after worker resume — no prompt watchdog recovers it

## Metadata
issue_number: `orch-stall`
adw_id: `resume`
issue_json: `{"title":"Orchestrator turn stalls silently after worker resume — only an operator message breaks the hang","body":"After a dispatched worker (agentic-practice-analyst) finished, the holding-pattern auto_resume fired correctly (~2s later, turn orch-877c689b-…-5636), but the resulting orchestrator LLM turn then produced no visible output for ~3 minutes until I manually nudged it. A log search for timeout/error/stuck over the window returned zero hits — no watchdog fired and the platform never auto-recovered. The wake mechanism is healthy (~10 prior auto_resume events worked); this is a per-turn generation stall, likely a zai/glm-5.2 stream stall the runtime accepted as 'still generating' indefinitely. Add a generation watchdog: if an orchestrator turn produces no output for N seconds, surface a stall/timeout and recover the turn instead of hanging until an operator intervenes."}`

## Bug Description
When an orchestrator turn (one harness invocation, resumed across turns) stops emitting
output mid-generation — e.g. the underlying provider's streaming response stalls — the
console shows the orchestrator stuck `:running` with no further output. Nothing surfaces
a timeout, and the turn does not end on its own within an operator-tolerable window. The
only thing that broke the observed stall was the operator sending a new message.

- **Expected:** A stalled orchestrator turn is detected within tens of seconds, a visible
  `idle timeout` signal is surfaced on the console feed, the turn ends cleanly, and the
  per-orchestrator `Queue` is free to proceed (run any owed auto-resume / next operator
  message) — no manual nudge required.
- **Actual:** The turn hangs silently for ~3 minutes (observed: 15:16:47 → 15:19:54 UTC,
  turn `orch-877c689b-0ac5-495c-be7f-a1363ac04efb-5636`). No `timeout`/`error`/`stuck`
  log appears in the window. The operator had to manually enqueue a message to break it.

Important scoping correction to the original diagnosis: a watchdog **does** exist
(`Session.Server`'s idle timer), but it is the **worker-grade 5-minute byte-idle default**
applied unchanged to orchestrator turns — too coarse to recover an interactive
orchestrator turn before an operator intervenes. That is the defect this plan fixes.

## Problem Statement
Orchestrator turns run through the exact same `Session.Server` runtime as workers and
inherit its idle-watchdog default of `idle_ms: 300_000` (5 minutes). `Orchestrator.Server`
passes **no** `idle_ms` override when it starts the session. A worker doing a long build
may legitimately be byte-silent for minutes; an **interactive orchestrator turn** that is
byte-silent for minutes is dead. So a stalled orchestrator turn is not surfaced/recovered
for a full 5 minutes — long enough that an operator nudges first, producing the perceived
"silent hang with no watchdog."

## Solution Statement
Give orchestrator turns their own, **shorter, configurable** idle watchdog, reusing the
existing — and already-tested — idle-timeout recovery path end to end. No new mechanism:

1. Add a `:turn_idle_ms` key to the `:orchestrator` config (default `120_000` = 2 min),
   documented and overridable per env.
2. In `Orchestrator.Server.handle_continue(:launch, …)`, thread `idle_ms:
   orchestrator_idle_ms()` into the `Session.Supervisor.start_session/1` opts (the session
   already honors an `idle_ms` opt — `cfg_value(opts, cfg, :idle_ms, 300_000)` at
   `session/server.ex:148`, proven by `server_test.exs:63`).

The recovery wiring is unchanged and already correct: on the (now sooner) idle expiry the
session emits `%Event.Error{reason: :idle_timeout, retryable: true}` (`session/server.ex:374`),
which the orchestrator turn process consumes (`orchestrator/server.ex:264`) →
`flush(:error)` → `{:stop, :normal}`; the `Queue` monitors that per-turn pid and dequeues
the next item on `:DOWN`. The Error also streams to the console feed (same dispatch path
all orchestrator events use), so the operator sees `idle timeout` instead of a silent
hang. We are only making that path fire promptly for orchestrator turns and surfacing it.

This is surgical (one config key + one opt threaded), preserves the nil-vs-error and
single-carrier invariants, and introduces no auto-retry (a resumed CLI session that
stalled is surfaced and the turn ends cleanly — the operator/queue decides next, matching
the diagnosis's "surface 'stalled' to the operator" option).

## Steps to Reproduce
1. Start the app (`scripts/pg.sh start`, then `mix phx.server`) and open
   `http://localhost:4000`.
2. Run an orchestrator turn on a harness/provider whose streaming response can stall
   mid-generation (observed: pi / zai / glm-5.2) — e.g. via the holding-pattern
   auto-resume after a worker completes.
3. Observe the orchestrator card/queue stuck `:running` (Busy) with no new output for
   minutes; no `idle timeout`/error row appears on the feed.
4. Only an operator message breaks the stall.

Deterministic reproduction (Tidewave `project_eval` / ExUnit): start an orchestrator turn
whose harness `command/1` spawns a hung child that emits nothing (`{"sleep", ["10"], [],
…}`), leave `turn_idle_ms` at the worker-grade default, and observe no terminal event for
5 minutes. Tidewave `get_logs` over the window shows no `idle_timeout` until 300 s elapse;
`execute_sql_query` on `orchestrators` shows the row stuck `status = 'running'`.

## Root Cause Analysis
- `Orchestrator.Server.handle_continue(:launch, …)` (`lib/repo_builder/orchestrator/server.ex:191-211`)
  builds the session opts and calls `Session.Supervisor.start_session/1` with **no**
  `idle_ms` key.
- `Session.Server.build_state/3` therefore falls back to
  `cfg_value(opts, cfg, :idle_ms, 300_000)` (`lib/repo_builder/session/server.ex:148`) —
  the 5-minute worker default. The timer is armed at spawn (`arm_idle/1`,
  `session/server.ex:609-610`, called at `:310`) and reset on **every** stdout chunk
  (`reset_idle/1` at `session/server.ex:345-346`).
- On expiry, `handle_info(:idle_timeout, …)` (`session/server.ex:374-388`) stops the child
  and dispatches `%Event.Error{reason: :idle_timeout, retryable: true}`, then `{:stop,
  :normal}`. `Orchestrator.Server.handle_info({:harness_event, %Event.Error{}}, …)`
  (`orchestrator/server.ex:264-267`) flushes `:error` and stops; the `Queue` (which
  `Process.monitor`s the per-turn pid) dequeues the next item on `:DOWN`.
- The recovery chain is correct but only fires after **5 minutes of byte silence** for an
  orchestrator turn. Because an interactive orchestrator turn should be responsive on the
  order of seconds, a multi-minute byte-stall is effectively a silent hang: the operator
  intervenes long before the watchdog. The fix is to give orchestrator turns a shorter,
  configurable idle window so the existing recovery fires promptly and visibly.
- (Acknowledged, out of scope) A stream that trickles keep-alive bytes without completing
  a frame would keep resetting the byte-idle timer regardless of threshold; that
  progress-aware variant and the separate ~51 s wake→turn-start scheduling latency are
  distinct follow-ups — see Notes.

## Relevant Files
Use these files to fix the bug:

- `lib/repo_builder/orchestrator/server.ex` — **fix site.** `handle_continue(:launch, …)`
  (`:186-220`) starts the orchestrator session with no `idle_ms`. Add an
  `@spec`'d private `orchestrator_idle_ms/0` (reads `:orchestrator` config, default
  `120_000`) and thread `idle_ms: orchestrator_idle_ms()` into the
  `Session.Supervisor.start_session/1` opts. The terminal handlers (`Done` `:255`, `Error`
  `:264`) and `flush/2` (`:293`) already perform clean recovery — no change.
- `config/config.exs` — `:orchestrator` config block (`:274-288`). Add
  `turn_idle_ms: 120_000` with a comment explaining the orchestrator-vs-worker rationale.
- `lib/repo_builder/session/server.ex` — read-only confirmation: `idle_ms` is an accepted
  start opt (`build_state/3` `:148`, `cfg_value/4` `:156`); the idle timer arms/resets
  (`:310`, `:345-346`, `:609-616`) and emits `%Event.Error{reason: :idle_timeout,
  retryable: true}` on expiry (`:374-388`). No change.
- `lib/repo_builder/orchestrator/queue.ex` — read-only: the `Queue` monitors each per-turn
  pid and dequeues on `:DOWN`, so the (sooner) turn termination re-engages the queue. No
  change.
- `config/test.exs` — `:orchestrator` test block (`:109-118`). Add `turn_idle_ms` for
  config parity; the new tests still override it per-scope to a tiny value. Optional.
- `test/repo_builder/session/server_test.exs` — reference for the hung-child idle-timeout
  pattern (`:63-77`: Mox `command/1` → `{"sleep", ["10"], …}`, `normalize/2` → `:skip`,
  `idle_ms: 100`). Mirror this for the orchestrator-level test.
- `test/support/session_case.ex` — `register_harness/2` Mox seam + global sandbox; the base
  test harness registry (`config/test.exs:51-95`) registers `"fake"` as `orchestrating:
  true`, so the orchestrator can be pointed at a hung Mock.
- `BUILD_PROMPT.md` — §3 typed style (preserve `@spec`s), §6 session runtime (idle
  watchdog), §9 LiveView dashboard/feed conventions for the UI proof.

### New Files
- `test/repo_builder/orchestrator/turn_idle_timeout_test.exs` — `RepoBuilder.SessionCase`,
  `async: false`. Proves a hung orchestrator turn surfaces `idle_timeout` and recovers
  within the (short, test-overridden) orchestrator idle window (fails before the fix —
  with no override the turn would not time out for 300 s — passes after).
- `test/repo_builder_web/live/test_orchestrator_turn_stall_test.exs` — `Phoenix.LiveViewTest`
  integration proof that the console surfaces the `idle timeout` Error row (and the
  orchestrator is no longer stuck Busy/running) after a stalled turn, instead of hanging.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Reproduce and confirm the root cause
- Read `BUILD_PROMPT.md` §6 (session runtime / idle watchdog) and §9 (LiveView feed).
- Confirm via Tidewave `get_logs` (the original window, if still available) that no
  `idle_timeout`/error surfaced during the ~3-minute stall, and via `execute_sql_query`
  that the orchestrator row sat `status = 'running'`.
- Confirm the wiring by reading: `orchestrator/server.ex:186-220` (no `idle_ms` passed),
  `session/server.ex:148` (`idle_ms` default `300_000`), `session/server.ex:374-388`
  (`Event.Error{:idle_timeout}` on expiry), and `orchestrator/server.ex:264-267`
  (orchestrator consumes the Error → `flush(:error)` → stop). Optional `project_eval`:
  start an orchestrator turn against a hung Mock harness with the default idle and observe
  no terminal event before 300 s.

### 2. Add the orchestrator idle-timeout config knob
- In `config/config.exs`, inside `config :repo_builder, :orchestrator, …` (`:274-288`), add
  `turn_idle_ms: 120_000` with a comment: orchestrator turns are interactive, so they get a
  shorter idle watchdog than the worker-grade `:session` `idle_ms` (5 min); a byte-silent
  orchestrator turn beyond this is treated as stalled and surfaced/recovered.
- In `config/test.exs`, add `turn_idle_ms: 120_000` to the `:orchestrator` block for parity
  (tests override per-scope). Optional but keeps config shape consistent across envs.

### 3. Thread the orchestrator idle timeout into the session start opts (the fix)
- In `lib/repo_builder/orchestrator/server.ex`, add an `@spec`'d private
  `orchestrator_idle_ms/0`:
  `Application.get_env(:repo_builder, :orchestrator, [])[:turn_idle_ms] || 120_000`
  (`@spec orchestrator_idle_ms() :: pos_integer()`), placed beside the other config readers
  (e.g. near `mcp_base_url/0`).
- In `handle_continue(:launch, {%State{} = state, orchestrator})` (`:186-211`), add
  `idle_ms: orchestrator_idle_ms()` to the `opts` keyword list passed to
  `Session.Supervisor.start_session/1`. Change nothing else — the terminal `Error`/`Done`
  handlers and `flush/2` already recover the turn and free the queue.
- Keep all `@spec`s precise; compile under `--warnings-as-errors`, the set-theoretic type
  checker, and Dialyzer.

### 4. Add the orchestrator-level idle-timeout integration test (fails before, passes after)
- Create `test/repo_builder/orchestrator/turn_idle_timeout_test.exs`
  (`use RepoBuilder.SessionCase, async: false`):
  - `setup`: override `Application.put_env(:repo_builder, :orchestrator, …)` with a tiny
    `turn_idle_ms` (e.g. `100`) for the scope (restore on exit). Keep `default_harness:
    "fake"`.
  - `register_harness("fake", SomeMock)` where the Mock's `command/1` returns a hung child
    that emits nothing — `{"sleep", ["10"], [], %{harness: :fake}}` — and `normalize/2`
    returns `:skip` (mirror `server_test.exs:63-77`).
  - Create/fetch the default orchestrator with a model set so `ensure_model/1` passes
    (`Orchestrators.get_or_create_default()` then set a model, or insert one directly with
    `harness: "fake"`, a non-blank `model`).
  - Subscribe to the turn's event topic: derive `agent_id` from
    `Orchestrator.Server.start_turn/2`'s `{:ok, pid, agent_id}` and
    `Phoenix.PubSub.subscribe(RepoBuilder.PubSub, "agent:#{agent_id}:events")` BEFORE the
    child emits (or subscribe in a way that races safely; the idle window is short but
    non-zero).
  - **Test A (stall recovers):** start the turn; `assert_receive {:harness_event,
    %Event.Error{reason: :idle_timeout, retryable: true}}, 2_000`; `Process.monitor` the
    turn pid and `assert_receive {:DOWN, …}`; then assert `Orchestrators.fetch(orch_id)`
    shows `status: :error` (the turn flushed). Confirm this FAILS before the fix (with no
    `idle_ms` threaded, the 100 ms override is ignored and no timeout arrives in 2 s).
  - **Test B (regression guard — normal turn unaffected):** register `"fake"` back to the
    real `RepoBuilder.Harness.Fake` (completing sequence), start a turn, and assert it ends
    with `%Event.Done{}` and the orchestrator flushes `status: :idle` — no spurious
    idle_timeout.

### 5. Add the LiveView UI proof (console surfaces the stall instead of hanging)
- Create `test/repo_builder_web/live/test_orchestrator_turn_stall_test.exs`
  (`use RepoBuilderWeb.ConnCase, async: false`, `import Phoenix.LiveViewTest`), modeled on
  the existing orchestrator console tests:
  - `setup`: tiny `turn_idle_ms` app-env override (restore on exit); `register_harness`
    the orchestrator harness to a hung Mock (as in step 4); ensure the default orchestrator
    has a model.
  - `live(conn, ~p"/")`; start a stalled orchestrator turn (`Orchestrator.Server.start_turn/2`
    or via the command form so the queue path runs); `wait` for the console feed to render
    the `idle timeout` Error row (the orchestrator Error streams to the global feed like
    every other orchestrator event).
  - Assert the orchestrator is no longer stuck Busy/running (e.g. the queue/status
    indicator is not `Busy`, or the orchestrator row status is not `:running`) — proving the
    turn ended rather than hanging.
  - Optionally capture a screenshot of `http://localhost:4000` via Tidewave Web vision mode
    (or Playwright MCP) showing the surfaced `idle timeout` row as visual proof.

### 6. Run the full validation suite
- Run every command in **Validation Commands**; all green, zero regressions. Re-run the
  Tidewave/`project_eval` reproduction to confirm a hung orchestrator turn now surfaces
  `idle_timeout` within the configured window instead of hanging.

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- `mix test test/repo_builder/orchestrator/turn_idle_timeout_test.exs` — the orchestrator
  idle-timeout integration test (Test A fails before the fix, passes after; Test B guards
  the normal-turn path).
- `mix test test/repo_builder_web/live/test_orchestrator_turn_stall_test.exs` — the LiveView
  proof that the console surfaces the stall and the orchestrator is no longer hung.
- `mix test test/repo_builder/orchestrator/ test/repo_builder/session/` — orchestrator
  (queue/holding-pattern/server) and session suites stay green (no regression in the idle
  path or turn lifecycle).
- `mix compile --warnings-as-errors` — clean compile; gradual set-theoretic type checker
  and `warnings_as_errors` pass.
- `mix test --warnings-as-errors` — full ExUnit suite, zero failures.
- `mix format --check-formatted` — formatting clean.
- `mix credo --strict` — lint, including the every-public-function-has-`@spec` rule.
- `mix dialyzer` — no new contract warnings; no stale ignore filters.

## Notes
- **No new dependencies, no migration.** One config key (`:orchestrator` `turn_idle_ms`)
  plus one opt (`idle_ms:`) threaded from `Orchestrator.Server` into the existing session
  start path. The idle-timeout → `Event.Error{retryable: true}` → `flush(:error)` → queue
  dequeue recovery chain already exists and is unchanged.
- **Default `120_000` ms (2 min)** is conservative: the idle timer resets on every streamed
  frame (thinking/text/tool/usage), so a genuinely-working orchestrator turn never trips
  it; only multi-minute byte silence (the stall) does. The observed 3-minute stall would
  surface at ~2 minutes and recover automatically. The value is configurable per env so an
  operator can raise it for unusually long single-turn reasoning.
- **No auto-retry.** A resumed CLI session that stalled is surfaced and the turn ends
  cleanly (status `:error`, a visible `idle timeout` feed row); the operator or the queue's
  next item decides what happens next. This matches the diagnosis's "surface 'stalled' to
  the operator" recommendation and avoids re-stalling / double-billing a bad resume.
- **Out of scope (documented, separate follow-ups):**
  - *Progress-aware watchdog:* a stream that trickles keep-alive bytes without completing a
    frame keeps resetting the byte-idle timer regardless of threshold. Resetting only on
    *meaningful* normalized events (not raw bytes) is a larger change to the line/normalize
    path — file separately.
  - *~51 s wake→turn-start latency* (15:16:47 → 15:17:38 in the incident) is a
    `Orchestrator.Queue` scheduling concern, distinct from the generation stall.
  - *zai/glm-5.2 transport* silently-dropped/stalled SSE responses — a harness-transport
    investigation, distinct from this platform-side watchdog fix.
  - The duplicate-create warnings (`orchestrator_id has already been taken` → now
    `duplicate or invalid name`) noted as a secondary anomaly were already addressed by the
    worker-spawn duplicate-name message fix; the underlying duplicate-name *retry/idempotency*
    is a separate issue.
- **Tidewave** is the primary reproduction/verification tool here: `project_eval` to drive a
  hung orchestrator turn, `get_logs` to confirm `idle_timeout` now surfaces within the
  window, and `execute_sql_query` to confirm the orchestrator row no longer sits stuck at
  `status = 'running'`.
