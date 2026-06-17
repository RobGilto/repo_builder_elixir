# Feature: Toggle viewing THINKING in the orchestrator chat (General settings)

## Metadata
issue_number: `be`
adw_id: `able`
issue_json: `to`

## Feature Description
Add a user-controllable toggle that shows or hides the orchestrator's **THINKING**
bubbles in the right-hand chat/command panel. Today every reasoning delta the
orchestrator emits (canonical `Event.TextDelta{thinking?: true}`) is turned into a
purple, italic `thinking_bubble` and rendered inline in the chat stream alongside
the orchestrator's normal responses and tool-use cards. Some operators want the
chat to read as a clean conversation (responses + actions only) and to suppress the
verbose reasoning; others want to watch the model think.

This feature adds a **"Show orchestrator thinking"** control to the existing
**General** tab of the Settings modal. When ON (the default — preserving today's
behavior), thinking bubbles render as they do now. When OFF, thinking bubbles are
filtered out of the chat panel. The toggle is a presentation-only, in-memory
preference on the `ConsoleLive` socket (exactly like the sibling `view_mode`,
`chat_width`, and `auto_follow?` settings): no schema, migration, context, or OTP
change. The underlying events are still captured, counted, persisted, and shown in
the center event-stream / swimlanes — only the *chat panel rendering* is gated.

## User Story
As an operator watching the orchestration console
I want to toggle whether the orchestrator's THINKING reasoning shows in the chat
So that I can either follow the model's reasoning or keep the chat a clean
responses-and-actions conversation, without losing the reasoning from the event log.

## Problem Statement
The orchestrator chat panel always renders THINKING bubbles. For long reasoning
chains this drowns out the orchestrator's actual responses and tool-use actions,
making the conversation hard to scan. There is currently no way to hide reasoning
in the chat while keeping it available in the event stream. Operators have a
Settings modal with a General tab (View mode, Auto-follow) that is the natural home
for such a display preference, but no thinking toggle exists.

## Solution Statement
Introduce a single boolean assign, `show_thinking?` (default `true`), on
`ConsoleLive`, surfaced as a **"Show orchestrator thinking"** ON/OFF control in the
**General** settings tab — mirroring the existing `Auto-follow` control's markup,
event seam, and styling exactly. A new `toggle_thinking` `handle_event/3` flips the
assign. The `command_panel/1`'s `:messages` slot loop in `ConsoleLive.render/1`
skips `:thinking`-role chat entries when `show_thinking?` is false (a guard on the
existing `for` comprehension — `msg.role != :thinking or @show_thinking?`). Because
the chat list is rebuilt from `@messages` on every render and the toggle is pure
derived presentation state, hiding/showing is instantaneous, survives the
`hidden`-toggle view switch, and re-derives correctly after a LiveView reconnect
(the assign resets to its default on `mount/1`, like the other display settings).

This reuses the established Settings-modal pattern: a `settings_field` row wrapping
a `cns-chip` ON/OFF button with a new element id, wired to a new `phx-click` event,
with the assign threaded into the `settings_modal/1` component via a new `attr`.

## Relevant Files
Use these files to implement the feature:

- `lib/repo_builder_web/live/console_live.ex` — Owns the chat `@messages` buffer and
  the `command_panel` `:messages` slot render loop (~lines 1104–1123), the default
  assigns block in `mount/1` (~lines 55–95, where `auto_follow?`, `view_mode`,
  `chat_width`, `settings_tab` live), the `handle_event/3` clauses (the
  `toggle_auto_follow` / `select_settings_tab` handlers ~lines 414–418 are the exact
  template), and the `settings_modal/1` render call (~lines 1135–1141). Add the
  `show_thinking?` default, the `toggle_thinking` handler, the comprehension guard,
  and pass `show_thinking?` into `settings_modal`.
- `lib/repo_builder_web/components/console_components.ex` — Home of `settings_modal/1`
  (~lines 655–759), `settings_field/1` (~line 784), and `command_panel/1`. Add a
  `attr :show_thinking?, :boolean, default: true` to `settings_modal/1` and a new
  `settings_field` row with an ON/OFF `cns-chip` button (`id="settings-thinking"`,
  `phx-click="toggle_thinking"`) in the **General** tab block, immediately after the
  existing "Auto-follow chat & stream" field. Mirror that field's markup precisely.
- `BUILD_PROMPT.md` §9 (LiveView dashboard) — Authoritative rules: harness-blindness,
  streams stay mounted, reconnect re-derivation, typed `attr/3` components. The
  toggle must not touch `Repo`, must keep both stream containers mounted, and must be
  pure presentation state.
- `ai_docs/typed-elixir-standard.md` — The enforced typed style (every public function
  `@spec`'d; `@impl true` callbacks exempt; precise types; `values:`-constrained
  enums). The new `attr` and any handler must comply.
- `AGENTS.md` — Phoenix v1.8 + LiveView component conventions for this repo.

### New Files
- `test/repo_builder_web/live/test_orchestrator_thinking_toggle_test.exs` —
  `Phoenix.LiveViewTest` integration test that mounts `ConsoleLive`, broadcasts a
  `Event.TextDelta{thinking?: true}` (and a normal response) over the `Dashboard`
  PubSub seam, asserts the `.cns-bubble--thinking` bubble is present by default,
  clicks `#settings-thinking` to toggle it OFF, asserts the thinking bubble is gone
  while the normal response bubble remains, and toggles back ON to assert it
  reappears.

## Implementation Plan
### Phase 1: Foundation
Add the preference state and its server-side seam without changing any rendering yet:
- Add `show_thinking?: true` to the `mount/1` default assigns block in `ConsoleLive`,
  placed next to `auto_follow?`/`settings_tab` so the display-preference cluster
  stays together. Default `true` preserves current behavior (thinking visible).
- Add a `handle_event("toggle_thinking", _params, socket)` clause that flips the
  assign, mirroring `toggle_auto_follow` exactly:
  `{:noreply, assign(socket, :show_thinking?, not socket.assigns.show_thinking?)}`.
  No `restream/1` call is needed — the chat panel is not a stream; it re-renders from
  `@messages` on the next diff.

### Phase 2: Core Implementation
Surface the control and apply the filter:
- In `settings_modal/1` (`console_components.ex`), add
  `attr :show_thinking?, :boolean, default: true` and a new `settings_field`
  (`label="Show orchestrator thinking"`) inside the `:general` tab `<div>`, directly
  after the "Auto-follow chat & stream" field. The control is a `cns-chip` button
  with `id="settings-thinking"`, `phx-click="toggle_thinking"`, the active styling
  (`@show_thinking? && "cns-chip--active cns-chip--hook"`), and ON/OFF label text —
  copied from the auto-follow field so the two read identically.
- In `ConsoleLive.render/1`, pass `show_thinking?={@show_thinking?}` to the
  `<.settings_modal ... />` call.
- In `ConsoleLive.render/1`, gate the chat loop: change
  `<%= for msg <- @messages do %>` to
  `<%= for msg <- @messages, msg.role != :thinking or @show_thinking? do %>` so
  thinking-role entries are dropped from the chat panel when the toggle is OFF. The
  `:thinking` branch of the inner `case` is otherwise unchanged.

### Phase 3: Integration
- Confirm the toggle is orthogonal to everything else: the center event-stream rows,
  swimlanes, agent-rail thinking counters, and persisted `agent_logs` are all
  unaffected — only the chat panel's thinking bubbles are gated. Reasoning is never
  lost; it is still visible in the THINKING-category event rows.
- Confirm it survives the `LOGS ⇄ ADWS` `view_mode` `hidden`-toggle (chat panel is
  outside both stream containers) and a LiveView reconnect (the assign resets to its
  `true` default on `mount/1`, like `chat_width`/`auto_follow?`).
- Confirm no interaction with the `typing_indicator` (still gated on `@typing?`/
  orchestrator-running) or the orchestrator activity orb — those are separate seams.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Add the LiveView integration test (write first, expect red)
- Create `test/repo_builder_web/live/test_orchestrator_thinking_toggle_test.exs` using
  `RepoBuilderWeb.ConnCase` (`async: false`) + `Phoenix.LiveViewTest`, mirroring
  `test/repo_builder_web/live/test_orchestration_console_ui_test.exs` (the
  `create_agent/2` helper and the `Dashboard.broadcast_event/2` chat-bubble pattern).
- Mount `ConsoleLive` at `/` with `live/2`; create a `fake` agent via the inline form.
- Broadcast `%Event.TextDelta{harness: :fake, text: "deep thoughts", thinking?: true}`
  and `%Event.TextDelta{harness: :fake, text: "hello response", thinking?: false}`
  over `Dashboard.broadcast_event/2`; force a `render(view)` to drain the mailbox.
- Assert default-ON: `has_element?(view, ".cns-bubble--thinking")` AND the response
  bubble is present (`has_element?(view, ".cns-bubble--orch")` / its text).
- Click `#settings-thinking` (`view |> element("#settings-thinking") |> render_click()`);
  assert `refute has_element?(view, ".cns-bubble--thinking")` while the response
  bubble remains.
- Click `#settings-thinking` again; assert the thinking bubble reappears.

### 2. Add the `show_thinking?` default assign
- In `ConsoleLive.mount/1`, add `show_thinking?: true` to the default assigns block
  (next to `auto_follow?`/`settings_tab`).

### 3. Add the `toggle_thinking` event handler
- In `ConsoleLive`, add `def handle_event("toggle_thinking", _params, socket)` that
  flips `:show_thinking?`, copying the `toggle_auto_follow` clause's shape (no
  `restream/1`).

### 4. Add the control to the General settings tab
- In `console_components.ex` `settings_modal/1`, add
  `attr :show_thinking?, :boolean, default: true`.
- Inside the `:general` tab `<div>`, after the "Auto-follow chat & stream"
  `settings_field`, add a "Show orchestrator thinking" `settings_field` whose control
  is a `cns-chip` button: `id="settings-thinking"`, `phx-click="toggle_thinking"`,
  `class={["cns-chip", @show_thinking? && "cns-chip--active cns-chip--hook"]}`, label
  `{if @show_thinking?, do: "ON", else: "OFF"}`.

### 5. Wire the assign into the modal and filter the chat loop
- In `ConsoleLive.render/1`, add `show_thinking?={@show_thinking?}` to the
  `<.settings_modal ... />` call.
- In the `command_panel` `:messages` slot, change the comprehension to
  `<%= for msg <- @messages, msg.role != :thinking or @show_thinking? do %>`.

### 6. Format, lint, type-check, and self-review
- Run `mix format`, then the full Validation Commands below. Resolve any
  `--warnings-as-errors`, Credo `@spec`, or Dialyzer findings. Add no new Dialyzer
  ignore entries.

### 7. Runtime validation (Tidewave) and optional visual proof
- With the app running (`scripts/pg.sh start` per session, then `mix phx.server`), use
  Tidewave `project_eval` to broadcast a `%Event.TextDelta{thinking?: true}` over the
  `RepoBuilder.Dashboard.broadcast_event/2` seam, and `get_logs` to confirm no errors.
- Optionally capture a screenshot of `http://localhost:4000` (Tidewave Web vision
  mode, or Playwright MCP) showing the General settings tab with the new toggle and
  the chat with thinking hidden, as visual proof.

### 8. Run the full validation suite
- Execute every command in **Validation Commands** and confirm zero failures and zero
  regressions, including the new LiveView test.

## Testing Strategy
### Unit Tests
- **Default visible:** mounting `ConsoleLive` and broadcasting a `thinking?: true`
  TextDelta renders a `.cns-bubble--thinking` in the chat panel (default ON).
- **Toggle hides thinking:** clicking `#settings-thinking` removes
  `.cns-bubble--thinking` from the chat while a normal response bubble
  (`.cns-bubble--orch`) remains rendered.
- **Toggle restores thinking:** clicking `#settings-thinking` again re-shows the
  thinking bubble (the underlying `@messages` entry was never dropped, only filtered).
- **Control reflects state:** the `#settings-thinking` button shows `ON`/`OFF` and the
  `cns-chip--active` class consistently with `@show_thinking?`.

### Edge Cases
- **Reasoning preserved in the event log:** with thinking hidden in chat, the
  THINKING-category event row (`.cns-cat--thinking` / event stream) and the agent-rail
  thinking counter still reflect the reasoning event — nothing is lost.
- **View toggle:** switching `LOGS ⇄ ADWS` (both stream containers stay mounted via
  `hidden`) does not affect the chat-panel thinking filter; the chat is outside both
  containers.
- **Reconnect:** after a LiveView reconnect, `mount/1` resets `show_thinking?` to its
  `true` default (consistent with `chat_width`/`auto_follow?` — these are in-memory
  display prefs, not persisted).
- **Rapid toggling:** flipping ON→OFF→ON in quick succession leaves the chat
  consistent with the latest `@show_thinking?` (pure derived render, no stuck state).
- **No thinking present:** with no thinking messages in the buffer, the toggle is a
  no-op visually and renders without error in either state.

## Acceptance Criteria
- A **"Show orchestrator thinking"** ON/OFF control exists in the **General** tab of
  the Settings modal, styled like the sibling "Auto-follow" control, with element id
  `#settings-thinking` and `phx-click="toggle_thinking"`.
- `settings_modal/1` gains a `attr :show_thinking?, :boolean, default: true` and the
  assign is threaded from `ConsoleLive.render/1`.
- `ConsoleLive` has a `show_thinking?` assign defaulting to `true` and a
  `toggle_thinking` `handle_event/3` that flips it.
- With the toggle ON (default), orchestrator THINKING bubbles render in the chat as
  today; with it OFF, they are filtered out of the chat panel while responses and
  tool-use cards still render.
- The toggle is presentation-only: no schema/migration/context/OTP change, no `Repo`
  access, both stream containers stay mounted, and the THINKING event rows / counters
  / persisted logs are unaffected.
- `test/repo_builder_web/live/test_orchestrator_thinking_toggle_test.exs` passes and
  asserts present-by-default, hidden-after-toggle (response retained), and
  restored-on-re-toggle.
- All Validation Commands pass with zero failures and zero new warnings.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix test test/repo_builder_web/live/test_orchestrator_thinking_toggle_test.exs` -
  Run the new LiveView integration test (default-visible, hidden-after-toggle with
  response retained, restored-on-re-toggle).
- `mix compile --warnings-as-errors` - Compile clean; the gradual set-theoretic type
  checker and `warnings_as_errors` must pass.
- `mix test --warnings-as-errors` - Run the full ExUnit suite (Postgres-backed cases)
  with zero failures.
- `mix format --check-formatted` - Ensure code is formatted.
- `mix credo --strict` - Lint, including the "every public function has an `@spec`"
  convention.
- `mix dialyzer` - `@spec`/contract checking with no new warnings and no stale ignore
  filters.

## Notes
- **No new dependency.** This is a pure presentation toggle over an assign the
  LiveView already renders, consistent with the existing `view_mode`/`chat_width`/
  `auto_follow?` settings and the established Settings-modal `settings_field` pattern.
- **Default ON is intentional** — it preserves the current behavior (thinking
  visible) so the change is non-surprising; operators opt into the cleaner view.
- **Scope is the chat panel only.** Reasoning remains a first-class canonical event:
  it is still streamed into the center THINKING-category rows, counted on the agent
  card, and persisted to `agent_logs`. This feature only gates the chat-bubble
  rendering, by design — so hiding thinking in chat never destroys information.
- **Not persisted across sessions.** Like the sibling display settings, this resets
  to its default on reconnect/remount. A future enhancement could persist console
  display preferences (e.g. via `localStorage` + a client hook, or a per-user
  settings row), but that is out of scope here.
- **Tidewave validation:** prefer `project_eval` to broadcast a synthetic
  `Event.TextDelta{thinking?: true}` over the `Dashboard` PubSub seam and `get_logs`
  to confirm no errors, per repo conventions, rather than ad-hoc IEx.
```
