# Feature: Workstreams UI

## Metadata
issue_number: `the`
adw_id: `workstreams`
issue_json: `ui`

## Feature Description
The Workstreams UI provides operators with a comprehensive, real-time interface for viewing and managing the orchestrator's parallel workstreams and their phase-level progress through the spec→implement→test→review lifecycle. This feature extends the existing bottom-drawer workstreams panel in ConsoleLive into a richer UI that supports:

- **Index view**: A streamed list of all workstreams for the active orchestrator, showing status (running/blocked/done/abandoned), current phase position (k/n), current stage, next action hint, stall count, and focus discipline. Auto-updates via PubSub on any workstream change.
- **Detail view**: An expanded view of a single workstream, displaying its ordered phases with per-phase stage outcomes (spec/implement/test/review), the captured spec_path, quality-gate evidence, iteration count for ui_ux phases, and the ability to advance stages or record outcomes via the `record_stage` action.
- **Live integration**: The UI subscribes to the existing `{:workstreams_updated, orchestrator_id, records}` PubSub broadcast, ensuring real-time synchronization without manual refresh.

The UI leverages the existing `RepoBuilder.Orchestrator.Workstreams` context (the only `Repo` caller for workstreams/tables) and follows the typed-style standard with `@spec`'d functions throughout. LiveView streams keep server memory flat, and PubSub-driven updates deliver instant feedback.

## User Story
As a platform operator orchestrating the repo builder
I want to view and manage the orchestrator's workstreams, their phases, and stage progress in a dedicated UI
So that I can monitor progress, identify blocked or stalled workstreams, and intervene by recording stage outcomes or setting focus when needed

## Problem Statement
The orchestrator's workstreams are only visible in a compact bottom-drawer panel within ConsoleLive. Operators cannot expand individual workstreams to see full phase details, inspect quality-gate evidence, or directly interact with stage progression. The panel is space-constrained and best suited for at-a-glance monitoring, not detailed management.

## Solution Statement
Extend the existing ConsoleLive workstreams panel with a dedicated, expanded Workstreams UI that provides:

1. **An index view** (streams-based, PubSub-updated) of all workstreams, surfaced either as a modal/overlay or as an expanded drawer section from the existing bottom drawer. Each row shows: title, status badge, phase position (k/n), current stage chip, next action hint, stall count, and current focus. Empty states use Tailwind's `only:block` pattern.

2. **A detail/expanded view** for a selected workstream, showing:
   - Goal and definition_of_done
   - All ordered phases with per-phase stage outcomes (spec/implement/test/review status chips)
   - The spec_path (linkable to the spec artifact)
   - Quality-gate evidence (five-stage strip: format·lint·type·test·mutation) for the test stage
   - Iteration count and surface for `:ui_ux` phases
   - Focus discipline (current focus or hint to set one)
   - Quick actions to record a stage outcome (passed/failed/blocked) via `record_stage`

3. **PubSub integration**: Subscribe to `{:workstreams_updated, orchestrator_id, records}` in `mount/3` (only when `connected?(socket)`), refresh the stream on receipt, and re-fetch full records when expanding a workstream.

4. **Typed context functions**: Ensure all UI-called functions in `RepoBuilder.Orchestrator.Workstreams` have `@spec` signatures. If needed, add a query helper like `list_workstreams/1` or `get_workstream_detail/2` that returns a `full_record()` map with phases preloaded.

5. **LiveView streams**: Use `stream/3` for the workstream list to keep server memory flat, with `phx-update="stream"` and unique DOM IDs per workstream.

6. **Integration test**: A `Phoenix.LiveViewTest` suite at `test/repo_builder_web/live/test_workstreams_ui_test.exs` that mounts the UI, triggers a workstream selection/expansion, drives a `record_stage` interaction, and asserts the rendered output and PubSub broadcast.

This plan extends the existing bottom-drawer panel (proven in `ConsoleComponents.workstreams_panel/1`) rather than duplicating functionality, keeping the at-a-glance view while adding depth for operators who need it.

## Relevant Files
Use these files to implement the feature:

### Existing files to read/extend:
- `lib/repo_builder/orchestrator/workstreams.ex` — The Workstreams context; verify `@spec` coverage on all functions the UI calls. Add query helpers if needed (e.g., a function returning the `full_record()` shape with phases preloaded).
- `lib/repo_builder/orchestrator/workstream.ex` — Workstream schema, type definitions for `status`, `stall_count`, etc.
- `lib/repo_builder/orchestrator/workstream_phase.ex` — WorkstreamPhase schema, type definitions for stages, `kind`/`surface`, iteration count.
- `lib/repo_builder_web/live/console_live.ex` — The main console LiveView; note how it already loads workstreams via `Workstreams.list_records(orchestrator.id)` and handles `{:workstreams_updated, orchestrator_id, records}` in `handle_info/2`. The bottom drawer renders via `<.workstreams_panel workstreams={@workstreams}>`.
- `lib/repo_builder_web/components/console_components.ex` — The `workstreams_panel/1` component; extend or call it from the new UI to preserve the existing styling while adding depth.
- `lib/repo_builder_web/router.ex` — The LiveView routes; ConsoleLive is at `live "/", ConsoleLive`. The new Workstreams UI can be a modal/overlay within ConsoleLive (no new route) or a dedicated route at `live "/workstreams", WorkstreamsLive`.
- `lib/repo_builder_web/components/core_components.ex` — The `<.input>`, `<.icon>`, `<.link>` components; use `<.input>` for any forms (e.g., recording a stage outcome with an optional note/artifact).
- `lib/repo_builder_web/components/layouts.ex` — The `<.flash_group>` component; templates must begin with `<Layouts.app flash={@flash} ...>` and pass `current_scope` if needed (current auth is scoped to orchestrators).
- `ai_docs/typed-elixir-standard.md` — The typed-style rules; ensure all public functions have `@spec`, structs use `@enforce_keys`/`typedstruct`, and types are precise.
- `mix.exs` — The project aliases; run `mix precommit` when complete (aggregates compile-warnings-as-errors, format, credo-strict, test, dialyzer).
- `test/repo_builder_web/live/console_autonomy_test.exs` — Example test pattern using `Phoenix.LiveViewTest`; mirror the `live/2`, `render/1`, `has_element?/2`, `element/2`, and PubSub broadcast/assert pattern.

### New Files
- `lib/repo_builder_web/live/workstreams_live.ex` — The new Workstreams LiveView (index + detail view), with `mount/3`, `handle_event/3` for workstream selection and stage recording, `handle_info/2` for PubSub updates, and LiveView streams.
- `lib/repo_builder_web/live/workstreams_live.html.heex` — The template, with `<Layouts.app flash={@flash} current_scope={@current_scope}>`, a workstream index using `@streams.workstreams` with `phx-update="stream"`, and a detail/expanded view for the selected workstream.
- `test/repo_builder_web/live/test_workstreams_ui_test.exs` — Phoenix.LiveViewTest integration test; mount the LiveView, drive interactions, assert rendered output and PubSub messages.

## Implementation Plan
### Phase 1: Foundation
- Verify `@spec` coverage in `RepoBuilder.Orchestrator.Workstreams` for all functions the UI will call (especially `list_records/1`, `get_workstream/2`, `record_stage/3`, `set_focus/3`, `clear_focus/2`). Add missing specs.
- Confirm the PubSub broadcast topic and payload: `Phoenix.PubSub.broadcast(RepoBuilder.PubSub, "workstreams:#{orchestrator_id}", {:workstreams_updated, orchestrator_id, records})` is already wired in the orchestrator server; note that ConsoleLive handles `{:workstreams_updated, orchestrator_id, records}` in `handle_info/2`.
- Define any new query helpers needed (e.g., a function that returns a workstream with phases preloaded for the detail view). If `get_workstream/2` already returns a `full_record()` with phases, reuse it; otherwise, add `get_workstream_detail/2` that preloads phases.

### Phase 2: Core Implementation
- Create `WorkstreamsLive` with:
  - `mount/3`: Load the active orchestrator, seed the workstreams stream via `stream(:workstreams, workstreams)`, subscribe to `workstreams:#{orchestrator_id}` (only when `connected?(socket)`), and assign `selected_workstream_id` for detail view.
  - `handle_info({:workstreams_updated, orchestrator_id, records}, socket)`: Re-stream the workstreams list with `reset: true` and update the selected workstream detail if it changed.
  - `handle_event("select_workstream", %{"id" => id}, socket)`: Assign the selected workstream ID and load its full record via `Workstreams.get_workstream/2`.
  - `handle_event("record_stage", params, socket)`: Call `Workstreams.record_stage/3` with the stage (spec|implement|test|review), outcome (passed|failed|blocked), and optional artifact/note, then broadcast the update via PubSub.
  - `handle_event("set_focus", %{"focus" => focus}, socket)`: Call `Workstreams.set_focus/3`.
  - `handle_event("clear_focus", _params, socket)`: Call `Workstreams.clear_focus/2`.
- Create the template with:
  - `<Layouts.app flash={@flash} current_scope={@current_scope}>` wrapping the content.
  - A workstream index using `<div id="workstreams" phx-update="stream">` and `<%= for {id, ws} <- @streams.workstreams do %>` to render each workstream row.
  - Per-workstream action buttons to select/expand (e.g., `<button phx-click="select_workstream" phx-value-id={ws.id}>View</button>`).
  - A detail/expanded view (conditional on `@selected_workstream`) showing the goal, definition_of_done, phases with stage chips, quality-gate evidence, and stage-recording forms.
  - Stage-recording forms using `<.form>` and `<.input>` (e.g., a select for outcome, optional text input for note/artifact, and a submit button calling `record_stage`).
  - Empty states using Tailwind's `only:block` pattern (e.g., `<div class="hidden only:block">No workstreams yet</div>`).
  - Use `<.icon>` for icons (e.g., status badges, action buttons).

### Phase 3: Integration
- Route the LiveView at `live "/workstreams", WorkstreamsLive` in `lib/repo_builder_web/router.ex`, within the existing `scope "/", RepoBuilderWeb do` with `pipe_through :browser`. No `live_session` needed unless auth is tightened; pass `current_scope` if the pattern requires it (current ConsoleLive does not pass it, so follow the existing pattern).
- Wire navigation from ConsoleLive: add a link or button in the existing bottom-drawer workstreams panel to open the new Workstreams UI (e.g., `<.link navigate={~p"/workstreams"}>View all workstreams</.link>`).
- Ensure PubSub subscriptions are only made when `connected?(socket)` (guard on `if connected?(socket)` in `mount/3` before subscribing), avoiding duplicate subscriptions on the disconnected render.
- Test that workstream changes (stage recording, focus changes) broadcast via `{:workstreams_updated, orchestrator_id, records}` and update the UI in real time.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### Verify and extend Workstreams context @spec coverage
- Read `lib/repo_builder/orchestrator/workstreams.ex` and confirm `@spec` signatures on all public functions: `list_workstreams/1`, `list_records/1`, `get_workstream/2`, `create_workstream/2`, `plan_phases/3`, `record_stage/3`, `close_workstream/3`, `set_focus/3`, `clear_focus/2`.
- Add any missing `@spec` signatures following the typed-style standard (prefer `{:ok, t()} | {:error, reason()}`).
- If a query helper is needed for the detail view (e.g., to preload phases), add it as a new `@spec`'d function returning a `full_record()` or similar map.

### Confirm PubSub broadcast and ConsoleLive integration
- Read `lib/repo_builder/dashboard.ex` to confirm the broadcast topic (`workstreams:#{orchestrator_id}`) and payload (`{:workstreams_updated, orchestrator_id, records}`).
- Read `lib/repo_builder_web/live/console_live.ex` to see how `handle_info({:workstreams_updated, orchestrator_id, records}, socket)` is implemented; mirror the pattern in the new LiveView.

### Create the WorkstreamsLive module
- Create `lib/repo_builder_web/live/workstreams_live.ex` with the `mount/3`, `handle_event/3`, and `handle_info/2` callbacks as defined in Phase 2.
- Ensure `use RepoBuilderWeb, :live_view` and `alias RepoBuilder.Orchestrator.Workstreams`.
- Use `stream(:workstreams, [])` and `stream_configure(:workstreams, dom_id: &"workstream-#{&1.id}")` in `mount/3`.
- Subscribe to `workstreams:#{orchestrator_id}` only when `connected?(socket)`.

### Create the WorkstreamsLive template
- Create `lib/repo_builder_web/live/workstreams_live.html.heex` with the structure defined in Phase 2.
- Begin with `<Layouts.app flash={@flash} current_scope={@current_scope}>`.
- Implement the workstream index using `@streams.workstreams` and `phx-update="stream"`.
- Implement the detail/expanded view with per-phase stage chips and quality-gate evidence.
- Add stage-recording forms using `<.form>` and `<.input>`.

### Route the LiveView and wire navigation from ConsoleLive
- Add `live "/workstreams", WorkstreamsLive` to `lib/repo_builder_web/router.ex` in the `scope "/", RepoBuilderWeb do` block.
- In `ConsoleComponents.workstreams_panel/1` or `ConsoleLive`, add a link/button to navigate to `/workstreams` (e.g., `<.link navigate={~p"/workstreams"} class="text-sm">View all workstreams</.link>`).

### Create the Phoenix.LiveViewTest integration test
- Create `test/repo_builder_web/live/test_workstreams_ui_test.exs` using `Phoenix.LiveViewTest`.
- Mount the LiveView with `{:ok, view, _html} = live(conn, "/workstreams")`.
- Assert that the workstreams index renders (e.g., `assert has_element?(view, "#workstreams")`).
- Create a test orchestrator and workstream with phases via `Workstreams.create_workstream/2` and `Workstreams.plan_phases/3`.
- Trigger a workstream selection via `view |> element("button[phx-click='select_workstream'][phx-value-id='#{ws.id}']") |> render_click()`.
- Assert that the detail view renders (e.g., `assert has_element?(view, "#workstream-detail-#{ws.id}")`).
- Trigger a stage recording via `view |> element("form[phx-submit='record_stage']") |> render_submit(%{stage: "spec", outcome: "passed", artifact: "path/to/spec.md"})`.
- Assert the rendered output shows the updated stage status.
- Assert that the PubSub message `{:workstreams_updated, orchestrator_id, records}` was broadcast using `assert_receive`.

### Run validation
- Run the Validation Commands below; zero failures.

## Testing Strategy
### Unit Tests
- Unit tests for any new Workstreams context functions (e.g., a new `get_workstream_detail/2` if added) should go in `test/repo_builder/orchestrator/workstreams_test.exs`, using `@spec` coverage and tagged-tuple returns.
- Ensure all context functions return `{:ok, t()} | {:error, reason()}` or plain lists/records for read indexes, matching the typed-style standard.

### Edge Cases
- Empty workstream list: The index should render an empty state using Tailwind's `only:block` pattern (e.g., `<div class="hidden only:block">No workstreams yet</div>`).
- Workstream with no phases: The detail view should handle this gracefully (e.g., show a message "No phases planned yet" instead of rendering an empty list).
- Blocked or stalled workstreams: The UI should surface `:blocked` status and `stall_count` prominently, with clear visual indicators (e.g., red badges or warning icons).
- Concurrent updates via PubSub: The UI should handle rapid workstreams updates (e.g., multiple stage recordings in quick succession) without stale state or race conditions; streams and PubSub broadcasts ensure the latest state is always rendered.
- ui_ux phases with iteration count: The detail view should display the iteration cap and current iteration for `:ui_ux` phases (e.g., "ui/ux 2/3").
- Quality-gate evidence: The test stage should render the five-stage gate strip (format·lint·type·test·mutation) with per-stage status dots; handle missing or partial gate data gracefully.
- Focus discipline: The UI should show the current focus or a hint to set it when none is set; provide a quick action to set/clear focus.

## Acceptance Criteria
- **Workstream index streams via PubSub**: The UI uses LiveView streams for the workstream list, subscribes to `workstreams:#{orchestrator_id}`, and updates in real time on any workstream change.
- **Detail view shows phases and stage outcomes**: Selecting a workstream displays its ordered phases with per-stage status chips (spec/implement/test/review), the spec_path, quality-gate evidence, and iteration count for ui_ux phases.
- **Recording a stage outcome persists + broadcasts + updates the UI**: The `record_stage` action persists the outcome via `Workstreams.record_stage/3`, broadcasts `{:workstreams_updated, orchestrator_id, records}`, and the UI reflects the new stage status immediately.
- **Typed style enforced**: All public functions in the Workstreams context and the new LiveView have `@spec` signatures; structs use `@enforce_keys`/`typedstruct`; types are precise (no `any()`/`map()` where a real shape is known).
- **All validation commands pass**: `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, `mix test --warnings-as-errors`, `mix dialyzer`, and `mix precommit` all succeed with zero failures.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix test test/repo_builder_web/live/test_workstreams_ui_test.exs` - Run the new LiveView integration test (must pass).
- `mix test --warnings-as-errors` - Full ExUnit suite (Postgres-backed cases) with zero failures.
- `mix compile --warnings-as-errors` - Compile clean; the gradual set-theoretic type checker and `warnings_as_errors` must pass.
- `mix format --check-formatted` - Ensure code is formatted.
- `mix credo --strict` - Lint, including the "every public function has an `@spec`" convention.
- `mix dialyzer` - `@spec`/contract checking with no new warnings and no stale ignore filters.
- `mix precommit` - Project alias aggregating the above.

## Notes
- **Extending the existing bottom drawer**: The current `ConsoleComponents.workstreams_panel/1` provides a compact, at-a-glance view that is ideal for monitoring. The new Workstreams UI extends this with depth (detail view, stage recording, focus actions) without duplicating functionality. Plan to preserve the bottom drawer for quick monitoring and add a "View all workstreams" link to the full UI.
- **Tidewave validation steps**: During implementation, use Tidewave's `project_eval` to verify DB state (e.g., `RepoBuilder.Orchestrator.Workstreams.list_records(orchestrator_id)`) and `execute_sql_query` to inspect the `orchestrator_workstreams` and `orchestrator_workstream_phases` tables directly.
- **Forward-looking considerations**: The index view could be enhanced with filtering (by status, by phase position), sorting (newest first, by stall count), and pagination if workstream counts grow large. The detail view could support bulk stage recording or replaying a phase. These are out of scope for the initial feature but are natural extensions.