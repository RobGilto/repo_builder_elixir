# Bug: Orchestrator cannot read a spawned worker's results (`check_agent_status` drops payloads; no result-reporting prompt rules)

## Metadata
issue_number: `2541`
adw_id: `worker-reporting`
issue_json: `logs upto seq_no 2541 — worker "job-seek-scout" (session worker-L6LzcTsMEnIEvozF, cwd /data/2.Areas/job-seeking) completed its scan, but the Orchestrator could not retrieve the worker's findings`

## Bug Description
While scanning `/data/2.Areas/job-seeking`, the operator dispatched a worker (`job-seek-scout`). The agent_logs (up to seq_no 2541) show the worker **did do the work**: it ran, produced finalized assistant text and a terminal `done`/`result` event carrying its written report. However, the Orchestrator (the meta-agent) **was unable to get that information** — it could see *that* the worker had reached a `done` state and emitted events, but never *what* the worker actually found or said. The Orchestrator therefore could not relay the scout's findings back to the operator.

Expected behavior: when the Orchestrator calls `check_agent_status` for a worker that has finished, the response should include the worker's actual output — at minimum its latest/final result text — so the Orchestrator can read and report the findings.

Actual behavior: `check_agent_status` returns a content-free tail. Each event in `recent_events` is reduced to `{"event_type": ..., "at": ...}` with the **payload (the text/result) stripped out**. The Orchestrator sees event *types* and timestamps but none of the worker's substance, so it has nothing to report.

## Problem Statement
The Orchestrator has no mechanism to retrieve a spawned worker's produced output. The only inspection tool, `check_agent_status`, deliberately discards the event payloads that hold the worker's finalized assistant text and final result. Compounding this, there are **no prompt rules** telling (a) workers to end their turn with a concise, self-contained result summary, or (b) the Orchestrator that a worker's findings are read via `check_agent_status`'s output text. The result: completed worker output is effectively invisible to the layer that is supposed to coordinate and report it.

## Solution Statement
Two surgical, complementary changes:

1. **Mechanism (primary, fixes the bug):** Enrich the `check_agent_status` tool response so it surfaces the worker's output. Add a top-level `final_message` field (the worker's most recent non-thinking result text, drawn from the latest `done` `result`/`final_text` or finalized `text_delta` payload), and include a **truncated** `text` excerpt per event in the `recent_events` tail. Truncation keeps the tool result bounded (the platform already has a known large-tool-result stdout-overflow concern — see `specs/issue-log-2389-adw-error-sdlc_planner-fix-stdout-overflow-large-tool-result.md`).

2. **Prompt rules (answers the operator's question — "should there be prompt rules for reporting results for spawned agents?": yes):** (a) Append a standard *reporting clause* to every spawned worker's system prompt so workers always finish their turn with a concise, retrievable summary of results. (b) Add an Orchestrator system-prompt rule that its `check_agent_status` `final_message` field is how it reads a worker's findings, and that it must retrieve that before reporting back.

Keep the data-layer change confined to the orchestrator tool boundary (`Orchestrator.Tools`); do not alter how events are persisted (`Logs.event_payload/2`) — the payloads are already correctly stored, they are simply being thrown away on read.

## Steps to Reproduce
1. Start a Claude worker via the Orchestrator (`create_agent` then `command_agent`) and give it a task that produces a written report (e.g. "scan this directory and report what you find").
2. Wait for the worker to finish (it emits finalized `text_delta` rows + a terminal `done` event whose payload holds `result`/`final_text`).
3. As the Orchestrator, call `check_agent_status` with the worker's name.
4. Observe: `recent_events` is a list of `{"event_type": "...", "at": "..."}` entries with **no text/result content**, and there is no field carrying the worker's final answer. The Orchestrator cannot see what the worker produced.

Runtime confirmation via Tidewave:
- `mcp__tidewave__get_logs` (grep `done|text` / inspect the `worker-…` session) shows the worker's `done` payload contains the `result` text and `text_delta` rows contain finalized `text` — i.e. the data exists in `agent_logs.payload`.
- `mcp__tidewave__project_eval` reproduces the loss directly:
  ```elixir
  {:ok, res} = RepoBuilder.Orchestrator.Tools.call("check_agent_status", orchestrator_id, %{"name" => "job-seek-scout"})
  res["recent_events"] # => maps with only "event_type"/"at"; no worker text. res["final_message"] # => key absent (the bug)
  ```

## Root Cause Analysis
The worker's output is persisted correctly but discarded on read:

- The worker's finalized assistant text is stored as `:text_delta` rows whose payload is `%{"text" => <text>, "thinking" => bool}` (`lib/repo_builder/logs.ex:368-370`, `event_payload/2`).
- The worker's terminal answer is stored as a `:done` row whose payload is the raw harness frame, which for Claude includes `"result" => <final text>` (`lib/repo_builder/harness/claude.ex:250-272`, mapped from `Event.Done.final_text`, `lib/repo_builder/harness/event.ex:157`).

`check_agent_status` builds its tail with:

```elixir
tail = worker.id |> Logs.list_recent(limit) |> Enum.map(&log_summary/1)   # tools.ex:309
```

and `log_summary/1` is:

```elixir
defp log_summary(log) do
  %{"event_type" => to_string(log.event_type), "at" => to_iso(log.inserted_at)}   # tools.ex:1017-1019
end
```

`log_summary/1` **drops `log.payload` entirely**, so every `text_delta`/`done` payload — exactly where the worker's report lives — is thrown away. The `check_agent_status` response (`tools.ex:312-319`) likewise has no field carrying the worker's final text. Hence the Orchestrator sees only event types + timestamps and "cannot get that information."

Contributing factor (prompt layer): a worker's `system_prompt` is whatever the Orchestrator passes (or a template body, possibly `nil`) — `create_agent/2` at `tools.ex:92-108` appends **no** standard reporting instruction. Combined with the Orchestrator prompt never stating that `check_agent_status` is the channel for reading worker output (`lib/repo_builder/orchestrator/system_prompt.ex`), even a well-behaved worker can bury its conclusion mid-transcript with nothing surfacing it. So the failure is both a hard data-plane gap (payloads dropped) and a soft contract gap (no reporting rules).

## Relevant Files
Use these files to fix the bug:

- `lib/repo_builder/orchestrator/tools.ex` — **Primary fix.** `log_summary/1` (lines 1017-1019) drops payloads; `check_agent_status/2` (lines 304-321) is the tool that must surface the worker's result text. `create_agent/2` (lines 92-128) is where a worker's `system_prompt` is assembled and where a standard reporting clause should be appended.
- `lib/repo_builder/orchestrator/tool_catalog.ex` — `check_agent_status` schema/description (lines 79-93); update the description to state it returns the worker's latest output/result.
- `lib/repo_builder/orchestrator/system_prompt.ex` — Orchestrator prompt; add the rule that `check_agent_status`'s `final_message` carries the worker's findings (the existing `check_agent_status` guidance lives around lines 31, 108).
- `lib/repo_builder/logs.ex` — Read-only reference for how payloads are stored (`event_payload/2`, lines 356-372; `list_recent/2`, lines 99-107). Do **not** change persistence; the data is already correct.
- `lib/repo_builder/harness/event.ex` — `Event.Done.final_text` (line 157) and `Event.TextDelta.text` definitions; confirms the payload keys the fix reads.
- `lib/repo_builder/harness/claude.ex` — `result success` → `done` mapping (lines 250-272) showing the `"result"` key in the `done` payload.
- `specs/issue-log-2389-adw-error-sdlc_planner-fix-stdout-overflow-large-tool-result.md` — Cross-reference: motivates truncating the surfaced text so the enriched tool result stays bounded.
- `BUILD_PROMPT.md` — §3 typed style guide (`@spec`s, precise types), §8 persistence (DB access behind context modules), §10 orchestrator/extensibility — keep the fix idiomatic and at the tool boundary.

### New Files
- `test/repo_builder/orchestrator/test_worker_result_reporting_test.exs` — ExUnit test that reproduces the bug (asserts the worker's result text is absent before the fix) and proves it fixed (asserts `final_message` + per-event `text` are surfaced after). Exercises `RepoBuilder.Orchestrator.Tools.call("check_agent_status", …)` against seeded `agent_logs`.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Reproduce and pin the current (buggy) contract
- Read `lib/repo_builder/orchestrator/tools.ex` `check_agent_status/2` and `log_summary/1`, and `lib/repo_builder/logs.ex` `event_payload/2`/`list_recent/2` to confirm the payload keys (`text_delta` → `"text"`/`"thinking"`; `done` → raw frame with `"result"`/`final_text`).
- Optionally reproduce live via Tidewave `project_eval` (call `check_agent_status` for an existing worker) and `get_logs` to confirm the worker's report exists in `agent_logs.payload` but is absent from the tool result.

### 2. Add a bounded result-extraction helper in `Orchestrator.Tools`
- Add a private, `@spec`'d helper `worker_final_message/1` that takes the chronological `[AgentLog.t()]` list (already fetched in `check_agent_status`) and returns the worker's most recent **non-thinking** result text: prefer the latest `:done` payload's `"result"`/`"final_text"`, else the latest finalized `:text_delta` payload's `"text"` where `"thinking"` is not `true`; return `nil` when none exists.
- Add a private `@spec`'d `truncate_text/2` (e.g. default cap ~2000 chars, append an `"… (truncated)"` marker) to keep surfaced text bounded per the stdout-overflow concern. Reuse an existing truncation helper if one already exists in the module rather than duplicating.

### 3. Enrich `log_summary/1` to include a payload excerpt
- Extend `log_summary/1` so content-bearing events carry a truncated `"text"` field: `:text_delta` → `payload["text"]`; `:done` → `payload["result"] || payload["final_text"]`; `:error` → the error `message`. Other event types keep the current compact `{event_type, at}` shape (no `text` key).
- Preserve the existing `@spec log_summary(Logs.AgentLog.t()) :: map()` and keep the function total (handle `nil`/missing payload keys gracefully — no raises, no `KeyError`).

### 4. Surface the worker's result in the `check_agent_status` response
- In `check_agent_status/2`, fetch the recent logs once, build `recent_events` via the enriched `log_summary/1`, and add a top-level `"final_message"` (string or `nil`) computed by `worker_final_message/1` over the same list.
- Keep the existing `id`/`name`/`status`/`cost_usd` fields and `@spec`; do not change `Logs.list_recent/2`.

### 5. Update the tool catalog description
- In `lib/repo_builder/orchestrator/tool_catalog.ex`, update the `check_agent_status` `description` (line 81) to state it now returns the worker's latest output text (`final_message`) plus a per-event text tail, so the Orchestrator knows this is the channel for reading a worker's findings.

### 6. Add result-reporting prompt rules
- In `create_agent/2` (`tools.ex`), append a standard reporting clause to the worker's `system_prompt` (a module constant, e.g. `@worker_reporting_clause`): instruct the worker that only its **final message** is surfaced to the coordinator, so it must end every turn with a concise, self-contained summary of results/findings (not bury them mid-transcript). Append to a provided/template prompt; use the clause alone when the prompt is `nil`/blank. Keep it idiomatic and typed.
- In `lib/repo_builder/orchestrator/system_prompt.ex`, add a short rule near the existing `check_agent_status` guidance: to read a worker's findings, call `check_agent_status` and use its `final_message` field; never assume a worker reported back — retrieve and relay it.

### 7. Add the regression test
- Create `test/repo_builder/orchestrator/test_worker_result_reporting_test.exs`. Seed an orchestrator + worker and insert `agent_logs` rows simulating a finished worker: finalized `:text_delta` (`%{"text" => "scan report …", "thinking" => false}`) and a terminal `:done` (`%{"result" => "Found 3 resumes and a cover letter."}`), plus a `:thinking` `text_delta` that must NOT be chosen.
- Assert the **bug shape would fail**: that `check_agent_status` now returns a non-nil `"final_message"` equal to the `done` result, that `recent_events` entries carry the `"text"` excerpt, and that thinking text is excluded from `final_message`. Add a long-text case asserting truncation bounds the output.
- Note in a comment: this is a tool/data-layer fix, not a LiveView interaction, so a `Phoenix.LiveViewTest` integration test is not the correct surface — the orchestrator reads worker output through the `Orchestrator.Tools` boundary, which this test exercises directly.

### 8. Run the full validation suite
- Run every command in `Validation Commands` and ensure all are green with zero regressions.

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- `mix test test/repo_builder/orchestrator/test_worker_result_reporting_test.exs` — The new regression test: worker `final_message` + per-event `text` are surfaced, thinking excluded, long text truncated. (Confirm it fails against the pre-fix `log_summary/1`/`check_agent_status/2` and passes after.)
- `mix compile --warnings-as-errors` - Compile clean; the gradual set-theoretic type checker and `warnings_as_errors` must pass.
- `mix test --warnings-as-errors` - Run the full ExUnit suite (Postgres-backed) with zero failures.
- `mix format --check-formatted` - Ensure code is formatted.
- `mix credo --strict` - Lint, including the "every public function has an `@spec`" convention (new private helpers carry `@spec`s).
- `mix dialyzer` - `@spec`/contract checking with no new warnings and no stale ignore filters.

## Notes
- **Why not fix `Logs.event_payload/2`?** The payloads are already persisted correctly; the bug is purely on the *read/surface* path inside `Orchestrator.Tools`. Keeping the change at the tool boundary is the minimal, regression-safe fix and respects §8 (DB access stays behind the `Logs` context, unchanged).
- **Truncation matters.** Surfacing full payloads unbounded could re-trigger the large-tool-result stdout overflow tracked in `specs/issue-log-2389-…`. Cap the surfaced `text`/`final_message` and mark truncation. Tune the cap conservatively (~2000 chars) — enough to convey a worker's summary, small enough to keep `check_agent_status` results bounded even at `limit=20`.
- **Harness generality.** The `done` payload key differs by harness; Claude uses `"result"` (mapped from `Event.Done.final_text`). Read `final_text`/`result` defensively so pi/ADW/fake harnesses (which set `"final_text"`, see `harness/fake.ex:119,169`) also surface correctly.
- **Operator's question, answered.** Yes — there should be prompt rules for reporting results from spawned agents. This plan adds both halves of the contract: a worker-side reporting clause (always end with a retrievable summary) and an Orchestrator-side rule (read findings via `check_agent_status.final_message`). The prompt rules harden the contract; the data-layer fix is what actually makes the worker's output retrievable.
- No new dependencies required.
