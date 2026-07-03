# Feature: Custom ADW swimlane observability — durable clickable step cards with human-friendly detail

## Metadata
issue_number: `custom-adw-observability`
adw_id: `custom-adw-obs`
issue_json: `null`

## Feature Description
Custom, in-app ADWs launched from the ADW Builder ("Run" button → `WorkflowEngine.start_workflow`,
workflow `type: "custom"`) currently render as an ADW **card** in the ADWS view (title, PLAN/BUILD/TEST
step boxes, running badge, cost) but the card has **no clickable event squares** and therefore **no
human-friendly "what's happening" drilldown** — unlike standard/orchestrator-launched ADWs, which show
per-step squares you can click to open the `event_detail_panel` with a friendly summary.

This feature makes custom ADWs first-class in the swimlane observability: each step's canonical events
become **durable, per-run, clickable squares grouped under the correct step box**, and clicking a square
opens the same human-friendly detail panel standard ADWs already provide — surviving reconnects and
late connects (opening the console mid-run).

## User Story
As an **operator** running a custom ADW from the ADW Builder,
I want to **see per-step event squares on the ADW card and click any of them for a plain-language
message of what the agent is doing**,
So that **I can confirm the run is actually working and diagnose it without reading raw logs — the
same observability I already get for standard ADWs, and it must still be there when I open or reload
the console partway through a long run.**

## Problem Statement
The ADW card's clickable squares come from `workflow_step_squares(@event_buffer, run_id, active)`
(`console_live.ex:4318`), which filters `@event_buffer` to rows whose `agent_key` equals the run id or
starts with `"wf-#{run_id}"`, then groups them. `@event_buffer` is populated two ways:

1. **Live** — the `{:agent_event, agent_id, event, log_no}` handler on `console:events` appends each
   canonical event (`record_event/4`, `console_live.ex:3216`).
2. **On mount / reconnect** — `backfill_events/1` (`console_live.ex:972`) seeds it from
   `Logs.list_recent_global(200, …)` (persisted `agent_logs` rows).

Standard ADWs persist their step events (worker sessions via `agent_db_id`, orchestrator/Python-ADW
sessions via `orchestrator_db_id` → `Logs.persist_orchestrator_event/2`), so their squares survive a
reconnect and appear on a late connect.

Custom in-app ADWs do **not** persist. `WorkflowEngine.Runner.start_step_session/5`
(`runner.ex:113-126`) starts each step `Session` with `agent_id: "wf-<run_id>-<step>"`
(`WorkflowEngine.step_agent_id/2`, `workflow_engine.ex:121`) but passes **neither `agent_db_id` nor
`orchestrator_db_id`**. In `session/server.ex`, `persist_target/1` (`:875-897`) returns `nil` unless one
of those UUIDs is present, and `Logs.Writer` (`writer.ex`, `persist: nil` branch) then **broadcasts the
event live but never writes an `agent_logs` row**. Empirically verified against the running dev DB:
`workflow_runs` row `5e4b1acb` (custom "Dashboard Builder", step `build`, cost `$1.20`) is live, yet
`agent_logs` has **zero** rows for it (newest global row is 8h older, from an unrelated `pi` run).

Consequences:
- **Late connect / reconnect (the reported symptom):** the card renders from `workflow_runs`, but
  `backfill_events` finds no persisted rows for the run → **no squares, no friendly drilldown**.
- **Even when connected live**, per-step grouping is fragile: `record_event/4` sets a row's `:step`
  from `payload["adw_step"]` (`event_step/1`, `console_live.ex:4302`), which in-app Claude/pi session
  events do **not** carry, so live squares default to the `"_workflow"` bucket and do not group under
  the named `plan`/`build`/`test` step boxes (`step_box` reads `Map.get(@step_squares, step.name, [])`,
  `dashboard_components.ex:104`).

(Out of scope: the separate **Workstreams Kanban board** (`workstreams_swimlane`,
`console_components.ex:1128`) is fed by `Orchestrator.Workstreams.list_records/1` and is a different
observability surface. This feature is about the ADW **card** step squares + friendly detail, which is
what "small cards you click for a human-friendly message" refers to.)

## Solution Statement
Add a **third durable persistence scope keyed by `workflow_run_id`** to the existing agent/orchestrator
two-scope design, so in-app workflow-step sessions persist their canonical events exactly like workers
and orchestrators do — and make the console group those events under the correct step box for both the
live and backfill paths.

1. **Persist workflow-step events.** Add a nullable `workflow_run_id` column (FK → `workflow_runs`,
   `on_delete: :delete_all`) to `agent_logs`; add `Logs.persist_workflow_event/2` mirroring
   `persist_orchestrator_event/2`; add a `Session.Server` `workflow_run_db_id` field + a
   `persist_target/1` clause that routes to `{:workflow, …}`; add the matching `Logs.Writer` branch.
   Thread `workflow_run_id` (already passed to `start_step_session`) into the session opts so the field
   is set. Persist with `session_id = state.agent_id` (`"wf-<run_id>-<step>"`) so the reconnect
   `agent_key` (computed by `log_to_row/4`) matches `workflow_step_squares`' `"wf-<run_id>"` prefix
   exactly as the live path does.
2. **Group squares under the right step for both paths.** Derive a row's step from the
   `"wf-<run_id>-<step>"` agent key when present (a run-scoped suffix parse), so both live-broadcast
   rows and backfilled rows land under the named `plan`/`build`/`test` boxes — independent of whether
   the event payload carries `adw_step`.
3. **Friendly message reuse.** No new mapping needed: persisted rows already carry the (redacted)
   payload, and `EventPresenter.from_payload/2` (`event_presenter.ex:119`) reconstructs the same
   friendly `body`/summary the live path builds via `from_event/1`, which `event_detail_panel`
   (`dashboard_components.ex:185-197`) renders. This is the standard-ADW drilldown, now available for
   custom ADWs.

This keeps the durable/live split (BUILD_PROMPT.md §7) intact — live streaming still flows through
GenServers/PubSub; the new persistence only adds the durable row that backfill needs — and it reuses
the entire existing UI (cards, squares, detail panel), so no new rendering concepts are introduced.

## Relevant Files
Use these files to implement the feature:

- `lib/repo_builder/workflow_engine/runner.ex` — `start_step_session/5` (`:109-135`) starts each step's
  `Session` with the `"wf-<run_id>-<step>"` `agent_id` but no durable scope. Thread
  `workflow_run_id: run.id` into a new `workflow_run_db_id` session opt (it already passes
  `workflow_run_id: run.id` at `:118`; wire it to the persist scope).
- `lib/repo_builder/workflow_engine.ex` — `step_agent_id/2` (`:121`) defines the `"wf-<run_id>-<step>"`
  key format the squares depend on; `record_step_state/3` (`:130`) is the existing progress-broadcast
  seam (unchanged, referenced for context).
- `lib/repo_builder/session/server.ex` — add `field :workflow_run_db_id, Ecto.UUID.t(), enforce: false`
  to the `State` typedstruct (near `orchestrator_db_id`, `:120`); read it in `init/1` (`:181-205`); add
  a `persist_target/1` clause (`:857-897`) for `workflow_run_db_id`. `record_for/2` (`:849`) and
  `dispatch/2` (`:768-796`) already route through `persist_target/1` — no other change there. The
  app-enforced "exactly one of agent/orchestrator" invariant becomes "exactly one of
  agent/orchestrator/workflow-run".
- `lib/repo_builder/logs.ex` — add `persist_workflow_event/2` (`@spec` returning
  `{:ok, AgentLog.t()} | {:error, Ecto.Changeset.t()}`) mirroring `persist_orchestrator_event/2`
  (`:74-99`): sets `workflow_run_id`, `session_id`, redacts `raw`, maps the event, no `agent_id`/
  `orchestrator_id`. `list_recent_global/2` (`:174`) already returns these rows for backfill — no query
  change needed.
- `lib/repo_builder/logs/writer.ex` — add the `route_key/1` (`:244-246`) and persist branch for
  `persist: {:workflow, ctx}` mirroring the `{:orchestrator, ctx}` branch (`:170-181`); the
  `Dashboard.broadcast_event(rec.agent_id, …)` live path (`:110`) is unchanged (already keyed by
  `rec.agent_id = "wf-<run_id>-<step>"`).
- `lib/repo_builder/logs/agent_log.ex` — add `field :workflow_run_id, Ecto.UUID.t()` + a precise
  `@type t` entry + `cast` it in the changeset (a programmatically-set FK: set on struct build, not
  operator input — follow the `orchestrator_id` precedent in this schema).
- `lib/repo_builder_web/live/console_live.ex` — `workflow_step_squares/3` (`:4315-4327`): derive the
  step key from the `"wf-<run_id>-<step>"` `agent_key` suffix (fall back to `row.step` for non-`wf-`
  keys, e.g. orchestrator/Python-ADW rows) so squares group under the named step boxes on both paths.
  `log_to_row/4` (`:4372`) computes the backfill `agent_key` — confirm it yields
  `"wf-<run_id>-<step>"` for these rows (it uses `log.agent_id || log.session_id`; with `agent_id: nil`
  and `session_id: "wf-<run_id>-<step>"` it already does).
- `lib/repo_builder/console/event_presenter.ex` — `from_payload/2` (`:119`) reconstructs the friendly
  render from a persisted row; reused as-is (referenced to confirm the drilldown body survives backfill).
- `lib/repo_builder_web/components/dashboard_components.ex` — `adw_card/1` (`:77`), `step_box/1`
  (`:126`), `event_square/1` (`:164`, `phx-click="open_event"`), `event_detail_panel/1` (`:185`).
  Reused as-is; referenced to confirm the click → friendly-message path.
- `priv/repo/migrations/` — new migration adding `agent_logs.workflow_run_id` + index (see New Files).
- `test/support/` — `ConnCase`/`DataCase`, Mox setup, and the registry-seam FakeHarness for driving a
  workflow run without a real CLI.

### New Files
- `priv/repo/migrations/<timestamp>_add_workflow_run_id_to_agent_logs.exs` — `alter table(:agent_logs)`
  adding `add :workflow_run_id, references(:workflow_runs, type: :binary_id, on_delete: :delete_all)`
  and `create index(:agent_logs, [:workflow_run_id])`. Generate via
  `mix ecto.gen.migration add_workflow_run_id_to_agent_logs`.
- `test/repo_builder_web/live/test_custom_adw_observability_test.exs` — `Phoenix.LiveViewTest`
  integration test: launch a custom ADW through the Builder against the FakeHarness, assert the run's
  step-event `agent_logs` rows persist, then **remount the LiveView** (simulating a reconnect/late
  connect) and assert the ADW card shows clickable event squares under the correct step and that
  `open_event` opens `event_detail_panel` with the human-friendly body.
- `test/repo_builder/logs/test_persist_workflow_event_test.exs` — unit test for
  `Logs.persist_workflow_event/2` (persists with `workflow_run_id` set, `agent_id`/`orchestrator_id`
  nil, redacts secrets in `raw`, round-trips `list_recent_global/2`).

## Implementation Plan
### Phase 1: Foundation
Add the durable `workflow_run_id` persistence scope end-to-end: migration → `AgentLog` schema/changeset
→ `Logs.persist_workflow_event/2` → `Logs.Writer` branch. Prove it persists in isolation with the unit
test before wiring the runtime.

### Phase 2: Core Implementation
Thread the scope through the runtime: `Session.Server.State` gains `workflow_run_db_id`, `init/1` reads
it, `persist_target/1` routes to `{:workflow, …}`; `WorkflowEngine.Runner.start_step_session/5` passes
`workflow_run_db_id: run.id` (persisting with `session_id = "wf-<run_id>-<step>"`). At this point a
custom ADW's step events persist and survive a reconnect.

### Phase 3: Integration
Make the console group the (now durable) squares under the correct step box for both the live and
backfill paths by deriving the step from the `"wf-<run_id>-<step>"` agent key in
`workflow_step_squares/3`, then prove the full loop with the LiveView reconnect test and the green gate.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Add the migration for `agent_logs.workflow_run_id`
- `mix ecto.gen.migration add_workflow_run_id_to_agent_logs`.
- Body: `alter table(:agent_logs) do add :workflow_run_id, references(:workflow_runs, type: :binary_id,
  on_delete: :delete_all) end` then `create index(:agent_logs, [:workflow_run_id])`.
- `mix ecto.migrate`. Verify with Tidewave `execute_sql_query` (`\d agent_logs` equivalent:
  `SELECT column_name FROM information_schema.columns WHERE table_name='agent_logs'`).

### 2. Extend the `AgentLog` schema + changeset
- In `lib/repo_builder/logs/agent_log.ex`, add `field :workflow_run_id, Ecto.UUID.t()` (nullable) with
  a precise entry in the hand-written `@type t`.
- Add `:workflow_run_id` to the changeset `cast/3` list (set programmatically at persist time, mirroring
  how `orchestrator_id` is handled). Keep the existing `@spec` on the changeset function.

### 3. Add `Logs.persist_workflow_event/2`
- In `lib/repo_builder/logs.ex`, add a public `@spec`'d function mirroring `persist_orchestrator_event/2`
  (`:74-99`):
  ```elixir
  @spec persist_workflow_event(Event.t(), %{
          required(:workflow_run_id) => Ecto.UUID.t(),
          required(:session_id) => String.t(),
          optional(:harness) => String.t(),
          optional(:project_id) => Ecto.UUID.t() | nil
        }) :: {:ok, AgentLog.t()} | {:error, Ecto.Changeset.t()}
  ```
  It redacts `event.raw` (secrets never hit the DB — reuse the same redaction path
  `persist_orchestrator_event/2` uses), maps the canonical event to `agent_logs` attrs with
  `workflow_run_id` set and `agent_id`/`orchestrator_id` nil, and inserts through the context.
- Write `test/repo_builder/logs/test_persist_workflow_event_test.exs` now (Phase-1 proof): persist a
  `SessionStarted`/`ToolCall`/`Done` sequence for a real `workflow_runs` row; assert the rows carry
  `workflow_run_id`, nil `agent_id`/`orchestrator_id`, that a secret in `raw` is scrubbed in the
  persisted `payload`, and that `list_recent_global/2` returns them.

### 4. Add the `Logs.Writer` persist branch
- In `lib/repo_builder/logs/writer.ex`, add a `route_key/1` clause for `%Record{persist: {:workflow, %{…}}}`
  (route on the `workflow_run_id` so ordering/`log_no` is FIFO per run) and a persist branch calling
  `Logs.persist_workflow_event/2` mirroring the `{:orchestrator, ctx}` branch (`:170-181`), including
  the `Logger.warning` on `{:error, _}`. Leave `Dashboard.broadcast_event/3` (`:110`) unchanged.

### 5. Add the `workflow_run_db_id` scope to `Session.Server`
- In `lib/repo_builder/session/server.ex`, add `field :workflow_run_db_id, Ecto.UUID.t(), enforce: false`
  to the `State` typedstruct (adjacent to `orchestrator_db_id`, `:120`), with a doc comment stating the
  "exactly one of agent/orchestrator/workflow-run durable target" invariant.
- Read it in `init/1` (`:181-205`): `workflow_run_db_id: opts[:workflow_run_db_id]`.
- Add a `persist_target/1` clause (before the catch-all at `:897`):
  ```elixir
  defp persist_target(%State{workflow_run_db_id: id} = state) when is_binary(id) do
    {:workflow, %{workflow_run_id: id, session_id: state.agent_id, harness: to_string(state.harness),
                  project_id: state.project_id}}
  end
  ```
  Note `session_id: state.agent_id` — persisting under the `"wf-<run_id>-<step>"` key so backfill's
  `agent_key` matches `workflow_step_squares`' prefix. `record_for/2` and `dispatch/2` already route
  through `persist_target/1`; no change there.

### 6. Thread the scope from the Runner
- In `lib/repo_builder/workflow_engine/runner.ex` `start_step_session/5` (`:113-126`), add
  `workflow_run_db_id: run.id` to the `Session.Supervisor.start_session/1` opts (alongside the existing
  `workflow_run_id: run.id`). No other Runner change; the per-step `agent_id` is already
  `"wf-<run_id>-<step>"`.
- Confirm the same seam is used by the durable twin `Workers.StepWorker` if it starts sessions the same
  way (parity note in the plan; only add the opt where a `Session` is actually started).

### 7. Group squares under the named step in `workflow_step_squares/3`
- In `lib/repo_builder_web/live/console_live.ex` `workflow_step_squares/3` (`:4318`), when a filtered
  row's `agent_key` matches `"wf-#{run_id}-" <> step`, group by that parsed `step`; otherwise fall back
  to `row.step` (preserves orchestrator/Python-ADW rows that key by `payload["adw_step"]`). Add a small
  `@spec`'d private helper `step_key(agent_key, run_id, fallback_step)` for the parse.
- Confirm `log_to_row/4` (`:4372`) yields `agent_key == "wf-<run_id>-<step>"` for the new rows
  (`agent_id: nil`, `session_id: "wf-<run_id>-<step>"` ⇒ `agent_id || session_id` = the wf key). No
  change expected; add a comment documenting the dependency.

### 8. Write the LiveView reconnect/late-connect integration test
- Create `test/repo_builder_web/live/test_custom_adw_observability_test.exs` using
  `use RepoBuilderWeb.ConnCase, async: false` and the FakeHarness registry seam (override the
  `:harnesses` map so `Registry.fetch/1` returns `RepoBuilder.Harness.Fake` for the step harness — the
  §13 injection pattern; use `Mox.allow/3` for the spawned session process).
- Drive a **custom** run end-to-end: either through the Builder handlers
  (`render_click("run_adw_builder")` after seeding `adw_steps`/`adw_spec`) or directly via
  `WorkflowEngine.start_workflow(%Workflow{type: "custom", steps: […]}, …)`; wait for the FakeHarness
  canned sequence to complete (`Process.monitor` on the session/`assert_receive`, never `Process.sleep`).
- Assert **persistence**: `Logs.list_recent_global/2` (or a scoped query) returns rows with
  `workflow_run_id == run_id` for the step.
- Assert **late connect**: `{:ok, view, _html} = live(conn, ~p"/")` (a fresh mount ⇒ `backfill_events`
  runs), switch to the ADWS view, and assert `has_element?(view, "#workflow-#{run_id}")`, that the card
  contains at least one `event_square` under the expected step box (assert by the square's DOM id /
  `phx-value-id`), and that `render_click(view, "[phx-click=open_event][phx-value-id=…]")` opens
  `#event-detail` (or the panel's id) showing the friendly `body` text produced by
  `EventPresenter.from_payload/2`.
- Optionally capture a Playwright screenshot of `http://localhost:4000` (ADWS view) as visual proof.

### 9. Run the full Validation Commands
- Execute every command in the Validation Commands section; fix any warning/lint/dialyzer/test failure
  until all are green with zero regressions.

## Testing Strategy
### Unit Tests
- `Logs.persist_workflow_event/2`: persists with `workflow_run_id` set and `agent_id`/`orchestrator_id`
  nil; redacts secrets in `raw`; round-trips through `list_recent_global/2`; returns `{:error, changeset}`
  (not a raw Postgrex error) when the `workflow_run_id` FK is violated (proves the migration's FK/index).
- `Session.Server.persist_target/1`: a state with only `workflow_run_db_id` set routes to
  `{:workflow, …}` with `session_id == agent_id`; a state with none stays ephemeral (`nil`); an
  agent/orchestrator state is unchanged (regression guard for the existing two scopes).
- `workflow_step_squares/3`: `wf-<run_id>-<step>` rows group under the parsed step; a non-`wf-` row falls
  back to `row.step`; category filtering still applies.

### Edge Cases
- **Late connect / reconnect** (the primary case): mount after the run's events have flowed; squares +
  drilldown appear from backfill.
- **Live-only, no reconnect**: squares still group under named steps (step derived from agent key, not
  the absent `payload["adw_step"]`).
- **Multi-step run**: `plan`/`build`/`test` events group under their own boxes, not a single `_workflow`
  bucket.
- **Secret redaction**: an API key in a step event's `raw` never appears in the persisted `payload`
  (parity with worker/orchestrator persistence, BUILD_PROMPT.md §4.1).
- **Cascade delete**: deleting a `workflow_runs` row removes its `agent_logs` rows (FK
  `on_delete: :delete_all`); no orphaned rows.
- **Backward compatibility**: existing worker (`agent_db_id`) and orchestrator (`orchestrator_db_id`)
  persistence paths and their squares are unchanged; standard-ADW cards still render identically.
- **CLEAR / show-hidden**: new rows honor the `hidden` soft-hide filter used by `list_recent_global/2`.

## Acceptance Criteria
- A custom ADW launched from the Builder persists one `agent_logs` row per canonical step event, keyed by
  `workflow_run_id`, with `agent_id`/`orchestrator_id` nil and secrets redacted.
- Opening (or reloading) the console **while a custom ADW is mid-run** shows the ADW card **with
  clickable event squares grouped under the correct step box** — verified by the reconnect LiveView test,
  not only by a continuously-connected live session.
- Clicking a square opens the `event_detail_panel` showing the same human-friendly summary standard ADWs
  show (from `EventPresenter`).
- Standard/orchestrator/worker ADW observability is unchanged (no regression in existing squares, cards,
  cost rollups, or the Workstreams Kanban board).
- All Validation Commands pass with zero regressions.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix ecto.migrate` - Applies the new `agent_logs.workflow_run_id` migration cleanly.
- `mix test test/repo_builder/logs/test_persist_workflow_event_test.exs --warnings-as-errors` - The new persistence unit test passes.
- `mix test test/repo_builder_web/live/test_custom_adw_observability_test.exs --warnings-as-errors` - The reconnect/late-connect integration test passes.
- `mix compile --warnings-as-errors` - Compile clean; gradual set-theoretic checker + warnings-as-errors pass.
- `mix test --warnings-as-errors` - Full ExUnit suite, zero failures.
- `mix format --check-formatted` - Formatting.
- `mix credo --strict` - Lint incl. the "every public function has an `@spec`" convention.
- `mix dialyzer` - `@spec`/contract checking, no new warnings and no stale ignore filters.

## Notes
- **Verified root cause (dev DB + code).** `workflow_runs` row `5e4b1acb` (custom "Dashboard Builder",
  step `build`, `$1.20`, live) has **zero** `agent_logs` rows; `persist_target/1` returns `nil` for
  workflow-step sessions because `start_step_session/5` passes no `agent_db_id`/`orchestrator_db_id`.
  That is why the card renders (from `workflow_runs`) but the squares/drilldown are missing on
  reconnect. This plan closes exactly that gap by adding a `workflow_run_id` scope.
- **Durable/live split preserved (BUILD_PROMPT.md §7).** Live streaming is unchanged (PubSub →
  `console:events` → `event_buffer`); the new persistence only adds the durable row that
  `backfill_events` needs so observability survives a reconnect. No hot-path streaming is routed through
  the DB.
- **Third scope is idiomatic here.** `agent_logs` already carries parallel nullable scopes
  (`agent_id`, `orchestrator_id`, `project_id`); a `workflow_run_id` scope follows the same pattern and
  keeps the "exactly one durable target" invariant (now agent | orchestrator | workflow-run).
- **No new deps.** Pure schema + context + runtime + LiveView change.
- **Alternative considered and rejected:** synthesizing a real `agents` row per workflow step (so
  `agent_db_id` is set) would persist events but pollute the agent roster with per-step pseudo-agents and
  entangle agent-status semantics; the `workflow_run_id` scope is cleaner and matches the source-of-truth
  model.
- **Follow-up (out of scope):** the Workstreams Kanban board (`workstreams_swimlane`) is a distinct
  surface fed by `Orchestrator.Workstreams`; if operators also want custom Builder ADWs to appear there,
  that is a separate feature (have `launch_adw_builder/4` create/advance a `Workstreams` record).
- **Validation via Tidewave** (`http://localhost:4000/tidewave/mcp`): use `execute_sql_query` to confirm
  `agent_logs.workflow_run_id` populates for a live custom run, `project_eval` to run
  `Logs.list_recent_global/2` and inspect the rows, and `get_logs` for any persist stacktrace.
