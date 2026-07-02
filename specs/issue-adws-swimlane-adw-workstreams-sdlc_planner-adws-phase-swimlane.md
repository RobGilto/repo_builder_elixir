# Feature Plan: ADWS Phase Swimlane — Workstreams as Kanban Board in ADWS View

```
issue_number: `adws`
adw_id: `swimlane`
issue_json: `adw-workstreams-sdlc_planner-adws-phase-swimlane`
```

## 1. Feature Description

Relocate the Workstreams UI from the ConsoleLive bottom drawer INTO the ADWS view (`view_mode: :adws`) as a Kanban-style swimlane board. Four columns = the four phases/stages `@stage_order [:spec, :implement, :test, :review]`. Each workstream phase is a card placed in the column matching its `current_stage`; cards move left→right as `record_stage/3` advances. This SUPERSEDES the prior `specs/issue-the-adw-workstreams-sdlc_planner-workstreams-ui.md` design (which extended the drawer).

## 2. User Story

As a platform operator, I want workstreams shown as a phase-grouped Kanban board in the ADWS view, so I can see all phases progressing Spec→Implement→Test→Review at a glance.

## 3. Problem Statement

Today workstreams live in the ConsoleLive drawer (via `workstreams_panel/1`, the `:workstreams` assign, and `handle_info({:workstreams_updated,...})`), which is space-constrained and not phase-oriented. Meanwhile the ADWS view (BUILD_PROMPT.md §9, `view_mode: :adws`) is the natural home for workstream/ADW progress — it already shows ADW swimlanes with per-event squares + detail panels. The drawer view is redundant with a swimlane and phases are better visualized as a board.

## 4. Solution Statement

(a) **REMOVE the workstreams UI from the ConsoleLive drawer** — drop the `<.workstreams_panel>` render, the `:workstreams` assign, and the `handle_info({:workstreams_updated,...})` branch from ConsoleLive.

(b) **ADD a swimlane board to the ADWS view** — when `view_mode == :adws`, render a `workstreams_swimlane` component with 4 columns [Spec, Implement, Test, Review]. Subscribe to `{:workstreams_updated, orchestrator_id, records}` (move the subscription here). Each card = a `phase_view()` from `get_workstream/2`/`list_workstreams/1`, placed by `current_stage`; show title, status chip, spec_path link, iteration (for :ui_ux), and a record-stage quick action calling `Workstreams.record_stage/3`. Use LiveView streams where appropriate (streams are NOT per-column — use a `current_stage`-grouped render or stream keyed by phase id grouped in the template with `<%= cond do %>` / `:for`).

## 5. Relevant Files

- `lib/repo_builder_web/live/console_live.ex` — REMOVE drawer render + `:workstreams` assign + `handle_info({:workstreams_updated})`; ADD swimlane render in the `view_mode == :adws` branch + move the PubSub subscription.
- `lib/repo_builder_web/components/console_components.ex` — ADD `workstreams_swimlane/1` component (4 columns); `workstreams_panel/1` becomes unused (note it can be removed).
- `lib/repo_builder_web/router.ex` — NO change (single `/` route; ADWS is a view mode).
- `lib/repo_builder/orchestrator/workstreams.ex` — verify `@spec` coverage on `list_workstreams/1`, `get_workstream/2`, `record_stage/3`; reuse `@stage_order`. Possibly add a helper to list all phases across all workstreams for the board.
- `lib/repo_builder/orchestrator/workstream_phase.ex` / `workstream.ex` — read for types (`stage`, `current_stage`, `status`, `kind`).
- `specs/issue-the-adw-workstreams-sdlc_planner-workstreams-ui.md` — SUPERSEDED (this spec replaces it).
- New file: `test/repo_builder_web/live/adws_workstreams_swimlane_test.exs`.

## 6. Implementation Plan

### Foundation
- Verify `@spec` coverage exists on `Workstreams.list_workstreams/1`, `Workstreams.get_workstream/2`, `Workstreams.record_stage/3`.
- Decide the data fetch strategy: either (a) add a helper to return all current phases across all workstreams grouped by stage, or (b) fetch full_records and flatten to phase_views in the LiveView.
- Confirm `@stage_order` constant is `[:spec, :implement, :test, :review]` (from grounding facts).

### Board Component
- Implement `workstreams_swimlane/1` in `console_components.ex` with:
  - Attrs: `orchestrator_id`, `workstreams` (list of full_records or phase_views), `context_tokens`.
  - Four columns with DOM ids: `swimlane-spec`, `swimlane-implement`, `swimlane-test`, `swimlane-review`.
  - Card DOM id: `phase-card-#{phase.id}`.
  - Card content: phase title, status chip (`:pending | :running | :done | :blocked`), spec_path link (if present), iteration badge for `kind: :ui_ux` (surface + iteration/cap), and a record-stage quick-action dropdown/button (`phx-click="record_stage" phx-value-stage phx-value-ref`).
  - Use `<%= cond do %>` / `:for` to group phases by `current_stage` for rendering.

### Wiring
- Move PubSub subscription for workstreams updates into the ADWS branch in ConsoleLive (subscribe when entering ADWS view, unsubscribe when leaving).
- Remove drawer render: drop the `<.workstreams_panel workstreams={@workstreams}>` call from the template.
- Remove `:workstreams` assign (or repurpose it for the swimlane data).
- Remove `handle_info({:workstreams_updated, orchestrator_id, records}, socket)` from ConsoleLive (or move it into the ADWS-specific logic).
- Add `handle_event("record_stage", %{"ref" => ref, "stage" => stage, "outcome" => outcome}, socket)` calling `Workstreams.record_stage/3`.
- After `record_stage/3` succeeds, broadcast via PubSub and re-fetch/re-stream the swimlane data.

### Test
- Create `test/repo_builder_web/live/adws_workstreams_swimlane_test.exs`:
  - Mount ConsoleLive, toggle to ADWS view via `render_click(view, "toggle_view")`.
  - Assert 4 column DOM ids exist: `has_element?(view, "#swimlane-spec")`, `#swimlane-implement`, `#swimlane-test`, `#swimlane-review`.
  - Seed a workstream with a phase at a specific `current_stage` (e.g., `:implement`).
  - Assert the phase card renders in the correct column: `has_element?(view, "#swimlane-implement #phase-card-#{phase.id}")`.
  - Drive a `record_stage` event via `render_click(element, "record_stage", %{"ref" => ref, "stage" => "implement", "outcome" => "passed"})`.
  - Assert the card moves to the next column (`#swimlane-test`) after the PubSub broadcast is handled.
  - Use `has_element?/2`, `element/2`, `render_hook/2`/`render_click` as appropriate.

## 7. Validation / Commands

- `mix format` — format all modified files.
- `mix credo --strict` — strict linting (catches missing `@spec`).
- `mix test test/repo_builder_web/live/adws_workstreams_swimlane_test.exs` — run new swimlane tests.
- `mix test` — full test suite.
- `mix precommit` — aggregates compile-warnings-as-errors / format / credo-strict / test / dialyzer.
- `mix dialyzer` — typed gate (Dialyzer checks `@spec` coverage).