# Feature: Unified, human-readable ADW swimlane cards

## Metadata
issue_number: `to`
adw_id: `make`
issue_json: `the`

## Feature Description
The console's **ADWS view** (the center column when the LOGS⇄ADWS toggle is on
ADWS) is hard to read because it renders **three disconnected, competing blocks**
stacked vertically:

1. `#workflow-runs` — `workflow_swimlane/1` cards: one per `WorkflowRun`, showing
   per-step **status squares** (plan/build/test…) sourced from `@workflow_progress`.
2. `#agent-lanes` — streamed `swimlane_row/1` rows: a flat **worker roster**
   (kind/label/harness/status) from `@streams.lanes`.
3. `#swimlanes` — `swimlane/1` panels: **per-agent event squares** grouped by event
   *kind* column, derived from `@event_buffer` via `agent_swimlanes/1`.

So the same run is represented in two unrelated places (a step-status card *and* a
pile of per-agent event squares), with a third roster strip wedged between them.
There is no single "what is this ADW doing right now" object on screen — the
operator has to mentally join three layouts. That is the "weird split between two
areas which makes no sense."

The reference UI that inspired this project
(`tac-14/.../orchestrator_3_stream/frontend/src/components/AdwSwimlanes.vue`) solves
this with **one** vertical list of self-contained **ADW cards**. Each card has:
a status-colored left border; a header with `ADW: <type>`, the run name, a status
pill, and a **duration** in the top-right corner; then a wrapping container of
**step boxes** (each step a distinctly-tinted box with its name + a grid of
**event squares carrying category icons** 💬🛠️🧠🪝⚙️); plus a top-of-view row of
**category filter chips** (Response / Tool / Thinking / Hook / System) and a
**click-a-square → slide-out detail panel**.

This feature rebuilds the repo's ADWS view into that single, coherent card layout:
one card per ADW run, reference-styled, with the worker roster folded into the card
header and the per-agent event squares re-homed under the cards (icon squares,
category-filterable). It reuses the existing `@workflow_progress` views,
`@event_buffer`, the `EventPresenter`, the existing `event_detail_panel/1`, and the
established `--cns-*`/`cns-square`/`cns-cat--*` design tokens.

It also makes the card **title** genuinely human-friendly. The header title comes
from the workflow's `name`/`type`, but those are sometimes machine-looking
(`"232sdasdasd"`, a slug, a UUID-ish blob). So this feature adds a **Fast-tier
agent humanizer**: at ADW launch, a deterministic detector decides whether the name
looks machine-generated; if so, a one-shot **Fast-tier** agent (the operator's
assigned `fast` roster model) is dispatched **asynchronously** to propose a short,
human-friendly title, which is **persisted to `Workflow.metadata`** and broadcast so
the card live-updates. This mirrors the established `RepoBuilder.Explain` pattern
(resolve the Fast roster entry → build a prompt → run a one-shot ephemeral runner
with persistence and the global feed disabled → reply to the caller). The launch is
**never blocked** on the humanizer: the card renders immediately with a deterministic
heuristic title and upgrades in place when (and if) the agent replies.

Scope note: the visual redesign is render-only, but the humanizer is **additive**
and touches the **launch path** + **persistence**. It needs **no migration**
(`Workflow.metadata` is an existing free-form map) and **no canonical `Event`/payload
or harness-adapter change** (it reuses the `Explain`/session-runtime seam). If the
Fast tier is unassigned or the agent fails, the heuristic title stands — the feature
degrades gracefully and never errors a launch or a render.

## User Story
As an operator watching one or more AI Developer Workflows run in the console
I want the ADWS view to show each ADW as a single, self-contained card (type, name,
status, duration, and its steps with per-event icon squares) instead of three
disconnected stacked blocks
So that I can see at a glance what each workflow is and what every step is doing,
without mentally stitching together separate panels.

## Problem Statement
The ADWS view (`console_live.ex:2714`–`2775`) renders three structurally different
layouts for overlapping data:

- **Redundant representation.** A run appears as a per-step status card
  (`workflow_swimlane/1`) *and* the agents running it appear as a separate pile of
  per-agent event squares (`swimlane/1`); nothing visually connects them.
- **A roster wedged in the middle.** `#agent-lanes` (`swimlane_row/1`) is a third,
  flatter block between the two, adding visual noise without tying anything together.
- **Squares without meaning.** Event squares (`event_square/1`) are bare colored
  dots — no category icon, so the operator can't tell a tool call from thinking at a
  glance (the reference uses 💬🛠️🧠🪝⚙️).
- **No duration, no filtering.** The reference shows per-run elapsed/total duration
  and a category-filter chip row scoping the squares; ours has neither in this view.

The data to fix this already exists: `@workflow_progress` carries ordered per-step
status + cost; `WorkflowRun` carries `inserted_at`/`updated_at` and `step_states`
(with `started_at`/`finished_at`) for duration; `@event_buffer` rows carry
`category`/`kind`/`body`/`agent_key`; and `@selected_event` + `event_detail_panel/1`
already implement the slide-out.

### Honest data constraint (drives the design)
`agent_logs` has **no `run_id` and no `adw_step` column** (`logs/agent_log.ex:44`)
and `workflow_runs` has **no agent linkage** (`workflow_run.ex:30`). So unlike the
reference (whose backend tags every event with `adw_step`), we **cannot** attribute
an arbitrary event to a specific workflow step. The redesign therefore must **not**
fabricate an event→step mapping. Instead it unifies the *visual language* into one
card list: ADW runs render as step-box cards (status + the run's live `current_step`
highlighted), and per-agent event squares render in their own consistently-styled
cards (same chrome), category-filterable — removing the "split" by giving every
block one layout, one scroll, one set of affordances, rather than by inventing a
linkage the schema can't support.

## Solution Statement
Replace the three stacked blocks with a **single scrolling list of cards sharing one
visual language**, modeled on `AdwSwimlanes.vue`:

1. **`adw_card/1`** (upgrade of `workflow_swimlane/1`) — one card per `WorkflowRun`
   from `@workflow_progress`: status-colored **left border**; header with a
   **human-friendly ADW title** (the workflow's `type`/`name`, e.g. `bug-fix-test`,
   `plan_build` — *not* a UUID), a status pill, **cost**, and a **duration**
   in the top-right; then a **wrapping** container of **step boxes**. Each step box
   shows the step name + a status accent (and highlights the run's `current_step`).

   **Human-friendly title (explicitly addressed).** Today `workflow_swimlane/1` is
   passed `label={view.current || view.run_id}` (`console_live.ex:2732`), so a run
   with no current step shows a **raw UUID**. `workflow_view/1` also never loads the
   associated `Workflow`, even though that is where the readable `name`/`type` live
   (`Workflow.name`/`Workflow.type`; `run_progress/1` already calls
   `get_workflow(workflow_id)` internally and discards them). The redesign loads the
   workflow once in the view builder and surfaces a **`title`** with a deterministic
   fallback chain: **`metadata["title"]` (the humanized title, if present)** →
   `Workflow.name` → `Workflow.type` (humanized, e.g. `plan_build` → `Plan Build`) →
   `run.current_step` → `"ADW " <> short_id(run.id)`. A UUID is the last resort,
   never the default. The card renders `ADW: <type>` as the small key line and the
   `title` as the prominent name (mirroring the reference's `adw-key` + `adw-name`).
2. **`agent_card/1`** (upgrade of `swimlane/1`) — standalone agents (manual launches /
   not represented by a run) render in the *same* card chrome, each holding columns
   of **`event_square/1`** squares that now carry a **category icon**. These cards sit
   in the same single list, below the ADW cards, under a quiet "Agents" subheading —
   one layout, not a competing one.
3. **Worker roster folded in.** The separate `#agent-lanes` roster block is removed;
   its signal (running workers + harness) is surfaced as a compact roster strip in
   the view header (or as the agent-card header), so it is no longer a third
   disconnected block.
4. **Category filter chips** at the top of the ADWS view (Response/Tool/Thinking/
   Hook/System), reusing the live LOGS-view filter mechanism, scoping which event
   squares show. At least one chip always stays active (reference behavior).
5. **Duration** derived in the workflow view builder from run timestamps /
   `step_states` (display string; no new persistence).
6. **Detail panel unchanged** — squares keep `phx-click="open_event"` → the existing
   `event_detail_panel/1` slide-out (already wired via `@selected_event`).
7. **Fast-tier title humanizer** (`RepoBuilder.Workflows.TitleHumanizer`, new) —
   mirrors `RepoBuilder.Explain`. At ADW launch, a deterministic
   **`machine_name?/1`** detector classifies the chosen `name`/`type` (machine-like
   = hex/base-N blobs, long digit runs, low vowel ratio, high character-class
   entropy, or a UUID). If machine-like (or absent), and the orchestrator's
   **`fast`** roster entry resolves (`Explain.fast_config/1` style), dispatch a
   **one-shot ephemeral Fast-tier runner** with a tight prompt ("rename this ADW to
   ≤4 plain words from its type/steps/issue") — persistence and the global feed
   **disabled** (no `agent_logs` row, no console pollution, no durable agent),
   exactly like `Explain.Server`. On reply, sanitize to a short title and **persist**
   it via `Workflows.put_workflow_title/2` (`metadata["title"]`), then broadcast
   (`Dashboard.broadcast_workflow_step/2` or a dedicated title broadcast) so the open
   card swaps the heuristic title for the humanized one live. The call is **async and
   non-blocking** (the ephemeral runner is out-of-band, like `Explain`); launch
   returns immediately. Idempotent: once `metadata["title"]` is set, never re-run.
   Failure/timeout/no-Fast-tier ⇒ keep the heuristic title; never error a launch.

The card data is read from existing assigns; the view-layer Elixir change is
enriching `workflow_view/1`/`default_workflow_view/1` with a derived `duration`
string, a `type`, and a human-friendly `title` (from `metadata["title"]` ▸ the
fallback chain), plus a `category_icon/1` helper. The humanizer adds one new context
function (`Workflows.put_workflow_title/2`, writing `metadata`) and one new module
pair (`TitleHumanizer` + its ephemeral runner) wired into the launch path — no
canonical `Event`/payload change, no migration.

## Relevant Files
Use these files to implement the feature:

- `lib/repo_builder_web/live/console_live.ex` — owns the ADWS view template
  (`:2714`–`2775`: `#swimlanes` → `#workflow-runs`/`#agent-lanes`/`#swimlanes` +
  `event_detail_panel`), the `workflow_view/1`/`default_workflow_view/1`/
  `workflow_views/1` builders (`:574`–`602`, `:3060`), `agent_swimlanes/1`
  (`:3071`), the view-mode toggle (`toggle_view`, `:1770`), and the existing
  category-filter + `open_event`/`close_event`/`clear_workflows` handlers. The
  template is rewritten to render the unified card list; the builders gain
  `duration`/`type`/`name`.
- `lib/repo_builder_web/components/dashboard_components.ex` — owns
  `workflow_swimlane/1` (`:97`), `swimlane/1` (`:62`), `swimlane_row/1` (`:34`),
  `event_square/1` (`:140`), `event_detail_panel/1` (`:157`), `step_square_class/1`
  (`:127`), `status_class/1` (`:246`), `adw_orb/1` (`:232`). The card components are
  rebuilt here: `adw_card/1`, `agent_card/1`, an enriched `event_square/1` (icon),
  a `step_box/1` sub-component, and a `category_icon/1` helper.
- `lib/repo_builder/workflows.ex` — `run_progress/1` (`:189`) + `progress`/
  `step_progress` types (`:150`–`165`) the cards render. Gains
  `put_workflow_title/2` (write `metadata["title"]`, mirroring `put_step_state/3`'s
  read-modify-write; the only DB-touching addition). The duration derivation lives in
  the console-side view builder.
- `lib/repo_builder/explain.ex` + `lib/repo_builder/explain/server.ex` — **the
  pattern to mirror** for the humanizer: `fast_config/1` resolves the orchestrator's
  `fast` roster entry; `Explain.Server` is the one-shot ephemeral runner dispatched
  through the session runtime with persistence + global feed disabled. The new
  `TitleHumanizer` + its runner are near-copies scoped to "rename an ADW".
- `lib/repo_builder/orchestrators.ex` — `agent_models/1` (the source of the `fast`
  roster entry `Explain.fast_config/1` reads); read-only, reused by the humanizer.
- `lib/repo_builder/workflow_engine.ex` — `create_workflow_of_type/3` (`:77`), the
  launch seam where an ADW's `name`/`type` are first known; the humanizer is invoked
  here (after create, fire-and-forget) so both the orchestrator `start_adw` path and
  the ADW Builder converge on one hook.
- `lib/repo_builder/orchestrator/tools.ex` — `start_adw` handler (`:399`,
  `create_workflow_of_type`) and `lib/repo_builder_web/live/console_live.ex`
  `launch_adw_builder/4` (`:1496`): the two launch entry points. Confirm both flow
  through the `WorkflowEngine` hook so neither bypasses humanization.
- `lib/repo_builder/dashboard.ex` — `broadcast_workflow_step/2` (`:46`) /
  `broadcast_workflow/2` (`:214`): the seam to push the humanized title to open
  consoles so the card updates live.
- `lib/repo_builder/workflows/workflow.ex` — `Workflow` fields incl. `metadata`
  (`:31`, the free-form map the title persists into — no migration) and `name`/`type`
  (`:25`/`:28`, the title source + `machine_name?/1` input).
- `lib/repo_builder/logs/agent_log.ex` — confirms the persistence constraint (no
  `run_id`/`adw_step`); read-only, cited so the implementer does not attempt an
  event→step join.
- `lib/repo_builder/workflows/workflow_run.ex` — `WorkflowRun` fields
  (`inserted_at`/`updated_at`/`step_states`/`current_step`/`status`); read-only,
  the source of the derived duration + status border + current-step highlight.
- `assets/css/app.css` — defines `cns-panel` (`:160`), `cns-cat--*` (`:312`),
  `cns-square`/`cns-square--*` (`:419`), `cns-detail` (`:435`), `cns-orb--adw`
  (`:404`). Add card chrome tokens (status left-border, step box, duration, filter
  chip active state, icon square) reusing the existing palette.
- `BUILD_PROMPT.md` §9 — the LiveView dashboard contract (streams, reconnect
  backfill, ADWS view, chat/events separation) the change must preserve.
- `AGENTS.md` — Phoenix 1.8 + LiveView typed-component conventions (`attr/3`,
  `Phoenix.LiveView.Rendered.t()` specs, no raw `Repo` in the web layer).
- `ai_docs/typed-elixir-standard.md` — the enforced typed standard (`@spec` on every
  public function, `@type`, precise unions, no bare `map()` where a shape is known).

### New Files
- `lib/repo_builder/workflows/title_humanizer.ex` —
  `RepoBuilder.Workflows.TitleHumanizer`: `machine_name?/1` (pure detector),
  `humanize/1`/`maybe_humanize_async/1` (gate + dispatch the Fast-tier runner),
  `fast_config/1`-style roster resolution (reuse `Explain.fast_config/1` directly if
  shared), and the persist-+-broadcast callback. Behaviour-mockable (a small
  `@callback`/config seam) so tests don't hit a real model. Fully `@spec`'d, no raw
  `Repo` (writes go through `Workflows.put_workflow_title/2`).
- `lib/repo_builder/workflows/title_humanizer/server.ex` — the one-shot ephemeral
  runner (near-copy of `RepoBuilder.Explain.Server`): starts a Fast-tier session with
  persistence + global feed disabled, captures the reply, sanitizes to a short title,
  persists + broadcasts, then terminates. Only needed if `Explain.Server` can't be
  reused/parameterized; prefer extracting a shared one-shot runner if trivial.
- `test/repo_builder/workflows/title_humanizer_test.exs` — unit tests for
  `machine_name?/1` (machine-like vs human-like names) and the humanize flow with a
  **mocked** Fast runner (asserts: gated off for human names; persists
  `metadata["title"]` + broadcasts on a good reply; no-Fast-tier and runner-error are
  no-ops that leave the title untouched; idempotent when `metadata["title"]` exists).
- `test/repo_builder_web/live/test_unified_adw_swimlane_cards_test.exs` — a
  `Phoenix.LiveViewTest` integration test that seeds a `WorkflowRun` with
  `step_states`, drives the live event path for an agent, switches to the ADWS view,
  and asserts the unified card layout: an ADW card with `ADW:`/type, status pill,
  duration, per-step boxes (with the current step highlighted), event squares
  carrying category icons, the category-filter chip row, and that clicking a square
  opens the detail panel. Also asserts the three old separate blocks
  (`#agent-lanes` roster as a distinct section) are gone / folded. Includes a
  **live-title-upgrade** assertion: a run seeded with a machine-looking name renders
  the heuristic title first, then — after a title broadcast (simulating the
  humanizer's persist+broadcast) — the card re-renders with the humanized title.

## Implementation Plan
### Phase 1: Foundation — enrich the workflow view + helpers
Extend the console-side workflow view builders so each ADW card has everything the
reference card shows, without new persistence:
- `workflow_view/1` and `default_workflow_view/1` gain `type` (the workflow type),
  a human-friendly **`title`**, and `duration` (a display string derived from
  `WorkflowRun.inserted_at`→`updated_at` for finished runs, or `inserted_at`→now for
  running ones; reuse `step_states` `started_at`/`finished_at` if richer). Keep
  `run_id`/`status`/`current`/`cost`/`completed`/`total`/`steps`.
- **Title derivation.** Load the run's `Workflow` once in `workflow_view/1`
  (`Workflows.get_workflow(run.workflow_id)`; `nil`-safe — ad-hoc runs have no
  `workflow_id`) and compute `title` via the fallback chain **`metadata["title"]`**
  (the humanized title, when the Fast-tier humanizer has persisted one) →
  `Workflow.name` → humanized `Workflow.type` → `run.current_step` →
  `"ADW " <> short_id(run.id)`. Add an `@spec`'d `workflow_title/2` (run +
  workflow-or-nil) helper plus a `humanize/1` for `type` strings (`"plan_build"` →
  `"Plan Build"`). `default_workflow_view/1` (used when a run is first seen via live
  broadcast before a refetch) gets the same chain with whatever is known, never a
  bare UUID as the default. Avoid an N+1: this builder runs over ≤50 recent runs on
  (re)seed only — a per-run `get_workflow` is acceptable, but prefer batching the
  workflow lookups if trivial.
- Add a pure `category_icon/1` (in `dashboard_components.ex`) mapping each canonical
  event category to its glyph (`:response`→💬, `:tool`→🛠️, `:thinking`→🧠,
  `:hook`→🪝, `:system`→⚙️), `@spec`'d, total over the `@event_categories` union.
- Confirm via Tidewave `project_eval` the exact `run_progress/1` step shape and a
  real `@event_buffer` row shape (`category`/`kind`/`body`/`agent_key`) so the cards
  bind to reality, not assumptions.

### Phase 2: Core Implementation — the card components
In `dashboard_components.ex`:
- **`adw_card/1`** — replaces `workflow_swimlane/1`. Typed `attr`s: `id`, `title`
  (string, the human-friendly name), `type` (string), `status`, `completed`,
  `total`, `cost`, `duration` (string|nil), `current` (string|nil, the active step),
  `steps` (list). Renders: a card with a **status-colored left border**
  (`status_class`-keyed), a header (`ADW: <type>` key line, the prominent `title`,
  status pill, `cost_badge`, `adw_orb`, and **duration top-right**), and a
  **wrapping** `step_box/1` per step. The header must never display `run_id`/a UUID
  as the title.
- **`step_box/1`** — a sub-component: distinctly-tinted box (status accent via
  `step_square_class`-style mapping), the formatted step name, a **highlight** when
  `name == current`, and room for event squares (slot) for parity with the reference
  step boxes.
- **`event_square/1`** — enrich to render the `category_icon/1` glyph inside the
  square (keep `phx-click="open_event"`, `phx-value-id`, tooltip `summary`); add an
  `icon` derivation by category. Keep it a `<button>`.
- **`agent_card/1`** — replaces `swimlane/1`: same card chrome as `adw_card/1`
  (consistent visual language), header with agent name + status + harness, body =
  columns of `event_square/1` (one column per event kind, as today) so standalone
  agents live in the same list, not a competing block.
- Delete/retire `swimlane_row/1` usage (roster folded into the view header); keep the
  function only if another caller exists (grep first).

### Phase 3: Integration — rewrite the ADWS view template + filters
In `console_live.ex` (`#swimlanes` region, `:2714`):
- Render **one** scrolling column: the CLEAR control + category-filter chip row at
  top; then `adw_card/1` for each `workflow_views(@workflow_progress)`; then, under a
  quiet "Agents" subheading, `agent_card/1` for each `agent_swimlanes(assigns)` whose
  events pass the active category filter; then the unchanged `event_detail_panel/1`.
- Remove the separate `#agent-lanes` `swimlane_row` block; surface running-worker/
  harness info as a compact roster strip in the view header instead.
- Wire the category-filter chips to the existing LOGS-view filter assign/handler
  (reuse the same event + state; enforce "≥1 active") so squares filter live; ensure
  the empty-state ("No AI Developer Workflows found — start one from the chat")
  renders when `@workflow_progress` is empty.
- Preserve: `toggle_view`, `clear_workflows` (+ `any_finished_workflows?`),
  `open_event`/`close_event` → detail panel, reconnect seeding
  (`seed_workflow_progress/1`), and the `view_mode != :adws && "hidden"` toggle (keep
  both views mounted, toggle via hidden — per the console-live pattern).

### Phase 4: Fast-tier title humanizer (launch-time, async, persisted)
Make machine-looking titles human-friendly via the operator's assigned **Fast**
agent, mirroring `RepoBuilder.Explain`:
- Add `Workflows.put_workflow_title/2` — read-modify-write `metadata["title"]`
  (mirror `put_step_state/3`), `@spec`'d `{:ok, Workflow.t()} | {:error, changeset}`.
- Build `RepoBuilder.Workflows.TitleHumanizer`: a pure `machine_name?/1` detector;
  `maybe_humanize_async/1` that (a) no-ops if `metadata["title"]` already set, (b)
  no-ops if the name/type is already human-friendly, (c) resolves the `fast` roster
  entry (reuse `Explain.fast_config/1`) and no-ops with `{:error, :no_fast_agent}`,
  (d) otherwise dispatches the one-shot Fast-tier runner out-of-band. The runner
  (reuse/extract `Explain.Server`) runs with persistence + global feed **disabled**,
  captures the reply, sanitizes (strip quotes/punctuation, clamp length/words), then
  `put_workflow_title/2` + broadcast. Inject the runner behind a behaviour/config seam
  so tests mock it.
- Wire the hook into `WorkflowEngine.create_workflow_of_type/3` (the single seam both
  `start_adw` and the ADW Builder reach) as a **fire-and-forget** call after the
  workflow row is created — launch never awaits it.
- On the LiveView side, handle the title broadcast: merge the new title into the
  matching `@workflow_progress` view (like `update_workflow_steps/3`) so the open card
  re-renders with the humanized title without a reconnect.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Read the standards and confirm the data contract
- Read `ai_docs/typed-elixir-standard.md`, `BUILD_PROMPT.md` §9, and `AGENTS.md`.
- Re-read `console_live.ex` ADWS region (`:2714`–`2775`), the workflow view builders
  (`:574`–`602`, `:3060`), `agent_swimlanes/1` (`:3071`), and
  `dashboard_components.ex` in full.
- Confirm the persistence constraint by reading `logs/agent_log.ex:44` and
  `workflows/workflow_run.ex:30` — there is **no** `run_id`/`adw_step`/agent linkage;
  the design must not attempt an event→step join.
- Use Tidewave `project_eval` to inspect a real `Workflows.run_progress/1` result and
  a real `@event_buffer` row so the card bindings match reality.

### 2. Add the LiveView integration test first (red)
- Create `test/repo_builder_web/live/test_unified_adw_swimlane_cards_test.exs`
  (model the mount/seed on `test/repo_builder_web/live/test_adw_swimlane_test.exs`:
  `use RepoBuilderWeb.ConnCase, async: false`, `seed_run/0`, `live(conn, ~p"/")`,
  `element("#view-toggle") |> render_click()` to enter ADWS).
- Assert the target layout (will fail until implemented): an `adw_card` showing the
  **human-friendly workflow name** (seed the `Workflow` with a recognizable
  `name`/`type` like `"bug-fix-test"` and assert the card renders it, and that it
  does **not** render the run's UUID as the title), `ADW:` + the workflow type, a
  status pill, a duration, per-step boxes with `data-step-status` and the
  `current_step` highlighted; the category-filter chip row; event squares carrying a
  category icon; and that `open_event` on a square opens `#event-detail-panel`.
  Assert there is no standalone `#agent-lanes` roster section.
- Add a focused title-fallback assertion: a run whose `Workflow` has only a `type`
  (no `name`) renders the humanized type; a run with no `workflow_id` renders the
  `"ADW <short-id>"` fallback (still not a bare UUID).

### 3. Enrich the workflow view builders (`console_live.ex`)
- Add `type`, a human-friendly **`title`**, and a derived `duration` string to
  `workflow_view/1` and `default_workflow_view/1` (duration from `WorkflowRun`
  timestamps / `step_states`). Add `current` if not already surfaced to the card.
  Keep all existing keys so `workflow_views/1`/seeding/live-merge paths stay green.
  `@spec` the `duration` and `workflow_title/2` (+ `humanize/1`) helpers.
- Implement the title fallback chain (`Workflow.name` → humanized `Workflow.type` →
  `current_step` → `"ADW " <> short_id`); load the `Workflow` via
  `Workflows.get_workflow/1` (`nil`-safe). Replace the
  `label={view.current || view.run_id}` call site so a UUID is never shown as a title.

### 4. Build the card components (`dashboard_components.ex`)
- Add `@spec`'d `category_icon/1` over `@event_categories`.
- Implement `adw_card/1`, `step_box/1`, `agent_card/1`; enrich `event_square/1` with
  the category icon. Each public component carries `attr/3` declarations and a
  `@spec ... :: Phoenix.LiveView.Rendered.t()`. Reuse `status_class/1`,
  `step_square_class/1`, `cost_badge/1`, `adw_orb/1`.
- Grep for any remaining `swimlane_row/1`/`swimlane/1`/`workflow_swimlane/1` callers
  before removing/renaming; keep the suite compiling.

### 5. Add the CSS tokens (`assets/css/app.css`)
- Add `.cns-card` (status left-border variants keyed off a `data-run-status`/status
  class), `.cns-step-box` (tinted box + `--current` highlight), `.cns-square` icon
  centering, `.cns-duration`, and a `.cns-chip--active` filter state — reusing
  `--cns-*` colors and the `cns-cat--*` palette so the cards match the theme. (CSS is
  style-only; do not validate via `browser_eval`.)

### 6. Rewrite the ADWS view template (`console_live.ex`)
- Replace the three stacked blocks with the single card list (Phase 3): filter-chip
  row + CLEAR; `adw_card/1` per workflow view; `agent_card/1` per agent swimlane
  (filtered); empty state; unchanged `event_detail_panel/1`. Fold the worker roster
  into a header strip; delete the `#agent-lanes` `swimlane_row` block.
- Keep both views mounted and toggle with `hidden` (do not `:if` the ADWS container —
  per the console-live streams-container pattern).

### 7. Wire the category filter chips
- Reuse the existing LOGS-view category filter state + event for the ADWS squares
  (enforce ≥1 active). Apply the filter when building/filtering the agent cards'
  squares so toggling a chip hides/shows squares live.

### 8. Build the Fast-tier title humanizer (`workflows/title_humanizer.ex` + runner)
- Add `Workflows.put_workflow_title/2` (read-modify-write `metadata["title"]`,
  mirroring `put_step_state/3`).
- Implement `machine_name?/1` (pure detector) and write its unit test first (red):
  machine-like (`"232sdasdasd"`, hex blobs, UUIDs, long digit runs, low vowel ratio)
  → `true`; human-like (`"bug-fix-test"`, `"Plan Build"`, `"nightly release"`)
  → `false`.
- Implement `maybe_humanize_async/1`: no-op when `metadata["title"]` already set, when
  the name is already human-friendly, or when `Explain.fast_config/1` returns
  `{:error, :no_fast_agent}`; otherwise dispatch the one-shot Fast-tier runner
  (reuse/extract `Explain.Server`) with persistence + global feed disabled and a tight
  rename prompt. On reply: sanitize → `put_workflow_title/2` → broadcast. Inject the
  runner behind a behaviour/config seam; the test uses a stub/Mox.
- Unit-test the flow with the mocked runner (see Testing Strategy): gated-off cases,
  persist+broadcast on success, no-op on error/no-Fast-tier, idempotency.

### 9. Wire the humanizer into the launch path + the LiveView title broadcast
- Call `TitleHumanizer.maybe_humanize_async/1` from
  `WorkflowEngine.create_workflow_of_type/3` (fire-and-forget, after create) so both
  `start_adw` (`orchestrator/tools.ex:399`) and `launch_adw_builder/4`
  (`console_live.ex:1496`) converge on one hook; verify neither bypasses it.
- Add the LiveView handler that merges a broadcast title into the matching
  `@workflow_progress` view (mirror `update_workflow_steps/3`) so the open card
  re-renders with the humanized title live. Extend the integration test's
  live-title-upgrade assertion to drive this broadcast.

### 10. Run the LiveView test (green) + iterate
- Run `mix test test/repo_builder_web/live/test_unified_adw_swimlane_cards_test.exs`
  and `mix test test/repo_builder/workflows/title_humanizer_test.exs` and fix until
  green. Confirm `test_adw_swimlane_test.exs` still passes (update its assertions only
  if the renamed component changed the DOM it asserts — preserve the
  `workflow-#{run.id}` id and `data-step-status` contract so it keeps working, or
  adjust the test deliberately and note it).

### 11. Manual runtime check via Tidewave (optional but recommended)
- With the app running, switch to the ADWS view; use Tidewave `get_logs` to confirm
  no render errors, and optionally capture a screenshot of `http://localhost:4000`
  (Tidewave Web vision mode, else Playwright) for visual parity with the reference
  `AdwSwimlanes.vue`.

### 12. Run the full validation suite
- Run every command in **Validation Commands** and fix any failure until all are
  green with zero regressions.

## Testing Strategy
### Unit Tests
- `category_icon/1`: returns the correct glyph for each of `:response`, `:tool`,
  `:thinking`, `:hook`, `:system` (total function; no fallthrough crash).
- Duration helper: a finished run yields a formatted `Xm Ys`/`Zs` string; a running
  run yields an elapsed string; a run with no timestamps yields `nil`/`"—"` (no raise).
- Title helper (`workflow_title/2` + `humanize/1`): `metadata["title"]` wins when
  present; else a workflow with a `name` returns the name; with only a `type` returns
  the humanized type (`"plan_build"` → `"Plan Build"`); a run with no
  `workflow_id`/workflow falls back to `current_step`, then to `"ADW <short-id>"` —
  and **never** returns a bare UUID.
- `TitleHumanizer.machine_name?/1`: machine-like inputs (`"232sdasdasd"`, hex blobs,
  UUIDs, long digit runs, low vowel ratio) → `true`; human-like (`"bug-fix-test"`,
  `"Plan Build"`, `"nightly release"`) → `false`. Pure, total, no raise.
- `TitleHumanizer.maybe_humanize_async/1` with a **mocked** Fast runner:
  (a) no-op when `metadata["title"]` already set (idempotent); (b) no-op for a
  human-friendly name; (c) no-op `{:error, :no_fast_agent}` when the `fast` tier is
  unset (title untouched); (d) on a good reply → `metadata["title"]` persisted +
  broadcast emitted; (e) runner error/timeout → title untouched, launch unaffected.
- (Component-level rendering is covered by the LiveView integration test below.)

### Edge Cases
- **Empty ADWS view** — `@workflow_progress == %{}` and no agents → the
  "No AI Developer Workflows found" empty state renders (no crash, no stray roster).
- **Run with zero steps** (`steps == []`) → card renders header only, no step boxes,
  no crash.
- **Unknown/`:idle` status** → status pill + border fall back to the ghost/neutral
  class (`status_class/1` already total).
- **Standalone agent with no events** → `agent_card/1` renders header with empty body
  (no orphaned squares), still in the single list.
- **All-but-one filter chips off** → toggling the last active chip is a no-op
  (≥1 enforced); squares for inactive categories are hidden but cards remain.
- **Reconnect/backfill** — after a LiveView reconnect, `seed_workflow_progress/1`
  re-seeds cards and `agent_swimlanes/1` rebuilds from `@event_buffer`; the view
  renders identically (no empty flash, no duplicated blocks).
- **No event→step linkage** — the design must not attribute events to specific steps;
  step boxes show per-step *status* only, and the test must not assert a false
  event-in-step mapping.
- **Humanizer non-blocking** — a slow/hung Fast runner must never delay launch or
  block the LiveView; the card shows the heuristic title until (if ever) the broadcast
  upgrades it.
- **Fast tier unassigned** — `maybe_humanize_async/1` no-ops cleanly; no crash, no
  flash, heuristic title stands (common in dev/CI where no `fast` model is set).
- **Already-good name** — humanizer is gated off; no model call, no metadata write
  (avoids spurious cost on every launch).
- **Humanizer idempotency** — re-launching / re-seeding never re-calls the agent once
  `metadata["title"]` exists.

## Acceptance Criteria
- The ADWS view renders a **single** vertical list of cards sharing one visual
  language — no separate `#agent-lanes` roster block and no duplicated run
  representation.
- Each ADW run renders as one **card** with: a status-colored left border, a
  **human-friendly title** (workflow `name`/humanized `type`, e.g. `bug-fix-test` —
  **never a raw UUID**) plus an `ADW: <type>` key line, a status pill, cost, a
  **duration**, and a **wrapping** set of **step boxes** that carry per-step status
  and **highlight the current step**.
- A **machine-looking** name/type (e.g. `"232sdasdasd"`) triggers the **Fast-tier
  agent** at launch to propose a human-friendly title, which is persisted to
  `Workflow.metadata` and pushed live so the open card upgrades from the heuristic
  title to the humanized one. Launch is never blocked; if the Fast tier is unassigned
  or the agent fails, the heuristic title stands and nothing errors. The agent does
  **not** run for already-friendly names, and never re-runs once a title is persisted.
- Event squares carry a **category icon** (💬/🛠️/🧠/🪝/⚙️) and a hover tooltip;
  clicking one opens the existing slide-out **detail panel**.
- A **category-filter chip row** scopes which event squares are shown; at least one
  chip is always active.
- Standalone (non-workflow) agents render in the **same** card chrome within the same
  list (not a competing layout).
- The empty state ("No AI Developer Workflows found — start one from the chat")
  renders when there are no runs.
- No DB **migration** and no canonical `Event`/payload or harness/adapter change; the
  only persistence write is the humanized title into the existing `Workflow.metadata`
  map. Reconnect backfill renders identically to the live view (a persisted
  `metadata["title"]` survives reconnect).
- The LOGS view, the LOGS⇄ADWS toggle, CLEAR (clear finished workflows), cost/counter
  accumulation, chat separation, and event selection/detail all continue to work.
- All validation commands pass with zero failures/warnings.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix test test/repo_builder_web/live/test_unified_adw_swimlane_cards_test.exs` —
  the new LiveView integration test passes (unified cards, step boxes, icon squares,
  duration, filter chips, detail panel; no separate roster block).
- `mix test test/repo_builder_web/live/test_adw_swimlane_test.exs` — the existing
  ADWS swimlane test still passes (per-step status + live `2/2` update preserved).
- `mix test test/repo_builder/workflows/title_humanizer_test.exs` — the humanizer unit
  suite passes (`machine_name?/1` classification + the mocked-runner humanize flow:
  gated-off, persist+broadcast, no-op-on-error/no-Fast-tier, idempotent).
- `mix compile --warnings-as-errors` — compile clean; gradual set-theoretic checker
  and `warnings_as_errors` pass.
- `mix test --warnings-as-errors` — full ExUnit suite green (no regressions in the
  console/dashboard/workflow suites).
- `mix format --check-formatted` — formatted.
- `mix credo --strict` — lint clean, including the "@spec on every public function"
  gate (new components and helpers each carry specs).
- `mix dialyzer` — no new contract warnings; the enriched view map + component attrs
  type-check against call sites.

## Notes
- **No new dependencies.** Everything derives from existing assigns
  (`@workflow_progress`, `@event_buffer`, `@selected_event`), the existing
  `EventPresenter`/`Explain` seam, and existing CSS tokens.
- **Render-redesign is persistence-untouched; the humanizer writes only
  `metadata`.** No `Logs.event_payload/2`, canonical `Event`, or DB-schema change;
  the worker-report full-fidelity spill path and its tests stay green. The single
  persistence write is `Workflow.metadata["title"]` (existing free-form column, no
  migration).
- **The humanizer mirrors `RepoBuilder.Explain`** — same Fast-roster resolution and
  one-shot ephemeral runner with persistence + global feed disabled (no `agent_logs`
  pollution, no durable agent). Prefer reusing/extracting `Explain.Server` over a
  parallel implementation. It is async, gated, idempotent, and failure-safe by design.
- **Cost discipline.** The Fast-tier call fires at most once per workflow and only
  when the name actually looks machine-generated — never on render, never on reconnect,
  never for already-friendly names.
- **Honest about the schema.** `agent_logs` carries no `run_id`/`adw_step` and
  `workflow_runs` carries no agent linkage, so — unlike the reference whose backend
  tags every event with `adw_step` — we render per-step *status* and group event
  squares per agent, not per step. The win is one coherent card layout (one scroll,
  one set of affordances), not a fabricated event→step mapping. If event→step
  attribution is wanted later, that is a separate persistence change (add `run_id`
  + `adw_step` to `agent_logs` and tag events at write time in the WorkflowEngine).
- **Single source of truth.** ADW cards read `@workflow_progress` (seeded by
  `seed_workflow_progress/1`, merged live by `update_workflow_status/2`/
  `update_workflow_steps/3`), so live and reconnect render identically — the
  established pattern in this view.
- **Keep both views mounted.** Per `[[console-live-orchestration]]`, the LOGS and
  ADWS containers stay mounted and toggle via `hidden`; do not switch them with
  `:if` (LiveView stream containers drop rows when `:if` removes them).
- **Reference parity (not pixel-copy).** `AdwSwimlanes.vue` is the design target
  (status border, duration corner, tinted step boxes, icon squares, filter chips,
  slide-out detail). Match the *structure and affordances* using the repo's
  `--cns-*`/daisyUI theme rather than copying the reference's color values verbatim.
- **Verification via Tidewave.** Prefer `project_eval` to confirm the live
  `run_progress/1` step shape and `@event_buffer` row shape, and `get_logs` to
  confirm no render errors after the rewrite.
```
