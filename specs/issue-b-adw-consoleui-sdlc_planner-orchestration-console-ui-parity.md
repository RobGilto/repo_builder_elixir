# Feature: Orchestration Console UI Parity (replicate the Vue `orchestrator_3_stream` console in Phoenix LiveView)

## Metadata
issue_number: `b`
adw_id: `consoleui`
issue_json: `{"title":"Rebuild ConsoleLive to visual + interaction parity with the orchestrator_3_stream reference UI","body":"The current ConsoleLive (/) is functional but visually bare. Replicate the reference dark 3-pane multi-agent orchestration console (Vue 3 + Pinia at /data/1.Projects/tactical-agentic-coding/tac-14/orchestrator-agent-with-adws/apps/orchestrator_3_stream/frontend) in Phoenix LiveView: a dark cyan/teal/purple design system, rich agent cards (status badge, context-window bar, per-category log counters, model+cost footer, collapse-to-rail, pulse), an EventStream with category filter chips + agent-name filter pills + regex search + auto-follow + clear-all + line numbers + agent colors + expandable rows, a chat-styled command panel (user/orchestrator/thinking/tool-use bubbles, typing indicator, width toggle, context indicator), an ADW swimlanes view with per-step colored event squares + hover tooltips + click-to-open event detail panel, header status pills (Active/Running/Logs/WS Events/Cost) + LOGS/ADWS toggle with glow + a Prompt (Cmd+K) global command input modal with keyboard shortcuts. Reference demo recorded at /home/robert/2026-06-16 20-17-34.mp4; knowledge graph at the reference repo .understand-anything/."}`

## Feature Description

Rebuild the existing `RepoBuilderWeb.ConsoleLive` (mounted at `/`) and `RepoBuilderWeb.ConsoleComponents` so the orchestration console matches the reference Vue application `orchestrator_3_stream` in **visual design and interaction**, while staying 100% harness-blind and driving only the seams the runtime already exposes (`Agents`, `Logs`, `Workflows`, `Dashboard` PubSub, `Session.Supervisor`, `WorkflowEngine`).

The reference UI is a dark, three-pane "command console":

- **Header bar** — title + a live connection dot, a row of status pills (`Active`, `Running`, `Logs`, `WS Events`, `Cost`), a `LOGS ⇄ ADWS` view-mode toggle (cyan glow on the active side), and a `Prompt (Cmd+K)` toggle.
- **Left rail (`AgentList`)** — rich per-agent cards (name with a deterministic agent-color left border, status badge, a `CONTEXT WINDOW` progress bar `Nk / 200k`, four per-category counters 💬/🛠️/🪝/🧠, a model + `$cost` footer), collapsible to a 48px icon rail, with a brief "pulse" highlight when an agent emits an event.
- **Center (`EventStream` ⇄ `AdwSwimlanes`)** — in `logs` mode: a filter bar (category chips `RESPONSE`/`TOOL`/`THINKING`/`HOOK`, active agent-name filter pills, a regex search box, an `AUTO-FOLLOW` toggle, a `CLEAR ALL` button) above an append-only stream of rows (line number, category badge, agent-colored accent, content, token + timestamp meta, click-to-expand). In `adws` mode: one swimlane per workflow run, broken into step columns, each holding small colored event squares (by canonical event type) with a hover tooltip and a click that opens a right-side event-detail panel.
- **Right (`OrchestratorChat` → our `CommandPanel`)** — a chat-styled panel: user bubbles, orchestrator "thinking" bubbles (purple), tool-use "action" cards (amber, tool name + pretty-printed JSON params), a typing indicator, a width toggle (sm/md/lg), and a context/cost indicator in its header — wrapping the existing prompt-composer + Interrupt + Launch-ADW controls.
- **Global command input** — a bottom-anchored modal overlay toggled by `Cmd+K`, with a large textarea, a "system info" panel (harnesses, agents, the example ADW), and keyboard shortcuts (`Cmd+K` toggle, `Cmd+J` switch view, `Esc` close, `Enter` send / `Shift+Enter` newline).

## User Story

As an **operator running multiple AI agent sessions and ADWs**
I want to **watch and command every live agent from one polished, information-dense console**
So that **I can see each agent's status, token/context usage, cost, and streaming activity at a glance, filter the live event firehose, follow workflow progress as swimlanes, and launch/interrupt work without leaving the page.**

## Problem Statement

The current `ConsoleLive` already wires the correct *runtime* seams (streams for `:events` and `:lanes`, the `console:events` global feed, `Session.Supervisor`, `WorkflowEngine`) but its **presentation is severely underdeveloped** versus the reference:

- The header shows only `Active/Running/Logs/Cost` flat badges — no `WS Events` pill, no glowing view toggle, no `Cmd+K` affordance.
- The left rail is a one-line status-dot + name + harness badge — no status badge, no context-window bar, no per-category counters, no model/cost footer, no collapse, no pulse.
- The center event rows are a single mono line (`agent · kind · body`) — no line numbers, no category color coding, no agent colors, no expand, no token/time meta, and **no filtering or search at all**.
- The center is missing a real swimlanes view: lanes render as flat rows with no per-step event squares, no tooltips, and no detail panel.
- The right panel is a bare launch form — none of the chat affordances (bubbles, thinking, tool-use cards, typing, width toggle, context indicator).
- There is no global command input modal and no keyboard shortcuts.
- There is no dark cyan/teal/purple design system; the page rides default daisyUI tokens.

## Solution Statement

Rebuild the console **in the web layer only**, on top of the existing contexts and PubSub seams, in four coordinated pieces:

1. **A console design system** — add a scoped dark palette + reusable utility classes to `assets/css/app.css` (custom CSS, no `@apply`, per AGENTS.md) mirroring the reference tokens (`#0a0a0a`/`#1a1a1a`/`#2a2a2a` surfaces, `#06b6d4` cyan / `#14b8a6` teal accents, `#a855f7` purple agent accent, status greens/reds/ambers/purples, JetBrains-Mono mono stack), plus a deterministic **agent-color** helper in Elixir (`RepoBuilderWeb.AgentColors`) so each agent gets a stable hue from its id/name (used for the rail border, the event-row accent, and the swimlane squares).

2. **Richer typed components** — expand `RepoBuilderWeb.ConsoleComponents` (and reuse/extend `DashboardComponents`) with `attr/3`-validated components: a fuller `header_bar` (adds `WS Events`, glow toggle, `Cmd+K` hint), `agent_card` + `agent_rail_compact`, `filter_bar`, a richer `event_row` (line #, category badge, agent color, token/time meta, expandable), chat bubble components (`chat_message`, `thinking_bubble`, `tool_use_card`, `typing_indicator`), a `swimlane` with `event_square` + `event_detail_panel`, and a `global_command_input` modal.

3. **More LiveView state + handlers** — extend `ConsoleLive` to track filters (active categories set, active agent-name set, search string, regex?), `auto_follow?`, `rail_collapsed?`, `chat_width`, `command_open?`, per-agent counters (`responses/tools/hooks/thinking`), per-agent context tokens, recent chat-style message buffer, and a `selected_event` for the detail panel. Add `handle_event/3` clauses for every interaction and keep filtering correct with a **bounded in-assign event buffer** that backs `stream(:events, ..., reset: true)` re-streams on filter/search changes (streams are not enumerable/filterable — re-stream from the buffer).

4. **Minimal JS hooks** — add three small colocated/external hooks in `assets/js/app.js` for behaviors LiveView can't express server-side: keyboard shortcuts (`Cmd+K`/`Cmd+J`/`Esc`/`Enter`/`Shift+Enter` pushing events to the server), auto-scroll-to-bottom of the event stream + chat when `auto_follow?`, and clipboard copy for the command-input system-info rows.

Backend features the reference has but our platform does not (a conversational LLM **orchestrator**, server-side **autocomplete** suggestions, per-ADW-event **AI summaries**, and git **file-change** tracking) are **explicitly adapted, not faked** (see Notes → Adaptations / Non-Goals): the chat panel renders our **canonical events** as chat bubbles (text→message, `thinking?`→thinking bubble, `tool_call`→tool-use card) and renders the existing launch/interrupt/ADW controls; the command-input "system info" lists real harnesses/agents/the example ADW instead of LLM autocomplete.

## Relevant Files

Use these files to implement the feature:

- `lib/repo_builder_web/live/console_live.ex` — **rewrite/extend.** The single LiveView at `/`; already owns the `:events`/`:lanes` streams, the `console:events` + `dashboard:lanes` subscriptions, and one `handle_info` clause per canonical `Event` variant. We add state (filters, counters, context tokens, chat buffer, UI toggles, selected event) and the new `handle_event/3` clauses; we keep the existing runtime calls (`Session.Supervisor`, `WorkflowEngine`, `Agents`).
- `lib/repo_builder_web/components/console_components.ex` — **rewrite/extend.** Home of the console's `attr/3`-validated components. Add the richer header, agent card/compact rail, filter bar, event row, chat bubbles, swimlane + detail panel, and the command-input modal. Every public component keeps `@spec component(map()) :: Phoenix.LiveView.Rendered.t()` and `values:`-constrained enums.
- `lib/repo_builder_web/components/dashboard_components.ex` — **extend.** Reuse `cost_badge/1`; extend `swimlane_row/1` (or add `swimlane/1` + `event_square/1`) and keep `status_class/1`. Used by `WorkflowLive`/`DashboardLive` too, so keep changes additive/back-compatible.
- `lib/repo_builder/dashboard.ex` — **read; possibly extend.** PubSub seam: `subscribe/0` + `{:lane, lane}`, `subscribe_events/0` + `{:agent_event, agent_id, event}`. If swimlane squares need the emitting agent's step/lane context, add a typed helper here (no `Repo` access — it is a pure PubSub module).
- `lib/repo_builder/logs.ex` — **read; extend.** Context for `agent_logs`. Already exposes `list_recent/2` and `cost_rollup!/1`. Add an `@spec`'d `list_recent_global/1` (most-recent N rows across all agents, chronological) to seed the center stream + chat buffer on connect so a reconnect backfills instead of starting empty (§9 reconnect rule). The **only** `Repo` caller for logs.
- `lib/repo_builder/agents.ex` — **read.** `list_agents/0`, `create_agent/1`, `Agent.changeset/2`. The rail and "system info" list agents through this context.
- `lib/repo_builder/workflows.ex` — **read.** `list_recent_runs/0` seeds workflow lanes; the swimlane view groups runs by `current_step`/`status`.
- `lib/repo_builder/harness/registry.ex` — **read.** `known/0` populates the harness `<select>`s and the command-input "system info" harness list.
- `lib/repo_builder/harness/event.ex` — **read.** The closed 8-variant canonical sum type the chat bubbles, event rows, and swimlane squares map from. Do not edit.
- `assets/css/app.css` — **extend.** Add the console design tokens + utility classes (custom CSS only; keep the existing daisyUI/Tailwind import block intact; no `@apply`).
- `assets/js/app.js` — **extend.** Register the three new hooks on the `LiveSocket`.
- `mix.exs` — **extend.** Add `{:tidewave, "~> 0.5", only: :dev}` to `deps/0` (verify the latest 0.5.x on hex.pm before pinning, per §2). Run `mix deps.get`.
- `lib/repo_builder_web/endpoint.ex` — **extend.** Add `plug Tidewave` guarded to development only (place it before the router plug, inside the existing dev/`code_reloading?` block) so the runtime-intelligence MCP is served at `/tidewave/mcp` in dev. Confirm exact placement against Tidewave's install docs (use Firecrawl/`get_docs` if unsure).
- `lib/repo_builder_web/components/layouts.ex` — **read.** The console is full-bleed (it does not use `<Layouts.app>`); confirm `flash_group/1` + `theme_toggle/1` usage stays valid and the console forces the dark console theme.
- `lib/repo_builder_web/router.ex` — **read.** Confirm `live "/", ConsoleLive` route is unchanged.
- `test/repo_builder_web/live/test_orchestration_console_test.exs` — **read; extend** (existing console test) **or** add the new test file below.
- `test/support/conn_case.ex`, `test/support/data_case.ex`, `test/support/harness_fixtures.ex`, `test/support/mocks.ex` — **read.** Test setup/seams (registry override → `Fake`/`Mock`, `Phoenix.LiveViewTest`).
- `BUILD_PROMPT.md` §3 (typed style), §4 (canonical events), §9 (LiveView dashboard: streams, `assign_async`, reconnect, typed components), §10 (harness-blind) — **read.** Authority for all conventions.
- `AGENTS.md` — **read.** Phoenix v1.8 + LiveView + HEEx + Tailwind v4 (no `@apply`, no inline `<script>`, colocated hooks) rules.
- `.claude/commands/conditional_docs.md` — routes this task to `BUILD_PROMPT.md` §9 + `AGENTS.md` (LiveView/HEEx/Tailwind) and `ai_docs/typed-elixir-standard.md` (the always-on typed standard).

### Reference (read-only, for fidelity — not part of our repo)

- `…/orchestrator_3_stream/frontend/src/App.vue` — the 3-column grid + breakpoints.
- `…/frontend/src/components/{AppHeader,AgentList,EventStream,FilterControls,AdwSwimlanes,OrchestratorChat,GlobalCommandInput}.vue` and `components/event-rows/*`, `components/chat/*` — component structure + behaviors.
- `…/frontend/src/styles/global.css` — the exact color tokens replicated in our design system.
- `…/frontend/src/stores/orchestratorStore.ts`, `services/*.ts`, `composables/*.ts`, `config/constants.ts` — data model, event types, filter logic, keyboard shortcuts.
- `…/.understand-anything/knowledge-graph.json` — component/relationship map.
- `/home/robert/2026-06-16 20-17-34.mp4` — the recorded demo (visual ground truth).

### New Files

- `lib/repo_builder_web/agent_colors.ex` — `RepoBuilderWeb.AgentColors`: deterministic, stable per-agent color from id/name via `:erlang.phash2` over a fixed palette; returns `%{hex: String.t(), rgb: String.t(), class: String.t()}` (or just `hex/1` + `rgb/1`). Used for the rail border, event-row accent, swimlane squares, and the `--pulse-color` CSS var. Pure, fully `@spec`'d, no `Repo`.
- `test/repo_builder_web/live/test_orchestration_console_ui_test.exs` — `Phoenix.LiveViewTest` integration test for the new UI (mount, toggle view, toggle prompt, open command input, select agent, apply a category filter + search, render an event row / chat bubble / swimlane square from a broadcast canonical event, open the event detail panel). Asserts via `element/2`/`has_element?/2` on the IDs added in the templates.
- *(optional)* `test/repo_builder_web/agent_colors_test.exs` — unit test that `AgentColors` is deterministic and total over arbitrary binaries.

## Implementation Plan

### Phase 1: Foundation (design system + agent colors + context read)

Lay down the visual language and the pure helpers everything else consumes, with no behavior change yet.

- Add the console design tokens + utility classes to `assets/css/app.css` (scoped under a `.console` root class or `[data-console]`, so the rest of the app's daisyUI theming is untouched). Replicate the reference palette and a JetBrains-Mono-first mono stack. Define utility classes used by the components (`.console`, `.cns-panel`, `.cns-pill`, `.cns-chip`, `.cns-chip--active`, `.cns-event-row`, `.cns-ctx-bar`, `.cns-bubble`, `.cns-bubble--thinking`, `.cns-bubble--tool`, `.cns-square`, `.cns-square--{response,tool,thinking,hook,system}`, `.cns-cmd-overlay`, `@keyframes cns-pulse`, etc.). Keep custom CSS only — **no `@apply`** (AGENTS.md).
- Create `RepoBuilderWeb.AgentColors` with a small fixed palette (≈12 colors drawn from the reference accent set) and `@spec`'d `hex/1`, `rgb/1`, and `assigns/1` mapping any agent id/name to a stable color. Cover with `agent_colors_test.exs` (determinism + totality).
- Extend `RepoBuilder.Logs` with `@spec list_recent_global(pos_integer()) :: [AgentLog.t()]` (most-recent N across all agents, chronological) for connect-time backfill. Keep it the sole `Repo` caller.

### Phase 2: Core Implementation (typed components)

Build the presentational layer as `attr/3`/`slot/3` components in `ConsoleComponents` (+ `DashboardComponents` extensions), each independently renderable and `@spec`'d.

- **Header:** extend `header_bar/1` — add the `WS Events` pill (already-tracked `ws_count`), keep `Active/Running/Logs/Cost`, give the `LOGS/ADWS` toggle a two-segment look with a cyan glow on the active segment, and add a `Prompt (⌘K)` toggle with the hint.
- **Left rail:** `agent_card/1` (name + agent-color left border, status badge, `CONTEXT WINDOW Nk/200k` bar via `.cns-ctx-bar` width style, four counters 💬/🛠️/🪝/🧠, model + `cost_badge` footer) and `agent_rail_compact/1` (44px icon item: initial + status dot, pulse). The rail header carries the count + a collapse chevron.
- **Filter bar:** `filter_bar/1` — category chips (`RESPONSE`/`TOOL`/`THINKING`/`HOOK`, colored, toggle active), active agent-name pills (with an `×` to remove), a regex-capable search input, an `AUTO-FOLLOW` toggle (cyan when on), a `CLEAR ALL` button. Pure presentation; emits `phx-click`/`phx-change` events.
- **Event row:** richer `event_row/1` — `[line# | category badge | agent (colored) | content | meta(tokens + time)]` grid, agent-color left accent, dim+italic when `thinking?`, click-to-expand (full body in a `<pre>`). Drive expand via a `expanded_ids` set in the LV (clicking pushes `toggle_event`).
- **Chat bubbles:** `chat_message/1` (user/orchestrator, label + `HH:MM`, `whitespace-pre-wrap` content), `thinking_bubble/1` (purple, "🤔 ORCHESTRATOR THINKING", italic mono, expandable past N chars), `tool_use_card/1` (amber, "🔧 ORCHESTRATOR ACTION", bold tool name + pretty-printed JSON params via `Jason.encode!(…, pretty: true)`), `typing_indicator/1` (three-dot animation). Wrap them in a chat container with a header (width toggle + cost/context indicator) and the existing launch/interrupt/ADW forms beneath (the command panel stays — restyled).
- **Swimlanes:** add `swimlane/1` (one workflow run: key/label + status badge + duration) containing horizontally-scrollable step columns of `event_square/1` (12px, colored by canonical event type, hover `title` tooltip with summary, `phx-click="open_event"`), and `event_detail_panel/1` (right slide-out: summary hero, type/category/step/time grid, pretty JSON payload, close `×`). Keep `swimlane_row/1` working for the other LiveViews.
- **Command input modal:** `global_command_input/1` — bottom-anchored overlay (`.cns-cmd-overlay`, `z-50`, backdrop blur), a large textarea bound to the same `run`/send flow, and a "system info" panel listing harnesses (`Registry.known/0`), agents, and the example ADW as clickable chips that append text (via a JS hook event). Hidden unless `@command_open?`.

### Phase 3: Integration (LiveView state, handlers, hooks, theme)

Wire the components to real state + interactions, keeping streams flat and the runtime calls intact.

- Extend `ConsoleLive` `mount/3` assigns: `active_categories` (MapSet, default all), `active_agents` (MapSet of names), `search`, `regex?`, `auto_follow?` (default `true`), `rail_collapsed?` (false), `chat_width` (`:sm`), `command_open?` (false), `expanded_ids` (MapSet), `counters` (`%{agent_id => %{responses, tools, hooks, thinking}}`), `context_tokens` (`%{agent_id => non_neg_integer}`), `messages` (bounded list for the chat buffer), `event_buffer` (bounded list of recent event rows for re-filtering), `selected_event` (nil). On connect, seed `event_buffer`/stream + `messages` from `Logs.list_recent_global/1` and seed lanes/cost as today.
- Update the per-variant `handle_info/2` clauses to additionally: bump the right `counters` bucket and `context_tokens`, append a chat message/thinking/tool-use entry to `messages` (bounded), push into `event_buffer` (bounded), and `stream_insert` the event row **only if it passes the active filters** (otherwise keep it in the buffer but not the stream). Trigger an `auto_follow` scroll via `push_event` to the JS hook.
- Add `handle_event/3` clauses: `toggle_category`, `toggle_agent_filter`, `set_search`, `toggle_regex`, `toggle_auto_follow`, `clear_filters`, `toggle_rail`, `set_chat_width`, `toggle_command`, `toggle_event` (expand), `open_event`/`close_event` (detail panel), plus keyboard-driven `command:toggle`/`view:toggle`/`command:close` from the hook. On any filter/search change, recompute the filtered list from `event_buffer` and `stream(:events, filtered, reset: true)` (streams aren't filterable — re-stream).
- Implement the regex search safely: `Regex.compile/1` (never `compile!`) and fall back to case-insensitive substring on `{:error, _}`; never crash on a bad pattern.
- Add the JS hooks in `assets/js/app.js`: `KeyboardShortcuts` (document-level `keydown`: ⌘K/Ctrl+K→`command:toggle`, ⌘J/Ctrl+J→`view:toggle`, `Esc`→`command:close`; `Enter`/`Shift+Enter` handled in the textarea), `AutoScroll` (scroll a container to bottom on `handleEvent("scroll:bottom")` / on update when enabled), `ClipboardCopy` (copy `data-copy` text). Use colocated hooks where they live inside HEEx; otherwise external hooks registered on the `LiveSocket`. **No inline `<script>`** (AGENTS.md).
- Force the console's dark theme: render the root with `class="console"` (+ `data-theme="dark"` if needed) so the design tokens apply regardless of the global light/dark toggle; keep `Layouts.flash_group/1` and `Layouts.theme_toggle/1` available.

## Step by Step Tasks

IMPORTANT: Execute every step in order, top to bottom.

### 1. Read the authority + reference, confirm conventions
- Re-read `BUILD_PROMPT.md` §3, §4, §9, §10; `AGENTS.md` (LiveView/HEEx/Tailwind/streams/hooks rules); `ai_docs/typed-elixir-standard.md`.
- Re-read the reference `App.vue`, `EventStream.vue`/`FilterControls.vue`, `AgentList.vue`, `OrchestratorChat.vue` + `chat/*`, `AdwSwimlanes.vue`, `GlobalCommandInput.vue`, and `styles/global.css` to lock the exact layout, classes, and tokens.
- **Research aid:** when uncertain about exact LiveView 1.2 / Phoenix 1.8 / Tailwind v4 syntax or a reference UI pattern, use the **Firecrawl** MCP (`firecrawl_scrape`/`firecrawl_search`) to fetch the authoritative doc page before coding — don't guess. Prefer Tidewave's `get_docs`/`get_source_location` for exact-version, in-project library docs once Tidewave is installed (next task).

### 1b. Install Tidewave (dev dependency) + `plug Tidewave`
- Add `{:tidewave, "~> 0.5", only: :dev}` to `mix.exs` `deps/0` (verify the latest 0.5.x on hex.pm first), run `mix deps.get`.
- Add `plug Tidewave` to `lib/repo_builder_web/endpoint.ex`, guarded to development (inside the existing dev/`code_reloading?` block, before the router plug). Confirm exact placement via Tidewave's install docs (Firecrawl/`get_docs`).
- Verify it serves: `mix compile --warnings-as-errors` clean, then with the server running confirm `http://localhost:4000/tidewave/mcp` is reachable. This unlocks `project_eval`/`get_logs`/`get_source_location` for the runtime validation in Task 12.

### 2. Add the design system to `assets/css/app.css`
- Append a console section with the replicated tokens (scoped under `.console`) and the `.cns-*` utility classes + `@keyframes cns-pulse`. Keep the existing daisyUI/Tailwind block intact. No `@apply`.
- Verify the bundle builds: `mix assets.build`.

### 3. Create `RepoBuilderWeb.AgentColors` (+ unit test)
- Implement `hex/1`, `rgb/1`, `assigns/1` over a fixed palette using `:erlang.phash2`. Fully `@spec`'d; pure.
- Add `test/repo_builder_web/agent_colors_test.exs` (deterministic, total over arbitrary binaries). `async: true`.

### 4. Extend `RepoBuilder.Logs` for connect-time backfill
- Add `@spec list_recent_global(pos_integer()) :: [AgentLog.t()]` (most-recent N across all agents, chronological). Keep it the only `Repo` caller. (Unit-covered by the existing persistence test patterns; add a focused case if cheap.)

### 5. Write the LiveView integration test FIRST (red), then iterate
- Create `test/repo_builder_web/live/test_orchestration_console_ui_test.exs`:
  - mount `/` with `live/2`; assert header IDs (`#console-header`, `#stat-active`, `#stat-running`, `#stat-logs`, `#stat-ws`, `#stat-cost`, `#view-toggle`, `#prompt-toggle`).
  - `render_click(view, "#view-toggle")` → swimlanes container visible (`#swimlanes:not(.hidden)`), event stream hidden.
  - `render_click(view, "#prompt-toggle")` → `#command-input` modal present.
  - seed an agent (fixture) → assert an `#agent-card-<id>` (or compact `#agent-<id>`) renders with a status badge + context bar element.
  - `render_click` a category chip (`#filter-tool`) → assert it gains the active class; `render_change` the search input → assert the stream re-renders.
  - broadcast canonical events onto `console:events` (`Dashboard.broadcast_event/2`) for `TextDelta{thinking?: false}`, `TextDelta{thinking?: true}`, `ToolCall{}`, `Usage{}`, `Done{}` → assert an `#ev-*` row with the right category badge, a chat `thinking` bubble, a `tool-use` card, the `Logs`/`WS Events` pills incrementing, and the cost pill updating.
  - in `adws` mode, broadcast a `{:lane, lane}` + an event → assert a `.cns-square` renders and `render_click("[phx-click=open_event]")` opens `#event-detail-panel`.
- Drive the registry to `Fake`/`Mock` via the override seam (`conn_case`/`harness_fixtures`); `async: true` with `Mox.allow/3` for session-spawned calls if any are exercised.

### 6. Expand `ConsoleComponents` (typed components)
- Implement/extend `header_bar/1`, `agent_card/1`, `agent_rail_compact/1`, `filter_bar/1`, `event_row/1`, `chat_message/1`, `thinking_bubble/1`, `tool_use_card/1`, `typing_indicator/1`, `global_command_input/1`. Every public component: `@spec component(map()) :: Phoenix.LiveView.Rendered.t()`, `attr/3` with `values:` on enums, stable DOM ids.

### 7. Extend `DashboardComponents` (swimlane squares + detail panel)
- Add `swimlane/1`, `event_square/1`, `event_detail_panel/1`; keep `swimlane_row/1`, `cost_badge/1`, `status_class/1` back-compatible (other LiveViews depend on them). `@spec` all new public components.

### 8. Rewrite/extend `ConsoleLive` state + render
- Add the new assigns (Phase 3) and the full render tree (header, rail with collapse, center logs/swimlanes with filter bar + detail panel, restyled right chat/command panel, command-input modal). Keep both stream containers mounted and toggled via `hidden` (existing comment/rule). Root element gets `class="console"`.

### 9. Add `ConsoleLive` handlers + filtering
- Add all `handle_event/3` clauses and update the per-variant `handle_info/2` clauses (counters, context tokens, chat buffer, event buffer, filtered `stream_insert`, auto-follow `push_event`). Implement safe regex search (`Regex.compile/1`, substring fallback). Re-stream with `reset: true` from the buffer on filter/search/clear.

### 10. Add JS hooks in `assets/js/app.js`
- Register `KeyboardShortcuts`, `AutoScroll`, `ClipboardCopy` on the `LiveSocket` (or colocated where inside HEEx). Wire `pushEvent` for `command:toggle`/`view:toggle`/`command:close`; `handleEvent("scroll:bottom", …)` for auto-follow. No inline `<script>`.

### 11. Make the integration test pass (green) + add focused component coverage
- Iterate on components/handlers until `test_orchestration_console_ui_test.exs` is green. Add any small `ConsoleComponents`/`AgentColors` unit assertions still missing.

### 12. Manual + runtime verification (Tidewave)
- Start the app (`scripts/pg.sh start` then `iex -S mix phx.server`); open `http://localhost:4000`.
- Use Tidewave MCP `get_logs` to confirm no LiveView crashes on mount/interaction; optionally `project_eval` to broadcast a few `Dashboard.broadcast_event/2` events and watch the stream/chat update live.
- Optionally capture a screenshot of `http://localhost:4000` (Tidewave Web vision mode, else Playwright MCP) as visual proof and eyeball it against `/home/robert/2026-06-16 20-17-34.mp4`.

### 13. Run the full Validation Commands (zero regressions)
- Run every command in **Validation Commands**; fix anything red until all are green.

## Testing Strategy

### Unit Tests
- `RepoBuilderWeb.AgentColors`: determinism (same input → same color across calls), totality (never raises on arbitrary binaries / empty string), palette membership.
- `RepoBuilder.Logs.list_recent_global/1`: returns chronological, bounded, across agents (extend persistence test patterns).
- `ConsoleComponents`/`DashboardComponents`: where practical, render components in isolation and assert key classes/ids (`render_component/2`) — e.g. `filter_bar` active chip class, `event_row` category badge + thinking dim, `tool_use_card` pretty JSON, `swimlane`/`event_square` color-by-type, `event_detail_panel` content.

### Integration Tests (`Phoenix.LiveViewTest`)
- Full flow in `test_orchestration_console_ui_test.exs` per Task 5: header pills + counts, view toggle, prompt/command toggle, agent select + filter, category chip + search re-stream, canonical-event → event row / chat bubble / tool card / cost+counter updates, swimlane square + detail panel open/close. Assert on element IDs, never raw HTML (AGENTS.md).

### Edge Cases
- **No agents / no events:** rail shows "No agents yet."; stream shows the empty-state placeholder; pills read `0`; cost reads `—` (nil unpriced, never `$0`).
- **Unpriced cost:** `Usage`/`Done` with `cost_usd: nil` must keep the cost pill at `—` (never coerce nil → `Decimal.new(0)`), while a priced-at-zero `0.0` shows `$0`.
- **Invalid regex in search:** must not crash — fall back to substring match.
- **Filter excludes all:** stream empties (re-stream `reset: true`) but `event_buffer` retains rows so clearing the filter restores them; `Logs`/`WS Events` counters keep counting regardless of filter.
- **Reconnect mid-stream:** `mount` re-seeds the stream + chat from `Logs.list_recent_global/1` (events broadcast while disconnected are gone — §9); the view resumes without duplicate subscriptions (subscribe only when `connected?`).
- **Thinking vs text:** `TextDelta{thinking?: true}` routes to the thinking bubble + the `THINKING` category; `false` → message + `RESPONSE`.
- **Rail collapsed / chat width:** layout grid columns change without losing stream containers (both stay mounted; toggle via class only).
- **Long content:** event rows and bubbles expand on click; very long bodies don't break layout (`break-all`/`pre-wrap`, scroll).
- **Keyboard shortcuts with focus in textarea:** `Enter` sends, `Shift+Enter` newlines, `⌘K`/`Esc` still toggle/close.

## Acceptance Criteria
- The console at `/` renders as a dark, three-pane layout matching the reference (header / left rail / center / right chat) with the cyan/teal/purple design tokens and a mono stack.
- Header shows live `Active`, `Running`, `Logs`, `WS Events`, and `Cost` pills (cost `—` when unpriced), a glowing `LOGS ⇄ ADWS` toggle, and a `Prompt (⌘K)` toggle.
- Left rail shows per-agent cards with a deterministic agent-color accent, a status badge, a `CONTEXT WINDOW Nk/200k` bar, four category counters, and a model + cost footer; the rail collapses to a 48px icon rail and pulses on activity.
- Center `logs` mode supports category-chip filtering, agent-name filter pills, regex/substring search, auto-follow, and clear-all; rows show line number, colored category badge, agent color, content, token+time meta, and expand on click — all backed by flat-memory streams (`reset:`-re-streamed on filter change).
- Center `adws` mode renders one swimlane per workflow run with step columns of colored event squares; hovering shows a tooltip and clicking opens a right-side event detail panel.
- Right panel renders chat-style user/orchestrator/thinking/tool-use entries (mapped from canonical events) with a typing indicator, a width toggle, and a header cost/context indicator, above the (restyled) launch / Interrupt / Launch-ADW controls.
- `Cmd+K` opens a bottom command-input modal with a "system info" panel (harnesses/agents/example ADW); `Cmd+J` toggles the view; `Esc` closes; `Enter`/`Shift+Enter` send/newline.
- The console is harness-blind and touches `Repo` only through contexts; runtime calls (`Session.Supervisor`, `WorkflowEngine`) are unchanged.
- `test_orchestration_console_ui_test.exs` passes, and **all Validation Commands are green** with zero regressions.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix deps.get` — resolves the newly added `{:tidewave, "~> 0.5", only: :dev}` dependency (markdown rendering is intentionally deferred — see Notes).
- (dev, manual) With the server running, confirm `http://localhost:4000/tidewave/mcp` responds — proves `plug Tidewave` is wired — then use Tidewave `get_logs`/`project_eval` for the runtime check in Task 12.
- `mix compile --warnings-as-errors` — compile clean; the gradual set-theoretic type checker + `warnings_as_errors` pass.
- `mix assets.build` — Tailwind + esbuild build the updated CSS/JS bundles without error.
- `mix test test/repo_builder_web/live/test_orchestration_console_ui_test.exs` — the new LiveView integration test passes.
- `mix test test/repo_builder_web/agent_colors_test.exs` — the agent-color unit test passes.
- `mix test --warnings-as-errors` — the full ExUnit suite passes (no regressions in the other console/dashboard tests).
- `mix format --check-formatted` — formatting clean.
- `mix credo --strict` — lint clean, including "every public function has an `@spec`".
- `mix dialyzer` — `@spec`/contract checking clean, no new warnings, no stale ignore filters.

## Notes

### Adaptations / Non-Goals (intentional, to avoid faking backend we don't have)
- **No conversational LLM orchestrator.** The reference `OrchestratorChat` is a back-and-forth with an LLM "orchestrator agent" plus server-side autocomplete. We have **no** such concept. Our right panel keeps the existing launch/interrupt/ADW controls but **renders our canonical events as chat bubbles** (text→message, `thinking?`→thinking bubble, `tool_call`→tool-use card) for the same *look and feel*. We do **not** add an LLM chat loop, a `/send_chat` endpoint, or autocomplete suggestions in this feature.
- **No per-ADW-event AI summaries** and **no git file-change tracking** (`FileChangesDisplay`). Swimlane squares use the canonical event `type`/`reason` + a short `inspect`-derived summary in the detail panel; file changes are out of scope (our events don't carry diffs).
- **Markdown rendering deferred.** The reference renders markdown in bubbles; we render `whitespace-pre-wrap` text and pretty-printed JSON to avoid adding a dependency. If desired later, add `{:mdex, "~> 0.x"}` (verify latest on hex.pm) behind a `safe_markdown/1` helper — tracked as a follow-up, **not** part of this plan.
- **Web-layer only.** No schema/migration changes; no new runtime processes. The single context addition is `Logs.list_recent_global/1` for reconnect backfill.

### New dependency added (reported per planning convention)
- `{:tidewave, "~> 0.5", only: :dev}` — Phoenix runtime-intelligence MCP, served at `/tidewave/mcp` via `plug Tidewave` in `endpoint.ex` (development only). Verify the latest 0.5.x on hex.pm before pinning (§2). It is `only: :dev`, so it is **not** in the prod release and does not affect the runtime contract; it exists purely to give the implementer/operator `project_eval`/`get_logs`/`execute_sql_query`/`get_source_location` during this build and beyond. This reconciles the project memory (`tidewave-tooling`) and `conditional_docs.md`, which already assume Tidewave is present, with the actual `mix.exs` (where it was missing).

### Research tooling
- **Firecrawl** (MCP, not a project dependency) is used as a *research aid only* — to scrape/verify exact LiveView 1.2 / Phoenix 1.8 / Tailwind v4 docs or reference patterns when uncertain during implementation. It adds no code or dependency to the repo.

### Conventions to honor
- Typed standard (§3): `@spec` on every public function (`@impl` callbacks exempt), `values:`-constrained `attr/3` enums, `typedstruct`/`@enforce_keys` for any new struct, precise types, tagged-tuple returns, build `--warnings-as-errors`, Dialyzer green.
- LiveView (§9 / AGENTS.md): subscribe only when `connected?`; use **streams** for both feeds (no large lists in assigns) with stable `dom_id`s and negative-`limit` pruning; re-stream with `reset: true` when filtering (streams aren't enumerable); both stream containers stay mounted and are toggled via `hidden`; give every key element a unique DOM id for tests; never test against raw HTML; never use deprecated `live_patch`/`phx-update="append"`; no inline `<script>` (use colocated/external hooks); Tailwind v4 + custom CSS (no `@apply`).
- Keep `DashboardComponents` changes additive so `WorkflowLive`/`DashboardLive`/`SystemLogsLive` keep working.

### Filtering design note
Because LiveView streams are not enumerable/filterable, the LV keeps a **bounded** `event_buffer` (≈last 500 rows) in an assign alongside the stream. New events append to both (the stream only if they pass current filters). On any filter/search change, the LV recomputes the filtered list from the buffer and calls `stream(:events, filtered, reset: true)`. This keeps the hot path append-only and flat while still supporting interactive filtering — matching the reference's client-side filter behavior without ballooning socket memory.

### Reference fidelity targets (from `global.css`)
Surfaces `#0a0a0a/#1a1a1a/#2a2a2a/#1e1e1e`; text `#ffffff/#b0b0b0/#6b7280/#4b5563`; accents cyan `#06b6d4`, teal `#14b8a6`, hover `#0891b2`; agent purple `#a855f7` (bg tint `#2d1b4e`); status success `#10b981`, error `#ef4444`, warning `#f59e0b`, info `#3b82f6`, debug/thinking purple `#8b5cf6`; chat user bubble `#1e3a5f`, orchestrator `#2a2a2a`; borders `#333/#404040`; mono `'JetBrains Mono','Fira Code',monospace`; context-window 200k max; agent "pulse" ≈335ms background fade.
