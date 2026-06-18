# Feature: Orchestrator Message Queuing & Holding Pattern

## Metadata
issue_number: `queue`
adw_id: `msgqueue`
issue_json: `{"title":"Orchestrator message queuing","body":"For the orchestrator require message queuing: when the orchestrator is in a process and I send another message I want that message to queue and kick off once the orchestrator finishes dispatching of agents. The orchestrator should have a holding pattern when agents come back to them, but should be able to do parallel work the user provides. See /data/1.Projects/tactical-agentic-coding/tac-14/ for insights."}`

## Feature Description
Today every operator message sent to the orchestrator immediately calls
`RepoBuilder.Orchestrator.Server.run_turn/2`, which spawns a brand-new per-turn
`Orchestrator.Server` that resumes the SAME durable CLI session (`--resume <session_id>`
for Claude, `--session` for pi). If a turn is already in flight, a second message
starts a **concurrent** turn that resumes the same session id at the same time —
two harness processes racing to write the same CLI session store. There is no
serialization, no operator visibility into "a message is waiting", and no way to
let the orchestrator finish dispatching its current batch before the next
instruction lands.

This feature introduces a **per-orchestrator FIFO message queue** that serializes
turns:

1. **Queue while busy.** When the orchestrator is mid-turn (running a harness
   session, dispatching agents), a new operator message is appended to a FIFO
   queue instead of starting a racing turn.
2. **Kick off on turn completion.** As soon as the current turn finishes
   dispatching (the orchestrator harness session emits `Done`/`Error` and the
   per-turn `Orchestrator.Server` stops), the next queued message is dequeued and
   run as the next turn — resuming the same session so context carries forward.
3. **Parallel work, not blocking.** Because each turn ends after the orchestrator
   has *dispatched* its workers (workers run in the background via their own
   `Session.Server`s), queued operator messages flow through as fast as the
   orchestrator finishes each dispatch round. The orchestrator never blocks the
   queue waiting for workers — the workers run in parallel while the next operator
   message is processed.
4. **Holding pattern on agent return.** When a worker the orchestrator dispatched
   reaches a terminal state ("comes back"), and the orchestrator is otherwise idle
   with an empty operator queue, an automatic low-priority "resume" turn is
   enqueued so the orchestrator can review the returned work and decide next steps
   — its holding pattern. Operator messages always take precedence over these
   auto-resume turns.

This mirrors the intent of the tac-14 reference
(`/data/1.Projects/tactical-agentic-coding/tac-14/`) — fire-and-forget background
dispatch (`command_agent` returns "dispatched … execute in background"), a
busy/idle state machine, and a "sleep + check" holding loop — but replaces
tac-14's *preempt-and-refocus* model (newest message interrupts the running turn)
with the **FIFO queue** the operator explicitly asked for (messages queue and run
in order after the current dispatch completes).

## User Story
As an operator driving the orchestration console
I want messages I send while the orchestrator is busy to queue and run in order once it finishes dispatching the current batch
So that I can pipeline several instructions without racing the orchestrator's session or losing messages, while my agents keep working in parallel in the background.

## Problem Statement
- A second operator message during an in-flight turn spawns a **concurrent**
  `Orchestrator.Server` that resumes the same CLI `session_id` simultaneously —
  a data race on the harness session store (Claude `--resume`, pi `--session`),
  with undefined ordering and possible context corruption.
- There is no FIFO ordering: rapid messages are not guaranteed to be applied in
  the order the operator sent them.
- The operator has no feedback that a message is queued/waiting, and no way to
  cancel a queued message before it runs.
- When a dispatched worker finishes, nothing re-engages the orchestrator; the
  operator must manually prompt it to review results (no holding pattern).

## Solution Statement
Introduce a long-lived, per-orchestrator **`RepoBuilder.Orchestrator.Queue`**
GenServer (registered by `orchestrator_id`, started on demand under a new
`DynamicSupervisor`) that owns the serialization:

- It is the single entry point for running turns: the console calls
  `Queue.enqueue/2` (which replaces the direct `Orchestrator.Server.run_turn/2`
  call in `ConsoleLive`).
- It holds an in-memory FIFO of pending operator prompts plus the currently
  in-flight turn. When idle it starts a turn immediately; when busy it appends.
- It launches each turn via a refactored `Orchestrator.Server.start_turn/2` that
  returns `{:ok, pid, agent_id}`, **monitors** that pid, and on the monitor's
  `:DOWN` (the per-turn server stops on `Done`/`Error`) dequeues and starts the
  next item — preserving FIFO order and guaranteeing only ONE turn resumes the
  session at a time.
- It broadcasts queue depth/contents over PubSub so the console can render a
  "queued messages" strip (with per-message cancel) and a busy/queued badge.
- A `:auto_resume_on_worker_return` config toggle wires a "holding pattern": a
  per-orchestrator worker-terminal PubSub signal lets the Queue enqueue a
  low-priority auto-resume turn when (and only when) it is idle and the operator
  queue is empty.

The orchestrator system prompt is updated so the model knows operator messages
sent mid-work are queued and delivered as its next turn — it should finish
dispatching the current batch and **end its turn** (report "kicked off the
workers") rather than blocking in a long monitor loop, so the queue keeps flowing
and workers run in parallel.

This is purely additive: `run_turn/2` is kept (now delegating to the queue) so
existing tests and callers keep working; no schema changes are strictly required
for the core queue (it is runtime state, matching tac-14's in-memory model and
OTP norms).

## Relevant Files
Use these files to implement the feature:

- `lib/repo_builder/orchestrator/server.ex` — the per-turn `:temporary` GenServer.
  Refactor its private `start_turn/2` into a public `start_turn/2` that returns
  `{:ok, pid, agent_id}` so the Queue can monitor the per-turn process; keep
  `run_turn/2` as a thin delegate to the Queue. This is where `set_status` →
  `:running`/`:idle`/`:error` and `Done`/`Error` handling already live (the
  lifecycle the Queue keys off of).
- `lib/repo_builder/orchestrator.ex` (`RepoBuilder.Orchestrators` context) — the
  only `Repo` caller for orchestrators; owns `set_status/2`, `fetch/1`, config
  helpers, and the atomic `metadata` writers. Add queue-config reads here if any
  per-orchestrator queue settings are persisted, and a helper to read the
  `:auto_resume_on_worker_return` flag from `config/0`.
- `lib/repo_builder/orchestrator/tools.ex` — `command_agent/2` returns
  `%{"status" => "dispatched", ...}` and starts the worker `Session.Server`
  (background dispatch). This is the seam that proves "parallel work": after a
  worker is dispatched, the orchestrator turn can end and the next queued message
  runs while the worker keeps going. The holding-pattern signal is emitted when a
  worker owned by this orchestrator reaches a terminal state — wire the emit near
  where worker sessions are started/completed (see `session/server.ex`).
- `lib/repo_builder/orchestrator/system_prompt.ex` — add a "Message queue &
  holding pattern" guidance block so the model finishes dispatching and ends its
  turn (lets the queue flow), and knows follow-up operator messages are queued.
- `lib/repo_builder/session/server.ex` & `lib/repo_builder/session/supervisor.ex`
  — reference patterns for `{:via, Registry, {RegistryName, id}}` registration,
  `DynamicSupervisor.start_child/2`, and broadcasting terminal worker events on
  `agent:<id>:events`. The Queue's registry/supervisor mirror these.
- `lib/repo_builder/application.ex` — supervision tree. Add the new
  `RepoBuilder.OrchestratorQueueRegistry` (unique keys) and
  `RepoBuilder.OrchestratorQueueSupervisor` (DynamicSupervisor) children, after
  PubSub and alongside `RepoBuilder.OrchestratorSupervisor`.
- `lib/repo_builder/dashboard.ex` — the broadcast seam used by the console.
  Add `broadcast_orchestrator_queue/2` (or reuse the orchestrator-updated topic)
  so `ConsoleLive` re-renders the queue strip; mirror the existing
  `broadcast_orchestrator_updated/1` pattern.
- `lib/repo_builder_web/live/console_live.ex` — `run_orchestrator/2` (≈ line
  1075) currently calls `OrchestratorServer.run_turn/2`. Route through
  `Queue.enqueue/2`, handle `{:ok, :started}` vs `{:ok, :queued, position}`,
  add `handle_event("cancel_queued", ...)` and a `handle_info` for the queue
  broadcast, and assign queue state for rendering.
- `lib/repo_builder_web/components/console_components.ex` — add a typed
  `queued_messages/1` function component (the pending-message strip with a
  per-item cancel button and a busy/queued badge), consistent with existing
  console components.
- `config/config.exs` / `config/test.exs` — add the `:orchestrator` config keys:
  `:auto_resume_on_worker_return` (boolean) and optionally `:max_queue_depth`.
  Tests may set a deterministic value.
- `BUILD_PROMPT.md` — authoritative spec; §5 (supervision tree), §6 (session
  runtime), §9 (LiveView dashboard), §3 (typed style). Honor all.
- `ai_docs/typed-elixir-standard.md` — **(always)** the enforced typed standard
  (`@spec` on every public function, `typedstruct`/`@enforce_keys`, precise
  types, `{:ok, t()} | {:error, reason()}` over raising; Credo `@spec` gate +
  Dialyzer).
- `test/repo_builder/orchestrator/server_test.exs` — existing per-turn server
  tests; reference for `SessionCase`/Fake-harness setup and `Done` event flow.
- `test/repo_builder_web/live/test_orchestration_console_test.exs` — existing
  console LiveView test; reference for mounting `/`, driving prompt submit, and
  asserting rendered/streamed output.

### New Files
- `lib/repo_builder/orchestrator/queue.ex` — `RepoBuilder.Orchestrator.Queue`,
  the long-lived per-orchestrator FIFO turn queue GenServer. Public API:
  `enqueue/2`, `cancel/2`, `snapshot/1`, `whereis/1`/`start_or_get/1`, plus
  internal `start_link/1`, `init/1`, `handle_call/3`, `handle_info/2` (monitor
  `:DOWN`, worker-return signal). Holds a `typedstruct` state with
  `:queue` (`:queue.queue/0` of queued-item structs), `:current`
  (`nil | {pid, reference, agent_id}`), and `:orchestrator_id`.
- `test/repo_builder/orchestrator/queue_test.exs` — unit tests for the queue
  state machine (idle→immediate start, busy→enqueue, FIFO dequeue on turn
  completion, cancel, dedupe/overflow, holding-pattern auto-resume gating).
- `test/repo_builder_web/live/test_orchestrator_queue_test.exs` —
  `Phoenix.LiveViewTest` integration test: while the orchestrator is busy,
  submitting a second prompt renders a queued chip; canceling removes it; the
  queued message runs after the current turn finishes.

## Implementation Plan
### Phase 1: Foundation
Stand up the per-orchestrator queue process and its supervision, and make the
per-turn server monitorable, without changing console behavior yet.

- Add `RepoBuilder.OrchestratorQueueRegistry` (unique keys) and
  `RepoBuilder.OrchestratorQueueSupervisor` (`DynamicSupervisor`) to the
  application supervision tree (after PubSub, near `OrchestratorSupervisor`).
- Refactor `Orchestrator.Server`: promote the private `start_turn/2` to a public
  `@spec`'d `start_turn/2` returning `{:ok, pid, agent_id} | {:error, term()}`
  (it already builds the child spec and calls `DynamicSupervisor.start_child/2`).
- Create `RepoBuilder.Orchestrator.Queue` with a `typedstruct` state, `via`
  registration by `orchestrator_id`, and a `start_or_get/1` that starts the child
  under the new DynamicSupervisor or returns the running pid.

### Phase 2: Core Implementation
Implement FIFO serialization, completion-driven dequeue, cancel, and operator
visibility.

- `enqueue/2`: if `current == nil`, validate the orchestrator can run
  (`ensure_orchestrating`/`ensure_model` semantics already in `Server`), start the
  turn via `Server.start_turn/2`, `Process.monitor/1` the pid, store `:current`,
  and return `{:ok, :started}`. Otherwise append a queued item (with a generated
  id + the prompt) and return `{:ok, :queued, position}`.
- `handle_info({:DOWN, ref, :process, _pid, _reason}, state)`: clear `:current`,
  pop the head of the FIFO; if present start it (same path) else go idle (and, if
  enabled, fall through to the holding-pattern check).
- `cancel/2`: remove a queued item by id (head-of-line or middle); the in-flight
  turn is NOT cancelled by this (use the existing `interrupt_agent` path for
  that). Returns `{:ok, snapshot} | {:error, :not_found}`.
- `snapshot/1`: return `%{busy?: boolean, current: agent_id | nil, queued:
  [%{id, preview}]}` for the console.
- Broadcast a queue update via `Dashboard.broadcast_orchestrator_queue/2` on every
  state change (enqueue, dequeue, cancel).
- Update `ConsoleLive.run_orchestrator/2` to call `Queue.enqueue/2` and reflect
  `:started` vs `:queued` (the user message is already pushed to the transcript;
  add a subtle "queued (position N)" affordance for queued ones).
- Add the `queued_messages/1` console component + `cancel_queued` event handler +
  `handle_info` for the queue broadcast in `ConsoleLive`.
- Update `Orchestrator.SystemPrompt` with the queue/holding-pattern guidance block.

### Phase 3: Integration
Wire the holding pattern (auto-resume on worker return) and finish observability.

- Emit a per-orchestrator worker-terminal signal: when a worker owned by an
  orchestrator reaches a terminal state, broadcast on
  `orchestrator:<orchestrator_id>:workers` (emit from the worker `Session.Server`
  `Done`/`Error` path, or from `Tools`/`Dashboard` where worker terminal state is
  already observed). Include `{worker_id, name, ok?}`.
- The Queue subscribes to its `orchestrator:<id>:workers` topic. On a worker
  terminal signal, IF `:auto_resume_on_worker_return` is enabled AND the queue is
  idle (`current == nil` and FIFO empty), enqueue a low-priority synthetic
  "resume" turn whose prompt summarizes the returned worker(s) and asks the
  orchestrator to review and continue. Operator `enqueue/2` calls always front-run
  any pending auto-resume item (operator priority).
- Log queue lifecycle to `system_logs` via `Logs.create_system_log/1` (enqueue,
  start, complete, cancel, auto-resume) for observability parity with `Tools`.
- Surface the busy/queued badge and queue depth in the console header.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Read the authoritative docs
- Read `BUILD_PROMPT.md` §5 (supervision tree), §6 (session runtime), §9 (LiveView)
  and `ai_docs/typed-elixir-standard.md` (the **always** typed standard).
- Skim `/data/1.Projects/tactical-agentic-coding/tac-14/` reference notes already
  captured in this plan (busy/idle state machine, background dispatch, holding
  loop) to confirm intent; note the deliberate deviation to FIFO (not preempt).

### 2. Add supervision children
- In `lib/repo_builder/application.ex`, add `{Registry, keys: :unique, name:
  RepoBuilder.OrchestratorQueueRegistry}` and `{DynamicSupervisor, name:
  RepoBuilder.OrchestratorQueueSupervisor, strategy: :one_for_one}` to `children`,
  placed after `{Phoenix.PubSub, ...}` and alongside `RepoBuilder.OrchestratorSupervisor`.

### 3. Make the per-turn server monitorable
- In `lib/repo_builder/orchestrator/server.ex`, promote `start_turn/2` to a
  public `@spec start_turn(Orchestrator.t(), String.t()) :: {:ok, pid(),
  String.t()} | {:error, term()}` returning the started pid + `agent_id`.
- Keep `run_turn/2` working (it will delegate to the Queue in step 7).

### 4. Create the queue GenServer (write the LiveView test stub early)
- Create `lib/repo_builder/orchestrator/queue.ex` with a `typedstruct` `State`
  (`orchestrator_id`, `queue` as `:queue.queue/0`, `current` as `nil | {pid,
  reference, String.t()}`), `via/1` registration on
  `RepoBuilder.OrchestratorQueueRegistry`, and `start_or_get/1`.
- Implement `enqueue/2`, `cancel/2`, `snapshot/1` with full `@spec`s and tagged
  tuples; never raise on expected paths.
- Implement `handle_info` for the monitor `:DOWN` (FIFO dequeue) and `handle_info`
  for the worker-terminal topic (holding pattern, Phase 3 — can be a no-op until
  step 8 wires the toggle).
- Create the test file `test/repo_builder_web/live/test_orchestrator_queue_test.exs`
  now (it will be fleshed out in step 11) so the LiveView surface is designed
  test-first.

### 5. Wire broadcast seam
- In `lib/repo_builder/dashboard.ex`, add `@spec`'d `broadcast_orchestrator_queue/2`
  (orchestrator_id + snapshot) on a stable topic the console already (or will)
  subscribe to; mirror `broadcast_orchestrator_updated/1`.

### 6. Config
- In `config/config.exs`, add under `:orchestrator`: `auto_resume_on_worker_return:
  false` (default) and `max_queue_depth: 50`. In `config/test.exs` set
  deterministic values for tests (e.g. `auto_resume_on_worker_return: false` for
  most tests; the holding-pattern test sets it true).
- Add `Orchestrators.auto_resume?/0` and `Orchestrators.max_queue_depth/0`
  `@spec`'d readers over `config/0`.

### 7. Route the console through the queue
- In `lib/repo_builder/orchestrator/server.ex`, make `run_turn/2` delegate to
  `Queue.start_or_get/1` + `Queue.enqueue/2` (preserving the existing
  `{:ok, agent_id}`-style success / error contract the LiveView matches on, OR
  update its single caller). Keep the no-model / not-orchestrator-capable errors
  surfaced as before.
- In `lib/repo_builder_web/live/console_live.ex`, update `run_orchestrator/2` to
  call the queue, branch on `{:ok, :started}` vs `{:ok, :queued, position}`, keep
  the existing error flashes, and subscribe to the queue broadcast topic in
  `mount/3`.

### 8. Holding pattern (auto-resume on worker return)
- Emit `{:worker_terminal, %{worker_id, name, ok?}}` on
  `orchestrator:<orchestrator_id>:workers` from the worker terminal path (worker
  `Session.Server` `Done`/`Error`, scoped to workers that carry an
  `orchestrator_id`). The Queue subscribes on init.
- In the Queue, on a worker-terminal message, when `auto_resume?/0` and the queue
  is fully idle, enqueue a synthetic low-priority resume turn (operator messages
  always front-run). Guard against resume storms (coalesce bursts; at most one
  pending auto-resume item).

### 9. System prompt guidance
- In `lib/repo_builder/orchestrator/system_prompt.ex`, add a "Message queue &
  holding pattern" block: operator messages sent while you work are queued and
  delivered as your next turn; finish dispatching the current batch and end your
  turn (report what you kicked off) so the queue flows and workers run in
  parallel; you'll be re-engaged automatically when workers return (holding
  pattern) if enabled.

### 10. Console UI
- Add the typed `queued_messages/1` function component to
  `lib/repo_builder_web/components/console_components.ex` (pending strip with
  per-item cancel button `phx-click="cancel_queued"` + `phx-value-id`, and a
  busy/queued badge with depth).
- In `console_live.ex`, add `handle_event("cancel_queued", %{"id" => id}, socket)`
  → `Queue.cancel/2`, a `handle_info` for the queue broadcast that re-assigns the
  snapshot, and render the component in the console layout/header.

### 11. Tests — unit
- Write `test/repo_builder/orchestrator/queue_test.exs` covering: idle enqueue
  starts immediately (`{:ok, :started}`); enqueue while busy returns
  `{:ok, :queued, 1}` and does NOT start a second turn; on the in-flight turn's
  process exit the head is dequeued and started (FIFO order across 3 messages);
  `cancel/2` removes a queued item and a missing id returns `{:error, :not_found}`;
  `max_queue_depth` overflow is rejected with a tagged error; with
  `auto_resume?/0` false a worker-terminal signal does nothing, and with it true
  (and idle) it enqueues exactly one resume turn while an operator message
  front-runs it. Use the Fake harness / `SessionCase` setup from
  `server_test.exs`.

### 12. Tests — LiveView integration
- Flesh out `test/repo_builder_web/live/test_orchestrator_queue_test.exs`:
  mount `/`, start an orchestrator turn (busy), submit a second prompt, assert a
  queued chip renders (with position), assert `cancel_queued` removes it, and
  assert the queued message runs (a new turn starts) after the current turn
  completes — assert via the PubSub queue broadcast / rendered state. Optionally
  capture a Playwright screenshot of `http://localhost:4000` as visual proof.

### 13. Runtime verification (Tidewave)
- With `scripts/pg.sh start` and the app running, use Tidewave `project_eval` to
  drive `Queue.enqueue/2` twice against the default orchestrator and assert the
  second returns `{:ok, :queued, _}`; use `get_logs` to confirm the queue
  lifecycle `system_logs` rows; use `execute_sql_query` to confirm no duplicate
  concurrent `status: :running` corruption.

### 14. Validate
- Run every command in **Validation Commands** and fix any failures until all are
  green with zero regressions.

## Testing Strategy
### Unit Tests
- Queue state machine: idle→started, busy→queued, FIFO dequeue on completion,
  cancel (head + middle + missing), overflow rejection, snapshot shape.
- Holding pattern: gating by config flag; idle-only enqueue; operator-priority
  front-running; resume-storm coalescing (at most one pending auto-resume).
- `Orchestrator.Server.start_turn/2` returns `{:ok, pid, agent_id}` and the pid is
  monitorable; `run_turn/2` still satisfies its existing contract via the queue.
- Config readers `auto_resume?/0`, `max_queue_depth/0`.

### Edge Cases
- Two messages submitted in the same instant (only one turn runs; the other
  queues; no concurrent `--resume` of the same session).
- Turn crashes/errors (monitor `:DOWN` with non-`:normal` reason): the queue still
  advances to the next item; orchestrator status reflects `:error` but the queue
  is not wedged.
- Cancel the head item while busy (does not affect the in-flight turn).
- Orchestrator switches harness/provider/model while items are queued (the next
  turn picks up the new config — turns read fresh orchestrator row at start).
- Queue process restart (supervisor) loses in-memory items — acceptable; document
  in Notes; ensure no crash on a dangling monitor after restart.
- Worker-terminal signal arrives while operator items are queued (auto-resume is
  suppressed; operator work runs first).
- `max_queue_depth` reached (reject with a tagged error + operator flash).

## Acceptance Criteria
- Sending a message while the orchestrator is mid-turn enqueues it (no second
  concurrent turn resumes the same session); it runs automatically, in order,
  once the current turn finishes dispatching.
- Multiple queued messages run strictly FIFO.
- Dispatched workers continue running in the background while the next queued
  operator message is processed (parallel work, non-blocking queue).
- The console shows queued messages with their position and a working cancel
  control, plus a busy/queued badge with depth; canceling removes the item before
  it runs.
- With `auto_resume_on_worker_return` enabled, a returning worker re-engages the
  idle orchestrator via a single auto-resume turn; operator messages always take
  precedence.
- `run_turn/2`'s existing callers/tests keep working (queue is the new backbone).
- All validation commands pass with zero regressions.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix test test/repo_builder/orchestrator/queue_test.exs` — the queue state-machine unit tests.
- `mix test test/repo_builder_web/live/test_orchestrator_queue_test.exs` — the LiveView integration test.
- `mix compile --warnings-as-errors` — clean compile; gradual set-theoretic type checker + `warnings_as_errors` pass.
- `mix test --warnings-as-errors` — full ExUnit suite, zero failures.
- `mix format --check-formatted` — formatting.
- `mix credo --strict` — lint incl. the "every public function has an `@spec`" gate.
- `mix dialyzer` — contract checking, no new warnings and no stale ignore filters.

## Notes
- **Deliberate deviation from tac-14.** tac-14 uses *preempt-and-refocus*
  (`active_client.interrupt()` — newest message wins; "refocusing on new
  message"). The operator explicitly asked for *queuing* ("queue and kick off
  once the orchestrator finishes dispatching"), so this plan implements a **FIFO
  queue** instead. The in-flight turn is allowed to finish dispatching; it is not
  interrupted. (The existing `interrupt_agent` tool remains the way to stop a
  runaway worker.)
- **Parallelism comes for free** from the existing design: `command_agent/2`
  dispatches workers into their own background `Session.Server`s and returns
  `"dispatched"`. The queue only serializes *orchestrator turns* (which share one
  resumable CLI session), never the workers — so queued operator messages and
  running workers proceed in parallel.
- **In-memory vs durable queue.** The queue is runtime state (matching tac-14 and
  OTP norms); it does not survive a BEAM/queue-process restart. If durable,
  restart-surviving queuing is later required, add a small `orchestrator_messages`
  table behind the `Orchestrators` context and have the Queue hydrate from it on
  init — out of scope here, noted for the future.
- **No new dependencies** are required (`:queue` is part of OTP/stdlib).
- **Typed standard:** every new public function carries an `@spec`; the Queue
  state is a `typedstruct` with `enforce: true`; results are `{:ok, ...} |
  {:error, reason()}`; no raising on expected paths — to satisfy the `.credo.exs`
  `@spec` gate and Dialyzer under `--warnings-as-errors`.
