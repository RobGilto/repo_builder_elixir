# Bug: Operator messages don't persist (and vanish from) the orchestrator chat history

## Metadata
issue_number: `operator`
adw_id: `messages`
issue_json: `are`

## Bug Description
In the ConsoleLive orchestrator chat pane, the **operator's own messages** ("YOU" turns — the prompts the human types and sends to the orchestrator) are not durable. They appear momentarily as a local echo while the LiveView stays connected, but:

- **Not persisting:** they are **never written to the database**. On any LiveView reconnect or server restart, `backfill_events/1` rebuilds the chat pane purely from persisted rows, so the operator turns are gone — the chat comes back showing only the orchestrator's replies, a one-sided transcript.
- **Not showing (after reconnect):** because they were never persisted, a reconnect/restart renders the conversation with the operator prompts missing entirely. This was made more visible by the recent orchestrator-chat backfill fix (`issue-chat-history-backfill`), which now correctly restores orchestrator replies — making the absence of the matching operator prompts obvious.
- **Colour:** the operator turns should be visually distinct from orchestrator turns (a different bubble colour) so the conversation reads as a dialogue.

- **Expected:** Operator messages render in the chat pane in a distinct colour AND survive reconnect/restart, interleaved in order with the orchestrator's replies (a complete two-sided transcript).
- **Actual:** Operator messages show only as an ephemeral local echo and disappear on reconnect/restart; only orchestrator replies are restored.

## Problem Statement
The operator message is added to ephemeral LiveView state only (`push_user_message/2` appends `%{role: :user, label: "YOU"}` to the `@messages` assign) and is **never persisted** to `agent_logs` (or any table). The reconnect/restart chat backfill (`backfill_messages/2` → `Logs.list_recent_orchestrator_messages/2`) only reads persisted orchestrator `:text_delta` rows, so operator turns cannot be reconstructed. The fix must durably record operator turns in an orchestrator-scoped way that the existing backfill can restore and render as the `:user` role.

## Solution Statement
Persist each operator prompt as an **orchestrator-scoped `agent_logs` row** at the single operator entry point (the public `Orchestrator.Queue.enqueue/2`, which is only ever called for operator-originated turns — internal holding-pattern resume turns use a different, non-public path/kind). Reuse the existing schema (no migration): store it as `event_type: :text_delta` with a payload marker `payload["role"] = "operator"` so it is distinguishable from orchestrator reply text that shares the same `orchestrator_id`. Then teach the backfill to recognize the marker:

- `log_to_row/4` carries the role marker through to the row.
- `chat_for_row/1` maps an operator-marked row to `%{role: :user, label: "YOU"}` (rendered by the existing `cns-bubble--user` colour) instead of the orchestrator bubble.
- `backfill_events/1` keeps operator rows **out of the center event stream** (operator text belongs to the chat pane only — matching the live path, where `push_user_message/2` never writes a center-stream row).

The live echo (`push_user_message/2`) stays for instant feedback; persistence runs in parallel with no broadcast, so the originating console never double-renders, and a reconnect/restart restores the full transcript from the DB. The "different colour" requirement is already satisfied by the existing `cns-bubble--user` style (`--cns-bubble-user: #1e3a5f`, a blue distinct from the orchestrator `--cns-bubble-orch: #2a2a2a`); the fix ensures backfilled operator rows actually use it.

## Steps to Reproduce
1. Start Postgres (`scripts/pg.sh start`) and the server (`mix phx.server`); open `http://localhost:4000`.
2. Send one or more prompts to the orchestrator (leave the agent filter unset so it routes to the orchestrator brain). Observe your "YOU" messages appear in the chat alongside the orchestrator's replies.
3. Reload the page (or restart the server) so the LiveView re-mounts and `backfill_events/1` runs.
4. **Observe:** the chat pane restores the orchestrator's replies but **not** your operator prompts — the transcript is now one-sided.

Runtime confirmation via Tidewave (prefer over guessing):
- `execute_sql_query`:
  `SELECT count(*) FROM agent_logs WHERE orchestrator_id IS NOT NULL AND (payload->>'role') = 'operator';`
  — returns **0** before the fix (operator turns were never persisted), confirming the root cause.
- `project_eval`: inspect `RepoBuilder.Logs.list_recent_orchestrator_messages(100, false)` — every returned row is an orchestrator reply; none are operator turns.

## Root Cause Analysis
`push_user_message/2` (`lib/repo_builder_web/live/console_live.ex:1743-1753`) is the only place an operator turn is recorded, and it writes **only** to the in-memory `@messages` assign:

```elixir
defp push_user_message(socket, prompt) do
  seq = socket.assigns.seq + 1
  msg = %{role: :user, label: "YOU", content: prompt, tool_name: nil, params_json: nil}
  socket
  |> assign(:seq, seq)
  |> assign(:messages, append_chat(socket.assigns.messages, msg, seq, socket.assigns.timezone))
end
```

It is called from `run_orchestrator/2` and `run_prompt/4` but is **never accompanied by a DB write**. Orchestrator *replies*, by contrast, are persisted by the orchestrator runtime via `Logs.persist_orchestrator_event/2` (`lib/repo_builder/orchestrator/server.ex`), so they survive reconnect; operator turns do not.

On reconnect/restart, `backfill_events/1` (`console_live.ex:640`) rebuilds the chat from `backfill_messages/2` → `Logs.list_recent_orchestrator_messages/2`, which queries `agent_logs WHERE not is_nil(orchestrator_id) and event_type == :text_delta`. Since operator turns were never inserted there, they cannot be restored — hence "not persisting" and, post-reconnect, "not showing".

**Conclusion:** the operator message is purely ephemeral UI state. The fix is to give it a durable, orchestrator-scoped representation that the existing backfill restores and that `chat_for_row/1` renders as the distinct `:user` bubble.

## Relevant Files
Use these files to fix the bug:

- `lib/repo_builder/logs.ex` — Add a typed `persist_operator_message/2` (mirrors `persist_orchestrator_event/2`): inserts an orchestrator-scoped `agent_logs` row with `event_type: :text_delta` and `payload: %{"text" => prompt, "role" => "operator"}`. This is the `@spec`'d context boundary for the new persistence (BUILD_PROMPT.md §8). `list_recent_orchestrator_messages/2` already returns these rows for the chat backfill — no query change needed.
- `lib/repo_builder/orchestrator/queue.ex` — `enqueue/2` (lines 108-113) is the single public, operator-only entry for orchestrator turns (always `kind: :operator`; internal resume turns never call it). Persist the operator message here so both callers (`console_live` and `Orchestrator.Server.run_turn/2`) are covered exactly once, and synthesized holding-pattern resume prompts are never mislabeled as operator turns.
- `lib/repo_builder_web/live/console_live.ex` — Backfill rendering:
  - `log_to_row/4` (~line 3120): carry the operator role marker from `log.payload["role"]` onto the row.
  - `chat_for_row/1` (~line 3147): branch so an operator-marked row → `%{role: :user, label: "YOU"}` (the `cns-bubble--user` colour) rather than the orchestrator bubble.
  - `backfill_events/1` (line 640): exclude operator-marked rows from the center-stream `rows` so operator text stays chat-pane-only (parity with the live path). Keep `push_user_message/2` for the instant local echo.
- `lib/repo_builder_web/components/console_components.ex` — `chat_message/1` (lines 654-668) already renders `:user` vs `:orchestrator` with `cns-bubble--user`/`cns-bubble--orch`; reference only (no change expected). The `role` attr `values: [:user, :orchestrator]` already permits `:user`.
- `assets/css/app.css` — `cns-bubble--user` (line 341) + `--cns-bubble-user` (line 142) already provide the distinct colour; reference only. Optionally tune the colour here if the operator wants a stronger contrast.
- `BUILD_PROMPT.md` §8 (persistence / JSONB), §9 (LiveView reconnect rule), §13 (testing / FakeHarness) — authoritative context.
- `ai_docs/typed-elixir-standard.md` — the enforced typed standard (always-applies row of the conditional-docs router): `@spec` on the new public function, precise types, no `String.to_atom/1` on untrusted keys.
- `AGENTS.md` — Phoenix v1.8 + LiveView conventions for the test and any markup touch.
- `specs/issue-chat-adw-history-sdlc_planner-orchestrator-chat-history-backfill.md` — the related, already-fixed orchestrator backfill; this fix builds directly on its `agent_key`-from-`orchestrator_id` derivation, so operator rows MUST carry the `role` marker to be told apart from orchestrator replies that share the `orchestrator_id`.

### New Files
- `test/repo_builder_web/live/test_operator_message_persist_test.exs` — `Phoenix.LiveViewTest` integration test that persists an operator message + an orchestrator reply (and floods worker rows), mounts ConsoleLive, and asserts BOTH turns appear in the chat with distinct bubbles (`.cns-bubble--user` for the operator, `.cns-bubble--orch` for the orchestrator) and that the operator turn survives reconnect. Fails before the fix (operator turn absent on backfill), passes after.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Add `persist_operator_message/2` to the Logs context
- In `lib/repo_builder/logs.ex`, add `@spec persist_operator_message(String.t(), %{required(:orchestrator_id) => Ecto.UUID.t(), optional(:session_id) => String.t(), optional(:harness) => String.t()}) :: {:ok, AgentLog.t()} | {:error, Ecto.Changeset.t()}`.
- Build params: `orchestrator_id` (required), `session_id` (caller-supplied or a synthesized `"orch-#{id}-op-#{System.unique_integer([:positive])}"`), `event_type: :text_delta`, `harness` (the orchestrator's harness string, for column parity), `payload: %{"text" => prompt, "role" => "operator", "thinking" => false}`. Insert via `AgentLog.changeset/2` + `Repo.insert/1`.
- `@doc` it as the durable record of an operator chat turn (the user side of the transcript), distinguished from orchestrator reply text by `payload["role"] == "operator"`; cite this bug.
- Keep typed/idiomatic per BUILD_PROMPT.md §3 and `ai_docs/typed-elixir-standard.md`.

### 2. Persist the operator message at the operator entry point
- In `lib/repo_builder/orchestrator/queue.ex` `enqueue/2`, after resolving the orchestrator (so we have `orchestrator_id`) and before/at the `GenServer.call({:enqueue, prompt, :operator})`, call `Logs.persist_operator_message(prompt, %{orchestrator_id: orchestrator_id})`. Treat a `{:error, _}` insert as non-fatal (log + continue; the turn must still run) — match the persist-then-broadcast tolerance used by `persist_orchestrator_event` callers.
- Do NOT broadcast a live event for it (the LiveView already echoes via `push_user_message/2`; broadcasting would double-render on the originating console). Note this trade-off (a second concurrent console sees the operator turn only after reconnect) in the plan Notes.
- Confirm the internal holding-pattern resume path does NOT route through this public `enqueue/2` (it builds items with a non-`:operator` kind), so resume prompts are never persisted as operator turns.

### 3. Carry the role marker through the backfill row
- In `console_live.ex` `log_to_row/4`, read `role = log.payload["role"]` and include it on the returned row map (e.g. `chat_role: role`), alongside the existing `thinking?` flag.

### 4. Route operator rows to the `:user` bubble in the chat backfill
- In `chat_for_row/1`, add a clause: a `:response` (text_delta) row whose `chat_role == "operator"` maps to `%{role: :user, label: "YOU", content: body, tool_name: nil, params_json: nil}`. Keep the existing orchestrator clause for non-operator orchestrator text. Ensure thinking rows still short-circuit to `nil`.
- Verify `append_chat/3` + `chat_message/1` render the `:user` role with `cns-bubble--user` (already supported).

### 5. Keep operator rows out of the center event stream on backfill
- In `backfill_events/1`, when building the center-stream `rows` from `list_recent_global/2`, skip rows where `chat_role == "operator"` (operator text is chat-pane-only, mirroring the live path where `push_user_message/2` writes no center-stream row). The chat pane is still seeded by `backfill_messages/2`/`list_recent_orchestrator_messages/2`, which includes operator rows.

### 6. Create the failing-then-passing LiveView integration test
- Create `test/repo_builder_web/live/test_operator_message_persist_test.exs` using `RepoBuilderWeb.ConnCase` + `import Phoenix.LiveViewTest`.
- Arrange: create an orchestrator; persist one operator turn via `RepoBuilder.Logs.persist_operator_message("hello orchestrator", %{orchestrator_id: orch.id})`; persist one orchestrator reply via `Logs.persist_orchestrator_event(%Event.TextDelta{harness: :fake, text: "orchestrator reply"}, %{orchestrator_id: orch.id, session_id: Ecto.UUID.generate()})`. Optionally flood >200 later worker rows (reuse the pattern from `test_orchestrator_chat_history_persist_test.exs`) to prove the operator turn survives the worker-dominated window.
- Act: `{:ok, view, _html} = live(conn, ~p"/")`.
- Assert (fails before fix, passes after):
  - `assert has_element?(view, ".cns-bubble--user", "hello orchestrator")` (operator turn restored, distinct colour).
  - `assert has_element?(view, ".cns-bubble--orch", "orchestrator reply")` (orchestrator turn restored).
  - Control: operator text does NOT appear as an orchestrator bubble — `refute has_element?(view, ".cns-bubble--orch", "hello orchestrator")`.
- Add a `Logs` unit assertion (in the same file or the logs test) that `persist_operator_message/2` round-trips a row with `payload["role"] == "operator"` and is returned by `list_recent_orchestrator_messages/2`.

### 7. Run the full validation suite
- Run every command in **Validation Commands**; all must be green with zero regressions. Optionally capture a `http://localhost:4000` screenshot showing the two-coloured dialogue after a reload as visual proof.

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- `mix test test/repo_builder_web/live/test_operator_message_persist_test.exs` — The new LiveView integration test: fails before the fix, passes after.
- `mix test test/repo_builder_web/live/test_orchestrator_chat_history_persist_test.exs` — Ensure the related orchestrator-reply backfill still works (no regression to the shared `log_to_row`/`chat_for_row`/`backfill_events` path).
- `mix test test/repo_builder_web/live/test_orchestrator_chat_worker_isolation_test.exs` — Worker text still never leaks into the chat pane.
- `mix compile --warnings-as-errors` — Compile clean; gradual set-theoretic type checker and `warnings_as_errors` must pass.
- `mix test --warnings-as-errors` — Full ExUnit suite (Postgres-backed) with zero failures.
- `mix format --check-formatted` — Code is formatted.
- `mix credo --strict` — Lint, including the "every public function has an `@spec`" convention (covers the new `persist_operator_message/2`).
- `mix dialyzer` — `@spec`/contract checking with no NEW warnings and no stale ignore filters.

## Notes
- **No new dependency, no migration, no new table.** The fix reuses the existing `agent_logs` schema (`event_type: :text_delta` + a `payload["role"]` marker). The `validate_owner/1` constraint is satisfied because operator rows set `orchestrator_id` only.
- **Why `event_type: :text_delta` rather than a new enum value.** Adding an `:operator_message` enum value would require a migration + schema/changeset edits and would fall outside the existing `list_recent_orchestrator_messages/2` filter. Reusing `:text_delta` with a payload marker is the minimal change and slots straight into the just-shipped orchestrator backfill. If a cleaner domain model is later desired, promoting this to a dedicated event type is a separate, non-urgent refactor.
- **Single-writer placement.** `Orchestrator.Queue.enqueue/2` is chosen because it is the one public, operator-only path; the orchestrator's reply text is already persisted by `Orchestrator.Server`. The queue item `kind` (`:operator`) is not threaded into the per-turn starter (`do_start_turn/2` receives only the prompt), so persisting at `do_start_turn` would also (incorrectly) capture synthesized holding-pattern resume prompts — `enqueue/2` avoids that.
- **Colour is already implemented.** `chat_message/1` renders `:user` turns right-aligned with `cns-bubble--user` (`--cns-bubble-user: #1e3a5f`) vs the orchestrator `cns-bubble--orch` (`--cns-bubble-orch: #2a2a2a`). The fix makes backfilled operator rows actually use it; adjust the CSS var only if the operator wants a stronger contrast.
- **Multi-console live consistency is out of scope.** Because we persist without broadcasting (to avoid double-rendering on the originating console), a second console open at the same time sees a new operator message only after its next reconnect/backfill. If live cross-console echo is later wanted, broadcast the operator turn on the global feed and drop the local `push_user_message/2` echo — a separate change.
- **Builds on `issue-chat-history-backfill`.** Operator rows share `orchestrator_id` with orchestrator replies, and `log_to_row/4` now derives the chat `agent_key` from `orchestrator_id`; the `payload["role"]` marker is what keeps the two apart in `chat_for_row/1`.
- Use Tidewave `execute_sql_query`/`project_eval` to confirm zero operator rows before and ≥1 after, and to verify the rendered transcript.
