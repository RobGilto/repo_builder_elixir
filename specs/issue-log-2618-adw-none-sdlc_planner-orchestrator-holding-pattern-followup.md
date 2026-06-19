# Bug: Orchestrator hangs in its holding pattern after a dispatched worker returns (never follows up)

## Metadata
issue_number: `log-2618`
adw_id: `-`
issue_json: `log`

## Bug Description
Between log-2618 and log-2726 the orchestrator dispatched a worker agent to gather
information. The worker ran to completion and reached a terminal state, but the
orchestrator's "holding pattern" never woke back up. It sat idle indefinitely — it
never called `check_agent_status` on the returned worker, never reported back, and
never decided next steps. The operator had to manually send another message to
un-stick it.

Expected behaviour: when a worker the orchestrator dispatched returns, and the
orchestrator is otherwise idle, the orchestrator should be re-engaged exactly once to
review the returned work and decide what to do next — without polling on a timer
(no spam) and without ever forgetting that work is outstanding (no amnesia).

Actual behaviour: the wakeup signal is broadcast and received by the turn queue, then
silently dropped, so the orchestrator hangs forever.

## Problem Statement
The orchestrator is a **turn-based** agent: one turn == one harness CLI invocation,
serialized through `RepoBuilder.Orchestrator.Queue`. After it dispatches async work
(`command_agent` / `start_adw` return immediately) the turn ends — by design, per the
system prompt ("END YOUR TURN… Do NOT sit and poll"). The only thing that can start a
new turn is (a) an operator message, or (b) the queue's **holding pattern**, which is
supposed to enqueue one low-priority `auto_resume` turn when a dispatched worker
returns.

The holding pattern is fully implemented in `Queue` (`maybe_auto_resume/2`,
`start_auto_resume/2`) and the wakeup source exists
(`Session.Server.maybe_emit_worker_terminal/2` →
`Dashboard.broadcast_worker_terminal/2` → `{:worker_terminal, info}` on
`orchestrator:<id>:workers`, which `Queue` subscribes to at init). But it never fires,
for two independent reasons that combine to a permanent hang.

## Solution Statement
Two surgical changes, matching the event-driven follow-up pattern (push wakeup on a
terminal event, coalesced to a single resume turn — no timer/poll), confirmed against
the reference orchestrator and current external guidance on event-driven multi-agent
systems (see Notes):

1. **Enable the holding pattern by default.** Flip
   `:auto_resume_on_worker_return` to `true` in `config/config.exs` so an idle
   orchestrator is re-engaged when a worker returns. (`config/test.exs` keeps it
   explicitly `false`; `SessionCase` already flips it per-scope where needed.)

2. **Make the wakeup robust to mid-turn returns (the real "scratchpad").** Add a
   minimal in-memory `pending_resume?` flag to `Queue.State`. Today
   `maybe_auto_resume/2` only acts when the queue is *fully idle* (`current == nil`);
   if a worker returns **while the orchestrator turn is still in flight** (the common
   case — the worker finishes while the orchestrator is still narrating its dispatch),
   the signal is dropped and nothing reschedules. The flag records "a worker returned,
   owe a resume" and is consumed when the queue next drains to idle, guaranteeing
   exactly one follow-up turn. Bursts coalesce to one flag; operator messages still
   front-run and clear it.

This keeps the existing anti-spam guarantees (event-driven, coalesced, no polling) and
closes the amnesia hole, so the orchestrator always follows up but never loops.

## Steps to Reproduce
1. Ensure the orchestrator uses a harness that actually dispatches a worker session
   (Claude/pi, or the Fake harness via `SessionCase` with auto-resume forced on).
2. Send the orchestrator a message that makes it `command_agent` (or `start_adw` via
   the adapter path) a worker to fetch information.
3. Let the worker run to a terminal `Event.Done`/`Event.Error`.
4. Observe: with the shipped default config (`auto_resume_on_worker_return: false`)
   the orchestrator never takes another turn — it hangs. Even with the flag enabled,
   if the worker returns *before* the orchestrator's dispatch turn has emitted `Done`,
   the resume is still dropped and it hangs.

## Root Cause Analysis
**Primary cause — feature gated off by default.**
`RepoBuilder.Orchestrators.auto_resume?/0` (`lib/repo_builder/orchestrator.ex:37-38`)
reads `config()[:auto_resume_on_worker_return] == true`, and `config/config.exs:281`
ships it as `false`. So in `Queue.maybe_auto_resume/2`
(`lib/repo_builder/orchestrator/queue.ex:262-268`) the first `cond` branch
`not Orchestrators.auto_resume?() -> state` returns the state unchanged — the
`{:worker_terminal, info}` message is received (`queue.ex:212-214`) and then silently
discarded. Nothing ever enqueues a follow-up turn, so the orchestrator hangs.

**Secondary cause — mid-turn returns are lost (amnesia even when enabled).**
`maybe_auto_resume/2` has a guard clause `maybe_auto_resume(%State{} = state, _info)`
(`queue.ex:270`) that ignores the signal whenever `current != nil` (a turn is in
flight). A worker very often reaches `Event.Done` while the orchestrator's own
dispatch turn is still running. That signal is dropped, the turn then ends, `advance/1`
finds the FIFO empty (`queue.ex:222-240`), the queue goes idle with `current: nil`, and
nothing is scheduled — a permanent hang. There is no record that a return was owed:
the queue has no "outstanding work" memory across the turn boundary.

**Why polling is not the fix.** The wakeup is already a clean push: the worker's
`Session.Server` emits a terminal broadcast (`session/server.ex:506-534`) that the
`Queue` consumes. The right fix preserves that event-driven design (no timer, no
`check_agent_status` poll loop — exactly what the system prompt forbids) and only adds a
one-bit memory so a return that arrives at an inconvenient moment is honoured once.

## Relevant Files
Use these files to fix the bug:

- `lib/repo_builder/orchestrator/queue.ex` — the turn-serialization GenServer and the
  holding pattern. Holds `maybe_auto_resume/2`/`start_auto_resume/2` (lines 258-294),
  the `:worker_terminal` handler (212-214), `advance/1` (222-240), the `:DOWN` handler
  (195-205), and `State` (49-63). **Both fixes land here** (add `pending_resume?` to
  `State`, set it when a return arrives mid-turn or while suppressed, consume it when
  the queue drains to idle).
- `lib/repo_builder/orchestrator.ex` — `auto_resume?/0` (37-38) reads the config flag.
  No code change required, but it is the gate the config flip turns on.
- `config/config.exs` — line 281 `auto_resume_on_worker_return: false`. **Flip to
  `true`** so the holding pattern is on by default.
- `config/test.exs` — lines 109-115 set `auto_resume_on_worker_return: false`
  deliberately so the suite is deterministic; `SessionCase` flips it on per-scope.
  Keep it `false` here; new queue tests drive the flag/starter directly.
- `lib/repo_builder/session/server.ex` — `maybe_emit_worker_terminal/2` (506-536) is
  the wakeup source. Verified to fire for both `command_agent` workers and
  `start_adw` adapter-path workers (both carry `orchestrator_id` + `agent_db_id`). No
  change; documented here so the fix isn't duplicated upstream.
- `lib/repo_builder/dashboard.ex` — the `orchestrator:<id>:workers` pub/sub seam
  (`broadcast_worker_terminal/2` 187-198, `subscribe_orchestrator_workers/1` 175-177).
  No change.
- `lib/repo_builder/orchestrator/system_prompt.ex` — lines 95-107 describe the holding
  pattern as conditional ("if that is enabled"). **Update wording** to state it is on
  by default, so the model's mental model matches runtime behaviour.
- `test/support/session_case.ex` — already enables auto-resume for session-scope tests;
  reference for how to force the flag in a test.

### New Files
- `test/repo_builder/orchestrator/queue_holding_pattern_test.exs` — focused unit test
  for the queue's holding pattern using the pluggable `starter` (deterministic, no real
  harness): proves a mid-turn worker return schedules exactly one resume after the turn
  drains, that a burst coalesces to one resume, and that an operator message front-runs
  and clears a pending resume.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Reproduce and confirm the root cause via Tidewave (runtime intelligence)
- With the app running (`scripts/pg.sh start` first if needed), use Tidewave
  `project_eval` to confirm the gate is off: evaluate
  `RepoBuilder.Orchestrators.auto_resume?()` → expect `false`.
- Use `project_eval` to drive a `Queue` with a controllable `starter` (a function that
  records calls) and reproduce the mid-turn drop: enqueue an operator turn, send the
  queue a `{:worker_terminal, %{name: "w", ok?: true}}` while `current != nil`, finish
  the turn, and observe no second `starter` call. Capture this as the failing baseline.
- Note the reproduction in the PR/commit description.

### 2. Add the `pending_resume?` memory to `Queue` (anti-amnesia)
- In `lib/repo_builder/orchestrator/queue.ex`, add `field :pending_resume?, boolean()`
  to the `State` typedstruct (default `false`; keep `enforce: true` — set it in `init/1`).
- In `init/1`, initialise `pending_resume?: false`.
- Update `maybe_auto_resume/2`:
  - When `current == nil`, auto-resume is enabled, and the queue is empty → start the
    resume (as today) and ensure `pending_resume?` is cleared.
  - When auto-resume is enabled but the queue is **busy** (`current != nil`) or
    non-empty → set `pending_resume?: true` (record the owed follow-up) instead of
    silently dropping. Coalesce: if already `true`, leave it `true`.
  - When auto-resume is **disabled** → unchanged (return state; no flag set), so the
    behaviour is fully opt-out via config.
- Keep `@spec`s precise and tagged; preserve the `TypedStruct`/`@enforce` style.

### 3. Consume the owed resume when the queue drains to idle
- In `advance/1` (and/or the `:DOWN` handler at `queue.ex:195-205`): after the FIFO is
  found empty and `current` is `nil`, if `pending_resume?` is `true` and auto-resume is
  enabled, clear the flag and start exactly one `auto_resume` turn (reuse
  `start_auto_resume/2`; the burst already coalesced to one flag). Guard so this can
  never recurse into a loop (the flag is cleared before starting; a fresh return is
  required to set it again).
- Ensure operator enqueue still wins: in the existing operator path
  (`append_with_priority/2`, `queue.ex:301-307`) also clear `pending_resume?` so an
  operator message supersedes the owed auto-resume (parity with how it drops pending
  `auto_resume` queue items today).
- Keep the auto-resume prompt informative (`auto_resume_prompt/1`); optionally include
  the returned worker name(s) so the resumed turn knows which worker to review.

### 4. Enable the holding pattern by default
- In `config/config.exs:281`, change `auto_resume_on_worker_return: false` to `true`.
  Update the adjacent comment (278-280) to say it now defaults on.
- Leave `config/test.exs:115` as `false` (deterministic suite); confirm `SessionCase`
  still force-enables it where session-scope tests rely on it.

### 5. Align the system prompt with the new default
- In `lib/repo_builder/orchestrator/system_prompt.ex` (95-107), reword the holding
  pattern section so it states the orchestrator **will** be re-engaged automatically
  when a dispatched worker returns (drop the "if that is enabled" conditional), and
  reaffirm "do NOT poll — you'll be woken once per return."
- Update `test/repo_builder/orchestrator/system_prompt_test.exs` if it asserts on the
  old wording.

### 6. Add the queue holding-pattern unit test (fails before, passes after)
- Create `test/repo_builder/orchestrator/queue_holding_pattern_test.exs`.
- Use a controllable `starter` injected via `start_link(orchestrator_id: ..., starter: fn _, prompt -> ... end)`
  that sends the spawned per-turn pid back to the test (so the test controls when a
  turn "finishes" by stopping that pid) and records each `(prompt)` it is asked to
  start. Force `auto_resume_on_worker_return: true` for the test (via
  `Application.put_env` in `setup`, restored in `on_exit`).
- Cases:
  1. **Mid-turn return is honoured:** start an operator turn, send
     `{:worker_terminal, %{name: "w1", ok?: true}}` while the turn is in flight, then
     stop the turn pid; assert a second turn starts with an `:auto_resume` prompt
     mentioning the worker. (This fails on the current code.)
  2. **Burst coalesces:** two `{:worker_terminal, …}` mid-turn → after the turn drains,
     exactly **one** auto-resume turn starts.
  3. **Operator front-runs:** with a pending resume owed, an operator `enqueue/2`
     supersedes it (no extra auto-resume turn; `pending_resume?` cleared).
  4. **Disabled is opt-out:** with the flag `false`, a worker return enqueues nothing.

### 7. (UI proof) Console integration test for re-engagement
- The console renders the queue snapshot (`Dashboard.broadcast_orchestrator_queue/2`).
  Add `test/repo_builder_web/live/test_orchestrator_holding_pattern_test.exs`: drive a
  Fake-harness orchestrator turn that dispatches a worker (via `SessionCase`-style
  setup with auto-resume on), let the worker reach terminal, and assert via
  `Phoenix.LiveViewTest` that the console shows a follow-up/auto-resume turn (the queue
  becomes busy again / an `auto_resume` lane appears) rather than staying idle.
- Optionally capture a screenshot of `http://localhost:4000` via Tidewave Web vision
  mode (or Playwright MCP) as visual proof the orchestrator re-engages.

### 8. Run the full validation suite
- Run every command in `Validation Commands` and ensure all are green with zero
  regressions.

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- `mix test test/repo_builder/orchestrator/queue_holding_pattern_test.exs` — the new
  queue unit test (the mid-turn case fails before the fix, passes after).
- `mix test test/repo_builder_web/live/test_orchestrator_holding_pattern_test.exs` —
  the LiveView re-engagement proof.
- `mix test test/repo_builder/orchestrator/ test/repo_builder/session/` — orchestrator
  + session suites (queue, server, holding pattern, broadcast feed) stay green.
- `mix compile --warnings-as-errors` — clean compile; gradual set-theoretic type
  checker and `warnings_as_errors` pass.
- `mix test --warnings-as-errors` — full ExUnit suite, zero failures.
- `mix format --check-formatted` — formatting.
- `mix credo --strict` — lint, including the every-public-function-has-`@spec` gate.
- `mix dialyzer` — no new contract warnings; no stale ignore filters.

## Notes
- **No new dependencies.** The fix is config + a one-bit state field + its drain-time
  consumer; all within existing modules.
- **Design pattern (firecrawl + reference).** The chosen approach is the
  *event-driven, coalesced single-resume* pattern: a worker's terminal event pushes one
  wakeup (no timer, no polling), and a minimal queue-side memory (`pending_resume?`)
  guarantees the wakeup is honoured exactly once even if it arrives mid-turn — avoiding
  both amnesia (never following up) and spam (re-checking on a loop). This matches the
  external guidance surfaced via firecrawl on event-driven multi-agent systems
  (Confluent, "Four Design Patterns for Event-Driven, Multi-Agent Systems"; DEV
  Community, "Event-Driven AI Agents: Patterns That Scale"; Spring AI "Subagent
  Orchestration"), all of which favour terminal-event signalling + coalescing over
  polling.
- **Contrast with the reference** `tactical-agentic-coding/.../orchestrator_3_stream`:
  that orchestrator deliberately does **no** autonomous follow-up — it is fire-and-forget
  + pull-based reconciliation on the *next user turn*, with a "don't be eager, monitor
  sparingly" prompt policy and conversation memory via SDK session resume as the
  "scratchpad". It is structurally immune to hanging only because it never promises
  autonomous follow-up. This repo's design *does* promise it (the holding pattern), so
  the correct fix is to honour that promise robustly rather than remove it. The
  reference is the source of the anti-spam discipline we keep (coalesce to one resume,
  operator messages always win, prompt tells the model not to poll).
- **Verified non-issues:** the wakeup source fires for both worker dispatch paths
  (`command_agent` and `start_adw` adapter path both create an agent row with
  `orchestrator_id`). The Fake-harness `start_adw_via_engine` WorkflowEngine fallback
  does **not** create an agent row and so will not emit a worker-terminal — out of scope
  for this bug (it is the test-only deterministic path), but worth noting if a future
  issue wants ADW-engine runs to also re-engage the orchestrator.
- **Loop-safety:** `pending_resume?` is cleared *before* starting the resume turn and is
  only re-set by a *new* `{:worker_terminal, …}`, so an auto-resume turn that itself
  dispatches no new workers cannot retrigger itself — no runaway loop.
