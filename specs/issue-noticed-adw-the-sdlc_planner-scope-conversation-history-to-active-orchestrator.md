# Feature: Per-Project Conversation History — scope the chat pane to the active orchestrator

## Metadata
issue_number: `noticed`
adw_id: `the`
issue_json: `conversation`

## Feature Description
The console's right-hand **conversation pane** must follow the project switcher. Today,
selecting a different project on the top-left switcher correctly swaps the *active
orchestrator* (its harness/model/cost/context gauge and rail roster all change — shipped
in the orchestrator↔project binding work), but the **chat/conversation pane does not
change**: it keeps showing one global stream of orchestrator messages regardless of which
project is selected.

This feature makes the conversation pane **per-orchestrator**: when the operator switches
projects, the pane reloads *that orchestrator's own* conversation history (operator turns
+ orchestrator replies), and while a project is selected, only that orchestrator's live
messages stream into the pane. The underlying "conversation memory" already exists and is
durable — each orchestrator row carries its own resumable CLI `session_id`, and every
chat turn is persisted to `agent_logs` keyed by `orchestrator_id`. The gap is purely in
the **UI read path**: the backfill query and the live router are not scoped to the active
orchestrator. This feature closes that gap so "one project ⇒ one brain ⇒ one conversation"
holds end-to-end.

## User Story
As an operator running multiple projects from one console
I want the conversation pane to show the selected project's orchestrator history and live replies
So that each project keeps its own continuous conversation and I never see another project's chat bleed into the one I'm looking at

## Problem Statement
Switching projects swaps the active orchestrator everywhere *except* the conversation
pane. Two concrete defects in the LiveView read path cause this:

1. **Backfill is global, not orchestrator-scoped.** `RepoBuilder.Logs.list_recent_orchestrator_messages/2`
   (`lib/repo_builder/logs.ex:196`) filters only on `not is_nil(l.orchestrator_id) and
   l.event_type == :text_delta` — it returns the most-recent chat rows across **all**
   orchestrators. `ConsoleLive.backfill_messages/2` (`console_live.ex:833`) calls it with
   no id, so when the project switch re-runs `backfill_events/1` (which calls
   `backfill_messages/2`), the pane re-renders the *same* global slice. The conversation
   does not change.

2. **The live chat router is orchestrator-blind.** `ConsoleLive.orchestrator_event?/1`
   (`console_live.ex:2554`) gates chat-pane routing on `String.starts_with?(agent_id,
   "orch-")` only. Orchestrator turn events broadcast under `"orch-<orchestrator_id>-<n>"`,
   so a *background* orchestrator (a second project mid-run) streams its text into the
   chat pane of whatever project is currently being viewed. There is no "is this the
   **active** orchestrator?" check.

Net effect: the conversation pane is a single shared view, contradicting the per-project
binding model the rest of the console already follows.

## Solution Statement
Scope the conversation pane to `socket.assigns.orchestrator_id` on both the backfill and
the live path — no schema change, no new persistence (memory is already durable and
per-orchestrator):

- **Backfill (read):** add an orchestrator-scoped query
  `Logs.list_orchestrator_messages/3` (id + limit + `include_hidden?`) that adds
  `where l.orchestrator_id == ^id`, and have `backfill_messages/2` pass the active
  `orchestrator_id`. Because `switch_orchestrator/2` (shipped) already calls
  `backfill_events/1` *after* `assign_orchestrator_selection/2` sets the new
  `orchestrator_id`, the switch will then reload the correct history automatically. A nil
  active orchestrator (the deep-link/disconnected edge) yields an empty pane, which is the
  correct "no brain selected" state.
- **Live (stream):** add `active_orchestrator_event?/2` that returns true only when
  `agent_id` begins with `"orch-<active_id>-"`, and use it for every chat-pane surface
  (partial-text accumulation, finalized text, finalized thinking) so only the active
  orchestrator's live tokens enter the pane. The center event stream and worker rail are
  unaffected (they already key off `agent_id`/project). Background orchestrators keep
  running and persisting; their messages simply re-appear via backfill when the operator
  switches back — delivering true "hold conversation memory and switch the UI to it."

This is the same project-as-anchor principle the binding work established, finishing the
"reload orchestrator-scoped views" intent of that work's Phase 3 for the chat pane
specifically.

## Relevant Files
Use these files to implement the feature:

- `lib/repo_builder/logs.ex` — the only `Repo` caller for `agent_logs`. Add the
  orchestrator-scoped chat query `list_orchestrator_messages/3` alongside the existing
  global `list_recent_orchestrator_messages/2` (`:196`); reuse `filter_hidden/2` and the
  same ordering/limit/reverse shape. `persist_operator_message/1` (`:116`) and
  `persist_orchestrator_event/2` (`:74`) already key chat rows by `orchestrator_id` — no
  change, just the read scope.
- `lib/repo_builder_web/live/console_live.ex` — the console LiveView. Scope
  `backfill_messages/2` (`:833`) to the active `orchestrator_id`; add
  `active_orchestrator_event?/2` and use it where `orchestrator_event?/1` (`:2554`) gates
  chat routing — the partial `TextDelta` handler (`:2119`), the finalized text handler
  (`:2158`), and the finalized thinking handler (`:2134`). `switch_orchestrator/2`
  (`:289`) and `backfill_events/1` (`:783`, which already resets `streaming`/
  `stream_pending`) need no change beyond benefiting from the scoped backfill.
- `lib/repo_builder/orchestrator/server.ex` — confirms the orchestrator turn `agent_id`
  format `"orch-<orchestrator_id>-<n>"` (`:85`/`:113`) that `active_orchestrator_event?/2`
  matches against. Reference only; no change.
- `test/repo_builder/logs_orchestrator_test.exs` — existing orchestrator-log context test;
  extend it (or add a sibling) for the new scoped query.
- `BUILD_PROMPT.md` — §8 (contexts own all `Repo` access; LiveView never touches
  `Repo`/`Ecto.Query`) and §9 (LiveView dashboard, streams, reconnect/backfill) are the
  governing sections.
- `ai_docs/typed-elixir-standard.md` — the enforced typed standard (`@spec` on every new
  public function, precise types, the Credo `@spec` gate + Dialyzer).
- `AGENTS.md` — Phoenix v1.8 + LiveView conventions for the test and any markup touched.

### New Files
- `test/repo_builder_web/live/test_conversation_history_switch_test.exs` — a
  `Phoenix.LiveViewTest` integration test: two project-bound orchestrators, each with its
  own persisted conversation; switching the project switches the visible chat history, and
  blank returns to the platform orchestrator's conversation.

## Implementation Plan
### Phase 1: Foundation
Add the orchestrator-scoped chat read path in the `Logs` context (the single `Repo`
boundary), mirroring the existing global query exactly but with an `orchestrator_id`
filter. This is the load-bearing change every UI fix depends on. Unit-test it directly
against the Repo with two orchestrators' rows.

### Phase 2: Core Implementation
Wire the LiveView read path to the active orchestrator: scope `backfill_messages/2` and
add the `active_orchestrator_event?/2` live filter, replacing the orchestrator-blind
`orchestrator_event?/1` checks on the three chat-pane surfaces. The shipped
`switch_orchestrator/2` already re-runs `backfill_events/1` after setting the new
orchestrator id and already clears the in-flight streaming buffers, so switching now
reloads and re-scopes the conversation as a side effect.

### Phase 3: Integration
Prove the end-to-end behaviour with a LiveView integration test that drives the project
switcher across two orchestrators and asserts the chat pane content swaps, plus a live
PubSub assertion that a non-active orchestrator's broadcast does not enter the visible
chat. Run the full green gate for zero regressions.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Add the orchestrator-scoped chat query to the `Logs` context
- In `lib/repo_builder/logs.ex`, add a public `@spec`'d function
  `list_orchestrator_messages(orchestrator_id, limit \\ 100, include_hidden? \\ false)`
  that mirrors `list_recent_orchestrator_messages/2` but adds
  `where([l], l.orchestrator_id == ^orchestrator_id and l.event_type == :text_delta)`,
  then `filter_hidden/2`, `order_by desc inserted_at, desc id`, `limit`, `Repo.all`,
  `Enum.reverse` (identical shape/ordering so the chat renders the same way).
- Spec: `@spec list_orchestrator_messages(Ecto.UUID.t(), pos_integer(), boolean()) :: [AgentLog.t()]`.
- Keep the existing global `list_recent_orchestrator_messages/2` (other callers/back-compat);
  add a short `@doc` noting the new one is the per-orchestrator chat backfill source and
  the old one is the unscoped global view.

### 2. Unit-test the scoped query
- Extend `test/repo_builder/logs_orchestrator_test.exs` (or add a focused sibling) to
  persist chat rows for **two** orchestrator ids (operator + orchestrator `:text_delta`
  rows via `persist_operator_message/1` / `persist_orchestrator_event/2`), then assert
  `list_orchestrator_messages/3` returns only the queried orchestrator's rows, in
  insertion order, and honours `include_hidden?` (a hidden row is excluded by default and
  included when `true`).

### 3. Scope the LiveView chat backfill to the active orchestrator
- In `lib/repo_builder_web/live/console_live.ex`, change `backfill_messages/2` to call
  `Logs.list_orchestrator_messages(socket.assigns.orchestrator_id, @messages_limit,
  socket.assigns.show_hidden?)` when `orchestrator_id` is a binary, and return `[]` when
  it is nil (no active brain ⇒ empty pane). Keep the rest of the reduce/`append_chat`
  pipeline unchanged.
- Confirm (no code change expected) that `backfill_events/1` already resets
  `streaming`/`stream_pending` and is invoked by both the connected mount (after
  `assign_orchestrator/1`) and `switch_orchestrator/2` (after
  `assign_orchestrator_selection/2`), so the new scope takes effect on switch.

### 4. Add the active-orchestrator live filter
- Add `@spec active_orchestrator_event?(Phoenix.LiveView.Socket.t(), String.t()) :: boolean()`
  returning `is_binary(active) and String.starts_with?(to_string(agent_id), "orch-" <> active <> "-")`
  where `active = socket.assigns.orchestrator_id`. (Robust against UUID dashes — it matches
  the full active id between the `"orch-"` prefix and the `-<n>` suffix; no UUID parsing.)
- Keep `orchestrator_event?/1` for any non-chat use, but replace the chat-routing checks
  with `active_orchestrator_event?/2` in:
  - the partial `%Event.TextDelta{partial?: true}` handler (`:2119`) — only accumulate the
    streaming bubble for the active orchestrator;
  - the finalized text `%Event.TextDelta{}` handler (`:2158`) — only build the `chat` map
    for the active orchestrator;
  - the finalized thinking `%Event.TextDelta{thinking?: true}` handler (`:2134`) if it
    routes to the chat pane (gate thinking chat on the active orchestrator too).
- Leave center-stream `record_event/3`, the rail, cost/context, and worker handling
  untouched — only the chat-pane surfaces gain the active-orchestrator gate.

### 5. Create the LiveView integration test
- Add `test/repo_builder_web/live/test_conversation_history_switch_test.exs`
  (`use RepoBuilderWeb.ConnCase, async: false` — shared sandbox reaches the LiveView):
  - Create two projects A and B; resolve each orchestrator via
    `Orchestrators.get_or_create_for_project/1`.
  - Persist a distinct conversation for each (e.g. operator "hello A" / orchestrator
    "reply A" for A; "hello B" / "reply B" for B) via the `Logs` persist functions.
  - `live(conn, ~p"/")`, then `render_change(view, "select_project", %{"project_id" =>
    a.id})` and assert the chat pane shows A's lines and **not** B's; switch to B and
    assert the inverse; switch to `""` and assert the platform orchestrator's pane.
  - Add a live assertion: broadcast a `%Event.TextDelta{}` under a *non-active*
    orchestrator's `"orch-<other_id>-1"` agent_id (via the same PubSub topic the console
    subscribes to) and assert it does **not** appear in the visible chat, proving
    `active_orchestrator_event?/2` filters background brains. Reference stable DOM
    ids/`has_element?`, not raw HTML.
- Optionally capture a Playwright screenshot of `http://localhost:4000` showing the pane
  swap as visual proof.

### 6. Run the validation commands
- Run every command in **Validation Commands** and fix any failure or new warning until
  all are green. Do not weaken existing Dialyzer ignore filters.

## Testing Strategy
### Unit Tests
- `Logs.list_orchestrator_messages/3`: returns only the queried orchestrator's
  `:text_delta` rows; preserves insertion order; respects `include_hidden?`; returns `[]`
  for an orchestrator with no messages.
- Verify the existing `list_recent_orchestrator_messages/2` is unchanged (regression).

### Integration Tests (LiveView)
- Switching projects swaps the conversation pane content to the selected orchestrator's
  history; blank restores the platform orchestrator's conversation.
- A background (non-active) orchestrator's live `TextDelta` broadcast does not enter the
  visible chat pane while another project is selected.

### Edge Cases
- **Nil active orchestrator** (e.g. resolve failure / deep-link before bind): chat pane
  backfills empty rather than showing a global mix.
- **Empty conversation**: a freshly-created per-project orchestrator shows an empty pane,
  not the previous project's chat.
- **Reconnect**: after a LiveView reconnect on a selected project, the pane backfills that
  orchestrator's history (driven by the same `backfill_events/1` path).
- **CLEAR / show-hidden**: hidden rows stay hidden in the scoped query unless the
  settings "show hidden" toggle is on (parity with the global query).
- **Concurrent runs**: two projects streaming at once — only the active one's tokens
  render live; the other's are recoverable via backfill on switch.

## Acceptance Criteria
- Selecting a project in the top-left switcher changes the right-hand conversation pane to
  that project's orchestrator history within the same gesture.
- Selecting "All / platform" (blank) shows the platform default orchestrator's
  conversation.
- While project A is selected, orchestrator B's live messages never appear in the chat
  pane; switching to B then shows B's full history (memory preserved).
- No schema/migration change; conversation memory remains the durable per-orchestrator
  `agent_logs` + resumable `session_id`.
- `Logs.list_orchestrator_messages/3` is `@spec`'d and is the only new `Repo` access; the
  LiveView calls the context, never `Repo`/`Ecto.Query` directly (§8).
- All five green-gate commands pass with zero new warnings and no weakened ignore filters.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix test test/repo_builder/logs_orchestrator_test.exs` — the scoped chat query (unit).
- `mix test test/repo_builder_web/live/test_conversation_history_switch_test.exs` — the
  conversation-pane project switch (LiveView integration).
- `mix test test/repo_builder_web/live/test_orchestrator_project_switch_test.exs test/repo_builder_web/live/test_orchestration_console_test.exs` — no regression in the orchestrator switch / console suites.
- `mix compile --warnings-as-errors` — compile clean under the set-theoretic checker.
- `mix test --warnings-as-errors` — full ExUnit suite green.
- `mix format --check-formatted` — formatting clean.
- `mix credo --strict` — lint + the `@spec` gate clean.
- `mix dialyzer` — no new contract warnings; existing ignore filters untouched.

(Optional runtime verification via Tidewave: `project_eval` to call
`RepoBuilder.Logs.list_orchestrator_messages/3` against seeded rows, and `execute_sql_query`
to confirm `agent_logs` chat rows are partitioned by `orchestrator_id`.)

## Notes
- **No new dependency** and **no migration** — the conversation is already persisted
  per-orchestrator (`agent_logs.orchestrator_id`) and each orchestrator already resumes
  its own CLI session (`orchestrators.session_id`). This feature only corrects the UI read
  scope.
- This completes the chat-pane half of the orchestrator↔project binding work's "reload
  orchestrator-scoped views on switch" intent; `switch_orchestrator/2` and the per-row
  context isolation it relies on are already shipped.
- Out of scope (future): a per-orchestrator unread/badge indicator on background
  conversations; persisting the operator's last-selected project across sessions; loading
  older history on scroll (the pane keeps the existing `@messages_limit` window).
- The `agent_id` → orchestrator matching uses the existing `"orch-<id>-<n>"` convention
  from `orchestrator/server.ex`; if that format ever changes, `active_orchestrator_event?/2`
  and `orchestrator_event?/1` must change together.
```
