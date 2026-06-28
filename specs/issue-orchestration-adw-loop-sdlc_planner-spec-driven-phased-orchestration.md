# Feature: Spec-Driven, Phased, Parallel **Workstream** Orchestration (with brain-compaction memory)

## Metadata
issue_number: `orchestration`
adw_id: `loop`
issue_json: `for`

## Feature Description
Today the autonomous Orchestrator is a single-track manager: it has at most **one** active
Task Ledger (a partial-unique index, `task_ledgers_one_active_per_orchestrator`, enforces
it), a free-form drive loop, and verification by eyeballing the tree (`inspect_repo`).
Deterministic plan→build→review→fix rigor only happens if it *chooses* to launch
`start_adw`. There is no spec-first hand-off, no phasing of a large objective, no way to run
several independent jobs in parallel, and no way for the brain to survive its own context
filling up.

This feature reshapes the orchestrator's durable state around a **Workstream** — an
independent, durable "scratchpad" of work — and gives it three integrated capabilities:

1. **Spec-driven phased delivery (per workstream).** Each Workstream owns an ordered
   **Pipeline of phases**, and each phase runs a fixed **spec → implement → test → review**
   stage machine (with a `review → fix → review` branch). A dedicated **work-decomposer**
   helper subagent breaks the objective into right-sized phases so a single worker can carry
   a phase through spec+implement **without exhausting its context window**. The `specs/…md`
   file produced by `/feature` `/bug` `/chore` `/plan` is the durable hand-off artifact into
   `/implement <spec_path>`, then `/test`, then `/review`.

2. **Parallel workstreams.** One orchestrator can hold **multiple** active Workstreams at
   once. The drive loop becomes a scheduler that advances any Workstream with a ready step;
   in a single turn the brain can fan out into several Workstreams, and their workers run
   **concurrently** (bounded by the existing `Session.Admission` gate, `max_live_sessions:
   100`). Worker returns are **tagged by `workstream_id`** so the brain resumes the right
   scratchpad.

3. **Brain external-memory & compaction.** Every Workstream is a durable **rehydration
   record** — id, title, goal/definition-of-done, the per-phase `spec_path`s, what is
   **completed**, what **remains**, the current phase/stage, and the single `next_action`.
   Because nothing important lives only in the LLM window, the orchestrator can **compact its
   own context** (`compact_self`) and then **re-read** the active Workstreams to rebuild just
   enough state to continue. A deterministic **rehydrate-on-resume** hook seeds every
   post-compaction turn with the compact Workstream index, so a compaction never leaves the
   brain amnesiac.

Net effect: large objectives become a set of small, specified, verified phases; independent
objectives run in parallel; and the orchestrator's working memory stays bounded no matter how
long the job runs — workers don't blow context (decomposer + fresh workers per stage) and the
brain doesn't blow context (durable workstreams + compact→rehydrate).

## User Story
As an operator practicing spec-driven development
I want the orchestrator to hold several parallel workstreams, deliver each one as right-sized
phases that go spec → implement → test → review, and compact-then-rehydrate its own memory
from durable per-workstream records
So that I can run multiple jobs at once, every change is specified before it's built and
verified after, and neither the workers nor the orchestrator brain stall by running out of
context on work that was too big to hold at once.

## Problem Statement
- **Single-track:** the orchestrator can drive only one goal; there is no first-class way to
  run independent objectives concurrently.
- **Ad-hoc, not spec-first:** work is "do this task," verified by an `inspect_repo` glance;
  test/review rigor is opt-in per dispatch.
- **No phasing:** a big objective is handed to one worker (or a flat ADW), so a worker
  frequently exhausts its context mid-task and degrades or triggers a handover.
- **Brain amnesia under context pressure:** the orchestrator cannot compact its own context
  (only the operator can `/compact` it today), and there is no durable, compact memory it can
  re-read after compaction — so long multi-agent sessions degrade the brain itself.

## Solution Statement
Introduce a **Workstream** layer as the orchestrator's top-level durable unit. A Workstream
carries its goal/definition-of-done, status, stall accounting, and an ordered **Pipeline of
phases**; each phase carries its `spec_path` and a `spec|implement|test|review` stage map.
Drive it with a small tool set (`create_workstream`, `plan_phases`, `record_stage`,
`list_workstreams`, `get_workstream`, `close_workstream`, `compact_self`) plus a seeded
`work-decomposer` subagent and two new system-prompt protocol sections ("Spec-driven phased
delivery" and "External memory & compaction"). Make the per-orchestrator drive loop
(`queue.ex`) a Workstream scheduler with **workstream-tagged return routing** and a
**rehydrate-on-resume** hook. Surface active Workstreams in the console autonomy panel.

Everything is additive and back-compatible: an orchestrator that never creates a Workstream
keeps its existing single Task Ledger behavior unchanged. Reuse all existing machinery —
slash-command expansion, `clear_context`/graceful-handover for worker context hygiene,
`inspect_repo` for verification, `report_cost` for the brain's own pressure signal, and the
canonical event/PubSub plumbing for the live UI.

This is deliberately **three integrated layers**:
- **Decomposition** (the helper subagent + `plan_phases`) — one objective → N right-sized phases.
- **Execution** (the per-phase stage machine + `record_stage`, scheduled across parallel
  Workstreams) — each phase driven spec→implement→test→review with fix-on-failure.
- **Memory** (the Workstream rehydration record + `compact_self` + rehydrate-on-resume) — the
  brain's external swap so its context stays bounded.

## Relevant Files
Use these files to implement the feature:

- `BUILD_PROMPT.md` — authoritative architecture/spec; honor §3 typed style, §5 supervision
  / admission gate, §6 session runtime, §7 workflow engine, §8 persistence (DB behind
  `@spec`'d contexts only), §9 LiveView.
- `lib/repo_builder/orchestrator/tool_catalog.ex` — the SINGLE source of truth for tool
  definitions (name/description/JSON-Schema). All new tools are declared here so BOTH the MCP
  `tools/list` controller and the pi extension manifest advertise them automatically.
- `lib/repo_builder/orchestrator/tools.ex` — `call/3` → `dispatch/3` clauses → private
  handlers. Each new tool gets a `dispatch/3` clause + handler.
- `lib/repo_builder/orchestrator/system_prompt.ex` — builds the prompt; add the two new
  protocol blocks. `leader_expertise_block/0` (drive loop) and `context_management_block/0`
  (today's worker compaction guidance, which states the brain's own `/compact` is
  operator-triggered) are the existing sections to extend/sit beside.
- `lib/repo_builder/orchestrator/queue.ex` — the per-orchestrator FIFO turn GenServer
  (serializes brain turns; holding-pattern auto-resume on worker return). Make it a
  Workstream scheduler: tag the resume with the returning worker's `workstream_id`, and add
  the **rehydrate-on-resume** hook (seed the post-compaction turn with `list_workstreams`).
- `lib/repo_builder/orchestrator/ledgers.ex` + `task_ledger.ex` — the existing single-goal
  dual-ledger. Workstreams generalize this; reuse its patterns. The "one active per
  orchestrator" unique index is relaxed/superseded per the migration task below.
- `lib/repo_builder/orchestrators.ex` — `@spec`'d orchestrator context; Workstream CRUD lives
  in a new `Orchestrator.Workstreams` context (see New Files).
- `lib/repo_builder/orchestrator/templates.ex` (+ seeds under `priv/orchestrator/`) — the
  subagent-template registry; the `work-decomposer` recipe is seeded here so it appears in the
  SUBAGENT MAP and is applicable via `create_agent(subagent_template:)`.
- `lib/repo_builder/session/admission.ex` — the live-session concurrency gate
  (`max_live_sessions: 100`); the source of the parallelism bound for concurrent workstream
  workers. No change expected; cite it in the parallel-scheduler design.
- `lib/repo_builder/session/server.ex` — per-agent GenServer; the worker-return / terminal
  path is where the `workstream_id` tag must be threaded for return routing.
- `lib/repo_builder/orchestrator/server.ex` — orchestrator turn lifecycle; the entry point for
  the `compact_self` action and the rehydrate-on-resume seed.
- `lib/repo_builder/workflow_engine/catalog.ex` — add an optional `spec_implement_test_review`
  catalog type so `start_adw` can run the same shape as one ADW (parity path).
- `lib/repo_builder_web/live/console_live.ex` + `components/console_components.ex` — the
  console autonomy surface; add a **Workstreams panel** (one row per workstream → phases →
  stage chips, current phase/stage highlighted, brain-context % from `report_cost`).
- `lib/repo_builder/console/event_presenter.ex` — presentation for workstream/phase transition
  console events.
- `.claude/commands/feature.md`, `bug.md`, `chore.md`, `plan.md`, `implement.md`, `test.md`,
  `review.md` — the slash commands the per-phase stages dispatch (no edits; the protocol
  references them). `/implement` STOPs without a `[path-to-plan]`, so the protocol MUST pass
  the phase's `spec_path`.
- `test/repo_builder/orchestrator/tools_ledger_test.exs`, `queue_holding_pattern_test.exs`,
  `ledgers_test.exs` — patterns for the new tests.

### New Files
- `lib/repo_builder/orchestrator/workstreams.ex` — the `@spec`'d Workstream context. All
  `Repo`/`Ecto.Query` access lives here (BUILD_PROMPT §8). Functions (all returning
  `{:ok, t()} | {:error, reason()}`):
  - `create_workstream/2` (orchestrator_id, %{title, goal, definition_of_done})
  - `plan_phases/3` (orchestrator_id, workstream_ref, [%{title, description, definition_of_done}])
  - `record_stage/3` (orchestrator_id, workstream_ref, %{stage, outcome, artifact, worker, note})
  - `list_workstreams/1` (orchestrator_id) → compact index rows (the rehydration *index*)
  - `get_workstream/2` (orchestrator_id, workstream_ref) → full rehydration record
  - `close_workstream/3` (orchestrator_id, workstream_ref, status)
  - `ready_workstreams/1` (orchestrator_id) → those with a dispatchable next step (scheduler)
- `lib/repo_builder/orchestrator/workstream.ex` — the `Workstream` Ecto schema (`typedstruct`,
  `binary_id`, `has_many :phases`, status enum `~w(running blocked done abandoned)`,
  `stall_count`, `current_phase_position`) + changeset.
- `lib/repo_builder/orchestrator/workstream_phase.ex` — the `WorkstreamPhase` schema:
  `position`, `title`, `description`, `definition_of_done`, `spec_path` (nullable), JSONB
  `stages` (`spec|implement|test|review` → `%{status, worker, artifact, note}`), `status`
  enum (`pending|running|done|blocked`), `current_stage` enum (`spec|implement|test|review|done`)
  + changeset.
- `priv/repo/migrations/<ts>_create_orchestrator_workstreams.exs` — `orchestrator_workstreams`
  + `orchestrator_workstream_phases` (binary_id PKs, JSONB `stages`, FKs with
  `on_delete: :delete_all`, index `(workstream_id, position)`), AND relax the legacy
  `task_ledgers_one_active_per_orchestrator` unique index (see task 1).
- `priv/orchestrator/templates/work-decomposer.md` — the seeded decomposer recipe.
- `test/repo_builder/orchestrator/workstreams_test.exs` — context unit tests (state machine,
  rehydration record shape, multi-workstream isolation).
- `test/repo_builder/orchestrator/tools_workstream_test.exs` — tool-surface tests for all new
  tools + `ToolCatalog.names/0` advertising them.
- `test/repo_builder/orchestrator/queue_workstream_resume_test.exs` — scheduler + workstream-
  tagged return routing + rehydrate-on-resume seeding.
- `test/repo_builder_web/live/test_workstreams_panel_test.exs` — `Phoenix.LiveViewTest` driving
  the console Workstreams panel, asserting streamed phase/stage updates over PubSub.

## Implementation Plan
### Phase 1: Foundation (durable Workstream model + rehydration record)
Stand up the Workstream data model and context with no runtime behavior change. Migration +
`Workstream`/`WorkstreamPhase` schemas + the `Orchestrator.Workstreams` context exposing the
`@spec`'d functions above. The context's `list_workstreams/1` and `get_workstream/2` produce
the **rehydration record** (index + full). Unit-test the per-phase state machine
(spec→implement→test→review→done with the `review → fix → review` branch and `:blocked`), the
next-phase promotion, and multi-workstream isolation. All DB access behind the context.

### Phase 2: Core (tools, decomposer, protocol)
- Declare the tools in `ToolCatalog` — `create_workstream`, `plan_phases`, `record_stage`,
  `list_workstreams`, `get_workstream`, `close_workstream`, `compact_self` — with precise
  JSON-Schema, each carrying a `workstream` selector where relevant. Add `dispatch/3` clauses
  + handlers in `tools.ex` delegating to `Orchestrator.Workstreams` (and to the orchestrator
  session for `compact_self`).
- Seed the `work-decomposer` subagent template (right-sized, context-budgeted phases; strict
  JSON output; never writes code).
- Add the two system-prompt blocks: **"Spec-driven phased delivery"** and **"External memory
  & compaction"**.

### Phase 3: Runtime (scheduler, return routing, rehydrate hook, parallelism)
- Make `queue.ex` a Workstream scheduler: a brain turn may dispatch into multiple
  Workstreams; worker returns carry `workstream_id` so the holding-pattern resume names the
  right scratchpad. Thread `workstream_id` through the `session/server.ex` worker→orchestrator
  return path.
- Add the **rehydrate-on-resume** hook: after `compact_self` (or operator/harness compaction),
  the next turn is seeded with the `list_workstreams` index so the brain wakes oriented.
- Concurrency is bounded by `Session.Admission` (100 slots) — no change, but assert parallel
  dispatch across workstreams respects it and degrades gracefully at capacity.

### Phase 4: Integration (console + parity + gate)
- Render the **Workstreams panel** in the console; broadcast workstream/phase transitions over
  PubSub; add the LiveView test.
- Add the optional `spec_implement_test_review` catalog type.
- Run the full validation gate.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Migration: workstream tables + relax legacy index
- Create `priv/repo/migrations/<ts>_create_orchestrator_workstreams.exs`.
- `orchestrator_workstreams`: `id` binary_id PK, `orchestrator_id` binary_id FK →
  `orchestrators` (`on_delete: :delete_all`), `title` string, `goal` text,
  `definition_of_done` text, `status` string default `"running"`, `stall_count` integer
  default 0, `current_phase_position` integer default 0, timestamps. Index `[:orchestrator_id]`.
- `orchestrator_workstream_phases`: `id` binary_id PK, `workstream_id` FK →
  `orchestrator_workstreams` (`on_delete: :delete_all`), `position` integer, `title` string,
  `description` text, `definition_of_done` text, `spec_path` string null, `stages` `:map`
  default `%{}`, `status` string default `"pending"`, `current_stage` string default
  `"spec"`, timestamps. Index `(workstream_id, position)`.
- Relax the legacy single-goal constraint so Workstreams can coexist: keep the existing
  `task_ledgers` single-track path working but no longer assume one active goal blocks
  Workstreams (document the chosen approach in Notes — e.g. Workstreams are a parallel
  structure and do not write `task_ledgers`, so the legacy index is untouched; OR add a
  nullable `workstream_id` to `task_ledgers` and make the partial-unique index
  `(orchestrator_id, workstream_id)`). Pick the lower-churn option and record it.
- `mix ecto.migrate` clean + reversible (`mix ecto.rollback` then re-migrate).

### 2. Ecto schemas
- `workstream.ex` and `workstream_phase.ex` via `typedstruct`/`@enforce_keys`, `binary_id`,
  enum-guarded `status`/`current_stage`/`stage_status`, typed JSONB `stages`, `@spec`'d
  `changeset/2`. Model `stages` as `%{optional(stage()) => %{status: stage_status(),
  worker: String.t() | nil, artifact: String.t() | nil, note: String.t() | nil}}`.

### 3. Workstreams context (state machine + rehydration record)
- `lib/repo_builder/orchestrator/workstreams.ex`, all `@spec`'d, `{:ok, t()} | {:error, reason()}`:
  - `create_workstream/2` — insert a running workstream (no phases yet).
  - `plan_phases/3` — insert ordered phases (from the decomposer) in a transaction; phase 1
    `status: :running, current_stage: :spec`; `current_phase_position: first`.
  - `record_stage/3` — set the current phase's `stages[stage]`; on `passed` advance
    `current_stage` (`spec→implement→test→review→done`); leaving `review` passed → phase
    `:done`, promote next `:pending` phase to `:running`; `review` failed → keep
    `current_stage: :review` and flag a fix need; other-stage `failed`/`blocked` per outcome
    (retry vs `:blocked`); bump `stall_count` when a turn records no advance.
  - `list_workstreams/1` — the **rehydration INDEX**: one compact row per workstream
    `{id, title, status, phase "k/n", current_stage, next_action, stall_count}`.
  - `get_workstream/2` — the **full rehydration record**: goal/DoD, all phases with
    `spec_path`, completed vs remaining stages, current pointer, the single `next_action`.
  - `close_workstream/3`, `ready_workstreams/1` (scheduler input: workstreams with a
    dispatchable next step and not `:blocked`/`:done`).
  - Accept a `workstream_ref` that resolves by id or title (operator/brain ergonomics).

### 4. Context unit tests
- `workstreams_test.exs`: create + plan_phases; full phase traversal + next-phase promotion;
  review-fail → fix → review-pass; `:blocked`; multi-workstream isolation (two streams
  advance independently); `list_workstreams/1` index shape and `get_workstream/2` record shape
  (asserts spec_path/completed/remaining/next_action are present and correct).

### 5. Tool definitions in ToolCatalog
- Add to `tool_catalog.ex` (stable order; precise JSON-Schema):
  - `create_workstream` — `{title, goal, definition_of_done}` → returns `workstream_id`.
  - `plan_phases` — `{workstream, phases:[{title, description, definition_of_done}]}`. Desc:
    persist the decomposer's right-sized PHASE breakdown for a workstream; each phase is
    delivered spec→implement→test→review.
  - `record_stage` — `{workstream, stage(spec|implement|test|review), outcome(passed|failed|
    blocked), artifact?, worker?, note?}`. Desc: record the CURRENT phase's stage outcome and
    advance the machine (review→fix→review on failure). VERIFY via `inspect_repo` first.
  - `list_workstreams` — no input; returns the compact rehydration INDEX. Desc nudges reading
    it at the START of every turn (this is your durable memory index).
  - `get_workstream` — `{workstream}`; returns the full rehydration record for one stream.
  - `close_workstream` — `{workstream, status(done|abandoned)}`.
  - `compact_self` — no input; compacts the orchestrator's OWN context, then the platform
    rehydrates the workstream index on the next turn. Desc: use when `report_cost` shows high
    context usage — your workstreams are durable, so compacting is safe; you'll wake re-oriented.

### 6. Tool handlers in tools.ex
- Add `dispatch/3` clauses + handlers for each, delegating to `Orchestrator.Workstreams`,
  normalizing `{:ok, _} | {:error, reason}` into the existing tool-result shape (string keys,
  JSON-encodable). `compact_self` delegates to the orchestrator session (see task 8).

### 7. Seed the work-decomposer subagent
- Add `work-decomposer` to the seeded templates. System prompt: read the objective (+ any
  linked context); output ONLY a strict JSON array of phases `{title, description,
  definition_of_done}`; **size each phase so one worker can author its spec AND implement it
  within a single context window** (heuristics: bounded file/surface count per phase, no phase
  spanning unrelated subsystems, split when a phase needs more than a few spec sections);
  order by dependency; never write code. Confirm it appears in the SUBAGENT MAP.

### 8. compact_self capability
- Add an orchestrator self-compaction path: a `compact_self` action on
  `Orchestrator.Server` that compacts the brain's own session (analogous to `compact_agent`
  for workers — dispatch `/compact` to its own session / trigger the harness compaction),
  returning `{:ok, :compacting}`. Wire `tools.ex` `compact_self` handler to it.

### 9. Rehydrate-on-resume hook in queue.ex
- After any compaction (self via `compact_self`, operator `/compact`, or harness auto-compact)
  the NEXT brain turn must be seeded with the `list_workstreams` index. Implement in `queue.ex`
  (or `server.ex` turn-start): detect the post-compaction / resume condition and prepend a
  synthetic context note containing the compact index so the brain always wakes oriented.
  Keep it a no-op when there are no active workstreams (back-compat).

### 10. Workstream scheduler + tagged return routing
- Make the holding-pattern resume name the returning worker's `workstream_id`: thread a
  `workstream_id` tag from the dispatching `command_agent` through `session/server.ex`'s
  terminal/return path back into `queue.ex` so the resume turn says which scratchpad to
  advance. Add `ready_workstreams/1`-driven guidance so the brain can advance any ready stream
  (parallel fan-out within a turn), bounded by `Session.Admission`.
- Test in `queue_workstream_resume_test.exs`: two workstreams, worker A returns → resume names
  workstream A; capacity at the admission gate degrades gracefully.

### 11. System-prompt protocol
- In `system_prompt.ex`, add two blocks beside `leader_expertise_block/0`:
  - **Spec-driven phased delivery (per workstream):** DECOMPOSE FIRST (spawn `work-decomposer`,
    `plan_phases`); PER PHASE run spec(`/feature|/bug|/chore|/plan` → capture `spec_path` →
    `record_stage(spec, passed, artifact: spec_path)`) → implement(`/implement <spec_path>` →
    verify → `record_stage`) → test(`/test`) → review(`/review`; fail → fix → re-review);
    CONTEXT HYGIENE per stage (`clear_context`/fresh role workers; resume from handover doc).
  - **External memory & compaction (the brain's durable swap):** treat Workstreams as your
    memory — hold only their IDs in-window; at the START of each turn read `list_workstreams`,
    then `get_workstream(id)` for the stream you're about to advance; watch `report_cost`, and
    at high context call `compact_self` (safe — workstreams are durable) then continue from the
    rehydrated index. Respect an ACTIVE-WORKSTREAM CAP (a configurable small number) so the
    brain isn't asked to juggle too many at once.
- Add a one-line pointer in the existing `context_management_block/0` noting the brain can now
  `compact_self` (superseding the "ask the operator to /compact you" line).

### 12. Console Workstreams panel + LiveView test
- Render a Workstreams panel: one row per workstream → its phases → four stage chips
  (`spec|implement|test|review`), current phase/stage highlighted, overall `done/total`, and
  the brain-context % (from `report_cost`). Subscribe to the workstream PubSub topic; update on
  broadcasts (keep both states mounted + toggle hidden per the project's LiveView stream
  pattern). Broadcast from `Orchestrator.Workstreams` on create/plan_phases/record_stage.
- `test/repo_builder_web/live/test_workstreams_panel_test.exs`: mount the console for an
  orchestrator with two seeded workstreams; assert both render with phase/stage state;
  broadcast a `record_stage` update and assert the panel re-renders the new stage chip.
- Optionally capture a Playwright/Tidewave screenshot of `http://localhost:4000`.

### 13. Optional catalog parity type
- In `catalog.ex`, add `spec_implement_test_review` to `types/0` + a `steps/2` clause
  (`spec → implement → review →(fix)→ done`) so `start_adw` can run the single-shot shape.
  Pure data; do NOT change `@default_type`.

### 14. Tidewave runtime validation
- App running (`scripts/pg.sh start`; `mix phx.server`): use Tidewave `project_eval` to drive
  `Workstreams.create_workstream/2` → `plan_phases/3` → `record_stage/3` → `get_workstream/2`
  and confirm the state machine + rehydration record; simulate `compact_self` and assert the
  next-turn seed contains the `list_workstreams` index; `execute_sql_query` to confirm
  `orchestrator_workstream_phases` JSONB `stages` persist. Note results.

### 15. Run the full validation gate
- Run every command in `Validation Commands`; fix until green with zero regressions.

## Testing Strategy
### Unit Tests
- `Orchestrator.Workstreams` state machine: create + plan_phases; per-stage advance; the
  `review → fix → review` branch; `:blocked`; next-phase promotion; multi-workstream isolation.
- Rehydration record: `list_workstreams/1` index fields; `get_workstream/2` returns goal/DoD,
  per-phase `spec_path`, completed vs remaining, current pointer, and a single `next_action`.
- Tool handlers: all new tools' happy paths + validation errors; `ToolCatalog.names/0`
  advertises every new tool (binding parity for MCP + pi).
- Schema changesets: enum guards; JSONB `stages` round-trip; FK `on_delete: :delete_all`
  cascade (deleting an orchestrator/workstream removes its phases).
- Queue: workstream-tagged resume names the right stream; rehydrate-on-resume seeds the index;
  no active workstreams ⇒ unchanged (back-compat).
- System prompt: both new blocks present and reference the right tools/commands/template.

### Edge Cases
- Multiple workstreams advancing in one turn → workers run concurrently; at the 100-slot
  admission cap further spawns get clean capacity errors (no crash).
- `record_stage` / `get_workstream` with an unknown `workstream_ref` → `{:error, :not_found}`
  surfaced as a tool error.
- Review fails repeatedly → bounded fix attempts then `:blocked` (no infinite loop); align with
  the queue's replan/circuit-breaker accounting, per workstream.
- `/implement` with no `spec_path` (command STOPs) → protocol guarantees the spec stage's
  `artifact`; test the missing-artifact guard.
- `compact_self` mid-pipeline → next turn rehydrates from `list_workstreams`; in-flight workers
  keep running and their returns still route by `workstream_id`.
- Worker graceful-handover mid-phase → phase resumes from the handover doc, stage status kept.
- Orchestrator restart with N active workstreams → all reload durably; the scheduler resumes
  each at its current phase/stage.
- Active-workstream cap exceeded → `create_workstream` warns/refuses past the cap (don't let the
  brain over-commit its own context).
- No workstreams at all → orchestrator behaves exactly as today (single Task Ledger path).

## Acceptance Criteria
- Migration creates `orchestrator_workstreams` + `orchestrator_workstream_phases`; the legacy
  single-goal index is relaxed/compatible; `mix ecto.migrate` clean and reversible.
- `Orchestrator.Workstreams` exposes the `@spec`'d functions returning
  `{:ok, t()} | {:error, reason()}`, all DB access behind the context.
- `ToolCatalog.names/0` includes `create_workstream`, `plan_phases`, `record_stage`,
  `list_workstreams`, `get_workstream`, `close_workstream`, `compact_self`; MCP + pi advertise
  them unchanged.
- The orchestrator can hold **multiple** active workstreams; a single brain turn can dispatch
  into several; their workers run concurrently within the admission cap; worker returns resume
  the correct workstream.
- Each workstream is a durable **rehydration record** (id, title, goal/DoD, per-phase
  `spec_path`, completed, remaining, current pointer, `next_action`); `get_workstream`/
  `list_workstreams` return it.
- `compact_self` compacts the brain's context; the next turn is seeded with the
  `list_workstreams` index (rehydrate-on-resume), so the brain continues without amnesia.
- The `work-decomposer` returns context-budgeted phases; per-phase spec→implement→test→review
  with a fix branch updates the durable workstream and is visible live in the console
  Workstreams panel.
- The LiveView integration test drives the Workstreams panel and asserts the streamed phase/
  stage state.
- Full gate green: compile (warnings-as-errors), tests, format, credo --strict, dialyzer.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix ecto.migrate` — applies the workstream migration cleanly (then `mix ecto.rollback` and
  re-migrate to prove reversibility).
- `mix test test/repo_builder/orchestrator/workstreams_test.exs` — workstream state machine +
  rehydration record.
- `mix test test/repo_builder/orchestrator/tools_workstream_test.exs` — tool surface + catalog parity.
- `mix test test/repo_builder/orchestrator/queue_workstream_resume_test.exs` — scheduler,
  tagged return routing, rehydrate-on-resume.
- `mix test test/repo_builder_web/live/test_workstreams_panel_test.exs` — LiveView panel.
- `mix test --warnings-as-errors` — full ExUnit suite, zero failures.
- `mix compile --warnings-as-errors` — clean compile; gradual set-theoretic checker passes.
- `mix format --check-formatted` — formatting.
- `mix credo --strict` — lint, including the every-public-function-has-an-`@spec` gate.
- `mix dialyzer` — `@spec`/contract checking, no new warnings, no stale ignore filters.

## Notes
- **Workstream = the brain's external memory.** The whole compaction story depends on the
  rehydration record being *complete enough* that nothing critical lives only in the LLM
  window. `record_stage` must persist the `spec_path` + outcome at every stage so
  `get_workstream` can always reconstruct "what's done / what remains / next action."
- **Two-sided context de-risking, now three-sided.** Workers don't blow context (decomposer
  right-sizes phases + fresh role workers per stage + graceful handover). The brain doesn't
  blow context (durable workstreams + `compact_self` + rehydrate-on-resume + active-workstream
  cap). The third side is *isolation*: each workstream's dedicated worker(s) keep contexts from
  cross-contaminating.
- **Parallelism bound is real and already enforced.** Concurrent workstream workers are capped
  by `Session.Admission` (`max_live_sessions: 100`) + the `max_children: 200` DynamicSupervisor
  backstop — cite, don't re-invent.
- **Serial brain, parallel workers (unchanged invariant).** `queue.ex` still serializes brain
  *turns*; parallelism comes from one turn fanning out into multiple workstreams whose workers
  then run concurrently. The scheduler just lets the brain pick any ready workstream.
- **Back-compat.** No workstream created ⇒ the existing single Task Ledger path and prompt are
  unchanged. Every new tool/prompt block is additive. Assert this explicitly.
- **Legacy index decision** (task 1): prefer the lowest-churn option — keep `task_ledgers`
  untouched and model Workstreams as a separate parallel structure — unless reusing the ledger
  per-workstream proves cleaner; record the final choice here during implementation.
- **No new dependencies** anticipated (Ecto/JSONB, PubSub, LiveView, slash-command expansion,
  `Jason` for decomposer JSON all exist). Update this section if that changes.
- **Open question resolved:** Workstreams are the top-level unit (primary); the single Task
  Ledger remains as the back-compat default; the `spec_implement_test_review` catalog type is a
  thin single-shot parity path for `start_adw`.
- **Follow-ups (out of scope):** intra-workstream parallel phases (a phase DAG with per-phase
  `depends_on`); auto-classifying the spec command (`/feature` vs `/bug` vs `/chore`) from the
  request; per-workstream budget-guard spend caps; persisting the decomposer's rationale and
  per-phase lessons as `record_reflection` entries tagged by workstream.
```
