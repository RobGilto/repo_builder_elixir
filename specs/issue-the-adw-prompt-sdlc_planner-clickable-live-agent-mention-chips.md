# Feature: Clickable live-agent mention chips in the prompt palette

## Metadata
issue_number: `the`
adw_id: `prompt`
issue_json: `UI`

## Feature Description
Add a new row to the ⌘K command-input prompt palette that lists the orchestrator's
**live agents** (the workers shown in the left rail) as clickable chips. Clicking a
chip inserts that agent's **exact name** into the prompt textarea at the caret — the
same client-side `rb:insert-token` mechanism the existing SLASH / AGENTS / ADWS
palette rows already use, with **no server round-trip**.

Today, to ask the orchestrator to act on a running/idle worker (e.g. "please delete
the agent career-scout"), the operator must hand-type the worker's name. The
orchestrator resolves a worker by **exact name** scoped to the orchestrator
(`Agents.get_by_name_for_orchestrator/2` → `Repo.get_by(... name: name)`), so a
single typo — "code-scout" vs. "career-scout" — yields `{:error, :not_found}` and the
LLM reports it "could not detect the agent". A click-to-insert chip removes the
typo class entirely: the operator clicks the agent they can see in the rail, the
canonical name lands in the prompt, and the orchestrator's name lookup succeeds.

The chips show each live agent's status (idle / running) so the operator can
distinguish the active objects at a glance — exactly the "point to active (idle or
in-progress) objects" affordance requested.

## User Story
As an operator driving the orchestrator from the console prompt
I want to click a chip for a live agent and have its exact name auto-fill the prompt
So that I can reliably reference that worker (to delete, command, or inspect it)
without hand-typing — and the orchestrator resolves it the first time.

## Problem Statement
The orchestrator's worker-management tools (`delete_agent`, `command_agent`,
`check_agent_status`, `interrupt_agent`, `update_agent`, `compact_agent`) all resolve
their target via `Agents.get_by_name_for_orchestrator/2`, an **exact, case-sensitive**
name match. The operator can see the worker in the left rail (e.g. an idle
`career-scout`) but must transcribe its name into free-text prose for the LLM to put
into the tool call. Any mismatch fails the lookup, and the failure surfaces as the
orchestrator "not being able to find" an agent that plainly exists in the UI. There
is no affordance to reference a visible agent by clicking it.

## Solution Statement
Reuse the existing file-driven prompt-palette infrastructure. The palette already
renders collapsible rows of chips (`palette_row/1`), and each chip dispatches a
client-side `rb:insert-token` event that the `CommandPaste` JS hook on
`#command-textarea` turns into a caret-aware, space-padded insert. We add **one more
row** — "LIVE AGENTS" — whose chips are built from the LiveView's already-present
`@agents` + `@statuses` assigns (no new query, no DB change), filtered to the
**active** statuses (`:idle`, `:running`) and ordered idle-first then by name. Each
chip's inserted token is the worker's **exact `name`** — precisely the string
`get_by_name_for_orchestrator/2` matches — and the chip surfaces a small status dot
so idle vs. in-progress agents are visually distinct.

The change is purely additive and client-side at the point of action: thread two
existing assigns into `global_command_input/1`, add a typed chip-builder, add a
small optional status indicator to `palette_row/1` (backward-compatible — existing
chips simply omit the new key), and render the new row. No schema, migration,
context, or harness change.

## Relevant Files
Use these files to implement the feature:

- `lib/repo_builder_web/components/console_components.ex` — Owns the prompt palette:
  - `global_command_input/1` (~L1987) renders the ⌘K modal and the three palette
    rows (~L2105-2122). The new "LIVE AGENTS" row is added here, and two new attrs
    (`agents`, `statuses`) are declared on the component (~L1975).
  - `palette_row/1` (~L2266) renders one collapsible chip row; each chip's
    `phx-click` dispatches `rb:insert-token` to `#command-textarea` (~L2284). Extend
    its chip template to render an optional status dot when `chip[:status]` is set.
  - `palette_chips/2` (~L2312) normalizes file-derived definitions into chip maps.
    Add a sibling typed builder `live_agent_chips/2` for runtime `Agent` structs
    (token = exact name, label = name, status = the live status, source = `:live`).
  - `status_cat_class/1` (~L2380) — existing status→CSS-class map; reuse it (or a
    small dot-color helper) for the chip's status dot so colors match the rail.
- `lib/repo_builder_web/live/console_live.ex` — The console LiveView:
  - It already assigns `@agents` (`Agents.list_agents/0`, ~L357) and `@statuses`
    (~L362), maintained live via `:agent_created`/`:agent_deleted`/status handlers
    (~L1658, ~L1714, `set_status/3` ~L2020). Pass both into `global_command_input`
    at the call site (~L2300-2310). No new state needed.
- `assets/js/app.js` — The `CommandPaste` hook (~L65) already handles
  `rb:insert-token` (caret-aware, space-padded insert + refocus). **No change** —
  read-only reference confirming the new chips need no new JS.
- `lib/repo_builder/orchestrator/tools.ex` — `delete_agent/2` (~L? ) and the other
  worker tools resolve by `Agents.get_by_name_for_orchestrator/2`. Read-only
  reference: confirms the inserted token must be the **exact** `name`. No change.
- `lib/repo_builder/agents.ex` — `get_by_name_for_orchestrator/2` (~L80, exact
  `Repo.get_by(name:)`), `list_agents/0` (~L16). Read-only reference for the
  exact-match contract. No change.
- `BUILD_PROMPT.md` — §9 (LiveView dashboard conventions), §3 (typed style guide).
  Authoritative for the component/typed-spec style.
- `AGENTS.md` — Phoenix v1.8 + LiveView component/`attr` conventions.
- `ai_docs/typed-elixir-standard.md` — the enforced typed standard (always-on row of
  `conditional_docs.md`): `@spec` on every public function, precise types over
  `map()`/`any()`.

### New Files
- `test/repo_builder_web/live/test_live_agent_mention_chips_test.exs` — a
  `Phoenix.LiveViewTest` integration test: seed an idle agent (and a non-active one
  to prove filtering), `live/2` the console, open the command modal, and assert the
  LIVE AGENTS row renders a chip whose `phx-click` encodes an `rb:insert-token`
  dispatch carrying the agent's exact name; assert the active/idle agent appears and
  the inactive one is excluded; assert the empty-state hint when no live agents.

## Implementation Plan
### Phase 1: Foundation
Confirm the runtime contract and the reuse seams. Establish that `@agents` +
`@statuses` are already live-maintained in `ConsoleLive` (created/deleted/status
PubSub handlers) so the new row stays in sync with the rail without extra wiring, and
that the inserted token must equal the worker's exact `name` (the orchestrator's
resolver). Decide the active-status set (`:idle`, `:running`) and ordering
(idle-first, then alphabetical).

### Phase 2: Core Implementation
Add the typed `live_agent_chips/2` builder, the backward-compatible optional status
dot in `palette_row/1`, and the two new `attr`s on `global_command_input/1`. Render
the new "LIVE AGENTS" palette row with an actionable empty hint.

### Phase 3: Integration
Pass `@agents` and `@statuses` from `ConsoleLive`'s render into
`global_command_input`. Verify end-to-end in the running app (Tidewave/Playwright):
the chip appears for a visible idle worker, clicking it fills the prompt with the
exact name, and the orchestrator's `delete_agent`/`command_agent` resolves it.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Read the contract docs
- Read `ai_docs/typed-elixir-standard.md` (always-on), `BUILD_PROMPT.md` §9, and
  `AGENTS.md` (LiveView/component conventions). Skim `assets/js/app.js`
  `CommandPaste` to confirm `rb:insert-token` needs no JS change.
- Use Tidewave `get_source_location` on `global_command_input/1`, `palette_row/1`,
  `palette_chips/2`, and `Agents.get_by_name_for_orchestrator/2` to anchor edits.

### 2. Add the typed `live_agent_chips/2` builder
- In `console_components.ex`, add `@spec live_agent_chips([Agent.t()], %{Ecto.UUID.t() => atom()}) :: [chip]`
  where `chip` is the existing chip shape extended with an optional `:status` —
  define/extend a module `@type chip :: %{token: String.t(), label: String.t(),
  source: atom(), description: String.t() | nil, status: atom() | nil}` (or a
  `@typep`) and use it for both `palette_chips/2` and `live_agent_chips/2`.
  - Resolve each agent's effective status as `Map.get(statuses, agent.id, agent.status)`
    (mirrors the rail's `agent_card` status resolution).
  - Keep only **active** statuses (`status in [:idle, :running]`).
  - Sort idle-first, then by `name` (so idle "available to command" agents lead).
  - `token: agent.name` (exact — matches the orchestrator resolver), `label: agent.name`,
    `source: :live`, `status: <resolved status>`, `description:` a short hint like
    `"#{status} · click to reference #{agent.name} in the prompt"`.
- Add `alias RepoBuilder.Agents.Agent` (or the correct struct module) if not already
  aliased in the component module; keep types precise (no `map()`).

### 3. Render the optional status dot in `palette_row/1` (backward-compatible)
- In the chip `:for` of `palette_row/1`, render a small status dot **only when**
  `chip[:status]` is set (`:if={chip[:status]}`), colored via a small `@spec`'d
  helper (reuse `status_cat_class/1` or add `agent_dot_class/1`). Existing chips
  (slash/agents/adws) omit `:status` → `chip[:status]` is `nil` → no dot, no
  behavior change. Verify the existing three rows still render identically.

### 4. Add the LIVE AGENTS row + new attrs to `global_command_input/1`
- Declare new attrs near the other palette attrs (~L1975):
  `attr :agents, :list, default: []` and
  `attr :statuses, :map, default: %{}`.
- After the ADWS `palette_row` (~L2122), add:
  ```heex
  <.palette_row
    id="live"
    label="LIVE AGENTS"
    chips={live_agent_chips(@agents, @statuses)}
    empty_hint="no live agents — create one, then click to reference it"
  />
  ```

### 5. Wire the assigns at the call site
- In `console_live.ex` render (~L2300), pass `agents={@agents}` and
  `statuses={@statuses}` into `<.global_command_input … />`. No new socket state —
  both assigns already exist and are kept live by the create/delete/status handlers.

### 6. LiveView integration test (early validation)
- Create `test/repo_builder_web/live/test_live_agent_mention_chips_test.exs`
  (`RepoBuilderWeb.ConnCase`, `Phoenix.LiveViewTest`, `async: false` so the sandbox
  reaches the connected LiveView, mirroring `test_agent_models_modal_test.exs`).
  - Seed the default orchestrator (read `orchestrator_id` from the mounted view's
    state as the existing modal tests do) and create an idle worker scoped to it via
    `Agents.create_agent/1`; broadcast `:agent_created` / `send` the handler (or
    re-mount) so `@agents`/`@statuses` include it.
  - `live/2` the console; assert the LIVE AGENTS chip for that agent renders and its
    `phx-click` encodes an `rb:insert-token` dispatch carrying the exact `name`
    (assert the rendered HTML contains both the agent name and `rb:insert-token`).
  - Assert filtering: an agent forced to a non-active status (e.g. `:succeeded` via
    `set_status` broadcast) does **not** appear in the LIVE AGENTS row.
  - Assert the empty-state hint renders when there are no active agents.
- Optionally capture a Playwright/Tidewave-Web screenshot of `http://localhost:4000`
  with the modal open and the LIVE AGENTS row expanded as visual proof.

### 7. Manual / runtime verification (Tidewave)
- With the app running, open ⌘K, expand LIVE AGENTS, click an idle worker's chip,
  and confirm its exact name lands in `#command-textarea` at the caret.
- Drive the original failure path: with the chip-filled name, ask the orchestrator to
  "delete the agent <name>"; confirm `delete_agent` resolves it (no
  `{:error, :not_found}`). Use Tidewave `project_eval`
  `RepoBuilder.Agents.get_by_name_for_orchestrator(<orch_id>, "<name>")` to confirm
  the exact-name match the chip guarantees.

### 8. Run the validation suite
- Run every command in `Validation Commands`; fix until all are green with zero
  regressions.

## Testing Strategy
### Unit Tests
- `live_agent_chips/2`: returns chips only for active statuses; token equals the
  exact `name`; idle-first ordering; status carried through; empty list when no
  active agents. (Can be a focused assertion within the LiveView test or a small
  component-function test, since the function is public and `@spec`'d.)
- `palette_row/1` backward-compat: chips without `:status` render no dot (covered by
  the existing palette test, `test_prompt_palette_test.exs`, staying green).

### Edge Cases
- **No agents / no active agents** → empty-state hint, no chips.
- **Status filtering** → `:succeeded`/`:failed`/`:error` agents excluded; only
  `:idle`/`:running` shown.
- **Live sync** → an agent created after mount appears (PubSub `:agent_created`); a
  deleted agent disappears (`:agent_deleted`); a status change re-colors/filters
  (`set_status`).
- **Name with whitespace/special chars** (defensive): the token is still the exact
  stored name so the resolver matches; the JS hook space-pads around the caret. Note
  in `Notes` that bare-name insertion mirrors current operator behavior and the
  exact-match resolver — no quoting is added (quoting would break the match).
- **Existing rows unaffected** → SLASH/AGENTS/ADWS chips render and insert exactly as
  before (no `:status` dot).

## Acceptance Criteria
- A "LIVE AGENTS" row appears in the ⌘K command palette, collapsible like the others,
  showing a count and one chip per **active** (`:idle`/`:running`) worker.
- Each chip shows the agent name and a status dot; clicking it inserts the agent's
  **exact name** into `#command-textarea` at the caret (verified via the existing
  `rb:insert-token` hook) with no server round-trip.
- Non-active agents (succeeded/failed/error) are not listed; the row shows an
  actionable empty hint when there are no active agents.
- The row stays in sync with the left rail live (create/delete/status changes).
- An orchestrator worker-tool call (e.g. `delete_agent`) using a chip-inserted name
  resolves the worker (no spurious `:not_found`).
- The new LiveView test passes; all existing palette/console tests stay green.
- `mix compile --warnings-as-errors`, `mix format --check-formatted`,
  `mix credo --strict`, `mix dialyzer`, and `mix test --warnings-as-errors` are all
  green.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix test test/repo_builder_web/live/test_live_agent_mention_chips_test.exs` — the
  new integration test: LIVE AGENTS chips render, encode the exact-name
  `rb:insert-token` dispatch, filter to active statuses, and show the empty hint.
- `mix test test/repo_builder_web/live/test_prompt_palette_test.exs` — the existing
  palette test stays green (backward-compatible `palette_row/1` change).
- `mix test test/repo_builder_web/live/` — no LiveView regressions.
- `mix compile --warnings-as-errors` — clean compile; set-theoretic checker +
  `warnings_as_errors` pass.
- `mix test --warnings-as-errors` — full ExUnit suite, zero failures.
- `mix format --check-formatted` — formatting.
- `mix credo --strict` — lint, incl. the every-public-function-`@spec` rule.
- `mix dialyzer` — `@spec`/contract checking, no new warnings, no stale ignores.

## Notes
- **No new dependencies, schema, migration, context, or harness change.** The feature
  is a LiveView/component-only addition that reuses the existing `rb:insert-token`
  palette mechanism and the already-live `@agents`/`@statuses` assigns.
- **Why the bare exact name is the right token:** every orchestrator worker tool
  resolves via `Agents.get_by_name_for_orchestrator/2` = `Repo.get_by(name:)` (exact,
  case-sensitive). Inserting the exact name is what makes the LLM's subsequent tool
  call succeed — this is the direct fix for the "can't detect the agent" report. We
  deliberately do **not** wrap the name in quotes/backticks, which would defeat the
  exact match and the operator's natural prose.
- **Scope:** live **agents** only (the requested case). Referencing other live
  objects (workflow runs / ADW lanes) by click is a natural follow-up using the same
  `palette_row` + `rb:insert-token` seam, but is out of scope here.
- **Future consideration:** if agent names with spaces become common, consider a
  distinct, unambiguous reference token (e.g. `agent:<name>`) plus a matching
  orchestrator resolver — but that is a contract change beyond this UI affordance.
- **Verification tooling:** prefer Tidewave `project_eval` /
  `get_source_location` and a Playwright/Tidewave-Web screenshot of
  `http://localhost:4000` (modal open, LIVE AGENTS expanded) over ad-hoc IEx.
```
