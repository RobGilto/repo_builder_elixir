# Feature: Stage-based ADW swimlane cards (group each workflow's events by stage)

## Metadata
issue_number: `UI`
adw_id: `for`
issue_json: `ADWs`

> Filed via `/feature` with the request: *"the UI for ADWs needs to be restructured —
> it needs to be restructured based on **stages**. Here is an example UI from
> `/data/1.Projects/tactical-agentic-coding/tac-14/orchestrator-agent-with-adws/apps/orchestrator_3_stream`
> — compare this to the UI we currently have."* The reference is a Vue/Python app whose
> `frontend/src/components/AdwSwimlanes.vue` is the model to match.

## Feature Description
Restructure the ADWS view of the console so each ADW/agent card presents its activity
**grouped by workflow stage** (`adw_step`: `plan` → `build` → `test` → `review` → `document`
→ `ship`, etc.), instead of the current grouping by raw event **kind**. Within each stage,
the per-event "squares" (category-colored icon faces) render in chronological order; clicking
a square opens the existing event-detail panel. Events without a stage fall back to a single
**"Workflow"** lane (mirroring the reference's `event.adw_step || '_workflow'` rule), so
non-ADW workers degrade gracefully.

This makes the ADWS view read like the reference `AdwSwimlanes.vue`: one card per ADW, a
status-colored header (type, friendly name, status, progress, cost, duration), then a wrapping
row of **stage lanes**, each a labeled, status-tinted box containing that stage's event
squares.

Concretely, two card families are unified onto the stage model:
1. **Workflow ADW cards** (`@workflow_progress` → `adw_card/1`): today their `step_box`es show
   only per-stage *status*. They gain the stage's **event squares** inside each box, keeping the
   ordered/"current step" semantics they already have from `Workflows.run_progress/1`.
2. **Agent swimlane cards** (`@swimlanes` → `adw_agent_card/1`): today grouped by event *kind*.
   They are regrouped **by stage**, with the same labeled stage-lane chrome.

## User Story
As an operator watching AI Developer Workflows on the console
I want each ADW's events organized into per-stage lanes (plan / build / review / …)
So that I can see at a glance which stage a run is in, what happened in each stage, and drill
into any single event — instead of scanning an undifferentiated, kind-grouped square soup.

## Problem Statement
The current ADWS view does not reflect the most important structural fact about an ADW: its
**stages**. The agent swimlane groups events by `kind` (`session`/`text`/`tool_call`/…), which
buries the plan→build→review progression the operator actually reasons about. The workflow card
*has* an ordered stage strip, but the stage boxes are status-only and disconnected from the
event squares, which live in a separate kind-grouped card. The stage of each event already
exists in the data (`adw_step` on the neutral ADW contract envelope, persisted in the row's
`payload`), but it is never threaded onto the event row, so nothing can group by it.

## Solution Statement
Thread the stage onto every event row (live + reconnect, single source of truth), then group by
it:
1. **Data:** add a `:step` field to the event-stream row built by `record_event/4` and
   `log_to_row/4`, derived from the event's `adw_step` (live: `attrs.payload["adw_step"]`, which
   is `event.raw`; reconnect: `log.payload["adw_step"]`), defaulting to `"_workflow"`.
2. **Grouping:** rewrite `agent_swimlanes/1` to group each agent's rows **by stage** in
   first-appearance (chronological) order, producing ordered `%{step, rows}` lanes; rename the
   category filter helper `visible_columns/2` → `visible_stages/2` (filter squares by active
   category within each stage, drop empty stages).
3. **Components:** add a typed `stage_lane/1` function component (a labeled, status-tinted box —
   reusing the existing `.cns-step-box` look — whose body is a wrapping `.cns-square` grid), and
   render the agent card's stages through it. Enrich `adw_card/1`'s `step_box` so each workflow
   stage box also holds that stage's event squares.
4. **Detail panel:** add the **stage** to `event_detail_panel/1`'s metadata grid (the reference
   shows "Step").
5. The existing category-filter chips, `open_event`/`close_event` detail flow, and the
   reconnect/backfill seam are reused unchanged.

## Relevant Files
Use these files to implement the feature:

### Reference / Standards (read before implementing)
- `ai_docs/typed-elixir-standard.md` — the (always) typed coding standard: `@spec` on every
  public function, `@enforce_keys`/`typedstruct`, precise types over `map()`, `{:ok, t()} |
  {:error, reason()}`. Required by `.claude/commands/conditional_docs.md`.
- `BUILD_PROMPT.md` §9 (LiveView Observability Dashboard) — swimlanes + streams + reconnect
  rules; the dashboard renders append-only logs via **streams** and must reseed from persisted
  rows on reconnect (so stage grouping must survive backfill).
- `BUILD_PROMPT.md` §4 (canonical event contract) — `adw_step` lives on the neutral ADW
  envelope and is carried in each canonical event's `raw`.
- `AGENTS.md` — Phoenix v1.8 + LiveView component/test conventions.
- `/data/1.Projects/tactical-agentic-coding/tac-14/orchestrator-agent-with-adws/apps/orchestrator_3_stream/frontend/src/components/AdwSwimlanes.vue`
  — the target UX (per-ADW card → per-stage lanes of event squares → click-to-detail).
- `/data/1.Projects/tactical-agentic-coding/tac-14/orchestrator-agent-with-adws/apps/orchestrator_3_stream/frontend/src/stores/orchestratorStore.ts`
  — the exact grouping rule to mirror: `const step = event.adw_step || '_workflow'`;
  `allAdwEventsByStep[adwId][step]` preserves insertion (chronological) order;
  `formatStepName('_workflow') === 'Workflow'`.

### Implementation files
- `lib/repo_builder_web/live/console_live.ex` — the ADWS render block (≈ lines 3033–3140), the
  row builders `record_event/4` (≈ 2475) and `log_to_row/4` (≈ 3486, backfill), `agent_swimlanes/1`
  (3482) and `visible_columns/2` (3501), the per-agent-event `handle_info({:agent_event, …})`
  clauses (≈ 2115–2334, each sets `payload: event.raw`), and `workflow_views/1` (3465). The
  workflow card render loop at ≈ 3124–3137 passes `view.steps`/`view.current` to `adw_card`.
- `lib/repo_builder_web/components/dashboard_components.ex` — `adw_agent_card/1` (64),
  `adw_card/1` (107), `step_box/1` (145), `event_square/1` (180), `event_detail_panel/1` (201),
  `format_step_name/1` (160), `category_icon/1` (167). Add `stage_lane/1`; restructure the agent
  card and step boxes to host squares.
- `assets/css/app.css` — reuse `.cns-square*` (438–457), `.cns-step-box*` (491–508), `.cns-card*`
  (460–489); add a thin stage-lane wrapper rule (e.g. `.cns-stage-lane` + its squares container)
  if the existing `.cns-step-box` chrome needs a body region for squares.
- `lib/repo_builder/harness/adw/event_schema.ex` — reference only: confirms `adw_step` is on the
  `Envelope` and preserved in `raw` for every decoded event (the data source for `:step`).

### New Files
- `test/repo_builder_web/live/test_adws_stage_swimlanes_test.exs` — `Phoenix.LiveViewTest`
  integration test asserting stage grouping, ordering, the `"_workflow"` fallback, category
  filtering within a stage, and the stage showing in the detail panel.

## Implementation Plan
### Phase 1: Foundation — thread the stage onto every event row
Make the stage a first-class field of the event-stream row, in both the live and reconnect
paths, so all downstream grouping/rendering is a pure read of `row.step`.

- Add a private `@spec`'d helper `event_step(payload :: map()) :: String.t()` that returns
  `payload["adw_step"]` when it is a non-empty binary, else `"_workflow"`.
- In `record_event/4`, set `step: event_step(Map.get(attrs, :payload, %{}))` on the row map
  (the clauses already pass `payload: event.raw`, so no per-clause edits are needed).
- In `log_to_row/4`, set `step: event_step(log.payload)` so reconnect backfill groups identically
  (single source of truth with the live path, per §9).

### Phase 2: Core — stage grouping + the stage-lane component
- Rewrite `agent_swimlanes/1` to group each agent's rows by `&1.step`, preserving
  first-appearance order (e.g. fold rows into an ordered list of `%{step, rows}` keyed by step),
  replacing the `group_by(& &1.kind)` columns. Keep `key`, `name`, `status`.
- Rename/replace `visible_columns/2` → `visible_stages/2`: for each stage lane, filter its rows
  by the active category set (reuse `category_pass?/2`), drop empty stages.
- Add `stage_lane/1` to `DashboardComponents` (typed `attr`s: `id`, `step` name, optional
  `status`, and an `:inner_block` slot or a `rows` list): renders a labeled box using the
  `.cns-step-box` look (status tint via `data-step-status`, `--current` highlight optional) with
  a `.cns-square` grid body. Reuse `format_step_name/1` so `"_workflow"` → `"Workflow"`.
- Update the agent card render (console_live ≈ 3106–3137) to iterate `visible_stages(...)` and
  render a `stage_lane` per stage, each containing `event_square`s for its rows.

### Phase 3: Integration — unify the workflow card + detail panel + filters
- Enrich `adw_card/1`'s `step_box/1` so each workflow stage box also renders the event squares
  for that stage: in the workflow render loop, join the run's `event_buffer` rows
  (`agent_key == run_id`) grouped by `:step` and pass each step's squares into the matching box.
  Preserve the existing ordered step list + `current?` highlight from `run_progress`.
- Add a `step` row to `event_detail_panel/1`'s metadata grid (`@event.step`, humanized).
- Confirm the existing category-filter chips now filter squares within stages (via
  `visible_stages/2`) and that the empty-state (`@workflow_progress == %{} and @swimlanes == []`)
  is unaffected.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Create the LiveView integration test first (red)
- Add `test/repo_builder_web/live/test_adws_stage_swimlanes_test.exs`
  (`use RepoBuilderWeb.ConnCase, async: false`, `import Phoenix.LiveViewTest`), modeled on
  `test/repo_builder_web/live/test_orchestrator_adw_shellout_test.exs` (replay recorded ADW
  frames through `RepoBuilder.Harness.Adw.normalize/2` + `Dashboard.broadcast_event/2`).
- Seed an ADW stream whose `text`/`tool`/`usage` frames carry distinct `adw_step` values
  (`plan`, then `build`, then `review`) plus one event with no `adw_step`.
- Assertions (fail before the feature): the card renders a stage lane labeled "Plan" before
  "Build" before "Review"; squares appear under their correct stage; the no-stage event renders
  under a "Workflow" lane; clicking a square (`open_event`) shows the stage in the detail panel.

### 2. Thread the stage onto rows (Phase 1)
- Add `event_step/1`; set `:step` in `record_event/4` and `log_to_row/4` as above.
- Add a focused assertion (or reuse the LiveView test) that a reconnect/backfill path
  (`log_to_row`) yields the same stage as the live path for an identical payload.

### 3. Stage grouping + `stage_lane/1` component (Phase 2)
- Rewrite `agent_swimlanes/1` to ordered stage lanes; add `visible_stages/2`.
- Add the typed `stage_lane/1` component and the `.cns-stage-lane` CSS (if needed); render the
  agent card through it.

### 4. Unify the workflow card + detail panel (Phase 3)
- Enrich `step_box/1`/`adw_card/1` to host per-stage squares from the run's buffer rows.
- Add the `step` row to `event_detail_panel/1`.

### 5. Make the test green + visual check
- Run the new LiveView test; iterate until green.
- Optional visual proof: with the app running (`scripts/pg.sh start`, `mix phx.server`), start an
  ADW from the orchestrator chat and capture a screenshot of `http://localhost:4000` (ADWS view)
  via Tidewave Web vision mode (or Playwright MCP) showing per-stage lanes.

### 6. Run the full validation gate
- Execute every command in **Validation Commands**; all green, zero new warnings (compiler +
  Dialyzer), zero regressions.

## Testing Strategy
### Unit Tests
- `agent_swimlanes/1`: given rows with mixed `:step` values, returns ordered `%{step, rows}`
  lanes in first-appearance order; rows with no/blank step bucket under `"_workflow"`.
- `visible_stages/2`: filters squares by active category within each stage and drops emptied
  stages; `:system` rows always pass (matching the LOGS view rule).
- `event_step/1`: binary `adw_step` → itself; `nil`/`""`/missing → `"_workflow"`.
- `DashboardComponents.stage_lane/1`: renders the humanized step name and the squares; `step_box/1`
  still tints by `data-step-status` and highlights `--current`.

### Edge Cases
- Non-ADW worker (Claude harness) with no `adw_step` on any event → a single "Workflow" lane.
- An event arriving before its `step_start` marker (still carries its own `adw_step`) buckets
  correctly (stateless per-event grouping, like the reference).
- Reconnect/backfill: stages identical to the live render (no drift), per §9.
- All categories filtered out of a stage → that stage lane disappears; card with all stages
  emptied falls back to the existing "No events"/empty treatment.
- A long ADW (plan→build→test→review→document→ship): stage lanes wrap without overflow.
- Category-filter chips toggle squares within stages without dropping stage labels that still
  have visible squares.

## Acceptance Criteria
- The ADWS view renders one card per ADW/agent, each showing **per-stage lanes** (not
  kind-grouped columns), in plan→build→…→ship (first-appearance) order.
- Each stage lane shows its event squares (category-colored icon faces) in chronological order;
  clicking a square opens the detail panel, which now shows the event's **stage**.
- Events lacking `adw_step` render under a single **"Workflow"** lane.
- Workflow ADW cards keep ordered status + "current step" highlight, and their stage boxes now
  contain the stage's event squares.
- Category-filter chips filter squares within stages; reconnect reproduces the identical stage
  layout.
- The new `Phoenix.LiveViewTest` passes; the full validation gate is green with zero regressions.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix test test/repo_builder_web/live/test_adws_stage_swimlanes_test.exs` - The new stage-grouping
  LiveView test passes (fails before the feature, passes after).
- `mix test test/repo_builder_web/live/test_orchestrator_adw_shellout_test.exs` - The existing ADW
  shell-out console test still passes (ordered per-step progress + cost) under the restructured view.
- `mix compile --warnings-as-errors` - Compile clean; the gradual set-theoretic type checker and `warnings_as_errors` must pass.
- `mix test --warnings-as-errors` - Run the full ExUnit suite (spawns Postgres-backed cases) with zero failures.
- `mix format --check-formatted` - Ensure code is formatted.
- `mix credo --strict` - Lint, including the "every public function has an `@spec`" convention.
- `mix dialyzer` - `@spec`/contract checking with no new warnings and no stale ignore filters.

## Notes
- **No new dependencies, no migration.** The stage (`adw_step`) is already on the neutral ADW
  contract envelope (`RepoBuilder.Harness.Adw.EventSchema.Envelope`) and is carried in each
  canonical event's `raw`, which is persisted as the row `payload` — so both the live
  (`record_event/4`) and reconnect (`log_to_row/4`) paths can read it with no schema change.
- **Grouping rule mirrors the reference exactly:** `event.adw_step || "_workflow"`, insertion
  order preserved, `"_workflow"` labeled "Workflow" — see `orchestratorStore.ts:587` and
  `AdwSwimlanes.vue:315`.
- **Reuse over rebuild:** `.cns-square`/`.cns-step-box`/`.cns-card` CSS, `event_square/1`,
  `category_icon/1`, `format_step_name/1`, the `open_event`/`close_event` detail flow, and the
  category-filter chips all exist; this feature is mostly regrouping + one new `stage_lane/1`
  component + threading one row field.
- **Scope boundary:** this restructures presentation/grouping only. It does not change the
  canonical event contract, the harness adapters, or persistence. A future enhancement could add
  an explicit ordered-stage roster per workflow type (from `WorkflowEngine.Catalog`) to render
  *not-yet-started* stages as pending placeholders; out of scope here (the reference shows only
  stages that have events).
- **Tidewave validation:** use `project_eval` with `Phoenix.LiveView.Debug.socket/1` to inspect
  the live socket's `event_buffer`/`@swimlanes` and confirm `row.step` is populated and lanes are
  ordered; use the running dashboard for the optional screenshot.
