# Feature: Graceful worker handover & wind-down at the context-window limit

## Metadata
issue_number: `i`
adw_id: `am`
issue_json: `interested`

## Feature Description
When an orchestrator-spawned worker agent approaches the end of its usable context
window (~80% occupancy), it must **wind down gracefully** instead of degrading or
silently overflowing. The graceful death sequence:

1. **The platform detects** that the worker crossed the handover threshold (it knows
   the real occupancy from each turn's `usage` event vs. the model's
   `ContextWindow.size/2` — the same signal that drives the rail's context bar). The
   worker is an LLM and cannot reliably count its own tokens, so detection is the
   platform's job; *acting* on it is the worker's.
2. **The platform issues a one-shot wind-down directive turn** to the worker — a
   `[WIND DOWN — CONTEXT LIMIT]` prompt that also restates the **original ask** (the
   receipt) so the worker can quote it verbatim.
3. **The worker writes a handover document** to `ai_docs/<name>-handover.md` in the
   shared working directory, with a header that is a *receipt of the original ask
   from the orchestrator*, then sections for **what it achieved** and **what is left
   to do**.
4. **The worker returns a signal** — its final message ends with the token
   `:handover <relative-path-to-doc>` — back to the orchestrator.
5. **The worker self-deletes** — the platform reaps its session and deletes its agent
   row once it sees the `:handover` signal.
6. **The orchestrator is not surprised** — the worker-return notification it already
   receives (the holding-pattern `:worker_terminal` signal) is enriched so the
   auto-resume prompt explicitly says the worker reached its context limit, handed
   over, and *has been retired*, with a link to the handover doc. The orchestrator
   consumes the doc (typically by spawning a fresh worker seeded with it) and never
   tries to command the now-deleted worker.

This makes long, context-heavy worker tasks survivable: work and intent are preserved
to disk and handed back cleanly, rather than lost to an overflow error or a worker
that keeps running past the point its output degrades.

## User Story
As an operator running long multi-agent sessions through the orchestration console
I want a worker that is filling its context window to save a handover document and
retire itself with a `:handover` signal back to the orchestrator
So that no work or intent is lost at the context limit, the orchestrator can continue
seamlessly from the handover doc, and I'm never left with a degraded or stuck worker.

## Problem Statement
Today the platform **measures** worker context occupancy (rail bar via
`ContextWindow.size/2` + the latest `usage` row) and the orchestrator's system prompt
*advises* the brain to `compact_agent`/`clear_context` at ~80% — but:

- The orchestrator (an LLM) has **no programmatic signal** for a worker's occupancy:
  neither `list_agents` nor `check_agent_status` returns context tokens/%, and the
  rail bar is UI-only. So the "compact at 80%" guidance is unactionable.
- There is **no automatic wind-down**: nothing detects the threshold and acts.
- There is **no overflow safety**: `Session.Server` has zero context-limit handling;
  a genuine overflow surfaces as a hard `Error` and the turn's work is lost.
- When a worker *is* retired, the orchestrator has no structured notice that it's gone
  or where its unfinished work was captured.

## Solution Statement
Add a platform-owned **handover protocol** that closes the loop between the occupancy
the platform already knows and the wind-down the worker performs:

- A pure helper module `RepoBuilder.Agents.Handover` centralizes the threshold, the
  occupancy decision, the `:handover <path>` signal parser, and the wind-down /
  retirement prompt text (harness-blind, no process state — testable in isolation).
- `Session.Server` enriches the existing `:worker_terminal` broadcast with the
  worker's last-turn `context_tokens` and the terminal `final_text`, so the surviving
  per-orchestrator `Queue` can decide what to do **without** the dying session having
  to start a new turn.
- The per-orchestrator `Queue` (which already owns "what happens when a worker
  returns" via the holding pattern) gains three branches in its worker-terminal
  handling, all reusing the existing `Tools.call/3` entrypoints (budget/session/cwd
  handling + system-log rows come for free):
  1. **Handover signal present** → self-delete the worker (`delete_agent` tool) and
     enqueue an orchestrator auto-resume turn whose prompt names the worker as retired
     and links the handover doc.
  2. **Over threshold, no signal yet, not already winding down** → mark the worker
     `winding_down` (config flag) and issue one wind-down command turn (`command_agent`
     tool) carrying the original-ask receipt. Suppress the normal resume for this
     terminal.
  3. **Already winding down but returned without a signal** (worker ignored the
     directive) → force-retire it anyway (delete + orchestrator resume noting "retired
     without a handover doc"), so a worker can never get stuck over budget.
- The worker-facing protocol is taught in the worker system-prompt clause
  (`Tools.worker_reporting_clause/0`); the orchestrator-facing expectation ("`:handover`
  workers self-delete; read the doc; spawn a fresh worker to continue") is taught in
  the orchestrator system prompt's context-management block.
- The original ask is recorded on the worker (`config["original_ask"]`) at first
  dispatch so both the wind-down directive and the orchestrator notice can quote it.
- The handover threshold becomes a single config value reused by this flow and by the
  existing `report_cost` warning, so they never drift.

No new DB columns (flags ride in the existing JSONB `agents.config`); no new
dependencies. The worker writes the doc with its existing file tools into the shared
`ai_docs/` directory (same destination the current reporting clause already uses for
overflow reports).

## Relevant Files
Use these files to implement the feature:

- `lib/repo_builder/session/server.ex` — the per-live-session GenServer; single writer
  of canonical events. `dispatch/2` → `maybe_emit_worker_terminal/2` broadcasts the
  holding-pattern `:worker_terminal`. Needs: track the latest `usage` occupancy
  (`context_tokens`) and the terminal `Done.final_text` in `State`, and pass both into
  the enriched broadcast. (No new turn is started here — the session is terminating.)
- `lib/repo_builder/dashboard.ex` — `broadcast_worker_terminal/2`; widen the `info`
  typespec/`@doc` to include the new `context_tokens` and `final_text` fields
  (additive, back-compatible).
- `lib/repo_builder/orchestrator/queue.ex` — per-orchestrator runtime queue;
  `handle_info({:worker_terminal, info}, …)` → `maybe_auto_resume/2`. The home of the
  three new branches (handover / wind-down / force-retire). Reuses `Tools.call/3` for
  `command_agent` and `delete_agent`; uses `Handover` for the decision. Mind the
  existing `seen_worker_ids` dedup — a wind-down turn produces a *second* legitimate
  terminal for the same `worker_id` that must NOT be deduped away (the handover branch
  must act on it).
- `lib/repo_builder/orchestrator/tools.ex` — the harness-blind tool logic.
  `command_agent/2` (record `config["original_ask"]` on first dispatch),
  `worker_reporting_clause/0` (append the worker handover protocol),
  `@high_usage_threshold` (replace with the shared config threshold via `Handover`),
  and the existing `delete_agent`/`command_agent` paths the Queue reuses.
- `lib/repo_builder/orchestrator/system_prompt.ex` — `context_management_block/0`;
  add orchestrator-side guidance: a `:handover` worker self-deletes (don't be
  surprised; don't command it again), read the linked doc, spawn a fresh worker to
  continue if needed.
- `lib/repo_builder/orchestrator/context_window.ex` — `size/2` and `usage_fraction/3`;
  the occupancy math `Handover` builds on (now Opus 4.8 = 1M after the prior fix).
- `lib/repo_builder/logs.ex` — `context_tokens_by_agent/0` / `context_size/1`; the
  per-agent latest occupancy used by the rail and a fallback occupancy source.
- `lib/repo_builder/agents.ex` + `lib/repo_builder/agents/agent.ex` — `update_worker`
  (or `set_status`/a small config-merge helper) to persist `winding_down` /
  `original_ask` in `config`; `delete_agent` (already used by the `delete_agent` tool).
- `lib/repo_builder_web/live/console_live.ex` — already handles `{:agent_deleted, …}`
  (line ~2330) to drop the rail card; the self-delete reuses `Dashboard.broadcast_agent_deleted`
  (emitted by the `delete_agent` tool) so the UI updates with no new handler. The
  orchestrator queue strip reflects the queued auto-resume.
- `lib/repo_builder/orchestrator.ex` — `auto_resume?/0` + the `:orchestrator` config
  block; the handover threshold config reader can live alongside it.
- `config/config.exs` — add the handover threshold under `config :repo_builder, :orchestrator`
  (or a dedicated key); document the precedence with the existing `report_cost` warning.
- `BUILD_PROMPT.md` §6 (session runtime — events, terminal synthesis, no auto-restart),
  §7 (holding pattern / queue / auto-resume), §9 (LiveView dashboard), §3 (typed style).
- `ai_docs/typed-elixir-standard.md` — the enforced typed standard (always row).
- `ai_docs/adw-orchestration.md` — the orchestration/holding-pattern reference (per
  `conditional_docs.md`: workflow/queue/run-resumption tasks).
- `ai_docs/bug-reports/holding-pattern-duplicate-resumes.md` — the `seen_worker_ids`
  dedup rationale this change must respect (the wind-down → handover two-terminal case).

### New Files
- `lib/repo_builder/agents/handover.ex` — `RepoBuilder.Agents.Handover`: pure,
  harness-blind helpers — `threshold/0`, `occupancy/3`, `over_threshold?/1`,
  `parse_signal/1` (`{:ok, path} | :none`), `wind_down_prompt/1`,
  `retired_resume_prompt/2`, `forced_retire_resume_prompt/1`, and the worker-facing
  `protocol_clause/0` (the text appended to the worker system prompt).
- `test/repo_builder/agents/handover_test.exs` — unit tests for the helpers (threshold
  resolution, signal parsing incl. edge cases, occupancy math, prompt construction).
- `test/repo_builder/orchestrator/queue_handover_test.exs` — Queue integration: a
  `:worker_terminal` with high occupancy + no signal issues exactly one wind-down
  (`command_agent`) and no orchestrator resume; a follow-up terminal carrying
  `:handover <path>` deletes the worker and enqueues a handover-aware orchestrator
  resume; the already-winding-down-no-signal case force-retires.
- `test/repo_builder_web/live/test_agent_handover_test.exs` — `Phoenix.LiveViewTest`:
  driving the handover path removes the worker's rail card (via `broadcast_agent_deleted`)
  and the orchestrator queue strip shows the queued handover resume.

## Implementation Plan
### Phase 1: Foundation
Build `RepoBuilder.Agents.Handover` as a standalone, pure module (threshold from
config, occupancy via `ContextWindow`, the `:handover` signal regex, and all prompt
text) with full unit coverage. Add the shared handover-threshold config and point both
this module and `report_cost`'s `@high_usage_threshold` at it so they cannot drift.

### Phase 2: Core Implementation
Enrich the worker-terminal signal end-to-end: `Session.Server` tracks last-turn
`context_tokens` + terminal `final_text` and includes them in
`Dashboard.broadcast_worker_terminal/2` (widen the typespec). Teach the worker the
handover protocol in `worker_reporting_clause/0`, record `original_ask` on first
`command_agent` dispatch, and teach the orchestrator the consume-and-don't-be-surprised
expectation in `context_management_block/0`.

### Phase 3: Integration
Implement the three branches in the `Queue`'s worker-terminal handling, reusing
`Tools.call/3` for the wind-down (`command_agent`) and self-delete (`delete_agent`)
and `Handover` for the decision, with careful interaction with the `seen_worker_ids`
dedup so the wind-down's follow-up handover terminal is acted on. Validate with unit
tests, a Queue integration test, a LiveView test, the live `project_eval` checks, and
the full gate.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Read the authoritative context
- Read `ai_docs/typed-elixir-standard.md`, `BUILD_PROMPT.md` §6/§7/§9,
  `ai_docs/adw-orchestration.md`, and `ai_docs/bug-reports/holding-pattern-duplicate-resumes.md`
  before coding, so the change honors the typed standard, the session-runtime rules,
  and the existing dedup contract.

### 2. Add the shared handover threshold config
- In `config/config.exs`, add a handover occupancy threshold (e.g. under
  `config :repo_builder, :orchestrator`, key `:handover_threshold`, default `0.8`).
  Document that `Handover.threshold/0` reads it and that `report_cost`'s high-usage
  warning shares the same value.
- Mirror in `config/test.exs` if needed (keep default `0.8`).

### 3. Create `RepoBuilder.Agents.Handover`
- New file `lib/repo_builder/agents/handover.ex` with `@moduledoc` describing the
  protocol and the platform-detects / worker-acts split. Every public function gets an
  `@spec`; precise types, no `any()`/`map()` where a struct/union fits.
- `@spec threshold() :: float()` — reads `:handover_threshold` (fallback `0.8`).
- `@spec occupancy(harness :: String.t() | nil, model :: String.t() | nil, context_tokens :: non_neg_integer()) :: float()`
  — delegates to `ContextWindow.usage_fraction/3`.
- `@spec over_threshold?(float()) :: boolean()`.
- `@spec parse_signal(String.t() | nil) :: {:ok, String.t()} | :none` — match the LAST
  `:handover <path>` token in the message via `~r/:handover\s+(\S+)/`; trim trailing
  punctuation/backticks; `nil`/no-match ⇒ `:none`.
- `@spec wind_down_prompt(original_ask :: String.t() | nil) :: String.t()` — the
  `[WIND DOWN — CONTEXT LIMIT]` directive: instruct the worker to write
  `ai_docs/<descriptive>-handover.md` with a header that quotes the original ask
  (interpolated when present), an "Achieved" section, and a "Remaining" section, then
  end its reply with exactly `:handover <relative-path>` and stop.
- `@spec retired_resume_prompt(name :: String.t(), doc_path :: String.t()) :: String.t()`
  — the orchestrator auto-resume text: worker `name` hit its context limit, handed
  over, and **has been retired (deleted)**; its handover doc is at `doc_path` (receipt
  + achieved + remaining); continue by reading it and spawning a fresh worker if the
  task isn't done.
- `@spec forced_retire_resume_prompt(name :: String.t()) :: String.t()` — variant for
  the "winding down but returned without a doc" case.
- `@spec protocol_clause() :: String.t()` — the worker-facing protocol appended to the
  worker system prompt (see step 5).

### 4. Unit-test `Handover` (write tests before wiring)
- New file `test/repo_builder/agents/handover_test.exs`:
  - `parse_signal/1`: matches `:handover ai_docs/x-handover.md`; ignores prose without
    the token; handles trailing backticks/period; takes the last occurrence; `nil`/`""`
    ⇒ `:none`.
  - `threshold/0` reads config; `over_threshold?/1` boundary at exactly the threshold.
  - `occupancy/3` matches `ContextWindow.usage_fraction/3` for known and unknown models.
  - prompt builders include the original ask when given, omit it cleanly when `nil`,
    and the wind-down prompt names the `:handover <path>` contract.

### 5. Teach the worker the protocol (`Tools.worker_reporting_clause/0`)
- In `lib/repo_builder/orchestrator/tools.ex`, append `Handover.protocol_clause/0`
  (or inline equivalent) to the existing worker reporting clause so EVERY spawned
  worker learns: how to recognize a `[WIND DOWN]` directive, the exact
  `ai_docs/<name>-handover.md` layout (receipt header / achieved / remaining), and the
  `:handover <path>` final-message contract — and that it must NOT keep working after
  emitting `:handover`.
- Replace the local `@high_usage_threshold 0.8` used by `report_cost/1` with
  `Handover.threshold()` so the warning and the handover share one value.

### 6. Record the original ask on first dispatch (`Tools.command_agent/2`)
- When `command_agent/2` dispatches a worker that has no prior session (first turn),
  persist `config["original_ask"]` = the command prompt (via `Agents.update_worker` or
  a small `Agents` config-merge helper) if not already set. Leave subsequent turns
  untouched. This is the receipt source for the wind-down directive and the
  orchestrator notice.

### 7. Enrich the worker-terminal signal (`Session.Server` + `Dashboard`)
- In `Session.Server.State`, add `field :context_tokens, non_neg_integer(), default: 0`
  and update it on each `%Event.Usage{}` (input + output, mirroring `Logs.context_size/1`).
- Capture the terminal message text: read `final_text` from `%Event.Done{}` when
  emitting the worker-terminal.
- Extend `maybe_emit_worker_terminal/2` to include `context_tokens` and `final_text`
  in the broadcast `info` map.
- Widen `Dashboard.broadcast_worker_terminal/2`'s typespec + `@doc` to the new optional
  fields (additive; existing `%{worker_id, name, ok?}` callers still type-check —
  `WorkflowEngine.emit_orchestrator_resume/2` and `StepWorker` keep working unchanged,
  treated as `context_tokens: 0`, `final_text: nil`).

### 8. Implement the Queue branches (`orchestrator/queue.ex`)
- In `maybe_auto_resume/2` (and the pending-consume path), branch on `info` using
  `Handover`:
  1. `Handover.parse_signal(info[:final_text])` returns `{:ok, path}` →
     **handover**: call `Tools.call("delete_agent", orchestrator_id, %{"name" => name})`
     to self-delete the worker, then `start_auto_resume` with
     `Handover.retired_resume_prompt(name, path)`. This terminal must bypass the
     `seen_worker_ids` duplicate-drop (a handover is always actionable) — gate the
     dedup to the non-handover path only.
  2. else if `Handover.over_threshold?(Handover.occupancy(harness, model, info.context_tokens))`
     AND the worker is not already `config["winding_down"]` →
     **wind down**: set `winding_down: true` (config), then
     `Tools.call("command_agent", orchestrator_id, %{"name" => name, "prompt" => Handover.wind_down_prompt(original_ask)})`.
     Do NOT auto-resume the orchestrator for this terminal (return state unchanged
     except the bookkeeping). Resolve `harness`/`model`/`original_ask`/`winding_down`
     from the worker row (`Agents.get_agent/1`).
  3. else if already `winding_down` and no signal → **force retire**: delete the worker
     and `start_auto_resume` with `Handover.forced_retire_resume_prompt(name)`.
  4. else → existing normal holding-pattern behavior (unchanged).
- Keep all new side effects quiet/fail-soft (a delete/command failure logs and falls
  through to existing behavior — never crashes the Queue).
- Note the dependency `Queue → Tools` is acceptable: the Queue is orchestrator-scoped
  runtime and `Tools.call/3` is the public, logged tool entrypoint (same path the brain
  uses), so budget checks, session config, cwd, and system-log rows are reused.

### 9. Teach the orchestrator (`SystemPrompt.context_management_block/0`)
- Add a short paragraph: a worker that hits its context limit performs a **graceful
  handover** — it writes `ai_docs/<name>-handover.md`, returns a `:handover <path>`
  signal, and is **automatically retired (deleted)**. Do NOT be surprised it's gone
  and do NOT try to `command_agent`/`check_agent_status` it again. To continue its
  task, read the handover doc and spawn a FRESH worker seeded with it.

### 10. Queue integration test
- New file `test/repo_builder/orchestrator/queue_handover_test.exs` (mirror the style
  of the existing queue/auto-resume tests, Fake-harness/seam-injected where possible):
  - high occupancy + no signal → exactly one `command_agent` (wind-down) issued, no
    orchestrator auto-resume queued, `winding_down` set.
  - follow-up terminal with `:handover ai_docs/w-handover.md` → worker deleted, an
    orchestrator auto-resume queued whose prompt names the worker retired + the doc path.
  - already winding down, terminal without a signal → force-retire (delete + resume).
  - the handover terminal is acted on even when its `worker_id` is already in
    `seen_worker_ids` (dedup must not swallow it).

### 11. LiveView integration test
- New file `test/repo_builder_web/live/test_agent_handover_test.exs` using
  `Phoenix.LiveViewTest`: seed an orchestrator + a running worker with a near-full
  `usage` row; drive the handover terminal; assert the worker's rail card is removed
  (the `{:agent_deleted, …}` path) and the orchestrator queue strip shows the queued
  handover resume (or a console line referencing the handover doc). Optionally capture
  a Playwright/Tidewave screenshot of `http://localhost:4000` as visual proof.

### 12. Runtime verification via Tidewave
- `project_eval`:
  `RepoBuilder.Agents.Handover.parse_signal("done.\n:handover ai_docs/x-handover.md")`
  ⇒ `{:ok, "ai_docs/x-handover.md"}`; `Handover.over_threshold?(Handover.occupancy("claude", "claude-opus-4-8", 850_000))` ⇒ `true`
  (1M window) and `false` at `700_000`.
- `execute_sql_query` (or `project_eval` over `Agents`): after a simulated handover,
  confirm the worker row is deleted and (before deletion) `config["winding_down"]` was set.

### 13. Run the Validation Commands
- Run every command in **Validation Commands**; fix any failure before declaring done.
  Zero failures, zero new warnings, zero new Dialyzer findings.

## Testing Strategy
### Unit Tests
- `Handover.parse_signal/1` across present/absent/multiple/trailing-punctuation cases
  and `nil`/`""`.
- `Handover.threshold/0` config read; `over_threshold?/1` boundary; `occupancy/3`
  agreement with `ContextWindow`.
- Prompt builders include/omit the original ask correctly and state the `:handover`
  contract.
- `Tools.command_agent/2` records `config["original_ask"]` once (first turn only).
- `Session.Server` includes `context_tokens` + `final_text` in the worker-terminal
  broadcast (a focused server/seam test, or assert via the Queue test's received info).

### Edge Cases
- Worker emits `:handover` with **no path** or a malformed token → treat as no signal
  (don't delete on an unparseable signal); the next terminal / force-retire path covers
  the over-budget worker.
- Worker emits `:handover` **without** crossing the threshold (proactively) → still
  honored: delete + retire-resume (the worker decided it's done handing over).
- Wind-down directive issued but the worker **ignores it** and returns a normal Done →
  force-retire (branch 3), no infinite wind-down loop (guarded by `winding_down`).
- `:worker_terminal` is an **Error** (not Done) → no `final_text` handover; existing
  behavior (no wind-down; normal terminal handling).
- `seen_worker_ids` dedup: a handover terminal for an already-seen worker is still acted
  on; a duplicate *non-handover* terminal is still dropped (no regression to the
  duplicate-resume fix).
- `auto_resume?/0` disabled: wind-down/handover detection still self-deletes on a
  handover signal (the worker asked to die), but does NOT enqueue an orchestrator
  resume — decide and document this explicitly (recommended: still delete; skip the
  resume when auto-resume is off, matching the existing opt-out).
- Window unknown (model not catalogued) → occupancy uses the `:default` (200k); ensure
  the wind-down doesn't fire spuriously for tiny token counts.
- ADW / workflow worker-terminals (`WorkflowEngine.emit_orchestrator_resume/2`, no
  `context_tokens`/`final_text`) → treated as `context_tokens: 0`, `final_text: nil`:
  never wind down, never parsed as handover — unchanged behavior.

## Acceptance Criteria
- A worker whose latest-turn occupancy ≥ the configured threshold and that has not yet
  handed over receives exactly **one** wind-down command turn and is flagged
  `winding_down`; the orchestrator is **not** auto-resumed for that terminal.
- A worker whose final message contains `:handover <path>` is **deleted** (session
  reaped + agent row removed + rail card disappears) and the orchestrator receives an
  auto-resume turn whose prompt states the worker was retired and links `<path>`.
- A `winding_down` worker that returns without a `:handover` signal is force-retired
  (deleted) with a corresponding orchestrator notice — never left stuck over budget.
- The worker system prompt teaches the `ai_docs/<name>-handover.md` layout (original-ask
  receipt header + achieved + remaining) and the `:handover <path>` contract; the
  orchestrator system prompt states that `:handover` workers self-delete and must not be
  re-commanded.
- The handover threshold is a single config value shared by this flow and `report_cost`.
- No regression to the holding-pattern duplicate-resume dedup.
- `mix compile --warnings-as-errors`, `mix test --warnings-as-errors`,
  `mix format --check-formatted`, `mix credo --strict`, and `mix dialyzer` all pass.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix test test/repo_builder/agents/handover_test.exs` — the pure handover helpers.
- `mix test test/repo_builder/orchestrator/queue_handover_test.exs` — the three Queue
  branches (wind-down, handover+delete+resume, force-retire) and dedup interaction.
- `mix test test/repo_builder_web/live/test_agent_handover_test.exs` — the LiveView
  proof (rail card removed, handover resume queued).
- `mix compile --warnings-as-errors` - Compile clean; gradual set-theoretic type
  checker and `warnings_as_errors` must pass.
- `mix test --warnings-as-errors` - Full ExUnit suite (Postgres-backed) with zero
  failures.
- `mix format --check-formatted` - Formatting gate.
- `mix credo --strict` - Lint incl. the "@spec on every public function" gate.
- `mix dialyzer` - Contract checking, no new warnings, no stale ignore filters.

## Notes
- **Why platform-detects / worker-acts.** The worker is an LLM with no reliable view of
  its own token count; the platform already knows real occupancy (`ContextWindow.size/2`
  + the latest `usage` row, the rail-bar signal). So the platform owns the *trigger*
  (the 80% decision and the wind-down directive) and the worker owns the *content* (the
  handover doc it can author from its own conversation) and the *signal*. This matches
  "the agent knows after 80%" as: the platform tells it, then it acts.
- **Why the Queue, not `Session.Server`.** The dying session can't safely start the
  wind-down turn (it's terminating, children are `:temporary`, no auto-restart per §6).
  The per-orchestrator `Queue` survives, already subscribes to `:worker_terminal`, and
  already owns "what happens when a worker returns" (the holding pattern) — so the new
  branches live there, reusing `Tools.call/3` for both the wind-down command and the
  self-delete.
- **`:handover` signal vs. canonical events.** The signal is a lightweight convention
  inside the worker's final message text (parsed by `Handover.parse_signal/1`), NOT a
  new canonical `Event` variant — this avoids touching the harness event contract (§4)
  and keeps the protocol harness-agnostic (Claude and pi both just emit text).
- **Future extension (out of scope):** surface a dedicated console feed event card for
  handovers (via `Console.EventPresenter`) and a transient "handing over" rail status;
  and an overflow safety net in `Session.Server` that converts a harness
  context-exceeded `Error` into an immediate forced handover. Both layer cleanly on this
  design but aren't required for the core loop.
- **Adjacent gap, not addressed here:** `check_agent_status`/`list_agents` still don't
  expose per-worker context %. This feature makes the *platform* act on occupancy
  automatically, so the brain no longer needs to poll it — but if we later want the
  brain to reason about it, adding `context_usage_pct` to `check_agent_status` is the
  natural follow-up.
- No new dependencies; no migration; flags ride in the existing JSONB `agents.config`.
  Runtime validation uses Tidewave `project_eval` / `execute_sql_query` per the project's
  preferred path.
