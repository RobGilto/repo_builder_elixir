# BUG: Worker reports `status: "idle"` while its session is actively running

**Component:** repo_builder platform — worker/agent status reporting
**Severity:** High — causes the orchestrator to take corrective action (redundant re-dispatch) against healthy, in-flight workers
**Reported:** 2026-07-01

## Summary
A worker agent that is actively executing a dispatched task is reported as `status: "idle"` by the status-surfacing path (the automatic resume-turn notification and, transiently, `check_agent_status`). The orchestrator interprets `idle` as "stalled / stopped after producing output" and re-dispatches or resumes the worker — even though the worker is mid-run and still emitting `tool_call` / `text_delta` / `usage` events.

## Impact
- False stall detection. The drive loop's holding-pattern re-engages the orchestrator with "Worker X went IDLE after producing output," prompting a corrective re-dispatch.
- Redundant/racing work. Re-commanding a worker that is already running risks duplicate edits, wasted budget, and context churn. Observed: m5-builder was re-dispatched a full milestone brief while actively building (adding Earmark + sanitizer, creating Markdown/WikiLinks modules, editing the Wiki context).
- Erodes trust in status. The orchestrator can no longer rely on `status` to gate interrupt/re-dispatch decisions and must fall back to inspecting `recent_events` timestamps to infer liveness.

## Steps to Reproduce
1. create_agent (heavy/opus worker), then command_agent with a substantial multi-step task.
2. Shortly after dispatch, observe the worker via the resume-turn notification and check_agent_status.
3. Observed: `status: "idle"` (and `cost_usd: "0"`) while `recent_events` simultaneously shows fresh tool_call/tool_result/text_delta/usage entries with current timestamps and a final_message describing in-progress work.
4. Expected: `status: "running"` whenever the session is live and emitting events.

## Evidence (observed session)
Two consecutive check_agent_status calls on m5-builder, seconds apart:
- Call A -> status: "idle", final_message: "Let me check the wiki_test patterns...", cost_usd: "0", but recent_events streaming tool calls with 05:46:xx timestamps.
- Call B (after operator flagged the bug) -> status: "running", final_message: "Now let me modify the Wiki context...", still cost_usd: "0", recent_events at 05:48-05:50.
The worker never actually stopped; only the reported status flipped.

## Suspected Root Cause (hypotheses)
- Status derived from a stale/last-checkpointed field rather than live session presence — status is written at session boundaries and not refreshed while events stream, so a just-started or between-tool-turn session reads as idle.
- Race between session-spawn and status write: the roster row is initialized idle and the transition to running lags the first emitted event, widening the window where a live worker looks idle.
- cost_usd: "0" correlation: cost is also 0 during this window, suggesting usage/cost aggregation and status both update only on a periodic/terminal flush rather than per-event. Consider deriving running directly from "has emitted an event within the last N seconds / session PID alive."

## Suggested Fix / Acceptance Criteria
- AC1: While a worker's underlying session is alive and has emitted any event within a short liveness window, status reports running (never idle) across both check_agent_status and the resume-turn notification text.
- AC2: The "went IDLE after producing output" resume trigger fires only on a genuine terminal/stopped session, not on an in-flight one.
- AC3: Regression test: dispatch a long-running task and poll status repeatedly; assert status is running for the full duration and flips to idle/terminal only after completion.
- AC4 (defensive): cost_usd/usage reflects accrued spend during the run, not just at terminal flush (or, if that's a separate issue, file/link it).

## Workaround (in place)
Orchestrator treats status: "idle" as advisory only and confirms liveness via recent_events timestamps + final_message before any interrupt/re-dispatch decision.