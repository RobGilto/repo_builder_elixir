# Bug: Worker reports still truncate because the `ai_docs/` overflow path is prompt-only and workers ignore it — spill long `final_message` to a file deterministically, platform-side

## Metadata
issue_number: `the`
adw_id: `prior`
issue_json: `worker-report-truncation`

## Bug Description
The previous fix (`specs/issue-send-adw-truncated-sdlc_planner-worker-report-truncation-ai-docs-handoff.md`, now implemented) added a **prompt clause** telling each worker to write long results to `ai_docs/<name>.md` and reference the path, plus an actionable truncation marker. The clause, marker, and a regression test all landed in `lib/repo_builder/orchestrator/tools.ex` and `test/repo_builder/orchestrator/worker_report_truncation_test.exs`.

It did **not** fix the user-visible problem, because the overflow path depends on the **non-deterministic worker complying** with a prompt instruction — and real workers (here `pi` + `glm-5.2`) do not comply: they keep inlining the full multi-section report into their final message instead of writing a file. The platform then truncates that message at `@worker_text_cap = 2_000` chars (`tools.ex:34`, `truncate_or_nil/1` → `truncate_text/2` at `:1139`), and the orchestrator again cannot recover the tail.

- **Expected:** the orchestrator can always obtain the worker's full findings, regardless of whether the worker chose to write a file.
- **Actual:** when a worker inlines a long report (the common case), `check_agent_status.final_message` is a ~2,000-char prefix + marker, and the rest is unreachable. The orchestrator burns turns re-dispatching the worker, hitting the cap repeatedly.

### Observed in logs 7131–7151 (live runtime, `pi` / `glm-5.2`), AFTER the prior fix shipped
- `log 7133` — `tool_result` for `check_agent_status`: `final_message` begins `"# Feature: Port the \"prompt-standard\" feature (validator + builder + CLI)…"` — a full inlined plan (10,105-byte escaped payload). The worker did **not** write an `ai_docs/` file.
- `log 7144` — another `check_agent_status` `tool_result`: `final_message` begins `"Here's the honest picture, with the verification limits stated up front…"` (10,338-byte payload) — again inlined, again truncated.
- `log 7146` — orchestrator text: *"The output **truncated a third time** on the §3/§4 detail…"*.
- `log 7147` — *"the truncation keeps cutting off the §3 (rewrite summary) and §4 (build-readiness verdict)…"*.

This is the same dead-end as logs 6779–6809, proving the prompt-only remedy is insufficient: the worker ignores the clause and the platform still amputates.

## Problem Statement
Retrievability of a long worker report currently hinges on the worker voluntarily writing a file. That is unreliable. The platform already has the **full** worker message in hand at the surfacing boundary (`worker_final_message/1` returns the complete text before `truncate_or_nil/1` shortens it), so the platform — not the worker — must guarantee the full content is retrievable when it overflows the surfaced cap.

## Solution Statement
Make overflow handling **deterministic and platform-side**, removing all dependence on worker compliance:

In `check_agent_status/2`, when the worker's full final message exceeds `@worker_text_cap`, the platform itself **spills the complete, untruncated message to a markdown file** under the orchestrator's working directory and returns the file path in the tool result alongside the (still-capped) preview:

- `final_message` → the existing truncated preview (keeps the tool result small; preserves the stdout-overflow protection the cap exists for, issue-log-2389).
- new `report_file` → the path to the spilled file containing the full message (present only when truncation occurred; `nil`/absent otherwise).

Because workers run in the orchestrator's working directory (`tools.ex:279` `cwd: orchestrator_working_dir(orchestrator_id)`), writing the spill file there means the path is inside the orchestrator's own cwd and is readable by the orchestrator's native file tools. The file is written idempotently (keyed on the source log so re-calling `check_agent_status` rewrites the same path, never clobbers unrelated reports).

The prompt clause and truncation marker from the prior fix **stay** (they remain good guidance and help when a worker *does* cooperate), but they are no longer the load-bearing mechanism — the deterministic spill is.

This is surgical: the only behavioral change is inside `check_agent_status/2` plus two private helpers; the cap, the event contract, persistence, and the LiveView are untouched.

## Steps to Reproduce
1. Configure an orchestrator with a Working directory (Settings → General).
2. Dispatch a `pi`/`glm-5.2` worker with a prompt that elicits a long multi-section report (e.g. *"Port the prompt-standard feature and report the concrete changes for §2/§3/§4."*).
3. The worker finishes with a >2,000-char final assistant message **inlined** (it does not write a file).
4. As the orchestrator, call `check_agent_status` for that worker.
5. Observe `final_message` ends in the truncation marker and there is **no** channel to the §3/§4 tail; re-dispatching re-truncates (mirrors logs 7131–7151).

Runtime reproduction via Tidewave (no live agent needed) — confirm the full text exists in the DB but is amputated at the surface:
- `execute_sql_query`: re-read logs 7131–7151 ordered by `log_no`; confirm 7133/7144 `tool_result` payloads carry truncated `final_message` and 7146/7147 `text_delta` rows complain of a "third" truncation.
- After the fix, `project_eval` calling `RepoBuilder.Orchestrator.Tools.call("check_agent_status", orch_id, %{"name" => name})` against a worker whose persisted `:done`/`:text_delta` payload exceeds the cap returns a map containing a non-nil `"report_file"`, and `File.read!(path)` yields the full untruncated text.

## Root Cause Analysis
`check_agent_status/2` (`lib/repo_builder/orchestrator/tools.ex:315`) computes `final_message = logs |> worker_final_message() |> truncate_or_nil()`. `worker_final_message/1` (`:1119`) returns the **complete** text; `truncate_or_nil/1` (`:1154`) then lossily slices it to `@worker_text_cap` (`:34`, value `2_000`) and appends a marker. There is exactly one surfacing channel and it is fixed-width.

The prior fix tried to prevent overflow by **instructing the worker** (`worker_reporting_clause/0`, `:1099`) to write an `ai_docs/` file for long output. But:
- The worker is a non-deterministic external agent; compliance is not guaranteed. Logs 7131–7151 show `glm-5.2` ignoring the clause and inlining a 10 KB report.
- Nothing in the platform falls back when the worker does not comply, so the long message is silently amputated exactly as before.

The full content is **already available** to the platform at the truncation boundary (it is the input to `truncate_or_nil/1`, and is durably persisted in `agent_logs`). The correct fix is to have the **platform** persist the overflow to a readable file and hand the orchestrator the path, rather than hoping the worker does. This converts retrievability from "best-effort, worker-dependent" to "guaranteed, platform-enforced".

Durability/readability holds because workers share the orchestrator working dir (`tools.ex:279`), which is **not** the ephemeral scratch workspace `cleanup_workspace/1` deletes (`lib/repo_builder/session/server.ex:720`); a file written there by the platform persists and sits inside the orchestrator's cwd, reachable by the orchestrator's native file-read tools. When no working dir is configured (`orchestrator_working_dir/1` returns `nil`, `:1050`), the spill falls back to the platform root (`File.cwd!()`), and the returned path is absolute so it remains referenceable; this matches the existing `working_dir_block/1` framing in `system_prompt.ex:146`.

## Relevant Files
Use these files to fix the bug:

- `lib/repo_builder/orchestrator/tools.ex` — **primary fix site.**
  - `check_agent_status/2` (`:315`) — add the overflow spill: when `worker_final_message/1` exceeds `@worker_text_cap`, write the full text to a file and add `"report_file"` to the result map.
  - `worker_final_message/1` (`:1119`), `worker_final_message_log/1` (new or derived) — source of the full text and the log it came from (for an idempotent filename).
  - `truncate_or_nil/1`/`truncate_text/2`/`truncation_marker/1` (`:1139`) — keep; `final_message` stays the capped preview.
  - `orchestrator_working_dir/1` (`:1050`) — target directory for the spill; `nil` ⇒ platform-root fallback.
  - `@worker_text_cap` (`:34`) — unchanged.
- `lib/repo_builder/orchestrator/system_prompt.ex` — `working_dir_block/1` (`:146`) framing; confirm the spill location/wording is consistent (read-only; likely no change). Optionally extend the reporting clause to mention the platform may itself spill overflow to a file the coordinator can read.
- `lib/repo_builder/session/server.ex` — `cleanup_workspace/1` (`:720`) confirms only scratch workspaces are removed, so a spill under the working dir persists (read-only reference).
- `test/repo_builder/orchestrator/worker_report_truncation_test.exs` — existing regression test; extend with the deterministic-spill assertions (see New Files note — this is an edit, not a new file).
- `BUILD_PROMPT.md` §4.1 (redaction — the spilled text is already-persisted, post-redaction content), §6 (stdout-overflow/`max_line_bytes` — why the cap and the small tool result must stay) — read-only context.

### New Files
- None required. The regression coverage is added to the existing `test/repo_builder/orchestrator/worker_report_truncation_test.exs`. (If preferred, a sibling `test/repo_builder/orchestrator/worker_report_spill_test.exs` may be created instead; keep it in the same `SessionCase` style.)

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Confirm the mechanism in the live runtime
- Use Tidewave `execute_sql_query` to re-read logs 7131–7151 (`agent_logs` by `log_no`) and confirm 7133/7144 carry inlined, truncated `final_message`s and 7146/7147 complain of repeated truncation — i.e. the worker did not write an `ai_docs/` file and the prompt clause was ignored.
- Use Tidewave `project_eval` to confirm `worker_final_message/1` returns the full text (length > 2,000) for such a worker while `check_agent_status` surfaces only the capped prefix. Use `get_source_location` to verify current line numbers before editing.

### 2. Add the deterministic spill helper(s)
- In `lib/repo_builder/orchestrator/tools.ex`, add a private helper that, given the orchestrator id, the worker, the full message, and the source log, writes the full message to a markdown file and returns `{:ok, path}` (or `nil` on write failure — never raise; the tool must keep returning the preview).
  - Directory: `Path.join(working_dir_or_platform_root, "ai_docs/worker-reports")`, created with `File.mkdir_p/1`.
  - `working_dir_or_platform_root = orchestrator_working_dir(orchestrator_id) || File.cwd!()`.
  - Filename: idempotent and collision-safe, derived from the worker name (slugified) + a stable suffix from the source log (e.g. the log's `id`/`log_no`), e.g. `"<worker-slug>-<log_no>.md"`. Re-calling `check_agent_status` rewrites the same path.
  - Returned path: **relative** to the working dir when a working dir is set (so the orchestrator can `Read ai_docs/worker-reports/...`); **absolute** when falling back to the platform root.
  - File body: the full untruncated message, optionally with a one-line header (worker name, status, captured-at) for readability.
- Add `@spec`s on every new public helper (private helpers may rely on inference per BUILD_PROMPT §3 rule 1, but add specs where they aid Dialyzer). Tagged-tuple returns; never raise (wrap `File.write` and return `nil` on `{:error, _}`).

### 3. Wire the spill into `check_agent_status/2`
- Compute the full message once (and the log it came from) before truncation. Two clean options — pick the minimal one:
  - keep `worker_final_message/1` and add a small companion that also returns the source log (e.g. `worker_final_message_with_log/1`), or
  - have `worker_final_message/1` return `{text, log} | nil` and adjust the lone caller.
- `final_message` stays `truncate_or_nil(full)` (capped preview, unchanged).
- When `full != nil` and `String.length(full) > @worker_text_cap`, call the spill helper and put `"report_file" => path` in the result map (omit or set `nil` when no truncation occurred or the write failed).
- Keep the result map shape otherwise identical (`id`, `name`, `status`, `cost_usd`, `final_message`, `recent_events`) so the LiveView and any callers are unaffected; `report_file` is purely additive.

### 4. (Optional, low-risk) Nudge the prompt + marker toward the deterministic reality
- Extend `truncation_marker/1` and/or `worker_reporting_clause/0` to note that the **platform writes the full output to `ai_docs/worker-reports/` and returns its path as `report_file`** when truncation occurs, so the orchestrator knows to read `report_file` rather than re-dispatch the worker. Keep the marker short. This is documentation-only and must not change the cap.

### 5. Extend the regression test
- In `test/repo_builder/orchestrator/worker_report_truncation_test.exs` (uses `RepoBuilder.SessionCase`):
  - Set the orchestrator's `working_dir` to a temp dir created by the test (and clean it up) so the spill target is deterministic and assertable.
  - Persist a `:done` (or `:text_delta`) event whose payload text exceeds `@worker_text_cap`.
  - Call `Tools.call("check_agent_status", orch.id, %{"name" => name})` and assert:
    - `result["final_message"]` is still capped and ends with the truncation marker (existing assertion preserved);
    - `result["report_file"]` is present and non-nil;
    - resolving `report_file` against the working dir yields a file whose contents equal the **full** original text (no truncation);
    - calling `check_agent_status` twice writes the **same** path (idempotent) and does not error.
  - Add a negative case: a short message (≤ cap) yields `report_file` absent/`nil` and an untruncated `final_message`.
  - Keep the existing clause/marker assertions green.

### 6. Validate
- Run the full `Validation Commands` block below; every command must be green with zero regressions.

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- `mix test test/repo_builder/orchestrator/worker_report_truncation_test.exs` — the extended regression test passes (the new spill assertions fail before the fix, pass after).
- `mix compile --warnings-as-errors` — compile clean; gradual set-theoretic checker + `warnings_as_errors` pass.
- `mix test --warnings-as-errors` — full ExUnit suite green.
- `mix format --check-formatted` — formatting clean.
- `mix credo --strict` — lint clean, including every-public-fn-`@spec`.
- `mix dialyzer` — no new `@spec`/contract warnings, no stale ignore filters.

## Notes
- **Why platform-side spill instead of more prompting?** The prior fix already proved prompting is insufficient — logs 7131–7151 (post-fix) show `glm-5.2` ignoring the `ai_docs/` clause and inlining a 10 KB report, truncated "a third time". Retrievability must not depend on a non-deterministic agent obeying instructions; the platform holds the full text at the boundary and can guarantee it.
- **Why not raise `@worker_text_cap`?** The cap deliberately bounds the `check_agent_status` tool result against the known large-tool-result stdout-overflow failure (`tools.ex:42-44`, issue-log-2389, `BUILD_PROMPT.md` §6). Raising it re-exposes that risk. Spilling the full text to a file keeps the tool result small **and** makes the full content retrievable.
- **Redaction:** the spilled text is the worker's already-persisted final message (post-redaction content from `agent_logs`), so writing it to a file under the working dir introduces no new secret exposure beyond what the DB and live UI already hold (`BUILD_PROMPT.md` §4.1).
- **Durability boundary:** the spill persists and is orchestrator-readable only when the orchestrator has a Working directory (workers share it). With no working dir, the fallback writes under the platform root and returns an absolute path; agents in that mode run in isolated scratch workspaces, so document this as the lesser path and keep steering operators to set a working dir (consistent with `system_prompt.ex` `working_dir_block/1`).
- **No LiveView change:** `report_file` is an additive field on the `check_agent_status` tool result consumed by the orchestrator agent; the dashboard renders unchanged, so no `Phoenix.LiveViewTest` is required. The regression test is plain ExUnit against the tools context.
- **Idempotency:** keying the spill filename on the source log (`id`/`log_no`) makes repeated `check_agent_status` calls overwrite the same file rather than accumulate duplicates — important because the orchestrator polls status repeatedly.
- **Lineage:** supersedes the prompt-only `specs/issue-send-adw-truncated-sdlc_planner-worker-report-truncation-ai-docs-handoff.md`; keep that clause/marker as cooperative guidance, but this deterministic spill is the guarantee.
