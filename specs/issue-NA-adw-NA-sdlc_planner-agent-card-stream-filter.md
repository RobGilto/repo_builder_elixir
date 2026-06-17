# Feature: Agent card click filters the event stream (filter-bar pill with close button)

## Metadata
issue_number: `NA`
adw_id: `NA`
issue_json: `{}` (interactive `/feature` invocation — see Feature Description for the verbatim request)

## Feature Description
Clicking an agent in the left rail currently "selects" it (sets `selected_agent_id`),
which both highlights the card and routes the next prompt to that single agent. The
user wants clicking an agent to instead act as a **stream-filtering mechanism**: the
clicked agent becomes an active filter shown as a removable pill in the center
**filter bar** — right next to the existing category chips (`RESPONSE`, `TOOL`,
`THINKING`, `HOOK`) — with a `×` close button, and the center event stream narrows to
that agent's events. Clicking the card again (or the pill's `×`, or `CLEAR FILTERS`)
removes the filter.

Verbatim request: "when i click an agent I want it to be a filtering mechanism near
the other [chips] (with a close button)".

The good news: most of this already exists. The filter bar already renders
`@active_agents` as name pills with a `×` that fires `toggle_agent_filter`
(`console_components.ex:352-363`), the handler already toggles membership and
re-streams (`console_live.ex:688-694`), and `agent_pass?` already filters rows by
agent (`console_live.ex:1331-1332`). What is missing is the **trigger**: nothing adds
an agent to `active_agents` — the card click goes to `select_agent` instead. This
feature wires the card click into the existing agent-filter path and resolves the
overloaded meaning of "selection".

## User Story
As an operator watching multiple agents stream into one console
I want to click an agent card to filter the event stream to just that agent's activity
So that I can focus on one (or a few) agents without manually managing filters, and remove the focus with a single click on the pill's close button.

## Problem Statement
The center event stream interleaves every agent's events. There is no way to focus it
on a specific agent from the UI: although `active_agents`, the filter pills (with `×`),
`toggle_agent_filter`, and `agent_pass?` all exist, **no UI element ever adds an agent
to `active_agents`**. The only per-agent affordance — clicking the card — is bound to
`select_agent`, which sets `selected_agent_id` for prompt routing, not filtering. So
the agent-filter feature is effectively dead, and the card click conflates "focus this
agent in the log" with "send my next prompt to this agent".

## Solution Statement
Repurpose the agent card / compact-rail click to toggle an **agent filter** via the
existing `toggle_agent_filter` path, keyed by the agent **id** (every event row already
carries `agent_key: agent_id`, so id-based filtering is collision-free vs. the current
name-based match). The clicked agent appears as a filter-bar pill (label resolved from
the `agent_names` id→name map) with a `×` close button, and the stream re-filters via
the existing `restream/1`. The card's highlight reflects "is an active filter" rather
than "is selected".

Because `selected_agent_id` also drives prompt routing (orchestrator vs. a single
agent, `console_live.ex:778`), we unify the two concepts: **the active agent-filter set
is the routing selection**. When exactly one agent filter is active, a manual prompt
routes to that agent; with zero or multiple active filters it routes to the
orchestrator (preserving today's "no selection ⇒ orchestrator" default). This removes
the separate `selected_agent_id` assign and the `select_agent` handler, eliminating the
overload while keeping single-agent runs possible.

## Relevant Files
Use these files to implement the feature:

- `lib/repo_builder_web/components/console_components.ex` — Defines `agent_card/1`
  (line 228, click at 233-237), `agent_rail_compact/1` (line 296, click at 299-303),
  the `filter_bar/1` (line 331) and its agent-name pills + `×` (lines 352-363). The
  card click target, the `selected?` styling source, and the pill rendering/label all
  change here.
- `lib/repo_builder_web/live/console_live.ex` — The LiveView. Holds the
  `active_agents` and `selected_agent_id`/`agent_names` assigns (init lines 66-98),
  `select_agent` (570-571), `toggle_agent_filter` (688-694), `clear_filters`
  (resets `active_agents`, ~717), `agent_pass?` (1330-1332), the rail render
  (1457-1491, `selected?={@selected_agent_id == agent.id}` at 1465 & 1477), the
  `filter_bar` invocation (1499-1505), and `run_prompt` routing (775-? at 778). This is
  where the trigger rewiring, the routing unification, and the pill-label wiring live.
- `BUILD_PROMPT.md` — §3 typed style guide (`@spec` on every public function,
  precise types, `--warnings-as-errors`), §9 LiveView dashboard conventions. The
  changed/added private helpers and component `attr/3`s must conform.
- `.claude/commands/conditional_docs.md` — Read to check whether any conditional
  documentation applies to this UI-only change (expected: none beyond the typed-Elixir
  standard already enforced by the Credo `@spec` gate + Dialyzer).

### New Files
- `test/repo_builder_web/live/test_agent_card_stream_filter_test.exs` — A
  `Phoenix.LiveViewTest` integration test that mounts the console, seeds agents via the
  `agent_created` seam, drives clicking an agent card, and asserts: the filter-bar pill
  appears with a `×`, the center event stream narrows to that agent's rows (using
  `Dashboard.broadcast_event/2` to inject rows for two agents), clicking again / the
  pill `×` / `CLEAR FILTERS` removes the filter, and (routing) a single active filter
  routes a manual run to that agent while zero/multiple route to the orchestrator.

## Implementation Plan
### Phase 1: Foundation
Switch agent filtering from name-based to **id-based** so the card (which has the agent
id) is the natural trigger and there are no name-collision ambiguities:
- Change `agent_pass?/2` to compare `row.agent_key` (the agent id, already on every
  row via `record_event` line 1136 and `log_to_row`) against `active_agents`.
- Decide `active_agents` now holds agent **ids** (list of `String.t()` ids).

### Phase 2: Core Implementation
- Rewire `agent_card/1` and `agent_rail_compact/1` click from `phx-click="select_agent"`
  to `phx-click="toggle_agent_filter"` with `phx-value-id={@id}`.
- Update `toggle_agent_filter` to read `%{"id" => id}` (instead of `"name"`), toggling
  the id in `active_agents` and re-streaming (logic already present).
- Make the filter-bar agent pills resolve their display label from an `agent_names`
  id→name map passed into `filter_bar/1`, and fire `toggle_agent_filter` with
  `phx-value-id={id}` for the `×`.
- Drive the card highlight from filter membership: `selected?={agent.id in @active_agents}`
  in the rail render (replacing `@selected_agent_id == agent.id`).

### Phase 3: Integration
- Unify routing: replace `selected_agent_id` usage in `run_prompt/4` with a derived
  target — `single_active_agent(active_agents)` returns the lone id when exactly one
  filter is active, else `nil` ⇒ orchestrator. Remove the `selected_agent_id` assign,
  the `select_agent` handler, and the now-unused references.
- Confirm `clear_filters` (already resets `active_agents: []`) clears agent pills and
  restreams, and that the `×` on a pill removes exactly that agent.
- Add/adjust the LiveView integration test and run the full validation suite.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Read context and confirm conventions
- Read `BUILD_PROMPT.md` §3 and §9, and `.claude/commands/conditional_docs.md`.
- Re-read the relevant ranges in `console_components.ex` and `console_live.ex` listed
  above to confirm line numbers before editing.

### 2. Write the LiveView integration test first (red)
- Create `test/repo_builder_web/live/test_agent_card_stream_filter_test.exs` using
  `RepoBuilderWeb.ConnCase, async: false` and `Phoenix.LiveViewTest`.
- Seed two agents via `Agents.create_agent/1` + `send(view.pid, {:agent_created, agent})`
  (mirror `test_orchestrator_thinking_toggle_test.exs`).
- Inject rows for both agents with `Dashboard.broadcast_event(agent.id, %Event.TextDelta{...})`.
- Assert default: both agents' rows are present in `#event-stream`.
- Click agent A's card (`element("#agent-#{a.id}") |> render_click()`); assert:
  a filter pill for A exists in `#filter-bar` with a `×` button, `#event-stream`
  shows A's row and not B's row.
- Click the pill `×` (or the card again); assert the filter clears and B's row
  reappears.
- Assert `CLEAR FILTERS` (`#clear-filters`) also clears an active agent filter.
- Routing: with exactly one agent filtered, drive a prompt submit and assert it routes
  to that agent; with none filtered, assert orchestrator routing. (Use the seam the
  other console tests use; if a full run can't be driven deterministically because of
  the known `fake`-harness spawn env issue, assert the derived target via the rendered
  state / a `run_prompt` unit-level check rather than a live spawn.)
- Run the test and confirm it fails for the right reasons.

### 3. Make filtering id-based
- In `console_live.ex`, change `agent_pass?/2` to match on `row.agent_key`:
  `defp agent_pass?(row, active), do: row.agent_key in active` (keep the `[]` clause).
- Keep `@spec agent_pass?(map(), [String.t()]) :: boolean()`.

### 4. Rewire the agent card + compact rail click to toggle the filter
- In `console_components.ex`, change `agent_card/1` (line 233-237) and
  `agent_rail_compact/1` (line 299-303) to `phx-click="toggle_agent_filter"` with
  `phx-value-id={@id}`.
- Leave the `selected?` attr/styling in place (its source changes in step 7).

### 5. Update the `toggle_agent_filter` handler to key by id
- In `console_live.ex` (688-694), change the pattern to `%{"id" => id}` and toggle `id`
  in `active_agents`, then `restream/1` (unchanged logic). Keep `@impl`/`@spec`-free
  `handle_event` style consistent with neighbors.

### 6. Resolve pill labels from `agent_names` and fire `×` by id
- Add an `attr :agent_names, :map, default: %{}` to `filter_bar/1`.
- In the pill loop (console_components.ex:352-363), render
  `{Map.get(@agent_names, id, id)}` as the label and set the `×` button to
  `phx-click="toggle_agent_filter"` `phx-value-id={id}` with an updated `aria-label`.
- Pass `agent_names={@agent_names}` where `filter_bar` is invoked
  (`console_live.ex:1499-1505`).

### 7. Drive card highlight from filter membership
- In the rail render (console_live.ex:1465 & 1477), set
  `selected?={agent.id in @active_agents}` for both `agent_rail_compact` and
  `agent_card`.

### 8. Unify prompt routing and retire `selected_agent_id`
- Add a private helper
  `@spec single_active_agent([String.t()]) :: String.t() | nil`
  returning the lone id when `length(active_agents) == 1`, else `nil`.
- In `run_prompt/4` (console_live.ex:778), replace `socket.assigns.selected_agent_id`
  with `single_active_agent(socket.assigns.active_agents)` (preserving the
  `nil ⇒ orchestrator` branch and the single-agent branch).
- Remove the `select_agent` handler (570-571) and the `selected_agent_id` assign
  (init line 69) plus any other references; ensure no compile warning for unused
  assigns/handlers.

### 9. Verify the close/clear paths
- Confirm `clear_filters` still resets `active_agents` and restreams (no change
  expected). Confirm a pill `×` removes exactly its agent.

### 10. Manual runtime check via Tidewave (optional but preferred)
- Use Tidewave's `project_eval` / browser to confirm: clicking a card adds a pill and
  filters `#event-stream`; the `×` removes it. Optionally capture a screenshot of
  `http://localhost:4000` for visual proof.

### 11. Run the Validation Commands
- Run every command in the Validation Commands section; fix any failure until all are
  green with zero regressions. Note: two pre-existing `test_orchestration_console_test.exs`
  failures (`spawn failed: env - invalid env argument #234`, the erlexec env gotcha) are
  unrelated to this feature — confirm they are unchanged, not newly introduced.

## Testing Strategy
### Unit Tests
- `agent_pass?/2`: returns true for all rows when `active_agents == []`; with one id,
  passes only rows whose `agent_key` matches; with multiple ids, passes the union.
- `single_active_agent/1`: `[] -> nil`, `[id] -> id`, `[a, b] -> nil`.
- These are exercised through the LiveView integration test (stream contents) and may
  also be covered by small direct tests if convenient.

### Edge Cases
- Two agents with the same display name: id-based filtering keeps them independent
  (only the clicked one filters), and both pills show the same label but key by id.
- Clicking the same agent twice toggles the filter off (stream returns to all agents).
- Multiple agents filtered at once: stream shows the union; routing falls back to the
  orchestrator (not a single agent).
- `CLEAR FILTERS` with active agent pills: clears categories, search, regex, AND agent
  pills; stream shows everything again; card highlights clear.
- Removing the last agent pill via `×` returns routing to the orchestrator.
- Reconnect/backfill: `log_to_row` rows carry `agent_key`, so id-based filtering keeps
  working after a refresh (no name dependency).

## Acceptance Criteria
- Clicking an agent card (or compact rail item) adds a removable pill for that agent in
  `#filter-bar`, positioned with the category chips, and narrows `#event-stream` to that
  agent's events.
- The pill has a `×` close button that removes the filter; clicking the card again also
  removes it; `CLEAR FILTERS` removes it.
- The agent card shows its "active filter" highlight while (and only while) it is an
  active filter.
- With exactly one agent filtered, a manual prompt routes to that agent; with zero or
  multiple, it routes to the orchestrator.
- No `select_agent`/`selected_agent_id` remnants cause compile warnings; the build is
  clean under `--warnings-as-errors`, Credo `--strict`, and Dialyzer.
- The new LiveView integration test passes; no new failures in the existing suite.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix test test/repo_builder_web/live/test_agent_card_stream_filter_test.exs` — The new
  LiveView integration test passes.
- `mix test test/repo_builder_web/live/test_streaming_console_test.exs test/repo_builder_web/live/test_orchestration_console_ui_test.exs test/repo_builder_web/live/test_orchestration_console_test.exs` —
  Console LiveView tests pass (the only acceptable failures are the two pre-existing
  `spawn failed: env - invalid env argument #234` cases, which must remain unchanged).
- `mix compile --warnings-as-errors` — Clean compile; gradual set-theoretic checker +
  `warnings_as_errors` pass.
- `mix test --warnings-as-errors` — Full suite; no new failures.
- `mix format --check-formatted` — Formatting clean.
- `mix credo --strict` — Lint passes, including the `@spec`-on-every-public-function gate.
- `mix dialyzer` — No new contract warnings; no stale ignore filters.

## Notes
- This is a UI/LiveView-only change: no new dependencies, no schema/migration, no
  context-module changes (no `Repo`/`Ecto.Query` touched). The DB-access boundary in
  §8 is unaffected.
- The infrastructure (`active_agents`, the pills + `×`, `toggle_agent_filter`,
  `agent_pass?`, `restream/1`, `agent_names`) already exists; this feature is mostly
  *wiring the trigger* and *removing the `selected_agent_id` overload*. Keep the diff
  small and conventional.
- Design decision worth surfacing in the PR: unifying "selection" with "filtering"
  (the filter set drives routing). If reviewers prefer to keep an explicit, separate
  "run as this agent" affordance, an alternative is to keep `selected_agent_id` for
  routing and add filtering purely on top — but that re-introduces two overlapping
  per-agent concepts; the unified model is recommended.
- Name-based vs id-based: id-based (`agent_key`) is chosen for collision-safety since
  the card naturally carries the id. The pill label is resolved through `agent_names`
  for a friendly display.
- Known environment caveat: `test_orchestration_console_test.exs` has two pre-existing
  failures from the erlexec `env - invalid env argument #234` spawn gotcha; verify they
  are not caused or worsened by this change.
```
