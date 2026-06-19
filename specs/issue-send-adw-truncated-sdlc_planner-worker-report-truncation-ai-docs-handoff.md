# Bug: Worker reports are hard-truncated at 2,000 chars and unrecoverable; tighten reporting prompt to hand off long results via `ai_docs/` files

## Metadata
issue_number: `send`
adw_id: `truncated`
issue_json: `report`

## Bug Description
When the orchestrator dispatches a worker to do substantive investigation/build work, the worker's findings are surfaced back to the orchestrator **only** through the `check_agent_status` tool, whose `final_message` (and each `recent_events[].text`) is hard-truncated at `@worker_text_cap = 2_000` characters in `RepoBuilder.Orchestrator.Tools` (`lib/repo_builder/orchestrator/tools.ex:45`, `truncate_text/2` at `:1122`).

Workers routinely produce reports far longer than 2,000 characters (the canonical example is a multi-section "Read-Only Investigation Report" / Python→Elixir port analysis). When that happens:

- **Expected:** the orchestrator can obtain the worker's full findings, or at minimum a clear, complete, retrievable artifact it can read in full.
- **Actual:** the orchestrator receives a ~2,000-char prefix with `… (truncated)` and has **no way to recover the rest**. Re-engaging the same worker just re-runs the report through the same 2,000-char ceiling, so the orchestrator burns turns/cost looping and never gets the tail of the report.

### Observed in logs 6779–6809 (live runtime, `pi` harness)
- `log 6784` — `tool_result` for `check_agent_status`: `final_message` begins `"# Read-Only Investigation Report: Python→Elixir Port of \"Prompt Standard…"` — already cut off (payload length 6,754 bytes of escaped JSON wrapping a 2,000-char cap).
- `log 6786` — orchestrator text: *"its `final_message` is **truncated** in what surfaced to me — I got the Elixir identity + partial…"*
- `log 6787` — *"The scout completed but the `final_message` is truncated. The `recent_events` also has truncated content. I need the full report…"*
- `logs 6789–6793` — orchestrator re-dispatches the scout to re-emit the missing portion.
- `log 6809` — *"the **truncation is a hard ceiling** — it cut off again mid-H-check list … and I never received t[he rest]"*.

This is the smoking gun: the cap is a dead end, and the orchestrator wastes a full retry loop ($0.056 + $0.059 of worker spend across 6784/6807) discovering it cannot escape it.

## Problem Statement
The worker→orchestrator reporting channel (`check_agent_status.final_message`) is a fixed-width 2,000-char window. There is no overflow path: any worker conclusion longer than the cap is permanently unreachable by the orchestrator, and the standard reporting clause (`@worker_reporting_clause`, `lib/repo_builder/orchestrator/tools.ex:34`) never tells the worker the cap exists or how to hand off a longer result, so workers keep inlining long reports straight into the truncation.

## Solution Statement
Keep the 2,000-char tool-result cap (it exists deliberately to bound `check_agent_status` results against the known large-tool-result stdout-overflow concern, issue-log-2389) but **give workers an explicit, prompted overflow path**: when a worker's findings exceed the surfaced budget, it must write the full report to a markdown file under `ai_docs/` in the shared working directory and **reference that file path** in its concise final summary. The orchestrator (which runs in the same working directory and already has file-read access via its harness) then reads the complete artifact directly instead of fighting the truncation.

Concretely:
1. Rewrite `@worker_reporting_clause` so every spawned worker is told: (a) only the final message is surfaced and it is capped at ~`@worker_text_cap` characters; (b) keep the final message a short self-contained summary; (c) for anything longer, write the full content to `ai_docs/<descriptive-name>.md` under the working directory and cite that **relative path** (e.g. `ai_docs/elixir-port-report.md`) in the final summary so the coordinator can open it.
2. Interpolate `@worker_text_cap` into the clause so the prompted limit and the code's truncation limit can never drift.
3. Make the truncation marker actionable: when `final_message` is actually truncated, append a hint pointing the orchestrator at the `ai_docs/` convention, so a coordinator that receives a legacy (un-prompted) overflow still knows to look for / request a file handoff.

This is surgical: the only behavioral change is prompt text plus the truncation marker; the cap, the tool contract, persistence, and the LiveView remain untouched.

## Steps to Reproduce
1. Configure an orchestrator with a Working directory (Settings → General) so workers share its cwd.
2. Dispatch a worker with a prompt that elicits a long report, e.g. *"Investigate X and produce a full multi-section report."*
3. Let the worker finish; its final assistant message exceeds 2,000 characters.
4. As the orchestrator, call `check_agent_status` for that worker.
5. Observe `final_message` ends in `… (truncated)` and the remainder of the report is unobtainable; re-dispatching the worker re-truncates at the same ceiling (mirrors logs 6779–6809).

Runtime reproduction via Tidewave `project_eval` (no live agent needed) — confirm the cap is the mechanism:
```elixir
text = String.duplicate("A", 5_000)
RepoBuilder.Orchestrator.Tools |> :erlang.apply(:truncate_text, [text, 2_000]) |> String.length()
# => 2_014  (2_000 + "… (truncated)")  — the report tail is gone
```
(If `truncate_text/2` is private, assert the same through `check_agent_status` against a seeded worker log instead — see test task below.)

## Root Cause Analysis
`check_agent_status/2` (`lib/repo_builder/orchestrator/tools.ex:325`) is the **only** seam the orchestrator has into a worker's findings: it reads `worker_final_message/1` and pipes it through `truncate_or_nil/1` → `truncate_text(text, @worker_text_cap)` (`:1128`, `:1122`). `@worker_text_cap` is `2_000` (`:45`). The truncation is lossy and one-way (`String.slice(text, 0, cap) <> "… (truncated)"`), and there is **no second channel** to fetch the dropped suffix.

The standard reporting clause appended to every worker (`with_reporting_clause/1`, `:1093`, using `@worker_reporting_clause`, `:34`) instructs the worker to "end with a concise self-contained summary" but:
- never states that the surfaced window is finite (2,000 chars), and
- never offers an overflow mechanism for legitimately long results.

So workers behave rationally — they write a thorough final report inline — and the platform silently amputates it. Re-engaging the worker cannot help because the cap re-applies to every `check_agent_status` call. The fix must change the worker's behavior (write long output to a file under the shared cwd and reference it), not raise the cap (which only moves the ceiling and re-exposes the stdout-overflow risk the cap was added to prevent).

Note on durability: workers are spawned with `cwd: orchestrator_working_dir(orchestrator_id)` (`:290`), i.e. the **orchestrator's** working directory, which is **not** the ephemeral per-session scratch workspace that `cleanup_workspace/1` deletes (`lib/repo_builder/session/server.ex:720`). So a file a worker writes under `ai_docs/` in the shared working dir persists after the worker exits and is readable by the orchestrator. (When no working dir is configured, each agent gets an isolated scratch workspace and file handoff is not durable — the clause therefore frames the path relative to "the working directory," matching the existing `working_dir_block/1` guidance in `system_prompt.ex:146`.)

## Relevant Files
Use these files to fix the bug:

- `lib/repo_builder/orchestrator/tools.ex` — **primary fix site.** Holds `@worker_reporting_clause` (`:34`), `@worker_text_cap` (`:45`), `with_reporting_clause/1` (`:1093`), `check_agent_status/2` (`:325`), `worker_final_message/1` (`:1102`), `truncate_or_nil/1`/`truncate_text/2` (`:1119`). The reporting clause and the truncation marker change here.
- `lib/repo_builder/orchestrator/system_prompt.ex` — `working_dir_block/1` (`:146`) already tells the orchestrator and its workers they share a working directory and where the platform root is; the new clause's `ai_docs/` path must be consistent with this framing (relative to the working directory). Read-only reference; likely no change, but confirm wording alignment.
- `lib/repo_builder/orchestrator/server.ex` / `lib/repo_builder/session/server.ex` — confirm worker cwd == orchestrator working_dir (durability of the `ai_docs/` artifact) and that scratch workspaces are the only thing cleaned up. Read-only reference.
- `ai_docs/` (repo root) — existing convention directory (`adw-orchestration.md`, `typed-elixir-standard.md`, …); the chosen handoff location reuses this established convention rather than inventing a new one.
- `BUILD_PROMPT.md` §4.1 (large-tool-result / redaction), §6 (stdout-overflow backpressure, `max_line_bytes`) — context for *why* the cap exists and must stay. Read-only reference.

### New Files
- `test/repo_builder/orchestrator/worker_report_truncation_test.exs` — ExUnit test that (a) the reporting clause appended to a worker mentions the surfaced cap and the `ai_docs/` overflow convention, and (b) `check_agent_status` still bounds `final_message` to the cap and marks it truncated for legacy overflow.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Confirm the cap mechanism and cwd durability in the live runtime
- Use Tidewave `execute_sql_query` to re-read logs 6779–6809 (`agent_logs`, ordered by `log_no`) and confirm the `check_agent_status` `tool_result` rows (6784, 6807) carry truncated `final_message` payloads and the orchestrator's follow-up `text_delta` rows complain about truncation.
- Use Tidewave `project_eval` to confirm `RepoBuilder.Orchestrator.Tools`'s cap value and truncation behavior, and `get_source_location`/`get_docs` if you need exact-version `String.slice/3` semantics.
- Confirm workers inherit the orchestrator working dir (`tools.ex:290` → `orchestrator_working_dir/1`) and that `cleanup_workspace/1` (`session/server.ex:720`) only removes managed scratch workspaces, so an `ai_docs/` file in the shared working dir survives worker exit.

### 2. Rewrite the worker reporting clause with the overflow path
- In `lib/repo_builder/orchestrator/tools.ex`, replace the `@worker_reporting_clause` heredoc so it:
  - states only the FINAL message is surfaced (via the orchestrator's `check_agent_status`) and is truncated at approximately `@worker_text_cap` characters;
  - tells the worker to keep that final message a concise, self-contained summary (what it did, found, concluded);
  - instructs: when the full result would exceed that budget, write the complete content to a markdown file at `ai_docs/<descriptive-name>.md` **inside the working directory** and reference that relative path in the final summary so the coordinator can read it in full;
  - keeps the existing "do not bury the outcome mid-transcript; restate it at the end" guidance.
- Interpolate `@worker_text_cap` into the clause text so the documented limit tracks the code constant. Because module attributes can't be interpolated inside a `@attr` heredoc directly, convert the clause to a private builder function (e.g. `defp worker_reporting_clause/0` returning the interpolated string) OR define the cap first and build the string with `"#{@worker_text_cap}"`. Keep it a single source of truth — `with_reporting_clause/1` calls the builder.
- Update `with_reporting_clause/1` (`:1093`) to use the new builder; preserve its `@spec` and the nil/empty-prompt behavior.

### 3. Make the truncation marker actionable
- In `truncate_text/2` (or `truncate_or_nil/1`), keep codepoint-safe slicing but change the truncation suffix to a short actionable hint, e.g. `"… (truncated at #{cap} chars — full output should be in an ai_docs/ file; ask the worker for the path)"`. Keep it concise so it does not itself bloat the tool result. Ensure `log_summary/1` (`:1133`) and `check_agent_status` continue to compile and stay within the cap budget.
- Do NOT change `@worker_text_cap`'s numeric value (the cap stays to protect against the stdout-overflow concern, issue-log-2389). If a modest bump is later desired, capture it in Notes, not in this fix.

### 4. Add a regression test
- Create `test/repo_builder/orchestrator/worker_report_truncation_test.exs`:
  - Assert the worker system prompt produced for a created worker contains the cap figure and the `ai_docs/` overflow instruction. Drive this through the public API: call `RepoBuilder.Orchestrator.Tools.call("create_agent", orchestrator_id, args)` with a seeded orchestrator, then load the created worker and assert its `system_prompt` includes both the surfaced-cap language and `ai_docs/`. (Use the existing test setup/case for orchestrator tools — mirror a neighboring tools test for fixtures/Mox/registry seam.)
  - Assert truncation still bounds output: seed a worker `agent_logs` row whose `:text_delta`/`:done` payload text exceeds `@worker_text_cap`, call `check_agent_status`, and assert `final_message` length is `<= @worker_text_cap + length(marker)` and ends with the truncation marker.
  - Keep it `async: true` if the surrounding case allows; otherwise match the neighboring case's setup.

### 5. Validate
- Run the full `Validation Commands` block below and ensure every command is green with zero regressions.

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- `mix test test/repo_builder/orchestrator/worker_report_truncation_test.exs` — the new regression test passes (fails before the clause/marker change, passes after).
- `mix compile --warnings-as-errors` — compile clean; gradual set-theoretic type checker + `warnings_as_errors` pass.
- `mix test --warnings-as-errors` — full ExUnit suite green.
- `mix format --check-formatted` — formatting clean.
- `mix credo --strict` — lint clean, including the every-public-fn-`@spec` rule.
- `mix dialyzer` — no new `@spec`/contract warnings, no stale ignore filters.

## Notes
- **Why not just raise the cap?** The 2,000-char cap was added deliberately (comment at `tools.ex:42-44`) to keep `check_agent_status` results small even at `limit=20`, because the platform has a known large-tool-result stdout-overflow failure (issue-log-2389, `BUILD_PROMPT.md` §6 `max_line_bytes`). Raising the cap only relocates the ceiling and re-exposes that risk. The durable, scalable fix is a file-based handoff for long output, which is exactly the user's suggested `ai_docs/` reference approach.
- **Durability caveat:** the file-handoff path only persists when the orchestrator has a Working directory set (workers then share it). With no working dir, agents run in ephemeral scratch workspaces that are `File.rm_rf`'d on exit (`session/server.ex:720`), so the artifact would not survive. The clause frames the path as "inside the working directory," consistent with `system_prompt.ex` `working_dir_block/1`, which already steers operators to set one for real codebase work. No code change is needed for the durable case; this is documented so reviewers understand the boundary.
- **No LiveView change:** this is a worker-prompt + tool-result change in `RepoBuilder.Orchestrator.Tools`; the dashboard renders whatever `check_agent_status` returns, so no `Phoenix.LiveViewTest` is required. The regression test is a plain ExUnit test against the tools context.
- **Related prior work:** issue-2541 introduced `@worker_reporting_clause`, `@worker_text_cap`, and the `check_agent_status` `final_message` surfacing. This bug is the natural follow-up: that work made the worker's conclusion *retrievable* but capped; this work makes *long* conclusions retrievable via a file pointer instead of silent amputation.
- **Single source of truth:** interpolating `@worker_text_cap` into the prompt prevents the documented limit and the enforced limit from drifting in future edits.
