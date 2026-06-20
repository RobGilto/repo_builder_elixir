# Bug: Orchestrator chat history does not persist when the server is restarted

## Metadata
issue_number: `chat`
adw_id: `history`
issue_json: `does`

## Bug Description
The ConsoleLive orchestrator **chat pane** (the right-hand conversation transcript built from the `@messages` assign) appears to "lose" all prior orchestrator messages after the Phoenix server is restarted (or, equivalently, after the LiveView reconnects / the page is reloaded against a freshly-restarted node).

- **Expected:** After restarting the server and reloading `http://localhost:4000`, the orchestrator chat pane re-displays the prior orchestrator conversation turns that were durably recorded, exactly as it does while the LiveView stays connected.
- **Actual:** After a restart/reload, the orchestrator chat pane comes back **empty (or missing most/all earlier turns)**, even though the orchestrator's text was persisted to the database. The center event stream may still show recent activity, but the orchestrator conversation transcript does not survive.

This is a UX/observability regression: the orchestrator conversation looks ephemeral even though the underlying events are durably stored.

## Problem Statement
Orchestrator conversation turns **are** persisted to the `agent_logs` table (via `RepoBuilder.Logs.persist_orchestrator_event/2`, with `orchestrator_id` set and the `"orch-…"` turn id in `session_id`). However, on (re)connect the chat pane is **not** rebuilt from an orchestrator-scoped query. It is rebuilt as a *byproduct* of the **global, worker-dominated** event backfill, which is capped at the most-recent 200 rows across **all** agents. Because workers emit far more events (tool calls, tool results, streamed text) than the orchestrator, the orchestrator's sparse chat rows are pushed out of that 200-row global window as soon as any meaningful worker activity exists. The result: the chat pane backfills empty even though the orchestrator messages are sitting in the DB.

## Solution Statement
Add a dedicated, **orchestrator-scoped** backfill query in the `RepoBuilder.Logs` context that returns the most-recent orchestrator `:text_delta` rows (the finalized assistant text that becomes chat) independent of the worker-dominated global window, and seed the console's `@messages` chat pane from it on connect. The center event stream keeps using the existing `list_recent_global/2`; only the chat-pane seeding changes so it no longer depends on whether orchestrator rows happen to fall inside the global 200-row slice.

This is the minimal, surgical fix: it does not change persistence (already correct), does not add a new table, and does not touch the live streaming path — it only fixes the reconnect/restart **backfill source** for the chat pane.

## Steps to Reproduce
1. Start Postgres (`scripts/pg.sh start`) and the server (`mix phx.server`); open `http://localhost:4000`.
2. Run one or more orchestrator turns so the chat pane shows ORCHESTRATOR messages.
3. Spawn/exercise one or more worker agents (or run an ADW) so that **more than ~200** `agent_logs` rows accumulate *after* the last orchestrator message (worker tool/text events are high-volume).
4. Restart the server (or simply reload the page so the LiveView re-mounts and `backfill_events/1` runs again).
5. **Observe:** the orchestrator chat pane is empty (or missing the earlier turns), even though `agent_logs` still contains the orchestrator `:text_delta` rows.

Runtime reproduction via Tidewave (preferred over guessing):
- Use `execute_sql_query` to confirm orchestrator rows exist:
  `SELECT count(*) FROM agent_logs WHERE orchestrator_id IS NOT NULL AND event_type = 'text_delta';`
- Use `project_eval` to show the bug directly:
  `length(RepoBuilder.Logs.list_recent_global(200, false) |> Enum.filter(& &1.orchestrator_id))`
  — observe this is 0 (or far fewer than the true count above) once worker rows dominate.

## Root Cause Analysis
The chat pane is **ephemeral in-memory state** (`@messages`, initialized to `[]`), rebuilt on every connect by `backfill_events/1`. That function seeds *both* the center stream and the chat pane from a single source:

```elixir
# lib/repo_builder_web/live/console_live.ex:640-657
defp backfill_events(socket) do
  logs = Logs.list_recent_global(200, socket.assigns.show_hidden?)   # <-- global, worker-dominated, capped at 200
  ...
  {rows, messages, seq} =
    Enum.reduce(logs, {[], [], 0}, fn log, {rows, msgs, seq} ->
      ...
      msgs = append_chat(msgs, chat_for_row(row), seq, timezone)     # <-- chat derived from the SAME 200 global rows
      ...
    end)
  ...
  |> assign(event_buffer: rows, messages: Enum.take(messages, -@messages_limit), seq: seq)
```

`list_recent_global/2` (`lib/repo_builder/logs.ex:127-135`) orders **all** `agent_logs` by recency and takes the last `limit` (200). `chat_for_row/1` then keeps only orchestrator `:text_delta` rows (`orchestrator_event?/1` gate on the `"orch-"` prefix carried in `agent_key = log.agent_id || log.session_id`).

Because workers emit many more events than the orchestrator, the orchestrator's chat rows fall outside the most-recent-200 global slice whenever ≥200 worker rows exist after the last orchestrator message. While the LiveView stays connected, `@messages` keeps accumulating live (so it *looks* persistent); but a restart/reconnect resets `@messages` and rebuilds it solely from this worker-dominated window — so the chat history disappears.

**Key conclusion:** persistence is correct; the **reconnect/restart backfill source for the chat pane is wrong** — it must be orchestrator-scoped, not the global stream slice.

## Relevant Files
Use these files to fix the bug:

- `lib/repo_builder/logs.ex` — Add a new `@spec`'d, orchestrator-scoped backfill query (`list_recent_orchestrator_messages/2`) alongside `list_recent/2` and `list_recent_global/2`. This is the typed context boundary for `agent_logs` reads (BUILD_PROMPT.md §8).
- `lib/repo_builder/logs/agent_log.ex` — Schema reference; confirms `orchestrator_id` and `event_type` fields and the `hidden` soft-hide flag the new query must respect (mirror `filter_hidden/2`).
- `lib/repo_builder_web/live/console_live.ex` — `backfill_events/1` (lines 640-668) seeds `@messages`; change it to build the chat pane from the new orchestrator-scoped query while keeping the center stream on `list_recent_global/2`. Reuse the existing `log_to_row/4` + `chat_for_row/1` + `append_chat/3` helpers (single source of truth) so rendering is identical to the live path. Respect `@messages_limit` (100) and the `show_hidden?` toggle.
- `test/repo_builder_web/live/test_orchestrator_chat_worker_isolation_test.exs` — Existing nearest-neighbor test for orchestrator-vs-worker chat separation; reference for setup patterns (creating orchestrator/worker logs, mounting ConsoleLive).
- `test/repo_builder_web/live/test_orchestration_console_test.exs` — Reference for ConsoleLive mount + backfill assertions.

### New Files
- `test/repo_builder_web/live/test_orchestrator_chat_history_persist_test.exs` — `Phoenix.LiveViewTest` integration test that persists orchestrator `:text_delta` rows to `agent_logs`, then floods `agent_logs` with >200 worker rows inserted *after* them, mounts ConsoleLive, and asserts the orchestrator chat pane still renders the orchestrator messages (fails before the fix because the global-200 window drops them; passes after).

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Add an orchestrator-scoped backfill query to the Logs context
- In `lib/repo_builder/logs.ex`, add `@spec list_recent_orchestrator_messages(pos_integer(), boolean()) :: [AgentLog.t()]` and its implementation.
- Query `AgentLog` `where(not is_nil(l.orchestrator_id) and l.event_type == :text_delta)`, apply the same `filter_hidden(include_hidden?)` helper used by `list_recent_global/2`, `order_by(desc: l.inserted_at, desc: l.id)`, `limit(^limit)`, `Repo.all()`, then `Enum.reverse()` to return chronological order. Default `limit \\ 100`, `include_hidden? \\ false` to mirror the existing functions' signatures.
- Add a `@doc` explaining this is the chat-pane reconnect/restart backfill source, independent of the worker-dominated global stream window (cite the bug: orchestrator rows fall out of the global slice once workers dominate).
- Keep it idiomatic and typed per BUILD_PROMPT.md §3/§8.

### 2. Seed the chat pane from the orchestrator-scoped query in ConsoleLive
- In `lib/repo_builder_web/live/console_live.ex` `backfill_events/1`, keep the center-stream rebuild on `Logs.list_recent_global(200, socket.assigns.show_hidden?)` exactly as is.
- Build `@messages` from a separate reduce over `Logs.list_recent_orchestrator_messages(@messages_limit, socket.assigns.show_hidden?)`, converting each row via the existing `log_to_row/4` (for `agent_key`/`thinking?`/`body`) → `chat_for_row/1` → `append_chat/3`, then `Enum.take(messages, -@messages_limit)`.
- IMPORTANT: the chat reduce needs its own `seq` so chat entry ids stay unique and don't collide with the center-stream `seq`; do not let the two reduces share/overwrite `seq`. Use a distinct counter (e.g. negative or offset ids, or a separate accumulator) consistent with how `append_chat/3` keys entries.
- Update the `assign(event_buffer: ..., messages: ..., seq: ...)` call so `messages` comes from the new orchestrator-scoped reduce while `event_buffer`/`seq` stay tied to the global stream.
- Preserve all other behavior in `backfill_events/1` (streaming reset, selection reset, `seed_context_tokens/1`, `seed_counters/1`, `stream(:events, rows, reset: true)`).

### 3. Add the failing-then-passing LiveView integration test
- Create `test/repo_builder_web/live/test_orchestrator_chat_history_persist_test.exs` using `RepoBuilderWeb.ConnCase` + `Phoenix.LiveViewTest` + `import Phoenix.LiveViewTest`.
- Arrange: insert several orchestrator `:text_delta` `agent_logs` rows (set `orchestrator_id`, `session_id: "orch-<id>"`, distinctive `payload` text, `thinking?` false) via `RepoBuilder.Logs.persist_orchestrator_event/2` or direct `Repo.insert!` of `AgentLog.changeset/2`.
- Then insert **> 200** worker `agent_logs` rows (set `agent_id`, varied `event_type`s) with later `inserted_at` so they dominate the global most-recent-200 window.
- Act: `{:ok, view, html} = live(conn, "/")`.
- Assert: the rendered chat pane contains the orchestrator message text (use a selector/text scoped to the chat pane). This FAILS before the fix (chat empty) and PASSES after.
- Add a control assertion that purely-worker text does **not** appear in the chat pane (orchestrator-only gate still holds), reusing the isolation expectations from `test_orchestrator_chat_worker_isolation_test.exs`.

### 4. Add/extend a Logs context unit test (optional but recommended)
- In the existing logs test module (or a small new one), assert `list_recent_orchestrator_messages/2` returns only orchestrator `:text_delta` rows, in chronological order, respecting `hidden`, even when worker rows vastly outnumber them. This guards the query independent of the LiveView.

### 5. Verify in the running app via Tidewave (no restart needed for the fix; code reloads)
- Use `project_eval` to confirm `RepoBuilder.Logs.list_recent_orchestrator_messages(100, false)` returns the orchestrator rows that `list_recent_global(200,false)` drops.
- Optionally capture a screenshot of `http://localhost:4000` after a reload to visually confirm the chat pane is repopulated.

### 6. Run the full validation suite
- Run every command in **Validation Commands** and ensure all are green with zero regressions.

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- `mix test test/repo_builder_web/live/test_orchestrator_chat_history_persist_test.exs` — The new LiveView integration test: fails before the fix, passes after.
- `mix test test/repo_builder_web/live/test_orchestrator_chat_worker_isolation_test.exs` — Ensure the orchestrator/worker chat separation still holds (no regression).
- `mix compile --warnings-as-errors` — Compile clean; gradual set-theoretic type checker and `warnings_as_errors` must pass.
- `mix test --warnings-as-errors` — Full ExUnit suite (Postgres-backed) with zero failures.
- `mix format --check-formatted` — Code is formatted.
- `mix credo --strict` — Lint, including the "every public function has an `@spec`" convention (covers the new `list_recent_orchestrator_messages/2`).
- `mix dialyzer` — `@spec`/contract checking with no new warnings and no stale ignore filters.

## Notes
- **No new dependency, no migration, no new table.** Persistence already works; this fix only corrects the reconnect/restart **backfill source** for the chat pane.
- **Why not just raise the global limit?** Increasing `list_recent_global/2`'s 200 cap would bloat the center stream, still not guarantee orchestrator coverage (a long worker run can exceed any fixed window), and harms reconnect performance. An orchestrator-scoped query is the correct, bounded fix.
- The chat pane currently shows **any** orchestrator (`orch-` prefix) text globally; the new query matches that semantics by filtering `not is_nil(orchestrator_id)` rather than a single `orchestrator_id`. If a future requirement scopes the console to one orchestrator, narrow the query to `socket.assigns.orchestrator_id` then — out of scope here.
- Keep the float→Decimal and redaction boundaries untouched; this change is read-only over already-persisted, already-scrubbed rows.
- Mind the dual `seq` counters in `backfill_events/1` (Step 2) — sharing one counter between the global-stream reduce and the chat reduce would produce duplicate/colliding row ids.
