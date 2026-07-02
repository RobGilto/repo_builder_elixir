# Worker report: workstreams-research (idle)

# Workstreams Research Report

## 1. Workstreams Domain

**YES**, there IS a workstreams context: `RepoBuilder.Orchestrator.Workstreams` at `/data/1.Projects/repo_builder_elixir/lib/repo_builder/orchestrator/workstreams.ex`.

### Modules
- `RepoBuilder.Orchestrator.Workstreams` - Context module (only Repo caller for orchestrator_workstreams/orchestrator_workstream_phases)
- `RepoBuilder.Orchestrator.Workstream` - Schema at `/data/1.Projects/repo_builder_elixir/lib/repo_builder/orchestrator/workstream.ex`
- `RepoBuilder.Orchestrator.WorkstreamPhase` - Schema at `/data/1.Projects/repo_builder_elixir/lib/repo_builder/orchestrator/workstream_phase.ex`

### Key Public Functions (with @spec signatures from workstreams.ex)
```elixir
@spec create_workstream(Ecto.UUID.t(), map()) :: {:ok, Workstream.t()} | {:error, Ecto.Changeset.t()}
@spec plan_phases(Ecto.UUID.t(), String.t(), [map()]) :: {:ok, Workstream.t()} | {:error, reason() | Ecto.Changeset.t()}
@spec record_stage(Ecto.UUID.t(), String.t(), map()) :: {:ok, Workstream.t()} | {:error, reason() | Ecto.Changeset.t()}
@spec close_workstream(Ecto.UUID.t(), String.t(), atom() | String.t()) :: {:ok, Workstream.t()} | {:error, reason() | Ecto.Changeset.t()}
@spec set_focus(Ecto.UUID.t(), String.t(), String.t()) :: {:ok, Workstream.t()} | {:error, reason() | Ecto.Changeset.t()}
@spec clear_focus(Ecto.UUID.t(), String.t()) :: {:ok, Workstream.t()} | {:error, reason() | Ecto.Changeset.t()}
@spec list_workstreams(Ecto.UUID.t()) :: [index_row()]
@spec get_workstream(Ecto.UUID.t(), String.t()) :: {:ok, full_record()} | {:error, reason()}
@spec list_records(Ecto.UUID.t()) :: [full_record()]
```

### Ecto Schemas

**Workstream** (lib/repo_builder/orchestrator/workstream.ex):
```elixir
@type t :: %__MODULE__{
  id: Ecto.UUID.t() | nil,
  orchestrator_id: Ecto.UUID.t() | nil,
  title: String.t() | nil,
  goal: String.t() | nil,
  definition_of_done: String.t() | nil,
  status: :running | :blocked | :done | :abandoned,
  stall_count: non_neg_integer(),
  current_phase_position: non_neg_integer(),
  focus: String.t() | nil,
  focus_set_at: DateTime.t() | nil,
  phases: [WorkstreamPhase.t()] | Ecto.Association.NotLoaded.t(),
  inserted_at: DateTime.t() | nil,
  updated_at: DateTime.t() | nil
}
```

**WorkstreamPhase** (lib/repo_builder/orchestrator/workstream_phase.ex):
```elixir
@type t :: %__MODULE__{
  id: Ecto.UUID.t() | nil,
  workstream_id: Ecto.UUID.t() | nil,
  position: pos_integer() | nil,
  title: String.t() | nil,
  description: String.t() | nil,
  definition_of_done: String.t() | nil,
  spec_path: String.t() | nil,
  stages: %{optional(String.t()) => stage_record()},
  status: :pending | :running | :done | :blocked,
  current_stage: :spec | :implement | :test | :review | :done,
  kind: :backend | :ui_ux,
  surface: :web | :desktop | :tui | nil,
  iteration: non_neg_integer(),
  workstream: Workstream.t() | Ecto.Association.NotLoaded.t(),
  inserted_at: DateTime.t() | nil,
  updated_at: DateTime.t() | nil
}
```

### Migrations + Tables + Columns + FKs

**Migration**: `priv/repo/migrations/20260628120000_create_orchestrator_workstreams.exs`

**Table `orchestrator_workstreams`**:
- `id` - binary_id (PK)
- `orchestrator_id` - binary_id (FK to orchestrators, on_delete: :delete_all)
- `title` - string (NOT NULL)
- `goal` - text (NOT NULL)
- `definition_of_done` - text (nullable)
- `status` - string (NOT NULL, default: "running")
- `stall_count` - integer (NOT NULL, default: 0)
- `current_phase_position` - integer (NOT NULL, default: 0)
- `focus` - text (added in 20260701003503_add_focus_to_orchestrator_focus_state.exs)
- `focus_set_at` - utc_datetime_usec (added in 20260701003503_add_focus_to_orchestrator_focus_state.exs)
- `inserted_at`, `updated_at` - utc_datetime_usec
- Index: `[:orchestrator_id]`

**Table `orchestrator_workstream_phases`**:
- `id` - binary_id (PK)
- `workstream_id` - binary_id (FK to orchestrator_workstreams, on_delete: :delete_all)
- `position` - integer (NOT NULL)
- `title` - string (NOT NULL)
- `description` - text (nullable)
- `definition_of_done` - text (nullable)
- `spec_path` - string (nullable)
- `stages` - map (JSONB, default: %{}, NOT NULL)
- `status` - string (NOT NULL, default: "pending")
- `current_stage` - string (NOT NULL, default: "spec")
- `inserted_at`, `updated_at` - utc_datetime_usec
- Index: `[:workstream_id, :position]`

**Binary_id usage**: YES, all tables use `:binary_id` (UUID) primary keys and foreign keys.

---

## 2. How Workstreams Connect to the Core

### Relation to Session Runtime (§6)
Workstreams are driven by the orchestrator's ADW loop, not directly by session runtime. The orchestrator (`RepoBuilder.Orchestrator.Server`) manages workstreams and dispatches work to individual worker sessions. The `Workstreams.record_stage/3` function advances phases through the spec→implement→test→review state machine.

### Relation to Workflow Engine (§7)
Workstreams are a SEPARATE concept from workflows. Workflows are ADW definitions (`RepoBuilder.Workflows`) with steps that delegate to harness sessions. Workstreams are the orchestrator's top-level durable unit of work for managing parallel objectives through phases.

### Relation to `RepoBuilder.Logs`
No direct connection found in the code. Agent logs (`agent_logs`) record canonical harness events, not workstream/phase state changes. The orchestrator's workstreams provide their own rehydration records.

### PubSub Topics
Workstreams broadcast state changes via `RepoBuilder.Dashboard.broadcast_workstreams/2` (lib/repo_builder/dashboard.ex):
- Topic: `"console:events"` (the global console event feed)
- Message: `{:workstreams_updated, orchestrator_id, records}` where `records` is the `Workstreams.list_records/1` list
- Called from `Workstreams.record_stage/3` → `Dashboard.broadcast_workflow_step/2` (for per-step progress) and likely from orchestrator actions

---

## 3. Existing LiveView Dashboard (§9)

**Main dashboard module**: `RepoBuilderWeb.ConsoleLive` at `/data/1.Projects/repo_builder_elixir/lib/repo_builder_web/live/console_live.ex`

**Routes** (from router.ex):
```elixir
live "/", ConsoleLive
live "/dashboard", DashboardLive
```

**Mount/handle_event/handle_info patterns**:
- ConsoleLive subscribes to `RepoBuilder.PubSub` via `Dashboard.subscribe_events()` in mount
- Handles `{:workstreams_updated, orchestrator_id, records}` in `handle_info/2`
- Uses `assign(socket, workstreams: Workstreams.list_records(orchestrator.id))` pattern

**LiveView streams usage**:
No explicit `stream/3` or `@streams.*` found in the workstreams context. The main dashboard (ConsoleLive) appears to use regular assigns for workstreams (`assign(socket, workstreams: ...)`).

**PubSub subscription in mount**:
```elixir
Dashboard.subscribe_events()  # subscribes to "console:events"
```

**Layouts.app usage**:
ConsoleLive uses `<Layouts.app flash={@flash} ...>` wrapper (Phoenix v1.8 guideline).

**Short excerpt from console_live.ex**:
```elixir
def handle_info({:workstreams_updated, orchestrator_id, records}, socket) do
  # Updates workstreams assign when broadcast received
  {:noreply, socket}
end
```

---

## 4. Existing Workstreams UI

**YES**, there IS existing workstreams UI in `RepoBuilderWeb.ConsoleLive`.

The console renders workstreams in a bottom drawer/panel showing:
- Workstreams as full records (phases + stage state)
- Workstreams are loaded via `Workstreams.list_records(orchestrator.id)`
- Updated via PubSub broadcasts on `{:workstreams_updated, orchestrator_id, records}`

The UI shows:
- Per-workstream: id, title, goal, definition_of_done, status, stall_count, current_phase_position, next_action, focus, focus_set_at
- Per-phase: position, title, description, definition_of_done, spec_path, status, current_stage, kind, surface, iteration, stages (JSONB map of stage outcomes)
- Phase stages: `spec`, `implement`, `test`, `review` with status (`passed`/`failed`/`blocked`), worker, artifact, note, gate (quality-gate evidence)

The workstreams panel is collapsible/expandable in the bottom orchestrator drawer of the console.

---

## 5. Conventions

### Function Components
- `RepoBuilderWeb.CoreComponents` imported in `my_app_web.ex` (standard Phoenix pattern)
- All LiveViews `use RepoBuilderWeb, :live` which imports core components

### `<.icon>` Usage
From Phoenix v1.8 guidelines: imported via `core_components.ex` with `<.icon name="hero-x-mark" class="w-5 h-5"/>` pattern.

### Form Pattern
- `to_form/2` for form creation in LiveView
- `<.form for={@form} id="...">` pattern with `<.input field={@form[:field]} type="...">`
- Never use `Phoenix.HTML.form_for` or `Phoenix.HTML.inputs_for` (deprecated)

### Context-as-only-Repo-Caller
**YES**, enforced: `RepoBuilder.Orchestrator.Workstreams` is the ONLY `Repo` caller for `orchestrator_workstreams`/`orchestrator_workstream_phases` (AGENTS.md §8 principle).

### Typed Style Guide
**Document exists**: `/data/1.Projects/repo_builder_elixir/ai_docs/typed-elixir-standard.md`

**Key rules**:
- `@spec` on EVERY public function (enforced via Credo)
- `@type`/`@typep`/`@opaque` for domain data
- `@enforce_keys` on every struct + explicit `@type t` (prefer `typedstruct`)
- `@behaviour` with `@callback` specs, `@impl true` on implementations
- Precise types over broad ones (`pos_integer()`, atom unions, tagged tuples)
- Wire type ≠ domain type (validate at boundary)
- Compiler warnings are hard failures (`--warnings-as-errors`)
- JSONB loads with string keys, never `String.to_atom/1` on untrusted keys

### `mix precommit` Alias
**Defined in mix.exs**:
```elixir
precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
```
Runs compile with warnings-as-errors, unlocks unused deps, formats code, and runs tests.

### Test Layout
- Tests under `/data/1.Projects/repo_builder_elixir/test/`
- `test/support/` for test helpers
- `async: true` preferred (no shared global state)
- Mox for behaviour mocking, FakeHarness for harness testing

---

## 6. BUILD_PROMPT.md Summary

### §3 Typed Style Guide (Key Constraints)
- `@spec` on every public function (exemption: `@impl true` callbacks)
- `@type`/`@opaque` for domain concepts
- `@enforce_keys` on every struct with explicit `@type t`
- `@behaviour` + `@callback` for contracts
- Precise types over `any()`/`term()`/`map()`
- Wire type ≠ domain type (validate at boundary with TypeCheck or Ecto)
- Compiler warnings are hard failures: `elixirc_options: [warnings_as_errors: true]`
- Prefer `{:ok, t()} | {:error, reason()}` over raising

**Quote**: "Treat a missing `@spec` on a public `def` as a lint failure."

### §6 Session Runtime
- One GenServer per live agent/orchestrator session under `SessionSupervisor`
- Session runtime owns harness child process (erlexec or muontrap)
- Durable os_pid ledger for orphan prevention on BEAM crash
- Per-session workspace isolation in `priv/workspaces/<session_id>/`
- Idle timeout (default 300s) with `%Error{reason: :idle_timeout}`
- **Relevance to workstreams**: Workstreams delegate to individual sessions via orchestrator dispatch, not directly owned by session runtime.

### §7 Workflow / ADW Engine
- Workflows are deterministic, composable chains of steps
- `WorkflowEngine.Runner` state machine under `WorkflowSupervisor`
- `workflow_runs` is source of truth for run position
- Steps: spec→implement→test→review with deterministic edges
- **Quote**: "A workflow definition is durable data... A running workflow is a supervised process / explicit state machine."

### §8 Persistence
- binary_id (UUID) PKs app-wide
- `Ecto.Enum` for closed domains (provider, status, etc.)
- Context modules are ONLY `Repo` callers (controllers/LiveViews/OTP never touch `Repo`/`Ecto.Query`)
- JSONB for event payloads + usage
- **Quote**: "All DB access lives behind `@spec`'d context modules — controllers, LiveViews, and OTP processes never touch `Repo`/`Ecto.Query` directly."

### §9 LiveView Observability Dashboard
- Server-rendered, real-time, swimlane-style
- Subscribe only when `connected?(socket)`
- Streams for append-only logs: `stream_configure(:logs, dom_id: &"log-#{&1.id}")` then `stream(:logs, [])`
- Live cost/status via `assign_async`/`start_async`
- Reconnect handling: seed stream from persisted last N rows on mount
- Typed function components with `attr/3` + `slot/3`
- **Quote**: "Subscribe only when `connected?(socket)` — mount/3 runs twice (static render, then live socket); subscribing on the disconnected render leaks/duplicates."

---

**Summary for Feature Planning**: Workstreams are a fully-persisted orchestrator concept (separate from workflows) with schemas, migrations, and a typed context (`RepoBuilder.Orchestrator.Workstreams`). They broadcast updates via PubSub on `"console:events"` and are rendered in ConsoleLive's bottom panel. Any new workstreams UI should follow the typed conventions, use streams for collections, subscribe to PubSub updates, and maintain the context-as-only-Repo-caller pattern.
