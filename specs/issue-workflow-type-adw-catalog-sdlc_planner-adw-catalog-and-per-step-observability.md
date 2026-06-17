# Feature: ADW Workflow-Type Catalog + Discovery + Per-Step Observability

## Metadata
issue_number: `workflow-type`
adw_id: `catalog`
issue_json: `+` (interactive request — no GitHub issue)

## Feature Description
Turn the orchestrator's single hardcoded ADW into a **discoverable catalog of named
workflow types** and make each workflow run **observable step-by-step**. Ported from the
reference `orchestrator_3_stream` ADW model (`adws/adw_workflows/adw_*.py` discovery +
`start_adw(workflow_type)` + per-step `StepStart`/`StepEnd` + the `AdwSwimlanes` per-step
view) onto our typed Elixir/OTP `WorkflowEngine`.

Four capabilities, shipped together because they share one substrate (named, multi-step
workflows with per-step state):

1. **Workflow-type catalog** — a typed, `@spec`'d registry of built-in ADW types
   (`plan_build`, `plan_build_review`, `plan_build_review_fix` — the last is today's
   `plan→build→review→fix` shape), each a slug + label + description + a harness-parameterized
   step-list builder. The single source of truth for "what ADWs can I run".
2. **Discovery + `start_adw(workflow_type)`** — a `workflow_type` parameter on `start_adw`
   (both tool bindings) validated against the catalog, defaulting to the current shape for
   back-compat; plus an `{{AVAILABLE_ADW_TYPES}}`-equivalent block injected into the
   orchestrator system prompt so the brain knows the menu. **This unblocks the stashed chore**
   `specs/issue-chore-adw-this-sdlc_planner-port-o3s-orchestrator-prompt.md`.
3. **Per-step observability** — each step becomes a first-class, observable unit: per-step
   status (`pending|running|succeeded|failed`), timing, and cost persisted on the run and
   broadcast on **both** the live `Runner` AND the durable `StepWorker` paths (today the
   durable path is observability-blind). `check_adw` is enriched to report `completed/total`
   progress, a per-step status list, and a recent per-step activity tail (reusing the existing
   `Logs`/`AgentLog` events keyed by the step-session agent id).
4. **Rich swimlane wired to runs** — the console ADWS view (and `WorkflowLive`) renders each
   workflow run with the existing per-step `swimlane/1` + `event_square/1` +
   `event_detail_panel/1` components driven by **WorkflowRun per-step data**, instead of the
   current flat one-orb `swimlane_row`.

Out of scope (Future Considerations): bridging to the Python `adws/` harness; AI/Haiku
two-tier event summaries; cancel/interrupt/retry of a running ADW; unifying the duplicated
`Runner` vs `StepWorker` state machines.

## User Story
As the **orchestrator brain (and the operator watching the console)**
I want to **choose which ADW workflow to launch from a discoverable menu and watch each run
progress step-by-step (status, cost, activity) live**
So that **the orchestrator can run the right multi-step workflow for the task instead of one
hardcoded shape, and I can see exactly where a run is, what each phase did, and what it cost —
without tailing raw logs or guessing from a single `current_step`.**

## Problem Statement
Our Elixir `WorkflowEngine` is durable and correct but exposes **one hardcoded workflow
shape**. `start_adw` (`lib/repo_builder/orchestrator/tools.ex`) calls
`WorkflowEngine.create_example_workflow/2` and takes only `input`+`harness` — there is no
`workflow_type`, no catalog, and no `{{AVAILABLE_ADW_TYPES}}` in the system prompt, so the
orchestrator cannot enumerate or choose workflows. Observability is thin: `check_adw` returns
only run status, a single `current_step`, one scalar `total_cost_usd`, and the rolled-up
`artifacts` map — **no per-step status, progress, timing, or cost**. The rich per-step
swimlane components exist but are wired to *agent* events, not workflow runs, so runs render as
a flat one-orb row. And the durable `StepWorker` path never broadcasts, so resumed/cron-launched
ADWs are invisible to the live UI. The reference `orchestrator_3_stream` solves all of this; we
have none of it.

## Solution Statement
1. Add a typed **`WorkflowEngine.Catalog`** registry of built-in workflow types (slug + label +
   description + step-builder), generalizing the current `example_steps/1` into per-type
   builders. Persist the chosen `type` on the `workflows` row.
2. Add **per-step state** to the run: a `step_states` JSONB map on `workflow_runs`
   (`%{step_name => %{status, started_at, finished_at, cost_usd}}`), written by a shared
   `Workflows.put_step_state/3` helper called from BOTH `Runner` and `StepWorker` at each
   transition, plus a typed `Workflows.run_progress/1` that returns `%{total, completed,
   current, steps: [...]}` (ordering taken from the run's workflow steps). This is authoritative
   (robust to branching like `review → fix`), needs no join table, and powers both `check_adw`
   and the UI.
3. Add a **`workflow_type`** param to `start_adw` (validated against the catalog, helpful error
   listing types, default = `plan_build_review_fix`) in `ToolCatalog` (Claude MCP) AND the pi
   extension TS, dispatched through `Tools`; add an `available_adw_types_block/0` to
   `SystemPrompt.build/1`.
4. **Enrich `check_adw`** to surface progress + per-step status + a recent activity tail
   (`Logs.list_recent/2` over a unified step-session agent id).
5. **Wire the rich swimlane** to runs in the console ADWS view + `WorkflowLive`, driven by
   `run_progress/1`, with a `Phoenix.LiveViewTest` proving it.
6. Cover with context, Catalog, `Tools`, `SystemPrompt`, and LiveView tests; pass the green gate.

## Relevant Files
Use these files to implement the feature:

- `lib/repo_builder/workflow_engine.ex` — facade. Generalize `example_steps/1` into the catalog
  builders; add `create_workflow_of_type/3` (build+persist a workflow for a catalog type);
  keep `create_example_workflow/2` delegating to `plan_build_review_fix` for back-compat. Add a
  `step_agent_id/2` helper (the single source of truth for the step-session agent id) and use it
  in both engines so per-step logs/events correlate under ONE prefix.
- `lib/repo_builder/workflow_engine/catalog.ex` — **NEW.** The typed workflow-type registry:
  `@spec types() :: [type_def()]`, `fetch/1`, `steps/2`, `default_type/0`. `type_def` is a
  `typedstruct`/`@type` (`slug`, `label`, `description`). The only source of truth for available
  types; mirrors `subagent_map`/tier-roster patterns.
- `lib/repo_builder/workflow_engine/step.ex` — referenced: the typed `Step` (status enum
  `pending|running|succeeded|failed|cancelled`, deterministic edges). No change expected; the
  per-step status persisted on the run reuses this status vocabulary.
- `lib/repo_builder/workflow_engine/runner.ex` — live state machine. At step start/end call the
  shared `Workflows.put_step_state/3` + broadcast helper; switch its `wfrun-<id>-<step>` agent id
  to `WorkflowEngine.step_agent_id/2`.
- `lib/repo_builder/workers/step_worker.ex` — durable state machine. Same: write per-step state
  AND broadcast lane/workflow updates at start/end (today it is observability-blind), via the
  same shared helpers; use `WorkflowEngine.step_agent_id/2` (replacing `wfjob-<id>-<step>`).
- `lib/repo_builder/workflows.ex` — the ONLY `Repo` caller for `workflows`/`workflow_runs`. Add
  `@spec`'d `put_step_state(WorkflowRun.t(), String.t(), map()) :: {:ok, WorkflowRun.t()} |
  {:error, Ecto.Changeset.t()}` (read-modify-write merge into `step_states`) and
  `run_progress(WorkflowRun.t()) :: progress()` (typed per-step view derived from the run's
  workflow `steps` order + `step_states`). Reuse `add_run_cost/2` for the run total.
- `lib/repo_builder/workflows/workflow.ex` — add `type :string` to schema, `@type t`, and the
  `cast/3` list (free-form slug; the catalog validates membership at the tool boundary).
- `lib/repo_builder/workflows/workflow_run.ex` — add `step_states :map default %{}` to schema,
  `@type t`, and `cast/3` list.
- `lib/repo_builder/dashboard.ex` — add a per-step broadcast seam (e.g. `broadcast_workflow/2`
  already exists for `{:workflow_update, run}`; add a richer `{:workflow_step, run_id,
  step_view}` message and/or include `step_states` so subscribers can redraw per-step squares).
  Keep additive — do not change the canonical `Event` sum type (§4).
- `lib/repo_builder/orchestrator/tool_catalog.ex` — add `workflow_type` to `start_adw`'s
  `input_schema` (enum of catalog slugs, optional, documented default).
- `priv/orchestrator/pi_extension/orchestrator-tools.ts` — mirror the `workflow_type` param on
  `start_adw` (defs only; logic stays in Elixir, §10 dual binding).
- `lib/repo_builder/orchestrator/tools.ex` — `start_adw`: accept+validate `workflow_type` via
  `Catalog`, build via `create_workflow_of_type/3`, helpful error listing types; `check_adw`:
  extend `run_summary/1` to add `progress` (`completed/total`), `steps` (per-step status+cost),
  and a recent per-step activity `tail` (via `Logs.list_recent/2` over `step_agent_id/2`).
- `lib/repo_builder/orchestrator/system_prompt.ex` — add `available_adw_types_block/0` (markdown
  bullets `- <slug>: <description>` from `Catalog.types()`, empty-state fallback) and reference
  it in `build/1`, mirroring `subagent_map_block/0`/`tools_block/0`. (This is the chore's
  `{{AVAILABLE_ADW_TYPES}}`.)
- `lib/repo_builder/logs.ex` — referenced: reuse `list_recent/2` and `cost_rollup!/1` keyed by
  the step-session agent id for the per-step activity tail + per-step cost. Confirm signatures.
- `lib/repo_builder_web/live/console_live.ex` — the ADWS view. Maintain a `workflow_progress`
  assign (map of `run_id => run_progress`), seed from `Workflows.list_recent_runs/1`, update on
  `{:workflow_update, run}` / `{:workflow_step, ...}` (subscribe to the lanes topic already in
  use), and render each run via the rich `swimlane/1` with per-step squares colored by step
  status instead of only `swimlane_row`.
- `lib/repo_builder_web/components/dashboard_components.ex` — referenced: `swimlane/1`,
  `event_square/1`, `event_detail_panel/1`, `swimlane_row/1`, `adw_orb/1`, `cost_badge/1`.
  Reuse; add a small `workflow_swimlane/1` (or extend `swimlane/1`) that takes per-step status
  columns. Keep `@spec component(map()) :: Phoenix.LiveView.Rendered.t()` + `attr` validation.
- `lib/repo_builder_web/live/workflow_live.ex` — the per-run detail view. Render the per-step
  list (name/status/cost) from `run_progress/1` instead of the flat artifacts `<ul>`.
- `priv/repo/migrations/<ts>_add_workflow_type_and_step_states.exs` — **NEW.** `alter table
  :workflows add :type, :string`; `alter table :workflow_runs add :step_states, :map, null:
  false, default: %{}`. No backfill (nullable type, empty default).
- `config/config.exs` — referenced only if a config knob is wanted; none required (catalog is
  code). Note in `Notes` if added.
- `ai_docs/adw-orchestration.md` — the ADW/workflow engine + durable-split + Oban reference
  (per `conditional_docs.md`: the workflow/ADW engine row).
- `ai_docs/typed-elixir-standard.md` — the enforced **(always)** typed standard.
- `BUILD_PROMPT.md` §7 (workflow engine, durable/live split), §8 (persistence/migrations, JSONB,
  cost float→Decimal boundary), §9 (LiveView/streams/swimlanes), §10 (dual tool binding), §4
  (canonical events — do NOT add a new `Event` variant).

### New Files
- `lib/repo_builder/workflow_engine/catalog.ex` — the workflow-type registry.
- `priv/repo/migrations/<timestamp>_add_workflow_type_and_step_states.exs` — `workflows.type` +
  `workflow_runs.step_states`.
- `test/repo_builder/workflow_engine/catalog_test.exs` — catalog enumeration, fetch, steps-per-
  type, unknown-type error, default type.
- `test/repo_builder/workflows_test.exs` (or extend an existing workflows test) — `put_step_state/3`
  merge semantics + `run_progress/1` derivation (total/completed/current/per-step status), and
  the branching case (`review → fix`).
- `test/repo_builder/orchestrator/adw_tools_test.exs` — `start_adw(workflow_type)` builds the
  right shape, validates unknown types with a helpful error, defaults for back-compat; enriched
  `check_adw` returns progress + per-step status + activity tail.
- `test/repo_builder_web/live/test_adw_swimlane_test.exs` — `Phoenix.LiveViewTest` for the ADWS
  view: a run renders per-step squares with per-step status, updates live on a broadcast.

## Implementation Plan
### Phase 1: Foundation
Add the workflow-type **catalog** and the **per-step state substrate**: the migration
(`workflows.type`, `workflow_runs.step_states`), schema/changeset updates, the `Catalog`
registry (generalizing `example_steps/1`), the `WorkflowEngine.create_workflow_of_type/3` +
`step_agent_id/2` helpers, and the `Workflows.put_step_state/3` + `run_progress/1` context
functions. Lock with Catalog + context unit tests. This is the substrate every later phase needs.

### Phase 2: Core Implementation
Wire the catalog and per-step state into the orchestrator: `workflow_type` on `start_adw` (both
bindings + `Tools`, catalog-validated), the `{{AVAILABLE_ADW_TYPES}}` block in `SystemPrompt`,
the enriched `check_adw` (progress + per-step status + activity tail), and per-step
state-writes + broadcasts on BOTH `Runner` and `StepWorker`. Cover with `Tools` + `SystemPrompt`
tests.

### Phase 3: Integration
Render the rich per-step swimlane for workflow runs in the console ADWS view and the per-step
list in `WorkflowLive`, driven by `run_progress/1` and live broadcasts. Verify the full loop
(orchestrator lists types → launches a chosen type → per-step state accrues on both paths →
`check_adw` reflects progress → the ADWS view draws per-step squares live). Lock with the
LiveView test and the green gate.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Migration: workflow `type` + run `step_states`
- `mix ecto.gen.migration add_workflow_type_and_step_states`.
- `alter table(:workflows) do add :type, :string end`.
- `alter table(:workflow_runs) do add :step_states, :map, null: false, default: %{} end`.
- No backfill. Confirm `mix ecto.migrate` then `mix ecto.rollback` + `mix ecto.migrate`
  round-trips.

### 2. Schema + changeset updates
- `workflow.ex`: add `type: String.t() | nil` to `@type t`, `field :type, :string`, and `:type`
  to `cast/3`.
- `workflow_run.ex`: add `step_states: map()` to `@type t`, `field :step_states, :map, default:
  %{}`, and `:step_states` to `cast/3`.

### 3. Build the `WorkflowEngine.Catalog` registry
- Create `lib/repo_builder/workflow_engine/catalog.ex`. Define a `type_def` (`typedstruct` or
  `@type`: `slug`, `label`, `description`). `@spec types() :: [type_def()]` lists the built-ins:
  `plan_build`, `plan_build_review`, `plan_build_review_fix`. `@spec fetch(String.t()) ::
  {:ok, type_def()} | {:error, :unknown_type}`. `@spec steps(String.t(), String.t()) ::
  {:ok, [map()]} | {:error, :unknown_type}` returns the harness-parameterized step maps per
  type (generalize `WorkflowEngine.example_steps/1`: `plan_build` = plan→build→done;
  `plan_build_review` = +review→done; `plan_build_review_fix` = current shape). `@spec
  default_type() :: String.t()` → `"plan_build_review_fix"`.

### 4. Generalize the engine facade + step-agent id
- In `workflow_engine.ex`: add `@spec create_workflow_of_type(String.t(), String.t(),
  String.t()) :: {:ok, Workflow.t()} | {:error, reason()}` (name, type, harness) → `Catalog.steps`
  → persist a `Workflow` with `type` set. Make `create_example_workflow/2` delegate to
  `create_workflow_of_type(name, Catalog.default_type(), harness)` (back-compat). Keep
  `example_steps/1` delegating to `Catalog.steps(default_type(), harness)`. Add `@spec
  step_agent_id(Ecto.UUID.t(), String.t()) :: String.t()` returning ONE canonical id (e.g.
  `"wf-#{run_id}-#{step}"`) and use it in Runner + StepWorker.

### 5. `Workflows` context: per-step state + progress
- Add `@spec put_step_state(WorkflowRun.t(), String.t(), map()) :: {:ok, WorkflowRun.t()} |
  {:error, Ecto.Changeset.t()}` — read-modify-write deep-merge `%{step => attrs}` into
  `step_states` (attrs: `status`, `started_at`, `finished_at`, `cost_usd` as string/nil — keep
  tokens/cost off the Decimal path except the existing run total). 
- Add a typed progress view: `@type step_progress :: %{name: String.t(), status: atom(),
  cost_usd: String.t() | nil, started_at: String.t() | nil, finished_at: String.t() | nil}` and
  `@type progress :: %{total: non_neg_integer(), completed: non_neg_integer(), current:
  String.t() | nil, steps: [step_progress()]}`. `@spec run_progress(WorkflowRun.t()) ::
  progress()` — order steps by the run's workflow `steps`, fold in `step_states` (default
  `:pending`), `completed` = count of `:succeeded`, `current` = `run.current_step`.
- Unit test (`workflows_test.exs`): `put_step_state` merges without clobbering siblings;
  `run_progress` totals/completed/current; branching (`review` failed → `fix`) is represented.

### 5b. Catalog unit test
- `test/repo_builder/workflow_engine/catalog_test.exs`: `types/0` lists the three; `fetch/1`
  ok + `:unknown_type`; `steps/2` returns the expected step names per type; `default_type/0`.

### 6. Write per-step state + broadcasts in BOTH engines
- `runner.ex`: at `:run_step` start, `put_step_state(run, name, %{status: :running, started_at:
  now})` + broadcast; on step success/fail, `put_step_state(run, name, %{status:
  :succeeded|:failed, finished_at: now, cost_usd: ...})` + broadcast. Switch agent id to
  `WorkflowEngine.step_agent_id/2`.
- `step_worker.ex`: same per-step writes + lane/workflow broadcasts at start and on
  done/error/timeout (today it broadcasts nothing). Switch agent id to `step_agent_id/2`.
- Extract a tiny shared helper (in `WorkflowEngine` or `Dashboard`) so both paths emit the SAME
  per-step broadcast shape (avoid drift; full engine-unification stays out of scope).
- Update/confirm existing Runner/StepWorker tests still pass with the new agent-id prefix and
  the extra writes (the per-step writes must not change terminal run status/artifacts behavior).

### 7. `start_adw(workflow_type)` — both bindings + Tools
- `tool_catalog.ex`: add `workflow_type` (string, `enum` of `Catalog` slugs, optional,
  description noting the default) to `start_adw`'s `input_schema`.
- `pi_extension/orchestrator-tools.ts`: mirror the `workflow_type` param on `start_adw`.
- `tools.ex` `start_adw`: read `workflow_type` (default `Catalog.default_type()`), validate via
  `Catalog.fetch/1` → on `:unknown_type` return a helpful error listing `Catalog.types()` slugs;
  build via `WorkflowEngine.create_workflow_of_type/3`; keep returning `%{"status" => "started",
  "run_id" => run_id, "workflow_type" => type}`.

### 8. `{{AVAILABLE_ADW_TYPES}}` block in the system prompt
- `system_prompt.ex`: add `available_adw_types_block/0` (bullets `- <slug>: <description>` from
  `Catalog.types()`, empty-state fallback) and reference it in `build/1` near the tools/subagent
  blocks. Extend `system_prompt_test.exs` asserting the block lists a catalog type.
- Note in the PR/Notes that this resolves the dependency in
  `specs/issue-chore-adw-this-sdlc_planner-port-o3s-orchestrator-prompt.md`.

### 9. Enrich `check_adw`
- `tools.ex`: extend `run_summary/1` (or the `check_adw` handler) to include `progress`
  (`%{"completed" => n, "total" => m}`), `steps` (per-step `%{name,status,cost_usd}` from
  `Workflows.run_progress/1`), `current_step`, and a recent activity `tail` built from
  `Logs.list_recent(step_agent_id, n)` for the current/last step (reuse `log_summary/1`). Keep
  the existing keys (`run_id/status/current_step/cost_usd/artifacts`) for back-compat.

### 10. Tools unit tests
- `test/repo_builder/orchestrator/adw_tools_test.exs` (Fake harness, SessionCase): `start_adw`
  with each `workflow_type` creates a workflow whose steps match the catalog; unknown type → a
  helpful `{:error, ...}` listing types; default applies when omitted; after driving a run (or
  seeding `step_states`), `check_adw` returns `progress` (completed/total), per-step `steps`
  with statuses, and an activity `tail`.

### 11. LiveView: rich per-step swimlane for runs (test first)
- `test/repo_builder_web/live/test_adw_swimlane_test.exs` (`async: false`): mount `~p"/"`, switch
  to the ADWS view, seed a `WorkflowRun` with `step_states`, assert per-step squares render with
  per-step status (element ids/classes), then broadcast a `{:workflow_update, run}` /
  `{:workflow_step, ...}` and assert the lane updates live.
- `dashboard_components.ex`: add `workflow_swimlane/1` (or extend `swimlane/1`) rendering per-step
  columns of `event_square`/status pills from a `run_progress` view; `@spec` + `attr`.
- `console_live.ex`: add a `workflow_progress` assign (`%{run_id => progress}`), seed from
  `Workflows.list_recent_runs/1` |> `run_progress/1` on mount, update on the workflow/lane
  broadcasts, and render runs via `workflow_swimlane/1` in the ADWS column (replacing the flat
  `swimlane_row` for workflow lanes; keep `swimlane_row` for agent lanes).
- `workflow_live.ex`: render the per-step list (name/status/cost) from `run_progress/1`.

### 12. Run the validation commands
- Run every command in **Validation Commands** and fix any failure until all are green. Confirm
  `mix ecto.rollback` + `mix ecto.migrate` round-trips the migration. Optionally eyeball via
  Tidewave (see Notes).

### 13. Post-implementation: offer to revisit the prompt-compatibility chore
- After the green gate passes, this feature has delivered the `workflow_type` param and the
  `{{AVAILABLE_ADW_TYPES}}` block — which is exactly the hard dependency that blocked the stashed
  chore `specs/issue-chore-adw-this-sdlc_planner-port-o3s-orchestrator-prompt.md`.
- **ASK THE USER** whether they want to now re-explore that chore's o3s prompt-compatibility
  analysis and update the orchestrator system prompt in our codebase (the remaining prose
  niceties — `ultrathink` keyword, inline `/slash-command` guidance, narrative framing — plus
  confirming the freshly-added `{{AVAILABLE_ADW_TYPES}}` block reads well). Do NOT auto-start it;
  surface it as an explicit offer so the user decides whether to proceed in this session or later.

## Testing Strategy
### Unit Tests
- **Catalog**: `types/0` lists the three built-ins; `fetch/1` ok + `:unknown_type`; `steps/2`
  returns the right step names per type; `default_type/0`.
- **Workflows context**: `put_step_state/3` merges one step without clobbering siblings;
  `run_progress/1` computes total/completed/current and per-step status from `step_states`
  ordered by the workflow steps; the branching case (`review` → `fix`) yields a coherent
  per-step view; a fresh run (empty `step_states`) → all `:pending`, `completed: 0`.
- **Tools**: `start_adw(workflow_type)` builds the catalog shape; unknown type → helpful error;
  default when omitted; enriched `check_adw` returns progress + per-step statuses + activity tail;
  existing `check_adw` keys still present (no regression).
- **SystemPrompt**: the `{{AVAILABLE_ADW_TYPES}}` block lists a catalog type and renders the
  empty-state fallback path.
- **Engines**: Runner + StepWorker still drive a run to the correct terminal status/artifacts
  AND now write per-step `step_states`; StepWorker now emits the lane/workflow broadcasts.

### Edge Cases
- Unknown `workflow_type` → `{:error, ...}` listing available types (never a crash).
- `workflow_type` omitted → defaults to `plan_build_review_fix` (back-compat with today's
  `start_adw`).
- Branching workflow (`review` fails → `fix` runs): per-step view shows `review` as a non-final
  outcome and `fix` as the continuation; `completed/total` stays coherent (don't double-count).
- Fresh run with empty `step_states` / `check_adw` before any step finishes → progress `0/total`,
  all `:pending`, no crash, no division issues.
- Durable resume: a run resumed by `WorkflowResume`/`StepWorker` writes per-step state AND
  broadcasts, so the UI reflects it live (today it would not).
- Cost stays on the float→Decimal boundary for the RUN total (`add_run_cost/2`); per-step
  `cost_usd` is a display string/nil and never re-enters the Decimal accumulation path (no
  double-counting).
- No new canonical `Event` variant is introduced (§4); per-step signals ride the additive
  Dashboard broadcast seam only.
- Disconnected LiveView mount renders the ADWS view without crashing (assigns default to empty).

## Acceptance Criteria
- A typed `WorkflowEngine.Catalog` enumerates ≥3 built-in workflow types; the run's workflow
  records its `type`.
- `start_adw` accepts a catalog-validated `workflow_type` (both Claude MCP + pi bindings),
  defaults to the current shape, and errors helpfully on unknown types; the system prompt's
  `{{AVAILABLE_ADW_TYPES}}` block lists the menu (resolving the stashed chore's dependency).
- Each run persists per-step status/timing/cost in `workflow_runs.step_states`, written on BOTH
  the live `Runner` and durable `StepWorker` paths, with live broadcasts from both.
- `check_adw` returns `completed/total` progress, a per-step status list, and a recent per-step
  activity tail — in addition to the existing fields (no regression).
- The console ADWS view and `WorkflowLive` render workflow runs as per-step swimlanes (status +
  cost per step), updating live.
- No regression to existing cost tracking or terminal run behavior; per-step cost never touches
  the run's Decimal accumulation twice.
- All five green-gate commands pass, plus the new Catalog, Workflows-context, Tools, SystemPrompt,
  and LiveView tests.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix ecto.migrate` — apply the `type` + `step_states` migration (then `mix ecto.rollback` +
  `mix ecto.migrate` round-trips).
- `mix test test/repo_builder/workflow_engine/catalog_test.exs` — the catalog.
- `mix test test/repo_builder/workflows_test.exs` — per-step state + progress.
- `mix test test/repo_builder/orchestrator/adw_tools_test.exs` — start_adw(workflow_type) + enriched check_adw.
- `mix test test/repo_builder/orchestrator/system_prompt_test.exs` — the {{AVAILABLE_ADW_TYPES}} block.
- `mix test test/repo_builder_web/live/test_adw_swimlane_test.exs` — the ADWS per-step swimlane.
- `mix compile --warnings-as-errors` - Compile clean; the gradual set-theoretic type checker and `warnings_as_errors` must pass.
- `mix test --warnings-as-errors` - Run the full ExUnit suite (spawns Postgres-backed cases) with zero failures.
- `mix format --check-formatted` - Ensure code is formatted.
- `mix credo --strict` - Lint, including the "every public function has an `@spec`" convention.
- `mix dialyzer` - `@spec`/contract checking with no new warnings and no stale ignore filters.

## Notes
- **No new dependencies.** Pure WorkflowEngine/context/LiveView work over existing Ecto, the
  canonical event seam, and the typed contract. The only schema change is the migration above.
- **Why a derived-but-persisted per-step model (not a join table):** a `step_states` JSONB map on
  the run is authoritative (robust to branching like `review → fix`), needs no second table or
  FK, and is written at the same transitions both engines already persist — minimizing the
  durable/live drift surface. A `workflow_run_steps` table is a clean future migration if
  per-step querying/analytics is later needed (the context API stays the same).
- **Unblocks the stashed chore** `specs/issue-chore-adw-this-sdlc_planner-port-o3s-orchestrator-prompt.md`:
  step 8 delivers the `{{AVAILABLE_ADW_TYPES}}` block and step 7 the `workflow_type` param the
  chore's Step 1 gate requires. After this lands, that chore can resolve (remaining items there
  are prose niceties: `ultrathink`, inline `/slash-command`, narrative).
- **Post-implementation handoff (see Step 13):** once the green gate passes, the implementer must
  ASK THE USER whether they want to re-explore the o3s prompt-compatibility chore and update the
  orchestrator system prompt in our codebase now that its dependency is satisfied — surfaced as an
  explicit offer, not auto-started.
- **Reference parity (o3s):** mirrors `_get_available_workflow_types` (glob → slugs) with a typed
  Elixir `Catalog`, `start_adw(workflow_type)`, `check_adw` progress + per-step activity, and the
  `AdwSwimlanes` per-step view — but on OUR multi-harness WorkflowEngine, NOT by bridging to the
  Python `adws/` scripts (explicitly out of scope; see `adws/README.md`).
- **Future Considerations (out of scope here):** bridge to the Python `adws/` harness; AI/Haiku
  two-tier per-event summaries; cancel/interrupt/retry of a running ADW (the `cancelled` status
  exists but nothing sets it); unify the `Runner` (live) and `StepWorker` (durable) state
  machines (they re-implement render/session/advance separately — shared helpers here reduce but
  don't remove the drift).
- **Optional runtime validation via Tidewave** (`http://localhost:4000/tidewave/mcp`):
  - `project_eval`: `RepoBuilder.WorkflowEngine.Catalog.types()` to eyeball the menu;
    `RepoBuilder.Orchestrators.get_or_create_default() |> elem(1) |>
    RepoBuilder.Orchestrator.SystemPrompt.build()` to see the `{{AVAILABLE_ADW_TYPES}}` block.
  - `execute_sql_query`: `select id, type from workflows;` and `select id, current_step,
    step_states from workflow_runs order by updated_at desc limit 5;`.
  - Screenshot `http://localhost:4000` (ADWS view) via the Playwright MCP tools for visual proof.
