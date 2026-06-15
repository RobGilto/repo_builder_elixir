# Feature: Multi-Layered Orchestration Console (LiveView)

## Metadata
issue_number: `a`
adw_id: `multi-layered`
issue_json: `orchestration`

## Feature Description
Adopt the multi-layered orchestration console UI — modeled on the reference Vue app
at `/data/3.Resources/engineering/TAC Repos/repos/tac-14/orchestrator-agent-with-adws/apps/orchestrator_3_stream`
that the platform spec (`BUILD_PROMPT.md`) was based on — into `repo_builder_elixir`
as a single, full-bleed **Phoenix LiveView** page.

Today the web layer is **observability-only**: `DashboardLive` renders swimlanes,
`AgentLive` renders a per-agent event log with hardcoded Start/Interrupt buttons,
`WorkflowLive`/`SystemLogsLive` render read views. There is **no browser UI to create
an agent, launch a session with a prompt, or kick off an ADW** — those actions only
exist in `@spec`'d contexts (`RepoBuilder.Agents`, `RepoBuilder.WorkflowEngine`) and
must be driven from IEx. This feature closes that gap by reproducing the reference
console's interaction model:

- a **header bar** with a live connection indicator, stat pills (Active agents,
  Running, Logs, Cost), a **LOGS / ADWS** view-mode toggle, and a **Prompt** toggle;
- a **left agent rail** listing agents (status dot + harness), selectable, with an
  inline **"New agent"** form (name, harness `<select>` from the registry, provider);
- a **center column** that switches between a live **event stream** (append-only,
  LiveView streams, flat memory) and **ADW swimlanes**;
- a **right command/launch panel** (the reference `OrchestratorChat` +
  `GlobalCommandInput`): a prompt composer that **starts a live session** on the
  selected agent, plus an **interrupt** action and a **Launch ADW** action.

The console is harness-blind: it drives the exact same `Session.Supervisor.start_session/1`
and `WorkflowEngine.start_workflow/2` paths the runtime already uses, so it works
identically with the keyless `fake` harness (dev), `claude`, and `pi`.

## User Story
As an operator of the orchestration platform
I want a single browser console to create agents, launch sessions/ADWs with a prompt, and watch live events stream in
So that I can drive and observe the platform end-to-end without dropping into IEx.

## Problem Statement
The platform implements the full M0–M7 runtime (session GenServers, workflow engine,
multi-harness adapters, persistence, swimlane dashboard), but every *control* action
(create agent, start session, launch workflow) is only reachable from IEx. A human
tester expecting "a UI to do this" has no entry point: the routes are detail/read
views, `seeds.exs` is empty, and there is no create/launch affordance anywhere in
`lib/repo_builder_web/`. The reference orchestrator app the spec was derived from is
explicitly a multi-column, command-driven console — that interaction model was never
ported.

## Solution Statement
Build one new full-bleed LiveView, `RepoBuilderWeb.ConsoleLive`, mounted at `/`, that
reproduces the reference 3-column console using the existing runtime seams:

1. **Reuse existing PubSub + contexts.** Swimlanes come from the existing
   `Dashboard` lanes topic; agent/workflow CRUD and launching go through the existing
   `Agents`, `Workflows`, `WorkflowEngine`, and `Session.Supervisor` APIs. LiveView
   never touches `Repo` directly (§8).
2. **Add one additive PubSub seam** for a *global* event feed: a `console:events`
   topic in the `Dashboard` context plus a single extra broadcast in
   `Session.Server.dispatch/2`. This lets the center column show events from **all**
   agents in one stream (the per-agent `agent:<id>:events` topics stay unchanged).
3. **Typed console components** (`attr/3`-validated) for the header stat pills, agent
   rail item, event row, and command panel, living alongside the existing
   `DashboardComponents`.
4. **Forms** built with `to_form/2`: the new-agent form from `Agent.changeset/2`, the
   launch form from a plain params map, the ADW launcher from a harness `<select>`.
5. **Streams everywhere** for the event feed and swimlanes (stable dom_ids,
   negative `limit:` pruning) so server memory stays flat (§9).

No new runtime dependency is required (LiveView + daisyUI are already present).

## Relevant Files
Use these files to implement the feature:

- `BUILD_PROMPT.md` — authoritative spec; §3 (typed style), §4.1 (canonical `Event`
  variants the console renders), §6 (session runtime that broadcasts events), §9
  (LiveView streams/`assign_async`/reconnect-backfill rules), §10 (harness registry
  the harness `<select>` is populated from), §13 (testing/injection seam).
- `README.md` / `AGENTS.md` — Phoenix 1.8 + LiveView conventions (streams, `<.input>`,
  `<.form for={@form}>`, `<Layouts.app>` usage rules, daisyUI available in `app.css`).
- `lib/repo_builder/dashboard.ex` — existing lanes PubSub helper; **extend** with a
  global `console:events` topic (`subscribe_events/0`, `broadcast_event/2`).
- `lib/repo_builder/session/server.ex` — `dispatch/2` already broadcasts
  `agent:<id>:events` + `dashboard:lanes`; **add** one `Dashboard.broadcast_event/2`
  call so the console gets a unified feed.
- `lib/repo_builder/session/supervisor.ex` — `start_session/1`, `stop_session/1`,
  `interrupt/1`, `whereis/1` — the launch/interrupt seam the command panel calls.
- `lib/repo_builder/agents.ex` + `lib/repo_builder/agents/agent.ex` — `list_agents/0`,
  `create_agent/1`, `set_status/2`; `Agent.changeset/2`, `Agent.status()`,
  `Agent.provider()` types and the `validate_inclusion` against the registry.
- `lib/repo_builder/workflows.ex` — `list_recent_runs/1` (seed workflow swimlanes).
- `lib/repo_builder/workflow_engine.ex` — `create_example_workflow/2`,
  `start_workflow/2`, `example_steps/1` (the "Launch ADW" action; defaults to `fake`).
- `lib/repo_builder/harness/registry.ex` — `known/0` (populate harness `<select>`),
  `fetch_config/1`.
- `lib/repo_builder/logs.ex` — `cost_rollup!/1`, `list_recent/2` (seed cost pill and
  optional event backfill); LiveView reads cost only through this context.
- `lib/repo_builder/harness/event.ex` — the canonical `Event.*` structs each
  `handle_info/2` clause matches (`SessionStarted`, `TextDelta`, `ToolCall`,
  `ToolResult`, `Usage`, `Status`, `Done`, `Error`).
- `lib/repo_builder_web/live/dashboard_live.ex` — pattern to copy for stream config,
  connected-mount seeding, and `{:lane, lane}` handling.
- `lib/repo_builder_web/live/agent_live.ex` — pattern to copy for per-variant
  `handle_info({:harness_event, %Event.*{}}, …)` clauses and `push_row/5`.
- `lib/repo_builder_web/components/dashboard_components.ex` — existing `swimlane_row`,
  `log_line`, `cost_badge`; reuse and extend with console components.
- `lib/repo_builder_web/components/layouts.ex` — `Layouts.flash_group/1`,
  `Layouts.theme_toggle/1`; note `Layouts.app/1` wraps content in `max-w-2xl`, so the
  full-bleed console renders its own shell + `<.flash_group>` (see Notes).
- `lib/repo_builder_web/router.ex` — make `/` the console (`live "/", ConsoleLive`),
  keeping `/dashboard`, `/agents/:id`, `/workflows/:id`, `/system-logs`.
- `config/config.exs` — harness registry (`fake` registered in `:dev` only, already
  added); the harness `<select>` derives from `Registry.known/0`, so it reflects this.
- `test/repo_builder_web/live/dashboard_live_test.exs` (if present) and
  `test/support/` — `Phoenix.LiveViewTest` + `RepoBuilder.DataCase`/Mox patterns to
  copy for the new integration test.

### New Files
- `lib/repo_builder_web/live/console_live.ex` — the multi-layered console LiveView
  (mount/streams/subscriptions, all `handle_event/3` for create/launch/interrupt/
  toggle/select, all `handle_info/2` for events + lanes, and `render/1`).
- `lib/repo_builder_web/components/console_components.ex` — typed function components:
  `header_bar/1` (stat pills + LOGS/ADWS toggle + Prompt toggle + connection dot),
  `agent_rail_item/1` (status dot, name, harness, selected styling),
  `event_row/1` (agent label + kind chip + body, thinking-dimmed), and
  `command_panel/1` (launch form scaffold). `attr/3`/`slot/3` validated.
- `test/repo_builder_web/live/test_orchestration_console_test.exs` — `Phoenix.LiveViewTest`
  integration test driving the console (create agent → launch fake session → assert
  streamed events + stat updates; toggle view; launch ADW).

## Implementation Plan
### Phase 1: Foundation
Add the **global event feed** seam without disturbing the existing per-agent and lane
topics. Extend `RepoBuilder.Dashboard` with a `console:events` topic
(`subscribe_events/0`, `broadcast_event/2` emitting `{:agent_event, agent_id, event}`)
and add exactly one `Dashboard.broadcast_event(agent_id, event)` call inside
`Session.Server.dispatch/2` (after the existing `agent:<id>:events` broadcast). This
is additive and keeps `dispatch/2`'s `@spec` and return value (`State.t()`) unchanged.
Add a unit test asserting a subscriber receives `{:agent_event, id, %Event{}}`.

### Phase 2: Core Implementation
Build `console_components.ex` (typed components) and `ConsoleLive`:
- Configure two streams (`:events`, `:lanes`) with stable dom_ids; on a **connected**
  mount, seed `:lanes` from `Agents.list_agents/0` + `Workflows.list_recent_runs/0`
  (same shape as `DashboardLive.seed_lanes/0`), seed the cost pill from
  `Logs.cost_rollup!/1` summed over agents, then subscribe to `Dashboard.subscribe/0`
  (lanes) and `Dashboard.subscribe_events/0` (global feed).
- Maintain assigns: `agents`, `agent_names` (id→name map for event labels),
  `statuses` (id→status map for the Running pill), `selected_agent_id`,
  `view_mode` (`:logs | :adws`), `show_new_agent?`, `agent_form`, `launch_form`,
  `adw_harness`, `log_count`, `ws_count`, `cost` (`Decimal.t()`), `connected?`.
- `handle_event/3`: `toggle_view`, `toggle_prompt`, `select_agent`, `show_new_agent`/
  `cancel_new_agent`, `validate_agent`, `create_agent`, `validate_launch`, `run`
  (start session on the selected agent), `interrupt`, `launch_adw`.
- `handle_info/2`: one clause per `{:agent_event, id, %Event.*{}}` variant (push an
  event row, bump `log_count`/`ws_count`, update `statuses`, accumulate `cost` from
  `Usage`/`Done`), plus `{:lane, lane}` → `stream_insert(:lanes, …)`.

### Phase 3: Integration
Wire `render/1` as the full-bleed 3-column grid (header / left rail / center / right
panel) using the new components and daisyUI classes already in `app.css`. Repoint the
root route `/` to `ConsoleLive` (replacing `PageController :home`) and keep all
existing routes. Confirm the same launch path drives `fake`, `claude`, and `pi`
unchanged (harness chosen via the `<select>` from `Registry.known/0`). Add the
LiveView integration test and run the full validation suite.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Extend the Dashboard context with a global event topic
- In `lib/repo_builder/dashboard.ex` add `@events_topic "console:events"`, a
  `@spec subscribe_events() :: :ok` and a `@spec broadcast_event(String.t(), Event.t()) :: :ok`
  that broadcasts `{:agent_event, agent_id, event}`. Reference the canonical type via
  `alias RepoBuilder.Harness.Event` (or `term()` if avoiding a cycle — prefer the
  precise `Event.t()`). Keep existing functions untouched.

### 2. Emit the global event from the session runtime
- In `lib/repo_builder/session/server.ex`, inside `dispatch/2`, add one line after the
  existing `Phoenix.PubSub.broadcast(@pubsub, "agent:#{agent_id}:events", …)`:
  `_ = RepoBuilder.Dashboard.broadcast_event(agent_id, event)`. Do not change the
  function's `@spec`/return. (Use the fully-qualified module to avoid a new alias.)

### 3. Unit-test the new PubSub seam
- In `test/repo_builder/dashboard_test.exs` (create if absent) assert that after
  `Dashboard.subscribe_events/0`, calling `Dashboard.broadcast_event(id, %Event.TextDelta{…})`
  delivers `{:agent_event, ^id, %Event.TextDelta{}}` to the test process.

### 4. Create the LiveView integration test FIRST (drives the design)
- Create `test/repo_builder_web/live/test_orchestration_console_test.exs` using
  `RepoBuilder.ConnCase` + `import Phoenix.LiveViewTest`.
- Inject a deterministic harness via the registry seam (§13): override the
  `:repo_builder, :harnesses` entry under test to point a key (e.g. `"fake"`, already
  registered in dev/test, or a Mox mock) — do **not** invent a `:harness_adapter` key.
- Test cases (minimal, outcome-focused, by element id):
  - `live(conn, "/")` mounts; the header (`#console-header`), agent rail
    (`#agent-rail`), and center stream (`#event-stream`) render.
  - Submitting the new-agent form (`#new-agent-form`) creates an agent and it appears
    as a rail item (`#agent-…`).
  - Selecting that agent + submitting the launch form (`#launch-form`) with a prompt
    starts a `fake` session; assert the event stream receives streamed rows (the fake
    sequence `session_started → text_delta → tool_call → tool_result → usage → done`)
    and the Logs/Active stat pills update. Use `Process.monitor` on the session pid (no
    `Process.sleep`) or assert on rendered stream content after the canned run.
  - Clicking the LOGS/ADWS toggle (`#view-toggle`) switches the center column to
    `#swimlanes`.
  - Clicking "Launch ADW" (`#launch-adw`) starts the example workflow and a workflow
    lane appears.

### 5. Build typed console components
- Create `lib/repo_builder_web/components/console_components.ex` (`use RepoBuilderWeb, :html`).
- `header_bar/1`: attrs `connected? :boolean`, `agent_count :integer`,
  `running_count :integer`, `log_count :integer`, `cost :any`, `view_mode :atom`
  (`values: [:logs, :adws]`), `prompt_open? :boolean`. Renders connection dot, stat
  pills, the LOGS/ADWS toggle (`#view-toggle`), and the Prompt toggle. Reuse
  `cost_badge` from `DashboardComponents` for the cost pill.
- `agent_rail_item/1`: attrs `id`, `name`, `status` (`values:` the agent statuses),
  `harness`, `selected? :boolean`. Status dot color via a private `status_class/1`.
- `event_row/1`: attrs `agent :string`, `kind :string`, `body :string`,
  `thinking? :boolean`. Agent label + kind chip + body; dim when `thinking?`.
- Every public component carries an `@spec component(map()) :: Phoenix.LiveView.Rendered.t()`.

### 6. Implement ConsoleLive — mount, streams, subscriptions
- Create `lib/repo_builder_web/live/console_live.ex` (`use RepoBuilderWeb, :live_view`).
- `mount/3`: `stream_configure(:events, dom_id: &"ev-#{&1.id}")`,
  `stream_configure(:lanes, dom_id: &"lane-#{&1.id}")`, both seeded `[]`. Assign the
  initial scalar state (forms via `to_form/2`, counters at 0, `cost: Decimal.new(0)`,
  `view_mode: :logs`, `selected_agent_id: nil`, `show_new_agent?: false`).
- On `connected?(socket)`: load `Agents.list_agents/0`, build `agent_names`/`statuses`
  maps, seed `:lanes` (agents + `Workflows.list_recent_runs/0`), seed `cost` from
  `Logs.cost_rollup!/1` summed over agents, then `Dashboard.subscribe/0` +
  `Dashboard.subscribe_events/0`.
- Add `@spec` to every private helper (`seed_lanes/0`, `recompute_cost/1`, etc.).

### 7. Implement ConsoleLive — control handlers
- `handle_event("toggle_view", …)` flips `:view_mode`.
- `handle_event("toggle_prompt", …)` flips `:prompt_open?`.
- `handle_event("select_agent", %{"id" => id}, …)` sets `selected_agent_id` and
  defaults the launch form harness to that agent's harness.
- `handle_event("validate_agent" | "create_agent", …)` uses `Agent.changeset/2`
  and `Agents.create_agent/1`; on success refresh `agents`/maps, re-seed the agent
  lanes, select the new agent, hide the form; on error re-assign the form with errors.
- `handle_event("validate_launch", …)` re-assigns the launch form.
- `handle_event("run", %{"launch" => %{"prompt" => p, "harness" => h, "model" => m}}, …)`:
  require a selected agent (flash error if none), then
  `Session.Supervisor.start_session(agent_id: id, agent_db_id: id, session_id: unique, harness: h, prompt: p, model: m_or_nil)`;
  map `{:error, :at_capacity}` / other errors to flashes.
- `handle_event("interrupt", …)` → `Session.Supervisor.interrupt(selected_agent_id)`.
- `handle_event("launch_adw", %{"adw" => %{"harness" => h}}, …)` →
  `WorkflowEngine.create_example_workflow("console-adw-…", h)` then
  `WorkflowEngine.start_workflow/1`; flash with the run id.

### 8. Implement ConsoleLive — event/lane handlers
- One `handle_info({:agent_event, agent_id, %Event.SessionStarted{}}, …)` … through
  `%Event.Error{}` clause (mirror `AgentLive`), each pushing an `event_row` into the
  `:events` stream (`at: -1, limit: -500`), bumping `log_count` and `ws_count`,
  updating `statuses[agent_id]` (`running` on start; `succeeded`/`failed`/`error` on
  terminal), and adding `Usage`/`Done` `cost_usd` (float→`Decimal.from_float/1`,
  preserving nil) into `cost`.
- `handle_info({:lane, lane}, …)` → `stream_insert(:lanes, lane)` (stable dom_id
  replaces in place).
- Derive the Running pill from `statuses` (count `:running`).

### 9. Implement ConsoleLive — render/1 (full-bleed 3-column shell)
- Render a top-level `div` (NOT `Layouts.app` — see Notes) using a CSS grid:
  header row, then `[agent rail | center | command panel]`. Include
  `<.flash_group flash={@flash} />` and `<.theme_toggle />` from `Layouts`.
- Left rail: `#agent-rail` with a `:for` over `@agents` rendering `agent_rail_item`,
  plus the toggleable `#new-agent-form` (`<.form for={@agent_form}>` with `<.input>`
  for name, a harness `<.input type="select" options={Registry.known()}>`, a provider
  select).
- Center: when `@view_mode == :logs`, `#event-stream` with `phx-update="stream"` over
  `@streams.events` rendering `event_row`; else `#swimlanes` with `phx-update="stream"`
  over `@streams.lanes` rendering `swimlane_row` + a `#launch-adw` form.
- Right: `#command-panel` with `<.form for={@launch_form} id="launch-form" phx-submit="run">`
  (prompt textarea, harness select, optional model), a Run button, and an Interrupt
  button. Give every form/button/list a stable DOM id for tests.

### 10. Repoint the root route
- In `lib/repo_builder_web/router.ex`, replace `get "/", PageController, :home` with
  `live "/", ConsoleLive`. Keep `/dashboard`, `/agents/:id`, `/workflows/:id`,
  `/system-logs`, `/webhooks/trigger`, and the `/dev` routes unchanged.
- Leave `PageController`/`page_html` in place (no longer routed) to avoid unrelated
  churn, or remove if it produces an unused-warning under `--warnings-as-errors`
  (verify; only delete if the compiler flags it).

### 11. Manual runtime validation (Tidewave preferred, else IEx)
- Start Postgres (`scripts/pg.sh start`) and the server (`iex -S mix phx.server`).
- If Tidewave is available (`http://localhost:4000/tidewave/mcp`), use `project_eval`
  to create an agent + start a fake session and `get_logs` to confirm no errors;
  otherwise drive `priv/repo/demo_seeds.exs` in the same node. Visit `/` and confirm:
  rail shows the agent, Run streams events into the center, stat pills update, the
  LOGS/ADWS toggle works, Launch ADW adds a workflow lane.
- Optionally capture a screenshot of `http://localhost:4000` via Tidewave Web vision
  mode (or the Playwright MCP tools) as visual proof.

### 12. Run all Validation Commands
- Execute every command in the `Validation Commands` section; fix any failure before
  considering the feature complete.

## Testing Strategy
### Unit Tests
- `Dashboard.broadcast_event/2` delivers `{:agent_event, id, %Event{}}` to a
  `subscribe_events/0` subscriber (Phase 1 seam).
- Console components render expected ids/classes given representative assigns
  (component-level render via `Phoenix.LiveViewTest.render_component/2` is optional but
  cheap for `header_bar`/`event_row`).

### LiveView Integration Tests (`test/repo_builder_web/live/test_orchestration_console_test.exs`)
- Mount `/`; assert header, rail, and event-stream containers render.
- Create-agent form creates an agent and renders a rail item.
- Select + Run with the `fake` harness streams the canned canonical sequence into the
  event stream and updates the Logs/Active pills; Done flips the agent's lane to
  `succeeded`.
- View toggle switches center column to swimlanes; Launch ADW adds a workflow lane.
- Use the registry override seam for harness injection and `Process.monitor`/PubSub
  assertions instead of `Process.sleep`.

### Edge Cases
- **Run with no agent selected** → flash error, no crash, no session started.
- **Create agent with a harness not in the registry** → changeset error surfaced in
  the form (`validate_inclusion` against `Registry.known/0`), no insert.
- **Duplicate agent name** → `{:error, changeset}` shown inline (unique constraint),
  not a raw Postgrex error.
- **`at_capacity`** from the admission gate → friendly flash, UI stays responsive.
- **Reconnect** (LiveView remount): lanes/cost re-seed from persisted state; events
  broadcast while disconnected are gone by design (PubSub is fire-and-forget, §9) —
  the stream simply restarts; assert no crash on remount.
- **Unpriced cost** (`cost_usd == nil`, e.g. pi without a price-table entry): cost pill
  shows `—`, never `$0`, and `nil` is not coerced to `Decimal.new(0)`.
- **High event volume**: streams with `limit: -500` keep server memory flat (spot-check
  the assign map stays small).

## Acceptance Criteria
- Visiting `/` renders a full-bleed 3-column console: header (connection dot + Active/
  Running/Logs/Cost pills + LOGS/ADWS toggle + Prompt toggle), left agent rail with a
  working "New agent" form, center event-stream/swimlane area, right command panel.
- An operator can **create an agent**, **select it**, **type a prompt and Run** to
  start a live session, and **watch canonical events stream** into the center column in
  real time; the stat pills update live.
- The same Run path works with the `fake` harness (no keys) and, when configured, with
  `claude`/`pi` by choosing the harness in the `<select>` — no code change.
- **Launch ADW** starts the example `plan → build → review → fix` workflow and a
  workflow lane appears/advances in ADWS view.
- **Interrupt** stops the selected agent's live session.
- LiveView never calls `Repo`/`Ecto.Query` directly; all data flows through `@spec`'d
  contexts. The only runtime change is the additive `console:events` broadcast.
- The LiveView integration test passes, and all Validation Commands are green with zero
  regressions (every public function `@spec`'d, structs `@enforce_keys`/`typedstruct`,
  Dialyzer clean, no stale ignore filters).

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix test test/repo_builder_web/live/test_orchestration_console_test.exs` — the new
  LiveView integration test passes (mount → create agent → launch fake session →
  assert streamed events + stat updates → toggle view → launch ADW).
- `mix test test/repo_builder/dashboard_test.exs` — the new PubSub seam unit test
  passes.
- `mix compile --warnings-as-errors` — compiles clean; gradual set-theoretic type
  checker + `warnings_as_errors` pass (no unused `PageController` warning after the
  route change).
- `mix test --warnings-as-errors` — full ExUnit suite (Postgres-backed) passes with
  zero failures and no regressions to existing dashboard/agent/workflow tests.
- `mix format --check-formatted` — formatting clean.
- `mix credo --strict` — lint clean, including "every public function has an `@spec`".
- `mix dialyzer` — contract checking clean, no new warnings, no stale ignore filters.

## Notes
- **No new dependencies.** LiveView 1.2 and daisyUI (`@plugin "../vendor/daisyui"` in
  `assets/css/app.css`) are already present; reuse `btn`/`badge`/`card` classes and the
  existing `DashboardComponents`.
- **Full-bleed layout vs `Layouts.app`.** `Layouts.app/1` wraps content in a centered
  `max-w-2xl` `<main>`, which fights a 3-column console. The README's "always begin
  templates with `<Layouts.app>`" guideline exists to avoid `current_scope` errors;
  this app uses no scopes/auth, so `ConsoleLive.render/1` renders its own full-height
  shell and includes `<Layouts.flash_group flash={@flash} />` directly. If a future
  reviewer prefers strict adherence, add a `Layouts.console/1` full-bleed wrapper
  component instead — call it out in review rather than blocking.
- **Reference fidelity.** The reference app (Vue + WebSocket + Pinia) splits center
  into `EventStream`/`AdwSwimlanes` and right into `OrchestratorChat` + a Cmd+K
  `GlobalCommandInput`. This plan maps WebSocket→`Phoenix.PubSub`, Pinia store→LiveView
  assigns/streams, and the command input→the right-column launch form. A literal
  Cmd+K floating overlay and the autocomplete/slash-command system are **out of scope**
  for v1 (the right-panel launch form covers the same action); they can be added later
  as a colocated JS hook + an autocomplete context.
- **Harness `<select>` is registry-driven** (`Registry.known/0`), so it automatically
  lists `fake` in dev and `claude`/`pi`/`cursor` everywhere — consistent with the
  "add a harness = one module + one config entry" promise (§10). No console code edits
  when a harness is added.
- **Cost accounting** is incremental (seed from `Logs.cost_rollup!/1` at mount, then
  add live `Usage`/`Done` deltas) to avoid a DB round-trip per event; the persisted
  rollup remains the source of truth and can be re-seeded on reconnect.
- A keyless end-to-end demo already exists at `priv/repo/demo_seeds.exs` (fake agent +
  session + example ADW) and is the fastest way to populate the console during manual
  validation; run it inside the running server's IEx (`Code.require_file/1`) so PubSub
  events reach the live page in the same node.
