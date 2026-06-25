# Feature: Scope the log/event stream to the active project

## Metadata
issue_number: `selecting`
adw_id: `a`
issue_json: `project,`

## Feature Description
The orchestration console at `/` renders a single global event stream (the "logs" view)
that interleaves events from **every** agent and orchestrator on the platform. The page
also carries a global **project switcher** (`RepoBuilderWeb.ProjectComponents.switcher`)
that, on change, performs a full context switch: it re-binds the active orchestrator,
re-scopes the agent rail roster (`Agents.list_for_project/1`), and reloads the
orchestrator-scoped views. However, the **log/event stream is NOT re-scoped** — after
switching projects the operator still sees logs from unrelated projects' orchestrators and
workers, making it impossible to follow a single project's activity.

This feature makes selecting a project automatically scope the event stream to that project:
only events emitted by the **project's bound orchestrator** and the **project's worker agents**
(those whose `agent.project_id` matches the active project) are shown. The scope is applied
automatically the moment a project is selected (no extra click), and exposes a single
toggle chip (`PROJECT ONLY`) in the existing filter bar so the operator can opt back into the
full unscoped feed when they need cross-project visibility.

This reuses the existing in-assign filtering machinery (`event_buffer` → `passes?/2` →
`restream/1`) and the existing project↔agent binding (`agent.project_id`,
`Agents.list_for_project/1`), so it is purely a presentation-layer filter — no new schema,
migration, or persistence is required. Persisted history is untouched; toggling the scope
off re-reveals buffered rows.

## User Story
As an operator running multiple projects from one console
I want the log stream to show only the active project's orchestrator and its workers when I
select a project
So that I can follow a single project's activity without noise from unrelated projects, and
still toggle back to the full feed when I need cross-project visibility.

## Problem Statement
Switching the project switcher re-scopes the agent rail, the orchestrator binding, and the
cost/chat views, but leaves the event stream global. The operator cannot see "just this
project's logs" — every project's orchestrator and worker events are interleaved in one feed,
which defeats the purpose of the per-project context switch for the most-watched panel.

## Solution Statement
Add a project-scope dimension to the existing event-stream filter pipeline:

1. Compute, per active project, the set of "owned" agent keys = the active project's bound
   **orchestrator id** ∪ its **worker agent ids** (`Agents.list_for_project/1`). Store it as a
   `project_agent_keys` MapSet assign, recomputed wherever the roster or orchestrator binding
   changes (`load_agents/1`, plus the `:agent_created`/`:agent_updated`/`:agent_deleted`
   handlers so workers spawned mid-session stay visible).
2. Add a `project_scoped?` boolean assign (default `true`). When `true` AND a project is
   active AND the owned-key set is non-empty, the stream filter `passes?/2` additionally
   requires each row's `agent_key` to be in `project_agent_keys`. When there is no active
   project, or scope is off, or the owned set is empty, the predicate is a no-op (preserving
   the back-compatible global view).
3. Make `select_project` **re-stream** after re-scoping (it currently only re-assigns; the
   already-buffered rows are never re-filtered), so the scope applies immediately on switch.
4. Surface a single `PROJECT ONLY` toggle chip in the existing `filter_bar` (mirroring the
   `AUTO-FOLLOW`/regex chips) wired to a new `toggle_project_scope` event that flips
   `project_scoped?` and re-streams. The chip is hidden when no project is active.

Because `event_buffer` retains every row regardless of the active filters (rows are only
filtered out of the *stream view*, never dropped from the buffer), toggling scope off
instantly re-reveals the unscoped rows with no reload.

## Relevant Files
Use these files to implement the feature:

- `lib/repo_builder_web/live/console_live.ex` — The console LiveView. Owns `event_buffer`,
  the `passes?/2` + `restream/1` filter pipeline (≈ lines 2774–2793), the `select_project`
  handler (≈ line 924), `load_agents/1` (≈ line 568), the `record_event/4` row builder
  (`agent_key: agent_id`, ≈ line 2534), `clear_filters` (≈ line 1558), the mount assigns
  (≈ lines 95, 149–160, 208), and the `:agent_created`/`:agent_updated`/`:agent_deleted`
  handlers (≈ lines 2387, 2455, 2476). This is where the scope assign, the new predicate,
  the recompute, the re-stream on switch, and the new toggle handler all live.
- `lib/repo_builder_web/components/console_components.ex` — `filter_bar/1` (≈ line 376) and its
  `attr` declarations (≈ lines 367–372). Add a `project_scoped?` + `project_active?` attr and
  the `PROJECT ONLY` toggle chip here, alongside the existing `AUTO-FOLLOW`/`CLEAR` chips.
- `lib/repo_builder/agents.ex` — `list_for_project/1` (≈ line 47) and `scope_by_project/2`
  (≈ line 39): the existing project→agents query, reused verbatim to build the owned-key set.
  No changes needed; read to confirm the `project_id` filter semantics (nil ⇒ unscoped).
- `lib/repo_builder/agents/agent.ex` — `Agent` schema with `project_id` field (≈ line 45) and
  type (≈ line 26). Confirms the worker→project binding the owned-key set relies on. No changes.
- `lib/repo_builder/orchestrators.ex` — `get_or_create_for_project/1` and the orchestrator↔
  project binding consumed by `switch_orchestrator/2`. Confirms the active orchestrator id
  (`socket.assigns.orchestrator_id`) is the project's bound brain, so it must be added to the
  owned-key set. Read only; no changes expected.
- `BUILD_PROMPT.md` — §9 (LiveView dashboard: streams + filters), §3 (typed style guide),
  §8 (persistence behind contexts). Authoritative conventions to honor.

### New Files
- `test/repo_builder_web/live/test_scope_logs_to_active_project_test.exs` — A
  `Phoenix.LiveViewTest` integration test that mounts `ConsoleLive`, drives a project switch,
  feeds the LiveView simulated `:agent_event` messages from (a) the project's orchestrator,
  (b) a worker bound to the project, and (c) an agent bound to a *different* project, and
  asserts only (a) and (b) render in `#event-stream` while (c) is excluded; then asserts
  clicking the `PROJECT ONLY` chip toggles scope off and re-reveals (c).

## Implementation Plan
### Phase 1: Foundation
Introduce the scope state and the owned-key set without yet changing the filter outcome.
Add two assigns — `project_scoped?` (boolean, default `true`) and `project_agent_keys`
(`MapSet.t(String.t())`, default empty) — to the mount assigns and to the `clear_filters`
reset block (so a clear returns to the documented default). Add a private
`project_agent_keys/1` helper that, given the socket, returns the MapSet of `to_string/1`-
normalized ids = the active orchestrator id (`socket.assigns.orchestrator_id`, when binary)
plus every `agent.id` from `Agents.list_for_project(active_project_id)`. Normalize to strings
because `record_event/4` stores `agent_key: agent_id` and elsewhere stringifies ids for color
keys; the predicate must compare like-for-like.

### Phase 2: Core Implementation
Wire the owned-key set into the filter pipeline:
- Recompute `project_agent_keys` inside `load_agents/1` (it already runs at mount, on
  `select_project`, and we will also call the recompute from the agent-roster handlers).
- Extend `passes?/2` with a `project_pass?/2` clause: when `project_scoped?` is `true`, a
  project is active, and `project_agent_keys` is non-empty, require
  `to_string(row.agent_key)` ∈ `project_agent_keys`; otherwise pass (no-op).
- Make `select_project` re-stream after `switch_orchestrator` + `load_agents` so the scope is
  applied to the already-buffered rows immediately on switch.
- Keep `record_event/4` unchanged: rows still always land in `event_buffer`; only the stream
  view is filtered, so toggling scope off re-reveals rows with no reload.

### Phase 3: Integration
Expose the control and keep the set fresh:
- Add a `toggle_project_scope` `handle_event` that flips `project_scoped?` and re-streams.
- Add `project_scoped?` + `project_active?` attrs to `filter_bar/1` and render a
  `PROJECT ONLY` toggle chip (only when a project is active), mirroring the `AUTO-FOLLOW`
  chip's active styling. Pass the two new assigns from the `render/1` `filter_bar` call site.
- In `:agent_created`, `:agent_updated`, and `:agent_deleted` handlers, recompute
  `project_agent_keys` (a worker reassigned to / spawned under the active project must become
  visible, and one removed must drop out) and re-stream so the live view stays correct.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Add the LiveView integration test (write first, expect red)
- Create `test/repo_builder_web/live/test_scope_logs_to_active_project_test.exs` using
  `RepoBuilderWeb.ConnCase` + `Phoenix.LiveViewTest` and the project test fixtures/factory used
  by the existing `console_live` and project tests (inspect `test/support/` and a sibling
  console test for the exact setup, e.g. seeding `Projects`, `Orchestrators`, `Agents`).
- Mount `ConsoleLive` (`live(conn, "/")`), seed two projects (A, B), a worker agent bound to A,
  a worker agent bound to B, and ensure A has a bound orchestrator.
- `render_change` the `#project-switcher` form (`select_project`) to project A.
- Send the LiveView simulated events the same way the runtime does — `send(view.pid,
  {:agent_event, agent_id, %Event.<Variant>{...}, log_no})` — for: A's orchestrator id, A's
  worker id, and B's worker id (use the canonical `Event` structs already used in
  `console_live.ex` handlers; copy a minimal shape from an existing console test).
- Assert `#event-stream` contains the A-orchestrator and A-worker bodies and does NOT contain
  the B-worker body.
- Click the `PROJECT ONLY` chip (`element(view, "#project-scope") |> render_click()`) and
  assert the B-worker body now appears (scope off ⇒ unscoped feed).
- Run it and confirm it fails for the right reason before implementing.

### 2. Add scope assigns to mount + clear defaults
- In `ConsoleLive.mount/3` assigns, add `project_scoped?: true` and
  `project_agent_keys: MapSet.new()`.
- In `clear_filters/2`'s reset block, add `project_scoped?: true` (leave
  `project_agent_keys` as-is — the roster set is rebuilt by `load_agents`, not by a filter
  clear). Re-stream as that handler already does.

### 3. Add the owned-key computation helper
- Add `@spec project_agent_keys(Phoenix.LiveView.Socket.t()) :: MapSet.t(String.t())` and a
  private `defp project_agent_keys/1` that returns
  `MapSet.new([orchestrator_id | worker_ids], &to_string/1)` filtered for the active project,
  where `worker_ids` come from `Agents.list_for_project(socket.assigns[:active_project_id])`
  and `orchestrator_id` is included only when `is_binary(socket.assigns[:orchestrator_id])`.
  When `active_project_id` is `nil`, return `MapSet.new()` (empty ⇒ predicate no-ops).

### 4. Recompute the set in `load_agents/1`
- In `load_agents/1`, after assigning `agents`, also `assign(:project_agent_keys,
  project_agent_keys(socket))`. Ensure it reads the freshly-assigned roster (compute from the
  same `Agents.list_for_project/1` result to avoid a second query, or call the helper after
  the agents assign). `load_agents/1` already runs at mount and in `select_project`.

### 5. Extend the filter predicate
- Add `@spec project_pass?(map(), map()) :: boolean()` and a `defp project_pass?/2` that
  returns `true` when `assigns.project_scoped?` is `false`, or `assigns.active_project_id` is
  `nil`, or `MapSet.size(assigns.project_agent_keys) == 0`; otherwise
  `MapSet.member?(assigns.project_agent_keys, to_string(row.agent_key))`.
- Add `project_pass?(row, assigns)` to the `and` chain in `passes?/2`.

### 6. Re-stream on project switch
- In the `select_project` handler, append `|> restream()` after `load_agents()` so the scope
  is applied to already-buffered rows the moment the project changes.

### 7. Add the toggle handler
- Add `def handle_event("toggle_project_scope", _params, socket)` that flips
  `project_scoped?` and pipes through `restream/1`. Add an `@impl true`/`@spec` consistent with
  the surrounding handlers (most are `@impl true def handle_event`).

### 8. Add the filter-bar chip
- In `console_components.ex`, add `attr :project_scoped?, :boolean, default: true` and
  `attr :project_active?, :boolean, default: false` to `filter_bar/1`.
- Render a `PROJECT ONLY` chip (id `project-scope`, `phx-click="toggle_project_scope"`,
  `:if={@project_active?}`) next to `AUTO-FOLLOW`, active-styled when `@project_scoped?`
  (reuse the `cns-chip--active cns-chip--hook` pattern), with a `title` explaining it scopes
  logs to the active project's orchestrator + workers.

### 9. Pass the new assigns at the call site
- In `ConsoleLive.render/1`, on the `<.filter_bar .../>` call, add
  `project_scoped?={@project_scoped?}` and
  `project_active?={@active_project_id != nil}`.

### 10. Keep the set fresh on roster changes
- In `:agent_created`, `:agent_updated`, and `:agent_deleted` handlers, after the existing
  roster mutation, recompute `assign(:project_agent_keys, project_agent_keys(socket))` (using
  the updated socket) and pipe through `restream/1` so a worker added to / removed from the
  active project immediately enters/leaves the scoped view. Keep the existing stream/lane
  side effects intact.

### 11. Run the validation commands
- Run every command in `Validation Commands` and fix any failures until all are green with
  zero regressions.

## Testing Strategy
### Unit Tests
- `project_pass?/2` truth table (can be exercised via the LiveView test, or a focused unit
  test if the helper is made testable): scope-off ⇒ pass; nil project ⇒ pass; empty key set
  ⇒ pass; member key ⇒ pass; non-member key ⇒ fail.
- `load_agents/1` populates `project_agent_keys` with the orchestrator id + project workers
  and excludes other projects' workers (covered by the integration test's render assertions).
- The LiveView integration test in
  `test/repo_builder_web/live/test_scope_logs_to_active_project_test.exs` is the primary
  end-to-end proof (switch → scoped stream → toggle → unscoped stream).

### Edge Cases
- **No active project (nil):** predicate no-ops; the global feed is preserved; the
  `PROJECT ONLY` chip is hidden.
- **Project with a bound orchestrator but zero workers:** owned set is just the orchestrator
  id (non-empty) ⇒ only orchestrator events show; not an accidental no-op.
- **Empty owned set** (project active but neither orchestrator id nor workers resolved):
  predicate no-ops rather than hiding *everything* (fail-open, avoids a blank stream).
- **Worker spawned mid-session under the active project** (`:agent_created`): recompute keeps
  it visible without a reload.
- **Worker reassigned/removed** (`:agent_updated`/`:agent_deleted`): recompute drops it.
- **Scope toggled off then back on:** buffered rows re-reveal / re-hide via `restream/1` with
  no data loss (rows always remain in `event_buffer`).
- **`agent_key` type mismatch:** `to_string/1` normalization on both the set and the row key
  guards against binary-vs-string comparison misses.

## Acceptance Criteria
- Selecting a project in the switcher immediately re-scopes `#event-stream` to that project's
  bound orchestrator + its worker agents; events from other projects' agents disappear from
  the stream view.
- A `PROJECT ONLY` chip appears in the filter bar only when a project is active, reflects the
  current scope state (active styling when on), and toggles between scoped and full feeds
  without reloading or losing buffered rows.
- With no active project, behavior is unchanged (global feed; chip hidden).
- Workers spawned, reassigned, or removed mid-session under the active project enter/leave the
  scoped view correctly.
- The new LiveView integration test passes, and the full suite, compile, format, Credo, and
  Dialyzer gates are all green with zero regressions.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix test test/repo_builder_web/live/test_scope_logs_to_active_project_test.exs` — The new
  LiveView integration test: project switch scopes the stream; toggle re-reveals the unscoped
  feed.
- `mix compile --warnings-as-errors` — Compile clean; gradual set-theoretic type checker and
  `warnings_as_errors` must pass.
- `mix test --warnings-as-errors` — Full ExUnit suite (Postgres-backed) with zero failures.
- `mix format --check-formatted` — Code is formatted.
- `mix credo --strict` — Lint, including the "every public function has an `@spec`" gate.
- `mix dialyzer` — `@spec`/contract checking with no new warnings and no stale ignore filters.

Optional runtime validation (Tidewave): use `project_eval` to confirm
`RepoBuilder.Agents.list_for_project/1` returns the expected workers for a seeded project, and
capture a screenshot of `http://localhost:4000` after selecting a project to visually confirm
the scoped stream + `PROJECT ONLY` chip.

## Notes
- **Presentation-only:** no schema, migration, dependency, or persistence change. The feature
  reuses the existing `event_buffer` → `passes?/2` → `restream/1` pipeline and the existing
  `agent.project_id` binding, so it stays entirely within `BUILD_PROMPT.md` §9 (LiveView
  filters) and §8 (DB access stays behind the `Agents` context — the LiveView never touches
  `Repo`).
- **Fail-open by design:** an empty owned-key set no-ops the predicate rather than blanking the
  stream, so a transient resolution gap never hides all logs.
- **Default scope-on** matches the user's request ("the UI can switch to this filter") — the
  scope engages automatically on project selection; the chip is the explicit opt-out.
- **Future extension:** the same `project_agent_keys` set could scope the swimlanes/ADW view
  and the cost rollups; out of scope here but a natural follow-up if cross-project noise is a
  problem there too.
