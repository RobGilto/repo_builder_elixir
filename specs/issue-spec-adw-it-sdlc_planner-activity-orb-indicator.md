# Feature: Activity Orb — live "processing" indicator for the orchestrator, agents, and ADWs

## Metadata
issue_number: `spec`
adw_id: `it`
issue_json: `out`

## Feature Description
Add a small, self-contained visual indicator — an **Activity Orb** — that signals
"this thing is actively working right now." It renders as a tiny pulsating core
with a few small dots that orbit/twist around it, conveying live computation at a
glance. The same indicator is reused, harness-blind, anywhere the console shows an
entity that can be mid-process:

- the **orchestrator** (the right-hand `ORCHESTRATOR` chat/command panel header),
  whenever it is streaming a turn;
- any **agent** in the left rail (rich `agent_card` and the collapsed
  `agent_rail_compact`) whose live status is `:running`;
- any **ADW / workflow swimlane** (`swimlane_row` and the `swimlane` header) whose
  status is `:running`.

The orb is **pure CSS** — a typed function component plus a handful of
`@keyframes` in `assets/css/app.css`. No JavaScript hook, no new dependency, no
per-frame server work. It is driven entirely by an `active?` boolean derived from
state the console already tracks (`statuses`, `typing?`, lane `status`), so it
animates while running and disappears (or idles) when work stops. It honors
`prefers-reduced-motion` by collapsing to a static dot.

This is deliberately distinct from the existing momentary `cns-agent-card--pulse`
flash (a 335ms one-shot background flash fired on each event via `pulsed_id`): the
orb is a **continuous** state indicator tied to lifecycle status, not a per-event
blip. The two compose (a running card can flash on each event *and* show the orb).

## User Story
As an operator watching the orchestration console
I want a clear, glanceable animation on whatever is currently processing
So that I can instantly tell which agents, ADWs, and the orchestrator itself are
live — without reading status text or waiting for the next event row.

## Problem Statement
Today "is it working?" is only inferable indirectly: a `:running` status badge
(static text), a momentary card flash on each incoming event (`pulsed_id` +
`cns-agent-card--pulse`), or a three-dot typing indicator that only appears in the
chat stream. None of these give a persistent, eye-catching "alive/processing"
signal on the entity itself. When several agents and ADWs run concurrently, the
operator cannot quickly scan the rail and swimlanes to see what is active right
now versus idle/terminal.

## Solution Statement
Introduce one reusable typed function component, `activity_orb/1`, in
`RepoBuilderWeb.ConsoleComponents`, backed by pure-CSS `cns-orb*` classes. It takes
an `active?` flag and a `variant` (`:agent` | `:orchestrator` | `:adw`) that tunes
size and color, plus an optional `color` so an agent orb can use the agent's
deterministic hex. When `active?` is true it renders a pulsing core with 2–3
orbiting dots animated by `transform: rotate()` on a wrapper (the "circling/
twisting") and a `scale`/glow pulse on the core (the "pulsating"); when false it
renders nothing (or a dim static dot, per call site).

Wire it into the existing render paths:
- `agent_card` / `agent_rail_compact` — show the orb when the agent's live status
  is `:running` (new `active?` attr, derived in `ConsoleLive.render/1` from
  `@statuses`). This is independent of the existing momentary `pulse?`.
- `swimlane_row` / `swimlane` (in `RepoBuilderWeb.DashboardComponents`) — show the
  orb in the header when `status == :running`.
- `command_panel` header (`ORCHESTRATOR` label) — show the orb when the
  orchestrator turn is in flight (reuse `@typing?`, which already gates the typing
  indicator).

No schema, context, migration, OTP, or harness change is required — this is a
presentation-layer feature over assigns the LiveView already computes. It follows
the established "pure-CSS `cns-*` micro-animation + `attr/3`-validated component"
pattern already used by `typing_indicator` and `cns-agent-card--pulse`.

## Relevant Files
Use these files to implement the feature:

- `lib/repo_builder_web/components/console_components.ex` — Home of the new
  `activity_orb/1` typed component; already defines `agent_card/1`,
  `agent_rail_compact/1`, `command_panel/1`, and `typing_indicator/1`, which are
  the call sites. Mirror their `attr/3` + `@spec component(map()) ::
  Phoenix.LiveView.Rendered.t()` style and `values:`-constrained enums.
- `lib/repo_builder_web/components/dashboard_components.ex` — Defines
  `swimlane_row/1` and `swimlane/1` (the ADW lanes) and the `@statuses` enum +
  `status_class/1`. Add the orb to these headers gated on `:running`.
- `lib/repo_builder_web/live/console_live.ex` — The LiveView that owns
  `@statuses`, `@typing?`, the agent rail render loop, and the swimlane/`@streams.lanes`
  render. Derive each `active?` here and pass it to the components. Note the
  existing `pulsed_id`/`pulse?` momentary-flash seam is separate and stays.
- `assets/css/app.css` — Holds the `cns-*` design system and existing
  `@keyframes cns-pulse` / `@keyframes cns-blink`. Add `cns-orb*` classes +
  `@keyframes` here (orbit rotation, core pulse) and the
  `@media (prefers-reduced-motion: reduce)` fallback, next to the typing indicator
  block (~lines 283–304).
- `BUILD_PROMPT.md` §9 (LiveView dashboard) — Authoritative rules for the console:
  harness-blindness, streams, reconnect, typed components. The orb must not break
  the "both stream containers stay mounted, toggled via `hidden`" rule or touch
  `Repo`.
- `ai_docs/typed-elixir-standard.md` — The enforced typed style (every public
  function `@spec`'d, precise types, `@impl true` callbacks exempt). The new
  component and any helper must comply.
- `AGENTS.md` — Phoenix v1.8 + LiveView component conventions for this repo.

### New Files
- `test/repo_builder_web/live/test_activity_orb_test.exs` — `Phoenix.LiveViewTest`
  integration test that mounts `ConsoleLive`, drives an agent into `:running` (and
  asserts the orchestrator/ADW paths), and asserts the orb markup is present for
  active entities and absent for idle/terminal ones.

## Implementation Plan
### Phase 1: Foundation
Establish the visual primitive in isolation so it can be reused everywhere:
- Add the `cns-orb*` CSS (wrapper, orbiting dots, pulsing core) plus
  `@keyframes cns-orbit` (continuous `rotate(0deg → 360deg)`) and
  `@keyframes cns-orb-core` (scale + box-shadow glow pulse) to `app.css`, with a
  `prefers-reduced-motion` reduce fallback that pins the animation off and shows a
  static dot. Drive color via a `--orb-color` custom property (default to a
  variant token), matching how `agent_card` already passes `--agent-color`.
- Add the `activity_orb/1` typed function component to `ConsoleComponents` with
  `attr :active?, :boolean`, `attr :variant, :atom, values: [:agent, :orchestrator,
  :adw]`, `attr :color, :string, default: nil`, and an optional `attr :title`.
  When `active?` is false, render nothing (call sites decide whether to show a
  static idle dot). `@spec activity_orb(map()) :: Phoenix.LiveView.Rendered.t()`.

### Phase 2: Core Implementation
Wire the orb into the three console surfaces, deriving `active?` from existing
assigns (no new state):
- **Agent rail:** add `attr :active?, :boolean, default: false` to `agent_card/1`
  and `agent_rail_compact/1`; render `<.activity_orb variant={:agent} color={@color}
  active?={@active?} />` beside the status badge / status dot. In
  `ConsoleLive.render/1`, compute `active? = Map.get(@statuses, agent.id,
  agent.status) == :running` per agent.
- **Orchestrator:** in `command_panel/1`, render `<.activity_orb
  variant={:orchestrator} active?={@typing?} />` next to the `ORCHESTRATOR` label
  (the panel already receives `typing?`).
- **ADW swimlanes:** add an orb to `swimlane_row/1` and `swimlane/1` headers in
  `DashboardComponents`, gated on `status == :running`, using a new private
  `running?/1` helper or inline comparison. Reuse the `:adw` variant color.

### Phase 3: Integration
- Confirm the orb composes with — and does not replace — the existing momentary
  `pulse?` flash and the chat `typing_indicator`. They are orthogonal seams.
- Verify it survives the `view_mode` `hidden`-toggle (both stream containers stay
  mounted) and a LiveView reconnect (status is re-derived from `@statuses`, which
  `mount/1` reloads via `load_agents/1`).
- Verify it imposes no measurable server cost (no new assigns churn, no JS hook,
  CSS-only animation) and degrades gracefully under `prefers-reduced-motion`.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Add the LiveView integration test (write first, expect red)
- Create `test/repo_builder_web/live/test_activity_orb_test.exs` using
  `RepoBuilderWeb.ConnCase` + `Phoenix.LiveViewTest`, mirroring existing console
  tests in `test/repo_builder_web/live/`.
- Mount `ConsoleLive` at `/` with `live/2`.
- Assert that for an agent whose status is `:running`, the rendered HTML contains
  the orb (e.g. an element matching `[data-orb][data-active="true"]` /
  `.cns-orb` scoped to that agent's card via its `id={"agent-#{id}"}`), and that an
  idle/terminal agent renders no active orb (`data-active="false"` or absent).
- Drive a status transition through the existing PubSub seam used by the live
  handlers: broadcast (or simulate) an `Event.SessionStarted` for an agent and
  assert the orb appears once the agent flips to `:running`; broadcast an
  `Event.Done` and assert it disappears. Use `Dashboard`/`PubSub` the same way the
  current `handle_info/2` clauses receive `{:agent_event, agent_id, %Event{}}`.
- Assert the orchestrator orb is present when `@typing?` is true (set via the test
  path that toggles typing, or assert the markup gating on `typing?`).
- Keep the test minimal and deterministic (use the `fake` harness / seeded agents;
  no real OS process).

### 2. Add the orb CSS primitive
- In `assets/css/app.css`, just after the typing-indicator block (~line 304), add:
  - `.cns-orb` (inline-flex wrapper, sized per variant via a `--orb-size` var),
  - `.cns-orb__core` (the pulsing center: `border-radius:9999px`, `background:
    var(--orb-color)`, `animation: cns-orb-core 1.4s ease-in-out infinite`,
    `box-shadow` glow),
  - `.cns-orb__ring` (absolutely-positioned, `animation: cns-orbit 1.8s linear
    infinite`) holding 2–3 `.cns-orb__dot` children offset via `transform-origin`
    so they circle the core; stagger with `animation-delay` / counter-rotation for
    the "twisting" feel,
  - `@keyframes cns-orbit { to { transform: rotate(360deg); } }`,
  - `@keyframes cns-orb-core { 0%,100% { transform: scale(0.85); opacity:.7 } 50%
    { transform: scale(1.1); opacity:1 } }`,
  - variant size/color modifiers `.cns-orb--agent`, `.cns-orb--orchestrator`,
    `.cns-orb--adw` setting `--orb-size` and a default `--orb-color` token
    (`--cns-cyan` etc.),
  - `@media (prefers-reduced-motion: reduce) { .cns-orb__ring, .cns-orb__core {
    animation: none } .cns-orb__core { opacity: 1 } }`.

### 3. Add the `activity_orb/1` typed component
- In `RepoBuilderWeb.ConsoleComponents`, add `activity_orb/1` with:
  - `attr :active?, :boolean, default: false`
  - `attr :variant, :atom, default: :agent, values: [:agent, :orchestrator, :adw]`
  - `attr :color, :string, default: nil` (agent hex; falls back to the variant token)
  - `attr :title, :string, default: "working"`
  - `@spec activity_orb(map()) :: Phoenix.LiveView.Rendered.t()`
  - Render nothing when `active?` is false (`~H""` empty / `:if`); when true, emit
    the `.cns-orb cns-orb--<variant>` wrapper with `data-orb`,
    `data-active={to_string(@active?)}`, `style={"--orb-color: #{@color || ...}"}`,
    a `.cns-orb__core`, and a `.cns-orb__ring` with the dots.
- If a tiny private helper is needed (e.g. variant→default color), give it an
  inference-safe spec consistent with the module's existing private-helper style.

### 4. Render the orb in the agent rail
- Add `attr :active?, :boolean, default: false` to `agent_card/1` and
  `agent_rail_compact/1`; place `<.activity_orb variant={:agent} color={@color}
  active?={@active?} />` next to the status badge (`agent_card`) and the status dot
  (`agent_rail_compact`).
- In `ConsoleLive.render/1`, in both the collapsed and expanded rail branches, pass
  `active?={Map.get(@statuses, agent.id, agent.status) == :running}`.

### 5. Render the orchestrator orb
- In `command_panel/1`, render `<.activity_orb variant={:orchestrator}
  active?={@typing?} />` next to the `ORCHESTRATOR` header label. `typing?` is
  already an attr on the panel and already passed from `ConsoleLive.render/1`.
- (Optional, only if trivial) also derive orchestrator-agent `:running` from
  `@statuses[@orchestrator_id]` and OR it with `@typing?` for robustness.

### 6. Render the ADW / swimlane orb
- In `DashboardComponents.swimlane_row/1` and `swimlane/1`, add the orb to the
  header, gated on `status == :running`. Since `DashboardComponents` should stay
  self-contained, either inline a minimal CSS-class orb consistent with the
  `cns-orb` markup or import `activity_orb/1` — prefer reusing `activity_orb/1` via
  `import RepoBuilderWeb.ConsoleComponents, only: [activity_orb: 1]` to avoid
  duplicate markup. Pass `variant={:adw}` and `active?={@status == :running}`.

### 7. Format, lint, type-check, and self-review
- Run `mix format`, then the full Validation Commands below. Resolve any
  `--warnings-as-errors`, Credo `@spec`, or Dialyzer findings. Ensure no new
  Dialyzer ignore entries are needed.

### 8. Runtime validation (Tidewave) and optional visual proof
- With the app running (`scripts/pg.sh start` per session, `mix phx.server`), use
  Tidewave `project_eval` to broadcast a fake `:running` agent event over the
  `Dashboard` PubSub seam and confirm no errors via Tidewave `get_logs`.
- Optionally capture a screenshot of `http://localhost:4000` (Tidewave Web vision
  mode, or Playwright MCP) showing the orb on a running agent/ADW as visual proof.

### 9. Run the full validation suite
- Execute every command in **Validation Commands** and confirm zero failures and
  zero regressions, including the new LiveView test.

## Testing Strategy
### Unit Tests
- **Component render (via the LiveView test):** mounting `ConsoleLive`, an agent in
  `:running` renders the orb markup (`data-orb`, `.cns-orb--agent`); an `:idle`/
  `:succeeded`/`:failed` agent does not render an active orb.
- **Status transition:** feeding `Event.SessionStarted` → agent flips to `:running`
  → orb appears; feeding `Event.Done`/`Event.Error` → agent flips to terminal →
  orb disappears. Driven through the same `{:agent_event, agent_id, %Event{}}`
  PubSub path the live `handle_info/2` clauses already handle.
- **Orchestrator gating:** orb present iff `@typing?` (and/or orchestrator agent
  `:running`).
- **ADW gating:** a swimlane/lane with `status: :running` renders the orb; other
  statuses do not.

### Edge Cases
- **Reduced motion:** `prefers-reduced-motion: reduce` collapses the orb to a
  static dot (assert the CSS class/media query exists; behavior is visual).
- **View toggle:** switching `LOGS ⇄ ADWS` (both containers stay mounted via
  `hidden`) keeps orbs correct in the hidden pane; no orb is orphaned.
- **Concurrent entities:** multiple agents + ADWs running at once each show their
  own orb; colors derive per-agent (`--orb-color` from `AgentColors.hex/1`).
- **Rapid status flapping:** running → done → running in quick succession leaves the
  orb consistent with the latest `@statuses` (no stuck-on orb), since it is purely
  derived state, not an event-triggered one-shot.
- **No double-signal regression:** the existing momentary `cns-agent-card--pulse`
  flash still fires on events and does not conflict with the orb.
- **Reconnect:** after a LiveView reconnect, `mount/1` reloads `@statuses`, so a
  still-running agent re-shows its orb.

## Acceptance Criteria
- A new `activity_orb/1` typed component exists in `ConsoleComponents` with full
  `attr/3` validation, a `values:`-constrained `variant`, and a
  `@spec ... :: Phoenix.LiveView.Rendered.t()`.
- Pure-CSS `cns-orb*` classes + `@keyframes` live in `assets/css/app.css`, including
  a `prefers-reduced-motion` fallback. No new dependency is added; no JS hook is
  added.
- A `:running` agent (rich card and collapsed rail) renders a pulsating, orbiting
  orb in its deterministic color; idle/terminal agents do not.
- The orchestrator panel shows the orb while a turn streams (`@typing?`).
- A `:running` ADW/workflow swimlane shows the orb in its header; non-running lanes
  do not.
- The orb is orthogonal to and does not break the existing `pulse?` flash or chat
  `typing_indicator`.
- `test/repo_builder_web/live/test_activity_orb_test.exs` passes and asserts the
  present/absent behavior across agent, orchestrator, and ADW surfaces.
- All Validation Commands pass with zero failures and zero new warnings.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix test test/repo_builder_web/live/test_activity_orb_test.exs` - Run the new
  LiveView integration test for the activity orb (present-for-active, absent-for-idle
  across agent/orchestrator/ADW surfaces).
- `mix compile --warnings-as-errors` - Compile clean; the gradual set-theoretic type
  checker and `warnings_as_errors` must pass.
- `mix test --warnings-as-errors` - Run the full ExUnit suite (Postgres-backed cases)
  with zero failures.
- `mix format --check-formatted` - Ensure code is formatted.
- `mix credo --strict` - Lint, including the "every public function has an `@spec`"
  convention.
- `mix dialyzer` - `@spec`/contract checking with no new warnings and no stale
  ignore filters.

## Notes
- **No new dependency.** The orb is pure CSS keyframes + a typed function
  component, consistent with the existing `typing_indicator` and
  `cns-agent-card--pulse` patterns. The 3D/particle approaches surfaced in research
  (three.js / react-three-fiber point clouds) were intentionally rejected as
  overkill for many simultaneous tiny badges and a Phoenix-LiveView (non-React)
  stack.
- **Design lineage (research):** the "small glowing orb = thinking/processing" is
  the current convention across leading AI products (e.g. Grok's pulsing orb,
  Gemini's sparkling rotator). The chosen composition — orbiting dots (the
  "circling/twisting") around a pulsing core (the "pulsating") — maps directly to
  the requested "pulsating tiny floating balls twisting and circling," and is the
  cheapest reliable way to render it at badge scale across dozens of live rows.
- **Separation of concerns:** `pulsed_id`/`pulse?` (momentary per-event flash) is
  explicitly *not* repurposed; the orb is a continuous status indicator. Keeping
  them separate avoids a stuck-on orb when events stop but status is still running,
  and vice-versa.
- **DashboardComponents reuse:** prefer importing `activity_orb/1` into
  `DashboardComponents` over duplicating markup, so the orb has exactly one source
  of truth. If an import cycle or layering concern arises, fall back to a shared
  thin wrapper, but document why.
- **Future considerations:** the `variant` enum leaves room for additional surfaces
  (e.g. header connection indicator, event-detail panel). An `active?`-driven idle
  state (dim static dot) could later replace the plain `:running` text badge if
  desired, but that is out of scope here.
- **Tidewave validation:** prefer `project_eval` to broadcast a synthetic running
  event over the `Dashboard` PubSub seam and `get_logs` to confirm no errors,
  rather than ad-hoc IEx, per repo conventions.
```
