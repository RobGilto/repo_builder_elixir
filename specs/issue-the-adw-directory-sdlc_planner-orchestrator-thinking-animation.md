# Feature: Orchestrator "thinking" animation in the command panel

## Metadata
issue_number: `the`
adw_id: `directory`
issue_json: `picker`

## Feature Description
Worker agent cards show a continuous "processing" animation (the `activity_orb`: a pulsing
core ringed by orbiting dots) while the agent's lifecycle status is `:running`. The operator
relies on this orb to see, at a glance, that an agent is working.

The orchestrator's command panel (the right-hand chat) is supposed to show the **same**
animation while a turn is in flight: the panel header already renders
`<.activity_orb variant={:orchestrator} active?={...} />` next to the "ORCHESTRATOR" label,
and a three-dot `typing_indicator` at the bottom of the chat log. But in practice neither
animates while the orchestrator is thinking — even though the operator can see in the logs
that a turn has started (the orchestrator's `session_id` populates).

This feature makes the orchestrator's thinking animation (the header orb and the chat-log
typing indicator) appear for the **entire** duration a turn is in flight — from the moment
the turn starts (before any text streams, i.e. the "thinking" gap) until the turn completes —
so the command panel mirrors the worker agent cards.

## User Story
As a console operator who has just sent the orchestrator a message
I want the command panel to show a live "thinking" animation while the orchestrator works
So that I get the same at-a-glance "it's working" feedback the worker agent cards already give,
instead of staring at a static panel and having to check the logs to confirm it started.

## Problem Statement
The command-panel orb and typing indicator are gated on
`@typing? || Map.get(@statuses, @orchestrator_id) == :running` (`console_live.ex:2512`). This
never becomes true during a turn:

- `@statuses` is keyed by the **per-turn segment agent_id** `"orch-<orchestrator_id>-<n>"`
  (see `orchestrator_event?/1` at `console_live.ex:1962-1966` and the `set_status(agent_id, …)`
  calls in the event handlers), **not** by the bare `@orchestrator_id`. So
  `Map.get(@statuses, @orchestrator_id)` is always `nil` for the orchestrator.
- `@typing?` is initialized to `false` (`console_live.ex:169`) and is never assigned `true`
  anywhere, so it is dead.

Net effect: the orchestrator's "thinking" animation never shows, while the worker agent
cards (keyed correctly by `agent.id`) animate fine.

## Solution Statement
Drive the command-panel thinking animation off the signal that already authoritatively tracks
"a turn is in flight": `@orchestrator_queue.busy?`.

The `RepoBuilder.Orchestrator.Queue` snapshot exposes `busy?: state.current != nil`
(`lib/repo_builder/orchestrator/queue.ex:43-48, 379-381`). It flips `true` the instant a turn
starts (covering the thinking gap before `SessionStarted`/first text delta) and `false` when
the turn's process finishes and the queue drains. It is already subscribed
(`subscribe_orchestrator_queue`) and pushed live into `@orchestrator_queue` via
`{:orchestrator_queue, id, snapshot}` (`console_live.ex:1791-1797`), and it is already used to
render the `queued_messages` strip (`console_live.ex:2554-2557`). So no new state, no new
PubSub, no new server logic is required.

Change the command panel's `typing?` to include `@orchestrator_queue.busy?`:

```elixir
typing?={@typing? || @orchestrator_queue.busy? || Map.get(@statuses, @orchestrator_id) == :running}
```

This makes both the header `activity_orb` (variant `:orchestrator`) and the bottom
`typing_indicator` animate for the full turn — visually matching the worker agent cards. The
existing `@statuses` / `@typing?` terms are kept so the change is purely additive (no
regression to whatever already works).

(Optional hardening, recommended: drop the dead `Map.get(@statuses, @orchestrator_id)` term
since it can never match, and/or remove the unused `@typing?` assign — but the minimal,
zero-risk change is the additive OR above.)

## Relevant Files
Use these files to implement the feature:

- `lib/repo_builder_web/live/console_live.ex` — the `<.command_panel ...>` render call passes
  `typing?={@typing? || Map.get(@statuses, @orchestrator_id) == :running}`
  (`~2512`). This is the one line to change. Also where `@orchestrator_queue` lives
  (init `~94`, seeded `~263`, updated live `~1791-1797`) — confirming `busy?` is always
  present and live.
- `lib/repo_builder_web/components/console_components.ex` — `command_panel/1` (`~748`) renders
  the header `<.activity_orb variant={:orchestrator} active?={@typing?} />` (`~757`) and
  `<.typing_indicator :if={@typing?} />` (`~786`). `activity_orb/1` (`~705`) is the shared
  animation already used by the agent cards. No change needed unless we also want the orb to
  carry a `title`/`aria-label` like the agent cards (optional polish).
- `lib/repo_builder/orchestrator/queue.ex` — defines the `snapshot` type and `busy?` semantics
  (`~43-48`, `~379-381`). Read-only reference; confirms `busy?` is the correct signal. No change.
- `BUILD_PROMPT.md` — §3 typed style guide, §9 LiveView dashboard conventions. The change is
  template-only but must keep the build green (warnings-as-errors, Dialyzer, Credo).

### New Files
- `test/repo_builder_web/live/test_orchestrator_thinking_animation_test.exs` —
  `Phoenix.LiveViewTest` integration test asserting the orb + typing indicator render while
  `@orchestrator_queue.busy?` is true and disappear when it is false.

## Implementation Plan
### Phase 1: Foundation
Confirm (already done in research) that `@orchestrator_queue.busy?` is the authoritative,
always-present, live-updated "turn in flight" signal, and that the current orb gate can never
fire for the orchestrator. No new state is introduced.

### Phase 2: Core Implementation
Make the command panel's `typing?` include `@orchestrator_queue.busy?` so the existing orb and
typing indicator animate for the whole turn.

### Phase 3: Integration
Verify the animation appears at turn start (thinking phase, before text), stays through
streaming, and clears on turn completion — and that the `queued_messages` busy badge and the
new animation now agree (both driven by the same `busy?`).

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Write the LiveView integration test first
- Create `test/repo_builder_web/live/test_orchestrator_thinking_animation_test.exs` using
  `Phoenix.LiveViewTest`.
- Mount `ConsoleLive` at `/`. Capture the live `orchestrator_id` from the mounted socket (or
  the seeded orchestrator).
- Drive the busy state the way the app does: broadcast the queue snapshot the LiveView
  subscribes to — `{:orchestrator_queue, orchestrator_id, %{busy?: true, current: "orch-…-1",
  queued: [], depth: 0}}` over the same topic `subscribe_orchestrator_queue/1` uses (find the
  topic in `RepoBuilder.Dashboard` / the queue module). Use `Phoenix.PubSub.broadcast` or the
  existing Dashboard publish helper.
- Assert that after the busy snapshot, the rendered panel contains the orb
  (`element(view, "#command-panel [data-orb][data-active=\"true\"]")` /
  `.cns-orb--orchestrator`) and the `#typing-indicator`.
- Broadcast `%{busy?: false, current: nil, queued: [], depth: 0}` and assert the orb and
  `#typing-indicator` are gone (`refute has_element?`).
- Prefer asserting on the orb's stable markers (`[data-orb]`, `cns-orb--orchestrator`) and
  `#typing-indicator` over brittle nth-child selectors.

### 2. Make the command panel thinking animation track orchestrator busy
- In `lib/repo_builder_web/live/console_live.ex` at the `<.command_panel>` call (~2512),
  change:
  `typing?={@typing? || Map.get(@statuses, @orchestrator_id) == :running}`
  to:
  `typing?={@orchestrator_queue.busy? || @typing? || Map.get(@statuses, @orchestrator_id) == :running}`
- This is template-only; no `@spec`/typespec changes. The `@orchestrator_queue` assign is
  always a map with a `busy?` boolean (init at ~94, never nil), so the access is safe.

### 3. (Optional polish) match the agent-card orb affordance
- If desired, give the orchestrator orb a `title`/`aria-label` (e.g. "Orchestrator working")
  by passing those attrs in `command_panel/1` where `<.activity_orb variant={:orchestrator}>`
  is rendered, mirroring the agent-card orb. Skip if out of scope.

### 4. Run the validation commands
- Run every command in `Validation Commands`; fix any failure until all are green with zero
  regressions.

## Testing Strategy
### Unit Tests
- No domain logic changes, so no new unit tests. `RepoBuilder.Orchestrator.Queue.busy?`
  semantics are already covered by the queue's existing tests; the new behavior is purely a
  render gate, best covered by the LiveView integration test.

### Edge Cases
- Turn start before any text streams (the "thinking" gap): `busy?` is already true, so the
  animation shows immediately — the core of the user's report.
- Queued (not yet running) turns: `busy?` is true while `current != nil`; assert the animation
  reflects an in-flight turn, consistent with the `queued_messages` busy badge.
- Turn completion / error: `busy?` flips false and the animation clears even if a stray
  `@statuses` segment is left at `:running`.
- Cross-tab/auto-resume turns that start without a fresh operator submit: covered, because the
  signal is the queue snapshot, not a client-side submit.

## Acceptance Criteria
- While the orchestrator is processing a turn (from start through completion), the command
  panel shows the same `activity_orb` animation used by worker agent cards (header orb) and the
  three-dot `typing_indicator` in the chat log.
- The animation appears during the initial "thinking" phase (before any assistant text
  streams), matching when the orchestrator `session_id` populates in the logs.
- The animation disappears when the turn completes (queue no longer busy).
- The new LiveView integration test passes.
- `mix compile --warnings-as-errors`, `mix test --warnings-as-errors`,
  `mix format --check-formatted`, `mix credo --strict`, and `mix dialyzer` are all green.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix test test/repo_builder_web/live/test_orchestrator_thinking_animation_test.exs` - Run the
  new LiveView integration test for the orchestrator thinking animation.
- `mix compile --warnings-as-errors` - Compile clean; gradual type checker + warnings-as-errors pass.
- `mix test --warnings-as-errors` - Full ExUnit suite, zero failures.
- `mix format --check-formatted` - Code formatting.
- `mix credo --strict` - Lint, including the `@spec`-on-every-public-function convention.
- `mix dialyzer` - Contract checking, no new warnings.

Optional runtime validation (Tidewave): with the app running, send the orchestrator a turn and
use Tidewave Web vision mode (or Playwright MCP) to screenshot `http://localhost:4000` during
the thinking phase, confirming the `cns-orb--orchestrator` orb and `#typing-indicator` are
visible; or use `project_eval` to broadcast a `%{busy?: true}` snapshot on the orchestrator
queue topic and observe the panel animate.

## Notes
- Root cause: the orb/typing gate keys off `Map.get(@statuses, @orchestrator_id)`, but
  orchestrator events are stored under the per-turn segment id `"orch-<id>-<n>"`
  (`orchestrator_event?/1`), so the bare-id lookup never matches; and `@typing?` is initialized
  to `false` and never set `true` (dead). The fix reuses the existing, authoritative
  `@orchestrator_queue.busy?` signal — already live over PubSub and already rendering the
  busy badge — so it is minimal and low-risk.
- No new dependencies, no migrations, no `FileBrowser`/queue/persistence changes.
- Cleanup opportunity (optional, can be a follow-up): remove the dead
  `Map.get(@statuses, @orchestrator_id) == :running` term and the unused `@typing?` assign now
  that `busy?` is the single source of truth — reduces confusion for the next reader. Keeping
  them is harmless; removing them keeps the build green only if every reference is removed
  together (Credo/warnings-as-errors).
- Future consideration: distinguish a dedicated "thinking" sub-state (model reasoning) from
  "streaming text" for a richer indicator, but that requires a new signal from the harness and
  is out of scope here.
