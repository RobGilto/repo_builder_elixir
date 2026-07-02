# Feature: Relocate workstreams UI to ADWS tab as phase-grouped swimlanes

## Metadata
issue_number: `0`
adw_id: `NA`
issue_json: `{}` (core UI reorganization — workstreams move from orchestrator drawer to ADWS swimlanes)

## Feature Description
The workstreams panel currently lives inside the orchestrator drawer in `ConsoleLive` (`workstreams_panel` rendered at lines 3813-3814), showing one row per workstream with its phases and four stage chips (Spec|Implement|Test|Review). The user wants this view relocated to the **ADWS tab** (`view_mode == :adws`) and reorganized as a **phase-grouped swimlane layout**: the four canonical stages become swimlane columns, phases appear as rows under their current stage column, and the existing stage-chip highlighting, done/total counts, and focus indicators are preserved.

No new context functions or schema changes are required — `Workstreams.list_records/1` already returns workstreams with phases preloaded, and the `:workstreams_updated` PubSub broadcast already drives live updates. The ADWS tab's existing `#swimlanes` container (currently used for ADW run cards and agent swimlane cards) is the natural destination for this view.

## User Story
As an operator managing multi-phase workstreams across Spec / Implement / Test / Review
I want to see workstreams rendered as swimlanes grouped by phase within the ADWS tab
So that I can visually track phase progression across all workstreams in one place, alongside ADW runs and agent activity, without opening the orchestrator drawer.

## Problem Statement
Workstreams are hidden away in the orchestrator drawer, forcing the operator to toggle that drawer open to see phase progress. The current one-row-per-workstream layout makes it hard to compare phases across workstreams — you cannot see "all phases currently in Review" at a glance. The ADWS tab already uses a swimlane idiom for ADW runs and agent cards; reusing that for workstreams provides a unified, visual-phase-centric view.

The existing `workstreams_panel` component works well for the drawer context but is not structured for swimlane columns. Moving to the ADWS tab requires:
1. A new swimlane-aware component that groups phases by their `current_stage` into four columns.
2. Reusing the existing helper functions (`stage_status`, `stage_chip_style`, `workstreams_done_count`, etc.) to preserve styling.
3. Preserving live updates via `:workstreams_updated` PubSub broadcasts.
4. Removing the old drawer rendering to avoid duplication.

## Solution Statement
Extend the ADWS tab's `#swimlanes` container to include a **workstreams swimlane section** alongside ADW runs and agent cards. The four stages — Spec, Implement, Test, Review — become column headers. Each phase row from each workstream appears under the column matching its phase's `current_stage`, with stage chips showing done/current/pending states via the existing helpers.

Implementation approach:
1. Add a new component `workstreams_swimlanes/1` in `console_components.ex` that renders the four-column swimlane layout. It consumes `@workstreams` (already assigned in `ConsoleLive`) and uses a stable DOM id per workstream-phase for stream-based updates.
2. In `ConsoleLive`, when `view_mode == :adws`, render the workstreams swimlanes within `#swimlanes` (after ADW runs, before `event_detail_panel`). Preserve the existing `handle_info({:workstreams_updated, ...})` handler to re-stream updates.
3. Remove the old `<.workstreams_panel>` render from the orchestrator drawer (lines 3813-3814).
4. Reuse `Workstreams.list_records/1` — no new context calls needed.
5. Follow §9 stream/swimlane idioms: use `stream_configure` with a stable `dom_id` function, seed the stream in `mount` when `connected?(socket)`, and re-seed on reconnect to survive disconnection.

The swimlane columns are derived directly from `WorkstreamPhase.current_stage` (`:spec | :implement | :test | :review | :done`) — phases in `:done` state are shown under their final completed stage or omitted from active swimlanes. The `stages` map on each phase stores per-stage outcomes/history for the stage chip rendering.

## Relevant Files
Use these files to implement the feature:

### Reference / Standards (read before implementing)
- `ai_docs/typed-elixir-standard.md` — typed-Elixir coding standard (always-row; `@spec` on every public function, precise types, `{:ok, t()} | {:error, reason()}` over raising, rule 10 float→Decimal).
- `BUILD_PROMPT.md §9` — LiveView streams / swimlane / reconnect handling (stream_configure, dom_id stability, reconnect re-seed, subscribe only when `connected?(socket)`).
- `BUILD_PROMPT.md §13` and `AGENTS.md` — test conventions (ConnCase, async: false for PubSub tests, Ecto sandbox ownership, `wait_render/3` poller pattern, `live/2`, `element/2`, `has_element?/2`, `render/1`).

### Implementation Files
- `lib/repo_builder_web/live/console_live.ex` — The main LiveView.
  - Lines 66: alias `RepoBuilder.Orchestrator.Workstreams`
  - Lines 105-107: `workstreams: []` assign (kept — used for swimlanes)
  - Lines 137: `view_mode` assign (logs|adws toggle)
  - Line 436: `assign_orchestrator_selection/2` seeds workstreams via `Workstreams.list_records(orchestrator.id)`
  - Lines 2543-2545: `toggle_view/1` flips logs↔adws
  - Lines 2891-2896: `handle_info({:workstreams_updated, orchestrator_id, records}, socket)` — preserve this
  - Line 3651: `#swimlanes` container (add workstreams swimlane section here)
  - Lines 3813-3814: REMOVE the `<.workstreams_panel>` render from orchestrator drawer
- `lib/repo_builder_web/components/console_components.ex` — Components.
  - Lines 1107-1169: `workstreams_panel/1` (will be deprecated/removed or left for potential reuse elsewhere)
  - Lines 1172-1298: helper functions to reuse in the new swimlane component (`workstreams_done_count`, `ui_ux_badge`, `phase_label_style`, `stage_status`, `stage_chip_style`, quality-gate helpers)
  - NEW: `workstreams_swimlanes/1` component (render four-column swimlane layout, stable DOM ids, consume `@workstreams`)
- `lib/repo_builder/orchestrator/workstreams.ex` — Context.
  - Lines ~383-386: `list_records/1` — already returns workstreams with phases preloaded (no change needed)
- `lib/repo_builder/orchestrator/workstream.ex` — Schema.
  - `has_many :phases, WorkstreamPhase` — phases are preloaded by `list_records/1`
- `lib/repo_builder/orchestrator/workstream_phase.ex` — Schema.
  - `current_stage` Ecto.Enum `[:spec, :implement, :test, :review, :done]` — the swimlane column key
  - `stages :map` — JSONB map storing per-stage outcomes for stage chip rendering

### New Files
- `test/repo_builder_web/live/test_workstreams_swimlanes_test.exs` — Phoenix.LiveViewTest integration test that mounts the console, creates a workstream with phases, switches to ADWS view, asserts swimlane column structure, verifies live updates via PubSub, and confirms workstreams no longer render in the orchestrator drawer.

## Implementation Plan
### Phase 1: Foundation — Prepare ADWS tab for workstreams
- Configure a new stream for workstream phases with stable DOM IDs.
- Seed the stream in `mount` when `connected?(socket)` using existing `Workstreams.list_records/1`.
- Subscribe to `:workstreams_updated` PubSub (already subscribed; preserve handler).
- Add a `workstreams_swimlanes/1` component skeleton that renders the four-column layout.

### Phase 2: Core Implementation — Render workstreams as swimlanes
- Implement `workstreams_swimlanes/1` to render four column headers (Spec, Implement, Test, Review).
- For each workstream, render each phase as a row under the column matching its `current_stage`.
- Reuse existing helper functions (`stage_status`, `stage_chip_style`, `workstreams_done_count`, `phase_label_style`, `ui_ux_badge`) for styling and done/total counts.
- Display the workstream title, current phase indicator, focus indicator, and stage chips.
- Set stable DOM IDs for each workstream-phase row (`workstream-#{workstream.id}-phase-#{phase.id}`).
- Use `phx-update="stream"` on the workstreams container.

### Phase 3: Integration — Remove old orchestrator drawer rendering
- Remove the `<.workstreams_panel>` render from the orchestrator drawer (lines 3813-3814).
- Deprecate or leave `workstreams_panel/1` for potential reuse elsewhere (no deletion needed unless confirming no other callers).
- Verify that switching to ADWS view shows workstreams swimlanes and toggling back to logs view hides them.
- Verify that the orchestrator drawer no longer renders workstreams.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Read context and confirm conventions
- Read `BUILD_PROMPT.md §9` and `ai_docs/typed-elixir-standard.md`.
- Re-read the relevant ranges in `console_live.ex` and `console_components.ex` listed above to confirm line numbers before editing.
- Examine the existing `adw_card`, `agent_swimlanes` patterns in `dashboard_components.ex` and `console_live.ex` for swimlane idiom consistency.

### 2. Add stream configuration for workstreams in ConsoleLive mount
- In `console_live.ex`, add after the existing `stream_configure` calls (around line ~762):
  ```elixir
  stream_configure(:workstreams, dom_id: fn {workstream, phase} ->
    "workstream-#{workstream.id}-phase-#{phase.id}"
  end)
  ```
- In the `mount/3` callback where streams are initialized, after seeding `:events` and `:swimlanes`, add:
  ```elixir
  if connected?(socket) do
    # Seed workstreams stream when an orchestrator is selected
    workstreams =
      case socket.assigns.orchestrator_selection do
        nil -> []
        orchestrator -> Workstreams.list_records(orchestrator.id)
      end

    socket =
      Enum.reduce(workstreams, socket, fn workstream, acc ->
        Enum.reduce(workstream.phases, acc, fn phase, inner_acc ->
          stream_insert(inner_acc, :workstreams, {workstream, phase}, at: -1)
        end)
      end)
  end
  ```
- This seeds the stream on mount and on reconnect (following §9's reconnect re-seed rule).

### 3. Add the `workstreams_swimlanes` component to console_components.ex
- Add the component after the existing `workstreams_panel/1` (around line 1170):
  ```elixir
  @doc """
  Renders workstreams as a four-column swimlane layout grouped by phase stage.
  Each workstream's phases appear as rows under the column matching their current_stage.
  """
  attr :workstreams, :list, required: true, doc: "List of workstreams with phases preloaded"

  def workstreams_swimlanes(%{workstreams: workstreams}) when workstreams == [] do
    ~H"""
    <div class="text-center text-gray-500 py-8">
      No workstreams yet. Select an orchestrator to begin.
    </div>
    """
  end

  def workstreams_swimlanes(%{workstreams: workstreams}) do
    ~H"""
    <div id="workstreams-swimlanes" phx-update="stream" class="mt-4">
      <!-- Column headers -->
      <div class="grid grid-cols-4 gap-2 mb-2 text-xs font-semibold text-gray-500 uppercase tracking-wide">
        <div>Spec</div>
        <div>Implement</div>
        <div>Test</div>
        <div>Review</div>
      </div>

      <!-- Swimlane rows: one per workstream-phase, placed under current_stage column -->
      <div class="grid grid-cols-4 gap-2">
        <%= for {_id, {workstream, phase}} <- @streams.workstreams do %>
          <div
            id={id}
            class={["rounded-lg border p-2", phase.status == :running && "border-blue-300 bg-blue-50", phase.status == :blocked && "border-red-300 bg-red-50", phase.status == :done && "border-green-300 bg-green-50"]}
            style={"grid-column-start: #{column_for_stage(phase.current_stage)}"}
          >
            <!-- Workstream title and focus indicator -->
            <div class="flex items-center justify-between mb-1">
              <span class="font-medium text-sm truncate" title={workstream.title}>{workstream.title}</span>
              <%= if workstream.focus do %>
                <.icon name="hero-star-solid" class="w-4 h-4 text-yellow-500 flex-shrink-0 ml-1" />
              <% end %>
            </div>

            <!-- Phase info -->
            <div class="text-xs text-gray-600 mb-1 truncate" title={phase.title}>
              {phase.title}
            </div>

            <!-- Stage chips (Spec | Implement | Test | Review) -->
            <div class="flex space-x-1">
              <%= for stage <- [:spec, :implement, :test, :review] do %>
                <span class={stage_chip_style(stage, phase.current_stage, Map.get(phase.stages, Atom.to_string(stage)))}>
                  {stage_label(stage)}
                </span>
              <% end %>
            </div>

            <!-- Done/total count -->
            <div class="text-xs text-gray-500 mt-1">
              {workstreams_done_count(workstream.phases)}/{length(workstream.phases)} phases done
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # Helper to map current_stage to 1-indexed column number
  defp column_for_stage(:spec), do: 1
  defp column_for_stage(:implement), do: 2
  defp column_for_stage(:test), do: 3
  defp column_for_stage(:review), do: 4
  defp column_for_stage(:done), do: 4  # done phases shown under Review (or omit)

  # Helper to render stage label (first letter uppercase)
  defp stage_label(:spec), do: "S"
  defp stage_label(:implement), do: "I"
  defp stage_label(:test), do: "T"
  defp stage_label(:review), do: "R"
  ```
- Reuse the existing `stage_chip_style` and `workstreams_done_count` helpers (lines 1217-1227, 1172-1177).

### 4. Render workstreams swimlanes in the ADWS tab
- In `console_live.ex`, inside the `#swimlanes` container (after line 3651, after `#workflow-runs`), add:
  ```elixir
  <!-- Workstreams swimlanes (shown when orchestrator selected) -->
  <%= if @orchestrator_selection do %>
    <div class="mt-6 border-t pt-4">
      <h3 class="text-sm font-semibold text-gray-700 mb-2">Workstreams</h3>
      <.workstreams_swimlanes workstreams={@streams.workstreams |> Enum.map(fn {_id, pair} -> pair end)} />
    </div>
  <% end %>
  ```
- This renders the workstreams swimlanes only when an orchestrator is selected, positioned after ADW runs.

### 5. Update the `:workstreams_updated` handler to re-stream
- The existing handler (lines 2891-2896) updates the `@workstreams` assign. Extend it to re-stream:
  ```elixir
  def handle_info({:workstreams_updated, orchestrator_id, records}, socket) do
    # Only update if this broadcast matches the selected orchestrator
    if socket.assigns.orchestrator_selection && socket.assigns.orchestrator_selection.id == orchestrator_id do
      # Clear and re-seed the workstreams stream with new records
      socket = stream(socket, :workstreams, [], reset: true)

      socket =
        Enum.reduce(records, socket, fn workstream, acc ->
          Enum.reduce(workstream.phases, acc, fn phase, inner_acc ->
            stream_insert(inner_acc, :workstreams, {workstream, phase}, at: -1)
          end)
        end)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end
  ```
- This ensures live updates re-stream the entire workstreams collection (following §9's stream reset pattern for filtering/refresh).

### 6. Remove the old workstreams panel from the orchestrator drawer
- In `console_live.ex`, remove lines 3813-3814:
  ```elixir
  # DELETE THESE LINES:
  # <.workstreams_panel workstreams={@workstreams} context_tokens={@orchestrator_context} />
  ```
- Verify no other references to `workstreams_panel` exist (grep to confirm).

### 7. Add a LiveView integration test
- Create `test/repo_builder_web/live/test_workstreams_swimlanes_test.exs` using `RepoBuilderWeb.ConnCase, async: false`:
  ```elixir
  defmodule RepoBuilderWeb.WorkstreamsSwimlanesTest do
    use RepoBuilderWeb.ConnCase, async: false
    import Phoenix.LiveViewTest

    alias RepoBuilder.Orchestrator.{Workstreams, Orchestrator}

    setup %{conn: conn} do
      {:ok, orchestrator} =
        Orchestrator.create_orchestrator(%{
          name: "test-orchestrator-#{uniq()}",
          goal: "Test orchestrator for workstreams swimlanes"
        })

      {:ok, workstream} =
        Workstreams.create_workstream(orchestrator.id, %{
          title: "Test Workstream",
          goal: "Test goal",
          definition_of_done: "Test DoD",
          status: :running
        })

      {:ok, phase1} =
        Workstreams.create_phase(workstream.id, %{
          position: 0,
          title: "Spec Phase",
          kind: :backend,
          surface: :web,
          current_stage: :spec,
          stages: %{"spec" => %{"status" => "done"}, "implement" => %{"status" => "pending"}}
        })

      {:ok, phase2} =
        Workstreams.create_phase(workstream.id, %{
          position: 1,
          title: "Implement Phase",
          kind: :backend,
          surface: :web,
          current_stage: :implement,
          stages: %{"implement" => %{"status" => "running"}, "test" => %{"status" => "pending"}}
        })

      {:ok, _view, _html} = live(conn, ~p"/")

      # Select the orchestrator (this triggers workstreams to load)
      {:ok, view, _html} =
        conn
        |> live(~p"/")
        |> then(&view(&1, "#orchestrator-#{orchestrator.id}"))
        |> render_click()

      {:ok, %{view: view, orchestrator: orchestrator, workstream: workstream, phase1: phase1, phase2: phase2}}
    end

    test "workstreams render as swimlanes in ADWS view with correct columns", %{view: view, workstream: workstream, phase1: phase1, phase2: phase2} do
      # Switch to ADWS view
      view |> element("#view-toggle") |> render_click()

      # Assert workstreams swimlanes container exists
      assert has_element?(view, "#workstreams-swimlanes")

      # Assert four column headers exist
      assert has_element?(view, "#workstreams-swimlanes > div:nth-child(1) > div:nth-child(1)", "Spec")
      assert has_element?(view, "#workstreams-swimlanes > div:nth-child(1) > div:nth-child(2)", "Implement")
      assert has_element?(view, "#workstreams-swimlanes > div:nth-child(1) > div:nth-child(3)", "Test")
      assert has_element?(view, "#workstreams-swimlanes > div:nth-child(1) > div:nth-child(4)", "Review")

      # Assert phase rows render under correct columns
      assert has_element?(view, "#workstream-#{workstream.id}-phase-#{phase1.id}")
      assert has_element?(view, "#workstream-#{workstream.id}-phase-#{phase2.id}")

      # Verify column placement via inline style (grid-column-start)
      html = render(view)
      assert html =~ "workstream-#{workstream.id}-phase-#{phase1.id}"
      assert html =~ "grid-column-start: 1"  # spec phase in column 1
      assert html =~ "workstream-#{workstream.id}-phase-#{phase2.id}"
      assert html =~ "grid-column-start: 2"  # implement phase in column 2
    end

    test "workstreams do not render in orchestrator drawer", %{view: view} do
      # Switch to ADWS view
      view |> element("#view-toggle") |> render_click()

      # Assert workstreams swimlanes exist in ADWS
      assert has_element?(view, "#workstreams-swimlanes")

      # Assert old workstreams panel does NOT exist in drawer
      refute has_element?(view, "#workstreams-panel")
    end

    test "toggling back to logs view hides workstreams swimlanes", %{view: view} do
      # Switch to ADWS view
      view |> element("#view-toggle") |> render_click()
      assert has_element?(view, "#workstreams-swimlanes")

      # Switch back to logs view
      view |> element("#view-toggle") |> render_click()

      # Assert swimlanes container is hidden (via @view_mode != :adws class)
      html = render(view)
      refute html =~ "workstreams-swimlanes"
    end

    test "workstreams update live on PubSub broadcast", %{view: view, workstream: workstream, phase1: phase1} do
      # Switch to ADWS view
      view |> element("#view-toggle") |> render_click()

      # Initial state: phase1 is in spec stage
      assert has_element?(view, "#workstream-#{workstream.id}-phase-#{phase1.id}")

      # Broadcast an update (simulating MCP tool call)
      Workstreams.update_phase(phase1.id, %{current_stage: :implement})
      records = Workstreams.list_records(workstream.orchestrator_id)
      Phoenix.PubSub.broadcast(RepoBuilder.PubSub, "workstreams:#{workstream.orchestrator_id}", {:workstreams_updated, workstream.orchestrator_id, records})

      # Assert view updates (poll for the change)
      assert wait_render(view, "workstream-#{workstream.id}-phase-#{phase1.id}")
      html = render(view)
      # Verify the phase moved to implement column
      assert html =~ "grid-column-start: 2"
    end
  end

  # Helper for unique identifiers
  defp uniq, do: System.unique_integer([:positive, :monotonic]) |> Integer.to_string()
  ```
- Add the `wait_render/3` helper (copy from `test_unified_adw_swimlane_cards_test.exs`).

### 8. Run the Validation Commands
- Run every command in the Validation Commands section; fix any failure until all are green with zero regressions.

## Testing Strategy
### Integration Tests
The LiveView integration test (`test_workstreams_swimlanes_test.exs`) covers:
- Switching to ADWS view renders workstreams swimlanes with four column headers.
- Workstream-phase rows appear under the correct column matching their `current_stage`.
- The orchestrator drawer no longer renders the old `workstreams_panel`.
- Toggling back to logs view hides the swimlanes container.
- PubSub `:workstreams_updated` broadcasts re-stream and update the view live.

### Edge Cases
- **No orchestrator selected**: workstreams swimlanes should show an empty state or not render at all.
- **Orchestrator selected but no workstreams**: show a "No workstreams yet" message.
- **Phase in `:done` state**: render under the Review column or omit from active swimlanes (per design decision).
- **Multiple workstreams**: all phases from all workstreams render; column layout handles many rows.
- **Workstream with focus indicator**: the star icon renders correctly.
- **Phases with different statuses** (`:running`, `:blocked`, `:done`, `:pending`): border/background colors apply via the status-driven classes.
- **Reconnect handling**: on page refresh, the stream re-seeds from `Workstreams.list_records/1` and swimlanes reappear.

## Acceptance Criteria
- The ADWS tab (`view_mode == :adws`) renders workstreams as a four-column swimlane layout with headers Spec / Implement / Test / Review.
- Each workstream's phases appear as rows under the column matching their `current_stage`.
- Stage chips, done/total counts, focus indicators, and status-driven styling are preserved (reusing existing helpers).
- The `:workstreams_updated` PubSub broadcast triggers a stream re-stream and live updates the view.
- The orchestrator drawer no longer renders the `workstreams_panel` component.
- Switching between logs and ADWS view correctly shows/hides the workstreams swimlanes.
- On reconnect, the workstreams stream re-seeds and swimlanes reappear.
- The new LiveView integration test passes; no new failures in the existing suite.
- The build is clean under `--warnings-as-errors`, Credo `--strict`, and Dialyzer.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix test test/repo_builder_web/live/test_workstreams_swimlanes_test.exs` — The new LiveView integration test passes.
- `mix test test/repo_builder_web/live/console_live_test.exs` — Console LiveView tests pass (no regressions from removing drawer rendering).
- `mix compile --warnings-as-errors` — Clean compile; gradual set-theoretic checker + `warnings_as_errors` pass.
- `mix test --warnings-as-errors` — Full suite; no new failures.
- `mix format --check-formatted` — Formatting clean.
- `mix credo --strict` — Lint passes, including the `@spec`-on-every-public-function gate.
- `mix dialyzer` — No new contract warnings; no stale ignore filters.

## Notes
- This is a UI/LiveView-only change: no new dependencies, no schema/migration, no new context functions. The `Workstreams.list_records/1` function already returns workstreams with phases preloaded.
- The existing `workstreams_panel` component is left in place (deprecated) rather than deleted to avoid breaking any potential external references. It can be removed in a follow-up if confirmed unused.
- Swimlane column placement uses CSS Grid (`grid-column-start`) — this keeps rows aligned under their stage column regardless of which columns have content.
- The `stages` map on `WorkstreamPhase` stores per-stage outcomes as JSONB; the existing `stage_status` and `stage_chip_style` helpers already read from this map for the stage chip styling.
- Reconnect handling follows §9's pattern: the stream is re-seeded in `mount` using `Workstreams.list_records/1`, which reads from the database, so disconnected updates are not lost (they persist via MCP tool calls).
- The `dom_id` function for `stream_configure` uses a composite key `{workstream, phase}` to ensure stable, unique IDs per phase row — this allows `stream_insert` with the same ID to replace in place when phases update.