# Bug: Orchestrator chat pane shows worker-agent messages

## Metadata
issue_number: `NA`
adw_id: `NA`
issue_json: `{}` (interactive `/bug` invocation — see Bug Description for the verbatim report)

## Bug Description
The right-hand **orchestrator chat** pane is supposed to show only the human-facing
conversation between the user and the orchestrator brain. Instead it also renders
**worker-agent** messages — e.g. the `crud-debugger` worker's text responses appear as
orchestrator chat bubbles. Every agent that streams over the global `console:events`
feed currently lands in the chat, not just the orchestrator.

- **Expected:** the chat pane shows only user prompts and the orchestrator's own
  text replies (orchestrator ↔ user). Worker activity belongs in the center **event
  stream** (where it is already attributed per-agent), not in the chat.
- **Actual:** worker-agent finalized text (and in-flight streaming text) is shown in
  the chat pane as `ORCHESTRATOR` bubbles, and reappears there after a reconnect.

Verbatim report: "in orchestrator chat it is displaying the agents messages, for
example the crud-debugger messages, which is not correct … it should only display
orchestrator chats with the user".

## Problem Statement
The chat-append logic in `ConsoleLive` is **agent-blind**: it turns any `Event.TextDelta`
into a chat bubble regardless of whether the source is the orchestrator turn or a
spawned worker session. There is no check that the event originated from the
orchestrator, so worker text pollutes the conversation pane.

## Solution Statement
Introduce a single predicate that identifies orchestrator-sourced events and gate every
chat-pane surface on it. Orchestrator turns broadcast under an `agent_id` namespaced
`"orch-<orchestrator_id>-<n>"` (`lib/repo_builder/orchestrator/server.ex:85,113`), while
worker DB agents broadcast under their Ecto UUID `agent_id` (never `"orch-"`). So
`orchestrator_event?(agent_id)` ≙ `String.starts_with?(to_string(agent_id), "orch-")`.
Gate the three chat surfaces with it; leave the center event stream (and per-agent
attribution there) completely untouched. This is a minimal, surgical change — no schema,
no new deps, no context-module changes.

## Steps to Reproduce
1. Start the app (`http://localhost:4000`) with a working orchestrator harness.
2. Send a prompt that causes the orchestrator to spawn a worker (e.g. a `crud-debugger`).
3. Watch the worker stream its response.
4. Observe the right-hand chat pane: the worker's text appears there as an `ORCHESTRATOR`
   bubble (both while streaming and after it finalizes).
5. Reload the page: the worker's text reappears in the chat pane from persisted history.

Deterministic reproduction without a live harness (used by the test): broadcast two
`Event.TextDelta` finalized events over `Dashboard.broadcast_event/2` — one under an
`"orch-…"` agent_id (orchestrator) and one under a UUID agent_id (worker) — then assert
both currently render as `.cns-bubble--orch` in the chat (the bug), instead of only the
orchestrator one.

## Root Cause Analysis
All three chat-pane surfaces are agent-blind:

1. **Live finalized text** — the finalized `Event.TextDelta` handler
   (`console_live.ex` ~line 1016) builds `chat: %{role: :orchestrator, …}` for **any**
   `agent_id` and `record_event/3` → `maybe_chat/3` appends it to `@messages`.
2. **Live in-flight streaming** — partial deltas (`partial?: true`) are handled at
   ~line 996 by `accumulate_partial/4`, which builds the `@streaming` buffer keyed by
   **any** `agent_id`; the chat aside renders `for {agent_id, buf} <- @streaming`, so
   every agent's in-flight text shows as a streaming bubble in the chat.
3. **Reconnect backfill** — `backfill_events/1` (line 388-397) calls `chat_for_row/1`
   (~line 1758), which maps **any** `:response` row to an orchestrator chat message,
   so worker text rows are reconstructed into the chat after a reload.

The distinguishing signal already exists and is consistent: orchestrator turns are
broadcast under `"orch-#{orchestrator.id}-#{n}"` (`orchestrator/server.ex:85` and `:113`),
whereas worker sessions use the agent's DB UUID. The bug is simply the absence of an
`agent_id` check before appending to the chat.

## Relevant Files
Use these files to fix the bug:

- `lib/repo_builder_web/live/console_live.ex` — Contains all three leaking surfaces:
  the partial-delta handler (~996, `accumulate_partial`), the finalized-text handler
  (~1016, the `chat:` attrs), `record_event/3`/`maybe_chat/3` (~1136/1232), and the
  backfill `chat_for_row/1` (~1758). The new `orchestrator_event?/1` predicate and the
  three gates live here. The chat render of `@streaming` is ~line 1616.
- `lib/repo_builder/orchestrator/server.ex` — Authoritative source of the orchestrator
  `agent_id` namespacing (`"orch-#{orchestrator.id}-#{n}"` at lines 85 and 113). Confirms
  the predicate; no change needed here, but it documents the contract the fix depends on.
- `lib/repo_builder_web/components/console_components.ex` — The chat bubble components
  (`chat_message/1`, `streaming_bubble/1`) — for reference only; the markup is correct,
  the bug is which events feed it. No change expected.
- `BUILD_PROMPT.md` — §3 typed style guide (new private predicate needs a precise
  `@spec`; build is `--warnings-as-errors`), §9 LiveView/reconnect rules (the backfill
  must stay consistent with the live path).
- `.claude/commands/conditional_docs.md` — Read to confirm no extra docs apply to this
  UI-only fix (expected: only the typed-Elixir standard already enforced by Credo/Dialyzer).

### New Files
- `test/repo_builder_web/live/test_orchestrator_chat_worker_isolation_test.exs` — A
  `Phoenix.LiveViewTest` integration test that reproduces the bug (fails before, passes
  after): broadcasts an orchestrator `TextDelta` (agent_id `"orch-…"`) and a worker
  `TextDelta` (UUID agent_id), and asserts the chat pane shows only the orchestrator
  text while the worker text is absent from the chat but present in `#event-stream`.
  Also covers the in-flight streaming surface and the reconnect/backfill surface.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Read context and confirm the contract
- Read `BUILD_PROMPT.md` §3 and §9, and `.claude/commands/conditional_docs.md`.
- Re-confirm the orchestrator `agent_id` prefix in `orchestrator/server.ex:85,113`
  (`"orch-…"`) and that worker DB agents use UUID `agent_id`s (no `"orch-"`).

### 2. Write the failing LiveViewTest (red)
- Create `test/repo_builder_web/live/test_orchestrator_chat_worker_isolation_test.exs`
  using `RepoBuilderWeb.ConnCase, async: false` + `Phoenix.LiveViewTest`.
- Mount `live(conn, ~p"/")`.
- **Finalized surface:** broadcast
  `Dashboard.broadcast_event("orch-#{Ecto.UUID.generate()}-1", %Event.TextDelta{harness: :fake, text: "orchestrator hello"})`
  and
  `Dashboard.broadcast_event(Ecto.UUID.generate(), %Event.TextDelta{harness: :fake, text: "crud-debugger worker output"})`.
  Assert: `has_element?(view, ".cns-bubble--orch", "orchestrator hello")` is true, and
  `has_element?(view, ".cns-bubble--orch", "crud-debugger worker output")` is **false**,
  while the worker text is present in `#event-stream` (so it's not lost, just not in chat).
- **Streaming surface:** broadcast a `partial?: true` worker `TextDelta` and a
  `partial?: true` orchestrator `TextDelta`, send `:flush_stream` to the view, and assert
  only the orchestrator streaming bubble renders in the chat (the worker one is absent).
- **Backfill surface (optional but recommended):** if practical, persist a worker
  `text_delta` log and a reconnect, asserting the worker text does not reconstruct into
  the chat. If a full reconnect is awkward, assert `chat_for_row/1` behavior indirectly
  via the finalized assertions above and cover backfill in step 4.
- Run it; confirm it FAILS on the worker-in-chat assertions (reproduces the bug).

### 3. Add the orchestrator-source predicate
- In `console_live.ex`, add a private helper:
  `@spec orchestrator_event?(String.t()) :: boolean()`
  `defp orchestrator_event?(agent_id), do: String.starts_with?(to_string(agent_id), "orch-")`.

### 4. Gate the three chat-pane surfaces on the predicate
- **Finalized text** (~line 1016): only set the `chat:` key when
  `orchestrator_event?(agent_id)`; otherwise omit it (or set `nil` — `maybe_chat/3`
  already no-ops on `nil`). The center-stream `record_event/3` row is unchanged, so
  worker text still appears (attributed) in `#event-stream`.
- **In-flight streaming** (~line 996 partial handler): only `accumulate_partial/4` when
  `orchestrator_event?(agent_id)`; for worker partials, return the socket unchanged
  (no chat streaming buffer is built). The center stream does not depend on partials.
- **Reconnect backfill** (`chat_for_row/1`, ~line 1758): add a guard so only rows whose
  `agent_key` satisfies `orchestrator_event?/1` map to an orchestrator chat message;
  worker `:response` rows fall through to `nil`. (`row.agent_key` carries the agent_id.)

### 5. Verify no regressions to the orchestrator path and the thinking/tool changes
- Confirm orchestrator text still appears in chat (predicate true for `"orch-…"`).
- Confirm the earlier chat/events separation still holds (thinking/tool not in chat).

### 6. Run the LiveViewTest (green) and optional visual check
- Re-run the new test; it must pass.
- Optionally drive a real orchestrator+worker run and screenshot `http://localhost:4000`
  showing the chat pane free of worker messages while `#event-stream` shows them.

### 7. Run the Validation Commands
- Run every command in the Validation Commands section; all green with zero regressions.
- Note: the two pre-existing `test_orchestration_console_test.exs` failures
  (`spawn failed: env - invalid env argument #234`, the erlexec env gotcha) are
  unrelated; confirm they are unchanged, not newly introduced.

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- `mix test test/repo_builder_web/live/test_orchestrator_chat_worker_isolation_test.exs` —
  The new reproduction test passes (worker text excluded from chat, present in stream).
- `mix test test/repo_builder_web/live/test_streaming_console_test.exs test/repo_builder_web/live/test_orchestrator_thinking_toggle_test.exs` —
  Existing chat/streaming behavior is preserved (orchestrator text + streaming bubbles
  still render; thinking/tool stay out of chat).
- `mix compile --warnings-as-errors` — Clean compile; gradual type checker + warnings gate pass.
- `mix test --warnings-as-errors` — Full suite; no new failures (only the two known
  erlexec-spawn env failures may remain, unchanged).
- `mix format --check-formatted` — Formatting clean.
- `mix credo --strict` — Lint passes, including the `@spec`-on-every-public-function gate.
- `mix dialyzer` — No new contract warnings; no stale ignore filters.

## Notes
- UI/LiveView-only fix: no new dependencies, no migration, no context/`Repo` changes;
  the §8 DB-access boundary is untouched.
- The predicate keys off the `"orch-"` `agent_id` namespacing in
  `orchestrator/server.ex`. If that namespacing ever changes, the predicate must change
  with it — consider extracting a shared constant/helper (e.g. an
  `Orchestrator.Server.orchestrator_agent_id?/1`) as a follow-up to avoid the string
  literal living in the LiveView. Kept inline here to stay minimal/surgical.
- Worker text is **not** suppressed globally — it remains fully visible and attributed
  in the center event stream (and filterable per-agent). This bug is strictly about the
  chat pane's audience: orchestrator ↔ user only.
- Related prior change: thinking/tool events were already removed from the chat (the
  tac-14 chat/events separation). This fix completes that separation by also excluding
  worker-agent text from the chat.
```
