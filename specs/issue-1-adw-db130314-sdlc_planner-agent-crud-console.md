# Feature: Full agent CRUD + functional console UI

## Metadata
issue_number: `1`
adw_id: `db130314`
issue_json: `{"number":1,"title":"Full agent CRUD + functional console UI to match reference orchestrator (tac-14)"}`

## Feature Description
Evolve `RepoBuilderWeb.ConsoleLive` (mounted at `/`) from a **create-only** console
into a **fully functional orchestrator UI with complete agent CRUD**, matching the
interaction model of the reference app at
`tac-14/orchestrator-agent-with-adws/apps/orchestrator_3_stream`. Today an operator can
*create* agents and *launch* sessions/ADWs from the browser, but cannot *edit* or
*archive* them, the create form omits `model`/`system_prompt`, and the left agent rail
is far thinner than the reference's agent cards.

This feature adds:

1. **Update** — per-agent inline edit (name / harness / provider / model / system_prompt)
   wired to the existing `RepoBuilder.Agents.update_agent/2`.
2. **Delete/Archive** — per-rail-item soft-archive (reference parity: an `archived`
   flag) with a confirm affordance, removing the agent from the rail live.
3. **Create** — add `model` (optional) + `system_prompt` (optional) fields, persisted on
   the `Agent`.
4. **Rail enrichment** — `agent_rail_item/1` gains a status badge, per-agent cost, and a
   model badge (live-updating).
5. **Fixes** — human-format the Cost pill (`$0.873`, not raw `Decimal`), and set a
   console-appropriate page `<title>`.

The console stays harness-blind and **never touches `Repo` directly** — every read/write
flows through the `@spec`'d `RepoBuilder.Agents` context (BUILD_PROMPT.md §8).

## User Story
As an **orchestration operator**
I want to **create, edit, and archive agents — and see each agent's status, model, and
cost — entirely from the console at `/`**
So that I can **manage my fleet of agents without leaving the live observability view or
dropping to a database/console.**

## Problem Statement
The console is create-only. There is no way to correct a misconfigured agent (wrong
harness/provider/model), no way to remove an agent that is no longer needed, and the
create form cannot capture the `model`/`system_prompt` the reference orchestrator treats
as first-class. The rail shows only a status dot + name + harness, so an operator cannot
see per-agent cost or model at a glance. Two polish bugs hurt trust: the Cost pill renders
a raw 18-digit `Decimal` (`$0.87287100000000000`) and the page title is the default
Phoenix scaffold title.

## Solution Statement
- Extend the `agents` schema with three columns (`model`, `system_prompt`, `archived`) via
  one migration, and widen `Agent.changeset/2` to cast/validate them.
- Add a soft-archive path to the `RepoBuilder.Agents` context (`archive_agent/1`) and make
  `list_agents/0` exclude archived agents by default (with an explicit opt-in for callers
  that want them). Keep the existing `update_agent/2`/`delete_agent/1` as-is.
- Wire the missing `handle_event/3` clauses in `ConsoleLive` for edit and archive, plus
  add the `model`/`system_prompt` inputs to the create form. Restructure `agent_rail_item/1`
  so the selectable row is no longer a single `<button>` wrapping everything (nested
  interactive elements are invalid HTML) — instead a row container with a selectable area
  and discrete Edit/Archive controls.
- Track per-agent cost in an `agent_costs` assign (seeded from `Logs.cost_rollup!/1`,
  updated live on `Usage`/`Done` events), and render it + the model badge in the enriched
  rail item.
- Fix `cost_badge/1` to round/format the `Decimal` to 3 decimal places; keep `nil`
  (unpriced) rendering as `—` (never `$0`).
- Prevent launching a session against an archived/deleted agent gracefully in the `run`
  handler by re-fetching through `Agents.fetch_agent/1`.
- Set `page_title` in `mount/3` and adjust the layout's `<.live_title>` suffix.

## Relevant Files
Use these files to implement the feature:

- `lib/repo_builder/agents/agent.ex` — add `model`/`system_prompt`/`archived` fields to the
  schema + `@type t`, and cast/validate them in `changeset/2`. Core data-model change.
- `lib/repo_builder/agents.ex` — the **only** `Repo` caller for `agents`. Add
  `archive_agent/1` (`@spec`'d, soft-archive) and make `list_agents/0` exclude archived
  agents (add `list_agents/1` opts, e.g. `include_archived: true`).
- `lib/repo_builder_web/live/console_live.ex` — wire `handle_event/3` for edit/archive,
  add create-form fields, track per-agent cost, prevent run-against-archived, set
  `page_title`. Already the integration point for all agent actions.
- `lib/repo_builder_web/components/console_components.ex` — enrich `agent_rail_item/1`
  (status badge + per-agent cost + model badge + Edit/Archive controls, restructured to
  avoid nested buttons); add an inline edit-form component (or reuse `.form`).
- `lib/repo_builder_web/components/dashboard_components.ex` — fix `cost_badge/1` to format
  the `Decimal` (round to 3 dp); shared by the header Cost pill and rail items.
- `lib/repo_builder_web/components/layouts/root.html.heex` — adjust the `<.live_title>`
  suffix so a console-appropriate title renders.
- `priv/repo/migrations/20260615230001_create_agents.exs` — reference for the existing
  column set / types when authoring the new migration (do NOT edit a shipped migration).
- `test/repo_builder_web/live/test_orchestration_console_test.exs` — existing console
  integration test; mirror its `create_agent` helper, `Dashboard.subscribe*`, and
  `assert_receive` patterns. (Not to be edited — new tests go in a new file.)
- `test/repo_builder/` — add/extend a context test for `Agents` (archive + list filter).
- `lib/repo_builder/dashboard.ex` — `broadcast_lane/1` and the lane shape; edit/archive
  must keep the swimlane in sync (re-insert or `stream_delete`).
- `lib/repo_builder/logs.ex` — `cost_rollup!/1` (per-agent cost seed) reference.
- `BUILD_PROMPT.md` §3 (typed style), §8 (persistence / float→Decimal), §9 (LiveView
  dashboard) — authoritative constraints.
- `ai_docs/typed-elixir-standard.md` — the **(always)** enforced typed standard (`@spec`
  on every public fn, `@type`, precise types, `{:ok,_}|{:error,_}`).

### New Files
- `priv/repo/migrations/<timestamp>_add_model_system_prompt_archived_to_agents.exs` — adds
  `model :string`, `system_prompt :text`, `archived :boolean, null: false, default: false`
  to `agents`, plus a partial/regular index on `archived` to keep the default
  non-archived list fast.
- `test/repo_builder_web/live/test_agent_crud_test.exs` — `Phoenix.LiveViewTest`
  integration test driving create (with model/system_prompt) → edit → archive, asserting
  the rail updates live and that a run against an archived agent is blocked.
- `test/repo_builder/agents_test.exs` — context unit test for `archive_agent/1`,
  `update_agent/2` with the new fields, and `list_agents/0` archived filtering (only if a
  context test does not already exist; otherwise extend the existing one).

## Implementation Plan
### Phase 1: Foundation (data model + context)
Extend the `Agent` schema and `agents` table with `model`, `system_prompt`, and `archived`.
Widen `Agent.changeset/2` to cast the three new fields (none required; `archived` defaults
`false`). Add `RepoBuilder.Agents.archive_agent/1` (soft-archive via the changeset) and
make `list_agents/0` exclude archived agents by default, with `list_agents/1` accepting
`include_archived: true`. Keep `update_agent/2`/`delete_agent/1` unchanged. This is the
foundational shared change every UI action depends on.

### Phase 2: Core Implementation (LiveView + components)
Add the create-form `model`/`system_prompt` inputs. Add `handle_event/3` clauses:
`edit_agent`/`cancel_edit_agent`/`validate_edit_agent`/`update_agent` (inline edit) and
`archive_agent` (with `data-confirm`). Track per-agent cost in an `agent_costs` assign,
seeded from `Logs.cost_rollup!/1` on mount and updated on `Usage`/`Done` events. Enrich
`agent_rail_item/1` (status badge + per-agent cost via `cost_badge` + model badge +
Edit/Archive controls), restructuring it so there are no nested interactive elements. Fix
`cost_badge/1` formatting. Set `page_title` and adjust the layout suffix.

### Phase 3: Integration (live sync + guard rails)
After create/edit/archive, keep the swimlane stream in sync: re-insert the agent lane on
edit (stable `lane.id` replaces in place), `stream_delete` the lane on archive, and clear
`selected_agent_id` when the selected agent is archived. Guard the `run` handler: re-fetch
the agent through `Agents.fetch_agent/1` and flash a graceful error if it is missing or
archived. Verify end-to-end via the LiveView integration test (and optionally a Tidewave
`project_eval`/`execute_sql_query` smoke check + a Playwright screenshot).

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Read the enforced standards
- Read `ai_docs/typed-elixir-standard.md` (the **(always)** row) and `BUILD_PROMPT.md`
  §8 (persistence, float→Decimal) and §9 (LiveView/streams) before writing code.

### 2. Migration: add columns to `agents`
- Create `priv/repo/migrations/<timestamp>_add_model_system_prompt_archived_to_agents.exs`.
- `alter table(:agents)`: `add :model, :string`; `add :system_prompt, :text`;
  `add :archived, :boolean, null: false, default: false`.
- Add `create index(:agents, [:archived])` (or a partial index `where: "archived = false"`)
  so the default list stays fast.
- Run `mix ecto.migrate` (Postgres provisioned per project memory — run `scripts/pg.sh start`
  first if needed).

### 3. Extend the `Agent` schema + changeset
- In `lib/repo_builder/agents/agent.ex`, add `field :model, :string`,
  `field :system_prompt, :string`, `field :archived, :boolean, default: false` to the
  schema.
- Update `@type t` to include `model: String.t() | nil`, `system_prompt: String.t() | nil`,
  `archived: boolean()`.
- In `changeset/2`, add `:model`, `:system_prompt`, `:archived` to the `cast/3` field list
  (keep `validate_required` unchanged — the three are optional). Optionally
  `validate_length(:system_prompt, max: 20_000)`.
- Add an `@spec`'d `archive_changeset/1` (or reuse `change/2`) if a dedicated soft-archive
  changeset reads cleaner.

### 4. Extend the `Agents` context
- In `lib/repo_builder/agents.ex`, change `list_agents/0` to exclude `archived` agents and
  add `list_agents/1` (`@spec list_agents(keyword()) :: [Agent.t()]`) honoring
  `include_archived: true`. Keep ordering by name.
- Add `@spec archive_agent(Agent.t()) :: {:ok, Agent.t()} | {:error, Ecto.Changeset.t()}`
  and implement it by updating `archived: true` through a changeset (soft-delete; preserves
  `agent_logs`/cost history). Keep `delete_agent/1` for the hard-delete path.
- Do NOT let any caller outside this context touch `Repo`.

### 5. Context unit tests (write before/with the UI)
- Create or extend `test/repo_builder/agents_test.exs`: assert `archive_agent/1` flips
  `archived` and removes the agent from `list_agents/0` but keeps it in
  `list_agents(include_archived: true)`; assert `update_agent/2` persists `model` and
  `system_prompt`; assert `create_agent/1` accepts the new fields.

### 6. Fix the cost formatting (`cost_badge/1`)
- In `lib/repo_builder_web/components/dashboard_components.ex`, round the `Decimal` for
  display: `Decimal.round(@cost, 3)` (or a small `@spec`'d `format_cost/1` helper) so the
  pill shows e.g. `$0.873`. Keep `nil` → `—`. Add a Decimal-rounding `@spec` helper if it
  improves clarity.

### 7. Enrich `agent_rail_item/1` (no nested interactive elements)
- In `lib/repo_builder_web/components/console_components.ex`, add attrs:
  `cost` (`:any`, default `nil`) and `model` (`:string`, default `nil`).
- Restructure the item: a `div` row containing (a) a selectable button (status dot + name +
  harness + model badge), and (b) discrete `Edit` and `Archive` buttons. The selectable
  button keeps `phx-click="select_agent"`. The Archive button uses `phx-click="archive_agent"`,
  `phx-value-id`, and `data-confirm="Archive this agent?"`.
- Add a small status **badge** (text, color-coded via the existing `status_class/1`) and
  render per-agent cost via `cost_badge/1`. Keep the `@statuses` `values:` list authoritative.
- Update the component `@spec`/`attr` docs accordingly.

### 8. Console: create-form fields
- In `lib/repo_builder_web/live/console_live.ex` render, add `model` (text, optional) and
  `system_prompt` (textarea, optional) inputs to `#new-agent-form`. They flow through the
  existing `validate_agent`/`create_agent` events unchanged (the changeset now casts them).

### 9. Console: inline edit
- Add assigns `editing_agent_id` (default `nil`) and `edit_agent_form`.
- `handle_event("edit_agent", %{"id" => id}, socket)` — set `editing_agent_id`, build
  `edit_agent_form` from `Agents.get_agent(id)` via `Agent.changeset/2`.
- `handle_event("validate_edit_agent", %{"agent" => params}, socket)` — revalidate form.
- `handle_event("cancel_edit_agent", _, socket)` — clear `editing_agent_id`.
- `handle_event("update_agent", %{"id" => id, "agent" => params}, socket)` — fetch via
  `Agents.fetch_agent/1`, call `Agents.update_agent/2`; on success reload agents, reseed/
  re-insert the agent lane (`Dashboard.broadcast_lane/1` or local `stream_insert`), clear
  `editing_agent_id`, flash; on `{:error, changeset}` re-render the edit form with errors.
- Render an inline edit form (toggled by `editing_agent_id`) with name/harness/provider/
  model/system_prompt inputs (mirror the create form; carry the `id` via a hidden value or
  `phx-value-id`).

### 10. Console: archive
- `handle_event("archive_agent", %{"id" => id}, socket)` — fetch via `Agents.fetch_agent/1`;
  call `Agents.archive_agent/1`; on success: reload agents, `stream_delete` the
  `agent:<id>` lane, clear `selected_agent_id` if it was the archived one, flash; ignore/flash
  on error. (Confirm is handled client-side by `data-confirm`.)

### 11. Console: per-agent cost tracking + rail wiring
- Add an `agent_costs` assign (`%{agent_id => Decimal.t() | nil}`), seeded in mount from
  `Logs.cost_rollup!/1` per agent (reuse `seed_cost/1`'s rollup).
- In the `Usage`/`Done` `handle_info` clauses, also accumulate the per-agent cost
  (`accumulate_cost/2` into `agent_costs[agent_id]`) alongside the global `cost`.
- Pass `cost={Map.get(@agent_costs, agent.id)}` and `model={agent.model}` into
  `agent_rail_item/1` in render.

### 12. Console: guard run-against-archived + page title
- In `handle_event("run", ...)`, after the `nil` selected-agent check, re-fetch via
  `Agents.fetch_agent/1`; if `{:error, :not_found}` (or `agent.archived`), flash a graceful
  error and start nothing.
- Set `page_title: "Orchestration Console"` in `mount/3` assigns.
- In `lib/repo_builder_web/components/layouts/root.html.heex`, change the `<.live_title>`
  `suffix` from `" · Phoenix Framework"` to `" · RepoBuilder"` (or drop the suffix) so the
  console title reads sensibly.

### 13. LiveView integration test
- Create `test/repo_builder_web/live/test_agent_crud_test.exs` using `Phoenix.LiveViewTest`
  (`use RepoBuilderWeb.ConnCase, async: false`). Mirror the existing console test's
  `create_agent` helper and `Dashboard.subscribe*` usage. Cover:
  - **Create**: submit `#new-agent-form` with `name/harness/provider/model/system_prompt`;
    assert the rail shows the model badge and the persisted agent has `model`/`system_prompt`.
  - **Edit**: click the agent's Edit control, submit `#edit-agent-form` with a new name +
    model; assert the rail label/model update and `Agents.get_agent/1` reflects the change.
  - **Archive**: click Archive; assert the rail item `#agent-<id>` is gone and
    `Agents.list_agents/0` excludes it (but `include_archived: true` includes it).
  - **Guard**: attempt `run` against the archived/selected agent → flash error, no session.
  - **Cost format**: assert the Cost pill renders a 3-dp `$` value (not a raw long Decimal)
    after a `fake` run, and `—` when unpriced.
- Optionally capture a Playwright screenshot of `http://localhost:4000/` as visual proof.

### 14. Run the full validation suite
- Execute every command in **Validation Commands** and fix any failure until all are green.

## Testing Strategy
### Unit Tests
- `RepoBuilder.Agents`: `archive_agent/1` sets `archived: true`; `list_agents/0` excludes
  archived; `list_agents(include_archived: true)` includes them; `update_agent/2` persists
  `model`/`system_prompt`; `create_agent/1` accepts the new optional fields.
- `Agent.changeset/2`: new fields are optional (omitting them is valid); `system_prompt`
  length bound (if added) rejects oversized input; unknown harness still rejected.
- `cost_badge/1` / `format_cost/1`: a `Decimal` formats to 3 dp; `nil` → `—`; `0.0`/`Decimal(0)`
  renders `$0.000` (priced-at-zero stays distinct from unpriced `—`).

### Edge Cases
- Archiving the **currently selected** agent clears the selection and the launch target.
- Editing an agent's **name to a duplicate** surfaces the `unique_constraint` error in the
  edit form (no crash).
- Running a session against an **archived** (or concurrently deleted) agent flashes an
  error and starts nothing.
- An agent with **no priced logs** shows `—` in both the header pill and its rail cost.
- Editing **harness** to one not in the registry surfaces the `validate_inclusion` error.
- The agent **lane** stays in sync: edit replaces the row in place; archive removes it.
- Reconnect/mount recomputes per-agent cost from `Logs.cost_rollup!/1` (no double-count).

## Acceptance Criteria
- An operator can **create, edit, and archive** an agent entirely from `/`, with the rail
  updating live (no full page reload).
- Edit changes (name/harness/provider/model/system_prompt) persist via `RepoBuilder.Agents`;
  the LiveView never calls `Repo`/`Ecto.Query` directly.
- Archive removes the agent from the rail (soft-delete, `archived = true`); `agent_logs`/
  cost history is preserved; running a session against an archived/deleted agent is
  prevented gracefully (flash, no session started).
- The create form includes **model** + optional **system_prompt**, both persisted on the
  `Agent`.
- The rail item shows a **status badge**, **per-agent cost**, and **model** in addition to
  the existing dot/name/harness.
- The Cost pill is human-formatted (e.g. `$0.873`); unpriced stays `—` (never `$0`).
- The page `<title>` is console-appropriate (not the Phoenix scaffold default).
- New/changed code keeps the green gate: `@spec` on all public funcs, no compiler warnings,
  formatted, Credo strict, Dialyzer clean — plus the LiveView integration test covering
  edit + archive passes.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `scripts/pg.sh start` — ensure the user-space Postgres cluster is up (project memory).
- `mix ecto.migrate` — apply the new `agents` columns migration cleanly.
- `mix test test/repo_builder_web/live/test_agent_crud_test.exs` — the new LiveView CRUD
  integration test passes (create + edit + archive + guard + cost format).
- `mix test test/repo_builder/agents_test.exs` — the `Agents` context unit tests pass.
- `mix compile --warnings-as-errors` — compile clean; gradual set-theoretic checker +
  `warnings_as_errors` pass.
- `mix test --warnings-as-errors` — full ExUnit suite green (Postgres-backed), zero failures.
- `mix format --check-formatted` — code is formatted.
- `mix credo --strict` — lint passes, including the "every public function has an `@spec`"
  rule.
- `mix dialyzer` — `@spec`/contract checking with no new warnings and no stale ignore filters.

Optional runtime verification via **Tidewave** (`http://localhost:4000/tidewave/mcp`):
- `execute_sql_query` — confirm an archived agent has `archived = true` and its `agent_logs`
  rows still exist.
- `project_eval` — `RepoBuilder.Agents.list_agents()` excludes the archived agent;
  `RepoBuilder.Agents.list_agents(include_archived: true)` includes it.
- `get_logs` — inspect any stacktrace if a handler misbehaves during manual exercise.
- Playwright MCP — navigate `http://localhost:4000/`, create/edit/archive an agent, and
  capture a screenshot as visual proof.

## Notes
- **Soft-archive vs hard-delete (decision):** this plan implements **soft-archive** (an
  `archived` boolean) to match the reference orchestrator and preserve `agent_logs`/cost
  history; `agent_logs` has `on_delete: :delete_all`, so a hard `delete_agent/1` would
  discard observability data. `delete_agent/1` is retained for a future explicit hard-delete
  affordance. If the team prefers hard-delete for the UI, swap `archive_agent/1` for
  `delete_agent/1` in step 10 and drop the `archived` column/list-filter from steps 2–4.
- **No new library** is required — `RepoBuilder.Agents` already exposes `update_agent/2`,
  `delete_agent/1`, and `fetch_agent/1`; the only context addition is `archive_agent/1` +
  the `list_agents/0` archived filter.
- **`model`/`system_prompt` placement:** stored as dedicated columns (per the BUILD_PROMPT
  §1 mission, which names `model` a first-class agent attribute) rather than buried in the
  `config` JSONB, so they are easy to validate, edit, and pre-fill into the launch form.
- **Launch form pre-fill (nice-to-have, in scope):** when an agent with a `model` is
  selected, pre-fill the launch `model` from `agent.model` (operator can still override at
  launch). Implement in the existing `select_agent` handler.
- **Out of scope (follow-ups per the issue):** Cmd+K palette, per-agent color theming,
  token/context bar + log counters, pulse animations, and git-worktree/working-dir
  provisioning. Track separately once core CRUD lands.
- **HTML validity:** the current `agent_rail_item/1` is a single `<button>` wrapping the
  whole row; adding Edit/Archive buttons inside it would nest interactive elements. Step 7
  restructures the item to a row container with sibling controls — verify no nested-button
  warnings in the LiveView render.
