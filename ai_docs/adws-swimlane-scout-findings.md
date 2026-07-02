# ADWS Swimlane Scout Findings

## 1. ADWS Tab Section

### Current Location
- **LiveView**: `lib/repo_builder_web/live/console_live.ex` (ConsoleLive)
- **Router Route**: `live "/", ConsoleLive` (root path, no separate route)
- **HEEx Template**: Inline HEEx within `console_live.ex` (no separate HTML file)

### ADWS View Mode Switching
- **Assign**: `view_mode` — atom type (`:logs` or `:adws`)
- **Default**: `:logs`
- **Toggle Function**: `toggle_view/1` (private helper)
- **Toggle Event**: No direct toggle event; the mode is switched internally
- **Location in Template**: Line ~3596-3697

### ADWS Content Rendering
- **Container ID**: `id="swimlanes"`
- **DOM Classes**: `flex min-h-0 flex-1` with conditional `hidden` class when `@view_mode != :adws`
- **ADWS Controls ID**: `id="adw-controls"`
- **Category Filter IDs**: Pattern `id="adw-cat-#{cat}"` where `cat` ∈ `[response, tool, thinking, hook]`
- **Workflow Cards Container**: `id="workflow-runs"`
- **Individual Workflow IDs**: Pattern `id="workflow-#{view.run_id}"`
- **No ADWs State**: `id="no-adws"`

### Data Loading
- **Workflow Progress**: Loaded via `workflow_views(@workflow_progress)` and `workflow_step_squares/3`
- **Event Buffer**: `@event_buffer` assign (bounded in-memory list)
- **Active Categories**: `@active_categories` (MapSet of enabled filter categories)
- **Finished Workflow Statuses**: `@finished_workflow_statuses` (module attribute: `[:succeeded, :failed, :cancelled]`)

### Clear Workflows Action
- **Button ID**: `id="clear-workflows"`
- **Event**: `phx-click="clear_workflows"`
- **Disabled Condition**: `not any_finished_workflows?(@workflow_progress)`
- **Validation**: `has_finished_workflows?/1` function checks if any workflow run has status in `@finished_workflow_statuses`

### ADWS Card Component
- **Component**: `<.adw_card>` from `RepoBuilderWeb.DashboardComponents`
- **Imported via**: `import RepoBuilderWeb.DashboardComponents, only: [adw_card: 1, event_detail_panel: 1]`

---

## 2. Tabs Component

### Console Settings Tab Rail (Vertical Tabs)
- **Module**: `lib/repo_builder_web/components/console_components.ex`
- **Component Function**: `settings_tab_button/1` (line ~2593-2608)
- **Function Signature**:
  ```elixir
  @spec settings_tab_button(map()) :: Phoenix.LiveView.Rendered.t()
  ```
- **Attributes**:
  - `:tab` (atom, required) — the tab identifier this button represents
  - `:active` (atom, required) — the currently active tab
  - `:label` (string, required) — display label for the tab
- **Event**: `phx-click="select_settings_tab"` with `phx-value-tab={@tab}`
- **DOM Classes**: `cns-chip text-left` with `cns-chip--active cns-chip--hook` when active

### Tab Switching Event Handler (ConsoleLive)
- **Handler**: `handle_event("select_settings_tab", %{"tab" => tab}, socket)`
- **Location**: `console_live.ex` (search for `"select_settings_tab"`)
- **Assign Updated**: `@settings_tab` assign stores the active tab value

### Settings Tab Values
From ConsoleLive mount assigns (line ~163):
- `:general` — default active tab
- Other tabs: Cost Center, Agent Templates, Stack Layers, Registered APIs (based on assign names)

### Tab-Related Functions
- `spend_summary_table/1` — time-windowed spend by period (today/week/month)
- `cost_rollup_table/1` — cost center rollup table
- `price_catalog_table/1` — price catalog rows
- `stack_layers_table/1` — stack layers management

---

## 3. Current Workstreams UI in ConsoleLive

### Workstreams Data Loading (ConsoleLive)
- **Load Location**: `mount/3` callback (line ~436)
- **Context Call**: `Workstreams.list_records(orchestrator.id)`
- **Assign**: `@workstreams` — list of full workstream records with phases
- **Initial Value**: `[]` (safe default for disconnected render)

### Workstreams Update Handler
- **Handler**: `handle_info({:workstreams_updated, orchestrator_id, records}, socket)`
- **Location**: Line ~2893-2895 in `console_live.ex`
- **PubSub Topic**: Broadcast by `RepoBuilder.Dashboard.broadcast_workstreams/2`
- **Payload Format**: `{:workstreams_updated, orchestrator_id, records}`
  - `orchestrator_id`: Ecto.UUID.t() (string)
  - `records`: `[RepoBuilder.Orchestrator.Workstreams.full_record()]` (list of full records)

### Workstreams Panel Component
- **Module**: `lib/repo_builder_web/components/console_components.ex`
- **Component Function**: `workstreams_panel/1` (line ~1109-1221)
- **Function Signature**:
  ```elixir
  @spec workstreams_panel(map()) :: Phoenix.LiveView.Rendered.t()
  ```
- **Attributes**:
  - `:workstreams` (list, default: `[]`) — the `Workstreams.list_records/1` list (full records)
  - `:context_tokens` (integer, default: `0`) — the brain's latest-turn context occupancy

### Workstreams Panel DOM Structure
- **Container ID**: `id="workstreams-panel"`
- **Context Badge ID**: `id="workstreams-context"` — shows brain context occupancy
- **Workstream Row IDs**: Pattern `id="workstream-#{ws.id}"`
- **Workstream Focus ID**: `id="workstream-#{ws.id}-focus"` (when focus is set)
- **Workstream Focus Hint ID**: `id="workstream-#{ws.id}-focus-hint"` (when no focus, status: :running)
- **Phase Row IDs**: Pattern `id="workstream-#{ws.id}-phase-#{phase.position}"`
- **Phase UI/UX Badge ID**: Pattern `id="workstream-#{ws.id}-phase-#{phase.position}-uiux"`
- **Stage Chip IDs**: Pattern `id="workstream-#{ws.id}-phase-#{phase.position}-#{stage}"` where `stage` ∈ `[spec, implement, test, review]`
- **Gate Strip ID**: Pattern `id="workstream-#{ws.id}-phase-#{phase.position}-gate"`
- **Gate Dot IDs**: Pattern `id="workstream-#{ws.id}-phase-#{phase.position}-gate-#{g}"` where `g` ∈ `[format, lint, type, test, mutation]`

### Workstreams Panel Rendering
- **Workstream Count Helper**: `workstream_done_count/1` — returns `"done/total"` phases completed
- **UI/UX Badge Helper**: `ui_ux_badge/1` — returns `"surface N/cap"` for ui_ux phases
- **Iteration Cap Function**: `ui_iteration_cap/0` — returns the configured cap (default: 3)
- **Stage Glyph Helper**: `stage_glyph/1` — returns single-letter stage codes (S/I/T/R)
- **Stage Status Function**: `stage_status/2` — returns `"passed" | "failed" | "blocked" | "current" | "pending"`
- **Stage Chip Style Function**: `stage_chip_style/2` — returns Tailwind style string based on status
- **Phase Label Style Function**: `phase_label_style/2` — highlights the current phase

### Drawer Location in ConsoleLive Template
- **Goal Card Toggle Button**: `id="toggle-goal-card"` (line ~3803)
- **Goal Card Container**: Wrapped in condition `:if={goal_card_present?(assigns)}`
- **Workstreams Panel Call**: `<.workstreams_panel workstreams={@workstreams} context_tokens={@orchestrator_context}>` (line ~3813-3814)

### Helper Functions for Drawer Visibility
- **Function**: `goal_card_present?/1` — checks if the drawer should render
- **Conditions**: `assigns.ledger != nil or assigns.workstreams != [] or ...`
- **Location**: `console_live.ex` line ~4113-4117

---

## 4. Workstreams Context

### Context Module
- **File**: `lib/repo_builder/orchestrator/workstreams.ex`
- **Module**: `RepoBuilder.Orchestrator.Workstreams`
- **Purpose**: Context for the durable WORKSTREAM layer; the ONLY `Repo` caller for `orchestrator_workstreams`/`orchestrator_workstream_phases` tables

### Public Functions with @spec Signatures

#### Create / Plan
```elixir
@spec create_workstream(Ecto.UUID.t(), map()) ::
        {:ok, Workstream.t()} | {:error, Ecto.Changeset.t()}
def create_workstream(orchestrator_id, attrs)

@spec plan_phases(Ecto.UUID.t(), String.t(), [map()]) ::
        {:ok, Workstream.t()} | {:error, reason() | Ecto.Changeset.t()}
def plan_phases(orchestrator_id, ref, phases)
```

#### Execution (Stage Recording)
```elixir
@spec record_stage(Ecto.UUID.t(), String.t(), map()) ::
        {:ok, Workstream.t()} | {:error, reason() | Ecto.Changeset.t()}
def record_stage(orchestrator_id, ref, attrs)
```
- `attrs` map keys: `stage` (spec|implement|test|review), `outcome` (passed|failed|blocked), optional `artifact`, `worker`, `note`, `gate`

#### Close
```elixir
@spec close_workstream(Ecto.UUID.t(), String.t(), atom() | String.t()) ::
        {:ok, Workstream.t()} | {:error, reason() | Ecto.Changeset.t()}
def close_workstream(orchestrator_id, ref, status)
```

#### Focus Discipline
```elixir
@spec set_focus(Ecto.UUID.t(), String.t(), String.t()) ::
        {:ok, Workstream.t()} | {:error, reason() | Ecto.Changeset.t()}
def set_focus(orchestrator_id, ref, focus)

@spec clear_focus(Ecto.UUID.t(), String.t()) ::
        {:ok, Workstream.t()} | {:error, reason() | Ecto.Changeset.t()}
def clear_focus(orchestrator_id, ref)
```

#### Read: Rehydration Index + Record
```elixir
@spec list_workstreams(Ecto.UUID.t()) :: [index_row()]
def list_workstreams(orchestrator_id)

@spec ready_workstreams(Ecto.UUID.t()) :: [index_row()]
def ready_workstreams(orchestrator_id)

@spec get_workstream(Ecto.UUID.t(), String.t()) :: {:ok, full_record()} | {:error, reason()}
def get_workstream(orchestrator_id, ref)

@spec list_records(Ecto.UUID.t()) :: [full_record()]
def list_records(orchestrator_id)
```

#### Resolution
```elixir
@spec resolve(Ecto.UUID.t(), String.t()) :: {:ok, Workstream.t()} | {:error, :not_found}
def resolve(orchestrator_id, ref)
```

### Type Definitions

#### Workstream Schema (`lib/repo_builder/orchestrator/workstream.ex`)
```elixir
@type status :: :running | :blocked | :done | :abandoned

@type t :: %__MODULE__{
        id: Ecto.UUID.t() | nil,
        orchestrator_id: Ecto.UUID.t() | nil,
        title: String.t() | nil,
        goal: String.t() | nil,
        definition_of_done: String.t() | nil,
        status: status(),
        stall_count: non_neg_integer(),
        current_phase_position: non_neg_integer(),
        focus: String.t() | nil,
        focus_set_at: DateTime.t() | nil,
        phases: [WorkstreamPhase.t()] | Ecto.Association.NotLoaded.t(),
        inserted_at: DateTime.t() | nil,
        updated_at: DateTime.t() | nil
      }
```

#### WorkstreamPhase Schema (`lib/repo_builder/orchestrator/workstream_phase.ex`)
```elixir
@type status :: :pending | :running | :done | :blocked
@type stage :: :spec | :implement | :test | :review
@type current_stage :: :spec | :implement | :test | :review | :done
@type stage_status :: :pending | :passed | :failed | :blocked
@type kind :: :backend | :ui_ux
@type surface :: :web | :desktop | :tui

@type t :: %__MODULE__{
        id: Ecto.UUID.t() | nil,
        workstream_id: Ecto.UUID.t() | nil,
        position: pos_integer() | nil,
        title: String.t() | nil,
        description: String.t() | nil,
        definition_of_done: String.t() | nil,
        spec_path: String.t() | nil,
        stages: %{optional(String.t()) => stage_record()},
        status: status(),
        current_stage: current_stage(),
        kind: kind(),
        surface: surface() | nil,
        iteration: non_neg_integer(),
        workstream: Workstream.t() | Ecto.Association.NotLoaded.t(),
        inserted_at: DateTime.t() | nil,
        updated_at: DateTime.t() | nil
      }
```

#### Context Index Row Type
```elixir
@type index_row :: %{
        id: Ecto.UUID.t(),
        title: String.t(),
        status: Workstream.status(),
        phase: String.t(),
        current_stage: WorkstreamPhase.current_stage() | nil,
        next_action: String.t(),
        stall_count: non_neg_integer(),
        focus: String.t() | nil,
        focus_set_at: DateTime.t() | nil
      }
```

#### Context Full Record Type
```elixir
@type full_record :: %{
        id: Ecto.UUID.t(),
        title: String.t(),
        goal: String.t() | nil,
        definition_of_done: String.t() | nil,
        status: Workstream.status(),
        stall_count: non_neg_integer(),
        current_phase_position: non_neg_integer(),
        next_action: String.t(),
        focus: String.t() | nil,
        focus_set_at: DateTime.t() | nil,
        phases: [phase_view()]
      }

@type phase_view :: %{
        position: pos_integer(),
        title: String.t(),
        description: String.t() | nil,
        definition_of_done: String.t() | nil,
        spec_path: String.t() | nil,
        status: WorkstreamPhase.status(),
        current_stage: WorkstreamPhase.current_stage(),
        kind: WorkstreamPhase.kind(),
        surface: WorkstreamPhase.surface() | nil,
        iteration: non_neg_integer(),
        stages: map(),
        completed: [String.t()],
        remaining: [String.t()]
      }
```

### PubSub Broadcast
- **Broadcast Function**: `RepoBuilder.Dashboard.broadcast_workstreams/2` (line ~184-188 in `lib/repo_builder/dashboard.ex`)
- **Topic**: Pattern `"workstreams:#{orchestrator_id}"` (where `orchestrator_id` is the UUID string)
- **Payload**: `{:workstreams_updated, orchestrator_id, records}`
  - `orchestrator_id`: Ecto.UUID.t()
  - `records`: `[full_record()]` — list of full workstream records with phases

### Constants
- **Stage Order**: `@stage_order [:spec, :implement, :test, :review]`
- **Stall Limit**: `@stall_limit 3` — bounded fix/retry attempts before `:blocked`
- **Default UI Iteration Cap**: `@default_ui_iteration_cap 3` — bounded polish for `:ui_ux` phases

---

## 5. Plan Format (from Existing Spec)

### Exact Section Headings (in order)

1. **Metadata**
   - `issue_number:`
   - `adw_id:`
   - `issue_json:`

2. **Feature Description**

3. **User Story**

4. **Problem Statement**

5. **Solution Statement**

6. **Relevant Files**
   - Existing files to read/extend (with subsections for each file)
   - New Files (with subsections for each new file)

7. **Implementation Plan**
   - Phase 1: Foundation
   - Phase 2: Core Implementation
   - Phase 3: Integration

8. **Step by Step Tasks**
   - IMPORTANT: Execute every step in order, top to bottom
   - Step-level tasks with checkboxes/descriptions

9. **Testing Strategy**
   - Unit Tests
   - Edge Cases

10. **Acceptance Criteria**

11. **Validation Commands**

12. **Notes**