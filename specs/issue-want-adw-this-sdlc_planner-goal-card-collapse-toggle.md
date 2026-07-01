# Feature: Goal-Card Collapse Toggle (vertical up/down drawer for the orchestrator autonomy panel)

## Metadata
issue_number: `want`
adw_id: `this`
issue_json: `goal`

## Feature Description
Add a **vertical up/down collapse toggle** to the orchestrator "goal card" drawer at the bottom of
the right-hand Orchestrator console column. The drawer holds the autonomy panel (Goal / 🎯 FOCUS /
Done-when / status / last-progress), the Workstreams panel, and the queued-messages list. Today that
drawer is always expanded and, when the goal text and workstreams are long, it eats a fixed slice of
the column (capped at `max-height: 45%`), squeezing the orchestrator chat above it.

This feature adds a slim, full-width **handle bar** at the top edge of that drawer with a single
chevron control — **▼ when expanded** (click to collapse the drawer downward) and **▲ when
collapsed** (click to expand it back up). When collapsed, the drawer body (autonomy panel +
workstreams + queued) is hidden and the chat panel reclaims the full column height; the handle bar
stays visible and shows a **compact one-line summary** — the current `🎯 focus` if set, else the
goal — so the operator can still glance at "what is it working on" without expanding. Collapse state
is session-local (a socket assign), mirroring the existing left-rail collapse (`@rail_collapsed?`)
and chat-width (`@chat_width`) toggles, which also reset on mount.

The value: the operator controls how much vertical real-estate the goal card takes. When they want a
tall scroll of the orchestrator's reasoning/tool stream, one click collapses the goal card to a slim
glanceable strip; when they want to see the full goal/focus/workstreams state, one click brings it
back — no lost context, since the collapsed strip still surfaces the live focus.

## User Story
As an **operator watching an autonomous orchestrator in the console**
I want to **collapse and expand the goal-card drawer at the bottom of the Orchestrator column with a
single up/down toggle**
So that **I can reclaim vertical space for the orchestrator's chat/tool stream when I want it, while
still glancing at the current focus from the collapsed strip and restoring the full goal/workstreams
view whenever I need it.**

## Problem Statement
The bottom orchestrator drawer (autonomy panel + Workstreams panel + queued messages) is always
rendered when there is an active goal or open workstreams. It is bounded to `max-height: 45%` of the
column, so it permanently consumes up to ~45% of the right column even when the operator is focused
on the chat stream above it. There is no way to hide it to give the chat full height, nor a compact
"what is it doing right now" strip when space is tight. Every other space-consuming region in the
console (the left agent rail, the chat column width) has an operator toggle; the goal-card drawer
does not.

## Solution Statement
Introduce a **session-local `@goal_card_collapsed?` boolean assign** and a **`toggle_goal_card`
LiveView event**, exactly mirroring the existing `@rail_collapsed?` / `toggle_rail` pattern
(`console_live.ex`). Restructure the bottom drawer (added when the goal/focus surface landed) into:

1. a **handle bar** — a full-width, keyboard-focusable `<button id="toggle-goal-card">` bound to
   `phx-click="toggle_goal_card"`, rendering `▼` when expanded and `▲` when collapsed, plus (only
   when collapsed) a truncated one-line summary from a new typed helper `goal_card_summary/1`
   (the `🎯 focus`, else the goal); and
2. the **drawer body** — the existing `autonomy_panel` + `workstreams_panel` + `queued_messages`,
   rendered `:if={not @goal_card_collapsed?}` inside the scroll region.

The handle bar renders only when there is something to toggle (an active ledger, ≥1 workstream, or a
non-empty queue), so an empty orchestrator shows no stray strip — the same "render nothing when
empty" discipline the panels already follow. No new DB state, no migration, no new dependency: this
is a pure LiveView/CSS + typed-function-component change, reusing the drawer container introduced
when the two-level focus surface shipped.

## Relevant Files
Use these files to implement the feature:

- `lib/repo_builder_web/live/console_live.ex` — the console LiveView. **Add** the
  `goal_card_collapsed?: false` assign in `mount/3` (near `rail_collapsed?`/`chat_width`); **add** a
  `handle_event("toggle_goal_card", ...)` clause (mirroring `handle_event("toggle_rail", ...)` at
  ~line 1546); **restructure** the bottom drawer in `render/1` (the
  `<div class="shrink-0 overflow-y-auto" style="max-height: 45%">` inside the right
  `aside[aria-label="Orchestrator console"]`, ~line 3784) into a handle bar + conditionally-rendered
  body.
- `lib/repo_builder_web/components/console_components.ex` — typed function components for the console.
  **Add** a `goal_card_summary/1` (or a small `goal_card_handle/1`) function component with an
  `@spec`, `attr`s, and a `Phoenix.LiveView.Rendered.t()` return — the compact collapsed-state
  summary line (truncated focus-or-goal). Reuse the existing chip/typography styling
  (`autonomy_panel/1` is right above it for reference).
- `test/repo_builder_web/live/test_goal_card_toggle_test.exs` — **new** `Phoenix.LiveViewTest`
  integration test (see New Files).

Conditional docs consulted (per `.claude/commands/conditional_docs.md`):
- `ai_docs/typed-elixir-standard.md` — **(always)** the enforced typed standard (`@spec` on every
  public function incl. function components, precise types, no stray `any()`/`map()`).
- `BUILD_PROMPT.md` §9 (LiveView dashboard) + `AGENTS.md` (Phoenix v1.8 + LiveView guidelines:
  prefer `element/2`/`has_element?` assertions, HEEx conventions, `phx-click` server events).

### New Files
- `test/repo_builder_web/live/test_goal_card_toggle_test.exs` — a `Phoenix.LiveViewTest` test that
  mounts `ConsoleLive` for an orchestrator with an active goal + a focus + a workstream, asserts the
  drawer body (`#autonomy-panel`, `#orchestrator-focus`, `#workstreams-panel`) is visible and the
  handle shows `▼`, clicks `#toggle-goal-card`, asserts the body is gone, the handle shows `▲`, and
  the collapsed summary contains the focus text; clicks again and asserts the body returns.

## Implementation Plan
### Phase 1: Foundation
Add the session-local collapse state: the `@goal_card_collapsed?` assign in `mount/3` and the
`toggle_goal_card` event handler that flips it — the exact shape of the existing `@rail_collapsed?` /
`toggle_rail` pair. No DB, no migration. This phase compiles and the assign threads through render
with no visual change yet (default expanded).

### Phase 2: Core Implementation
Add the `goal_card_summary/1` typed function component (the collapsed one-line focus-or-goal strip)
and restructure the bottom drawer in `render/1` into a handle bar (the `▼`/`▲` toggle button, with
the summary shown only when collapsed) plus the drawer body rendered `:if={not
@goal_card_collapsed?}`. Gate the whole handle bar on "there is something to show" so an empty
orchestrator renders nothing.

### Phase 3: Integration
Wire the LiveView integration test and run the full green gate. Confirm the collapse/expand cycle
works live (the chat panel reclaims height on collapse, the collapsed strip surfaces the live focus),
and that existing autonomy/workstreams/focus tests still pass unchanged (the panels keep their ids
and only move under the `:if`).

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Assign — `goal_card_collapsed?` in mount
- In `lib/repo_builder_web/live/console_live.ex` `mount/3`, add `goal_card_collapsed?: false` to the
  assign map next to `rail_collapsed?: false` and `chat_width: :sm` (~line 138). Default **expanded**
  (`false`) so the disconnected/static render is unchanged and back-compatible.

### 2. Event — `toggle_goal_card`
- Add a `handle_event/3` clause immediately after `handle_event("toggle_rail", …)` (~line 1546):
  ```elixir
  def handle_event("toggle_goal_card", _params, socket),
    do: {:noreply, assign(socket, :goal_card_collapsed?, not socket.assigns.goal_card_collapsed?)}
  ```
  `@impl true` is already declared on the `handle_event/3` group — do NOT add a second `@spec`
  (LiveView callbacks are `@impl`-exempt from the `@spec` rule).

### 3. Component — `goal_card_summary/1` (collapsed strip)
- In `lib/repo_builder_web/components/console_components.ex`, just above or below `autonomy_panel/1`,
  add a typed function component for the collapsed one-liner:
  - `attr :ledger, :map, default: nil` and `attr :workstreams, :list, default: []`.
  - `@spec goal_card_summary(map()) :: Phoenix.LiveView.Rendered.t()`.
  - Render a single truncated line: the ledger's `🎯 focus` when set, else `Goal: <goal>`, else a
    workstream count fallback (`N workstreams`). Use `truncate`/`whitespace-nowrap` + the existing
    `--cns-text-2` muted style so it reads as a strip, not a panel. Give it a stable id
    `id="goal-card-summary"` for the test.
  - Add a private `@spec`'d helper (e.g. `defp summary_text(ledger, workstreams) :: String.t()`) so
    the string logic is typed and testable; keep it total (handles nil ledger + empty list).

### 4. Render — restructure the bottom drawer into handle + body
- In `console_live.ex` `render/1`, locate the bottom drawer inside
  `aside[aria-label="Orchestrator console"]` — currently:
  ```heex
  <div class="shrink-0 overflow-y-auto" style="max-height: 45%">
    <.autonomy_panel ledger={@ledger} holding_reason={@orchestrator_holding_reason} />
    <.workstreams_panel workstreams={@workstreams} context_tokens={@orchestrator_context} />
    <.queued_messages busy?={…} depth={…} queued={…} />
  </div>
  ```
- Replace it with a handle bar + conditional body, rendered only when there is something to toggle
  (an active ledger, ≥1 workstream, a non-empty queue, or a holding reason):
  ```heex
  <div :if={goal_card_present?(assigns)} class="shrink-0 flex min-h-0 flex-col">
    <button
      type="button"
      id="toggle-goal-card"
      phx-click="toggle_goal_card"
      title={if @goal_card_collapsed?, do: "Expand goal card", else: "Collapse goal card"}
      class="flex w-full items-center gap-2 border-t px-3 py-1 text-[0.7rem]"
      style="border-color: var(--cns-border)"
    >
      <span aria-hidden="true">{if @goal_card_collapsed?, do: "▲", else: "▼"}</span>
      <.goal_card_summary :if={@goal_card_collapsed?} ledger={@ledger} workstreams={@workstreams} />
    </button>
    <div :if={not @goal_card_collapsed?} class="min-h-0 overflow-y-auto" style="max-height: 45vh">
      <.autonomy_panel ledger={@ledger} holding_reason={@orchestrator_holding_reason} />
      <.workstreams_panel workstreams={@workstreams} context_tokens={@orchestrator_context} />
      <.queued_messages
        busy?={@orchestrator_queue.busy?}
        depth={@orchestrator_queue.depth}
        queued={@orchestrator_queue.queued}
      />
    </div>
  </div>
  ```
- Add a private `@spec goal_card_present?(map()) :: boolean()` helper in `console_live.ex` (near the
  other render helpers like `rail_width/1`/`chat_col/1`) returning `true` when
  `assigns.ledger != nil or assigns.workstreams != [] or assigns.orchestrator_holding_reason != nil
  or assigns.orchestrator_queue.queued != []` — so the handle never shows on a truly empty
  orchestrator. Keep the chevron glyphs as the collapse affordance (▼ = collapse down, ▲ = expand
  up) to satisfy the "vertical up/down" request.
- Preserve the flex-column layout the drawer already lives in (the aside is `flex min-h-0 flex-col`;
  the chat wrapper is `flex-1 min-h-0`), so collapsing the body lets the chat wrapper reclaim the
  freed height automatically.

### 5. LiveView integration test
- Create `test/repo_builder_web/live/test_goal_card_toggle_test.exs` using `Phoenix.LiveViewTest`
  (mirror `test_orchestrator_focus_test.exs` / `console_autonomy_test.exs` setup —
  `Orchestrators.get_or_create_default/0`, `Ledgers.upsert_goal/2`, `Ledgers.set_focus/2`,
  `Workstreams.create_workstream/2`):
  - Mount `ConsoleLive` at `/`. Assert expanded by default: `has_element?(view, "#toggle-goal-card")`
    and `has_element?(view, "#autonomy-panel")` and `has_element?(view, "#orchestrator-focus")` and
    the handle renders `▼`.
  - `render_click(element(view, "#toggle-goal-card"))`; assert collapsed:
    `refute has_element?(view, "#autonomy-panel")`, the handle renders `▲`,
    `has_element?(view, "#goal-card-summary")`, and the summary contains the focus text.
  - Click again; assert the body returns (`has_element?(view, "#autonomy-panel")` and
    `#workstreams-panel`). Prefer `element/2`/`has_element?` over raw HTML (per `AGENTS.md`).
  - Optionally capture a Playwright screenshot of `http://localhost:4000` in both states for visual
    proof (non-blocking).

### 6. Validate
- Run every command in **Validation Commands** below and confirm zero failures / zero new warnings.
- Manually (or via Playwright) confirm on `http://localhost:4000` that clicking the toggle collapses
  the drawer (chat reclaims height, collapsed strip shows the `🎯 focus`) and expands it back.

## Testing Strategy
### Unit Tests
- **LiveView (`test_goal_card_toggle_test.exs`)**: default-expanded render shows the drawer body and
  a `▼` handle; `toggle_goal_card` collapses (body gone, `▲` handle, `#goal-card-summary` with the
  focus text) and expands again (body back). This is the primary coverage — the feature is UI state.
- **Component (optional, `console_components` test)**: `goal_card_summary/1` renders the focus when a
  ledger focus is set, falls back to the goal when focus is nil, and to the workstream-count string
  when there is no ledger — asserting `summary_text/2` totality across the three inputs.

### Edge Cases
- **Empty orchestrator** (no ledger, no workstreams, no queued, no holding reason): the handle bar and
  drawer render **nothing** (`goal_card_present?/1` is false) — no stray toggle strip.
- **Collapsed with no focus**: the summary falls back to `Goal: …`; with no ledger at all (only
  workstreams/queue), it falls back to the workstream-count / a neutral label — never a blank strip.
- **Live update while collapsed**: a `ledger_updated` / `workstreams` broadcast updates `@ledger` /
  `@workstreams`; because the collapsed summary reads those assigns, the strip reflects a new focus
  even while collapsed (no expand required). Assert (or at least manually verify) the summary text
  changes after a broadcast in the collapsed state.
- **Reconnect / remount**: collapse state is session-local and resets to expanded on mount (matches
  `@rail_collapsed?`/`@chat_width`) — documented, not a bug.
- **Long focus/goal text**: the summary is single-line truncated (no wrap), so a long goal cannot
  blow out the handle bar height.

## Acceptance Criteria
- A `▼`/`▲` toggle (`#toggle-goal-card`) appears at the top edge of the bottom orchestrator drawer
  whenever there is a goal card to show, and is absent on an empty orchestrator.
- Clicking it collapses the drawer body (autonomy panel + Workstreams panel + queued messages hidden)
  and the orchestrator chat reclaims the freed vertical space; clicking again restores it.
- While collapsed, a compact one-line summary (`#goal-card-summary`) surfaces the current `🎯 focus`
  (else the goal), and updates live on `ledger_updated` / `workstreams` broadcasts.
- The existing autonomy/focus/workstreams panels keep their DOM ids (`#autonomy-panel`,
  `#orchestrator-focus`, `#workstreams-panel`) and all their current tests pass unchanged.
- Collapse state is a session-local assign (`@goal_card_collapsed?`), mirroring `@rail_collapsed?`;
  no DB, no migration, no new dependency.
- A `Phoenix.LiveViewTest` proves the expand→collapse→expand cycle and the collapsed summary.
- The full green gate passes with zero regressions and no new Dialyzer warnings or stale ignores.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix test test/repo_builder_web/live/test_goal_card_toggle_test.exs` — the new toggle integration
  test.
- `mix test test/repo_builder_web/live/test_orchestrator_focus_test.exs` — the focus surface still
  renders (drawer body ids unchanged).
- `mix test test/repo_builder_web/live/console_autonomy_test.exs test/repo_builder_web/live/test_workstreams_panel_test.exs` —
  the autonomy + workstreams panels still pass under the restructured drawer.
- `mix compile --warnings-as-errors` — gradual type checker + `warnings_as_errors` clean.
- `mix test --warnings-as-errors` — full ExUnit suite (Postgres-backed) green, zero failures.
- `mix format --check-formatted` — formatting.
- `mix credo --strict` — lint incl. the "`@spec` on every public function" rule (the new
  `goal_card_summary/1` component + `goal_card_present?/1` helper must carry `@spec`s).
- `mix dialyzer` — `@spec`/contract checking, no new warnings, no stale ignore filters.

Runtime validation via **Tidewave** (preferred over ad-hoc IEx):
- `project_eval`: render the collapsed summary in isolation, e.g. evaluate
  `RepoBuilderWeb.ConsoleComponents.goal_card_summary(%{ledger: %{focus: "ship it", goal: "g"},
  workstreams: []})` and confirm it returns a `Phoenix.LiveView.Rendered.t()` mentioning the focus.
- Playwright (visual proof): navigate to `http://localhost:4000`, click `#toggle-goal-card`, and
  screenshot both the expanded and collapsed states of the right Orchestrator column.

## Notes
- **Mirrors an existing pattern.** `@goal_card_collapsed?` + `toggle_goal_card` is a direct copy of
  the left-rail `@rail_collapsed?` + `toggle_rail` toggle (`console_live.ex` ~line 1546 / ~3533), so
  it inherits the same conventions (session-local boolean, `phx-click` server event, chevron glyph
  affordance) with no new machinery.
- **Depends on the focus surface layout.** This builds on the bottom drawer / flex-column layout
  introduced with the two-level focus feature (the `aside` is `flex min-h-0 flex-col`; the chat
  wrapper is `flex-1 min-h-0`). Collapsing the body simply lets the chat wrapper's `flex-1` grow —
  no extra height math.
- **No persistence (by design, for now).** Collapse state resets on mount like the other view
  toggles. **Future extension:** persist per-orchestrator (a `console_prefs` jsonb column or an
  existing settings seam) so a collapsed goal card stays collapsed across reloads; and/or a global
  `⌘`-key shortcut (the console already binds `⌘K`/`⌘J`) to toggle it from the keyboard.
- **Accessibility.** The toggle is a real `<button>` (focusable, Enter/Space-activatable) with a
  descriptive `title`; the chevron glyph is `aria-hidden` with the button's title carrying the
  meaning. Consider adding `aria-expanded={not @goal_card_collapsed?}` for screen readers.
