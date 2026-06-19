# Feature: Orchestrator `clear_context` tool (full worker context reset)

## Metadata
issue_number: `clear_context`
adw_id: `tool`
issue_json: `—`

## Feature Description
Give the orchestrator a tool to **fully reset a worker agent's context window**, not merely compact it. Today the only context-management lever the orchestrator has against a worker is `compact_agent`, which dispatches the harness's `/compact` slash command — that *summarizes and compresses* the worker's conversation but still leaves a summary occupying the window. There is no way to return a worker to a genuinely blank slate.

The mechanism is simple because of how this platform stores worker context: **a worker's conversation lives entirely inside the harness CLI session, keyed by `agents.session_id`.** Elixir never holds the message buffer — it persists only the `session_id` and replays it via the harness's `--resume`/`--session` flag (`lib/repo_builder/harness/claude.ex:70-72`, `lib/repo_builder/harness/pi.ex:59-61`). The dispatch path proves it (`lib/repo_builder/orchestrator/tools.ex:251`):

```elixir
session_id = worker.session_id || generate_session_id()
```

So nulling `session_id` makes the *next* `command_agent` mint a fresh session → the harness starts with **zero prior history**. That is a true clear. (Soft-hiding `agent_logs` rows would only wipe Elixir's observability copy, not the harness's actual context — so that is explicitly **not** the mechanism here.)

The feature is two parts:
1. A new `clear_context` orchestrator tool that reaps any live session, then nulls the worker's `session_id` so its next task begins fresh.
2. System-prompt guidance teaching the orchestrator *when* to clear vs. compact — proactively clearing a high-usage worker (≈80%+) before handing it new, unrelated work, while preferring `compact_agent` when the next task depends on prior history.

## User Story
As the **orchestrator agent** (driving a long multi-agent session)
I want to **fully reset a worker's context window before giving it new, unrelated work**
So that **the worker starts the new task with a clean, maximally-available context instead of dragging a compacted summary of irrelevant prior work — improving quality and reducing token cost.**

## Problem Statement
The orchestrator can detect that a worker's context window is filling (`report_cost` already rolls up per-worker token usage and warns at `@high_usage_threshold 0.8` via `ContextWindow.usage_fraction/3`), but its only remedial action is `compact_agent`. Compaction keeps a summary in-window, which:
- still consumes a meaningful fraction of the window,
- carries forward irrelevant prior-task context when the *next* task is unrelated, and
- cannot return a degraded/poisoned context to a clean state.

There is no tool to reset a worker to a blank context, and no guidance telling the orchestrator to do so before dispatching independent new work.

## Solution Statement
Add a `clear_context` tool that mirrors the existing `compact_agent`/`interrupt_agent`/`delete_agent` shape:
1. Resolve the worker by name (orchestrator-scoped).
2. Reap any live session with `Session.Supervisor.stop_session/1` (ignored if none), so no orphaned OS child survives the reset.
3. Null the worker's session via `Agents.set_session(worker.id, nil)` — already spec'd to accept `nil` (`lib/repo_builder/agents.ex:99`; `Agent.session_changeset/2` has no `validate_required` on the field, `lib/repo_builder/agents/agent.ex:90`).
4. Mark the worker `:idle` and broadcast an agent-updated event so the dashboard reflects the reset.
5. Return `{:ok, %{"status" => "cleared", ...}}`.

The next `command_agent` call then takes the `|| generate_session_id()` branch and the harness launches a brand-new session.

The detection infrastructure for the "almost full" heuristic already exists (`ContextWindow`, `report_cost`'s 80% threshold); only orchestrator *instruction* is missing. Extend `context_management_block/0` in the system prompt to distinguish clear (new independent task → blank window) from compact (continuing related work → keep summary).

## Relevant Files
Use these files to implement the feature:

- `lib/repo_builder/orchestrator/tool_catalog.ex` — Single source of truth for the orchestrator's tool schemas (the MCP controller and pi binding both render from `ToolCatalog.tools/0`). Add the `clear_context` tool definition here (alongside `compact_agent`).
- `lib/repo_builder/orchestrator/tools.ex` — Tool dispatch + handlers. Add a `dispatch("clear_context", …)` clause (next to `compact_agent` at line 79) and a `clear_context/2` handler (model it on `compact_agent/2` line 776, `interrupt_agent/2` line 319, and `delete_agent/2` lines 516-533, which already does the `stop_session` + broadcast pattern).
- `lib/repo_builder/agents.ex` — `set_session/2` (line 101) already accepts `nil`; `set_status/2` (line 116) for marking `:idle`. No change expected; reuse.
- `lib/repo_builder/agents/agent.ex` — `session_changeset/2` (line 90) confirms nulling is valid (no required-field guard). Reference only.
- `lib/repo_builder/orchestrator/system_prompt.ex` — `context_management_block/0` (≈lines 240-251) currently only mentions compaction. Extend it with clear-vs-compact guidance and the proactive-at-80% rule.
- `lib/repo_builder/orchestrator/context_window.ex` — `usage_fraction/3` + window sizing; already powers the 80% warning. Reference only (no change; confirms the heuristic exists).
- `lib/repo_builder/session/server.ex` / `lib/repo_builder/session/supervisor.ex` — `stop_session/1` reaps the live OS process for a worker (used by `delete_agent`). Reference for the reap step.
- `lib/repo_builder/dashboard.ex` — Broadcast seam (`delete_agent` uses `Dashboard.broadcast_agent_deleted/1`); use the analogous agent-updated broadcast so the UI reflects the cleared/idle state. Confirm the exact function name during implementation.
- `BUILD_PROMPT.md` — §10 (extensibility — tool surface), §6 (session runtime / OS-process lifecycle / reaping), §4 (canonical events). Authoritative architecture reference.
- `ai_docs/typed-elixir-standard.md` — **(always)** enforced typed standard: `@spec` on every public/private-handler function, precise types, `{:ok, t()} | {:error, reason()}` over raising.
- `.claude/commands/conditional_docs.md` routing matched: **(always)** typed standard; "Adding or swapping a harness / tool surface" → `BUILD_PROMPT.md` §10; "session runtime / OS-process lifecycle / orphan reaping" → `BUILD_PROMPT.md` §6 + `ai_docs/adw-primitives.md`.

### New Files
- `test/repo_builder/orchestrator/clear_context_test.exs` — ExUnit test for the new tool: clears `session_id`, reaps a live session, sets `:idle`, broadcasts, and verifies the next `command_agent` starts a fresh session. Also covers the not-found error path.

## Implementation Plan
### Phase 1: Foundation
Confirm the seams the handler will reuse (no new infra needed):
- `Agents.set_session/2` accepts `nil` (verified — line 99 spec `String.t() | nil`).
- `Agents.set_status/2` for `:idle`.
- `Session.Supervisor.stop_session/1` reaps a live session and is a safe no-op when none exists (as relied upon by `delete_agent`).
- The dashboard agent-updated broadcast function name (grep `Dashboard.broadcast_agent_*`).

### Phase 2: Core Implementation
Add the `clear_context` tool: schema in `ToolCatalog`, `dispatch/3` clause, and the `clear_context/2` handler (reap → null session → idle → broadcast → ok tuple), with `@spec`.

### Phase 3: Integration
Teach the orchestrator when to use it: extend `context_management_block/0` with the clear-vs-compact distinction and the proactive-at-80% rule. Update the system-prompt test to assert the new guidance is present. Verify the tool appears in the rendered tool catalog (MCP + pi surfaces render from `ToolCatalog.tools/0`, so no separate binding file needs editing — confirm via a catalog assertion).

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Confirm seams and broadcast name
- Grep `Dashboard.broadcast_agent_` in `lib/repo_builder/dashboard.ex` to find the agent-updated/agent-changed broadcast used elsewhere; note its arity/return.
- Confirm `Session.Supervisor.stop_session/1` returns are ignorable (`delete_agent` does `_ = Session.Supervisor.stop_session(worker.id)`).

### 2. Write the failing test (`test/repo_builder/orchestrator/clear_context_test.exs`)
- Set up an orchestrator + worker (follow `tools_test.exs` / `cost_report_test.exs` setup helpers).
- Case A — clears session: give the worker a non-nil `session_id` (via `Agents.set_session/2`), call `Tools.call("clear_context", orch.id, %{"name" => name})`, assert `{:ok, %{"status" => "cleared"}}`, then reload the worker and assert `session_id == nil` and `status == :idle`.
- Case B — fresh session on next dispatch: after clearing, assert that a subsequent `command_agent` path uses a newly generated session id (assert worker's `session_id` is non-nil and **differs** from the pre-clear value). Use the FakeHarness/existing session test seam so no real CLI spawns.
- Case C — not found: `Tools.call("clear_context", orch.id, %{"name" => "ghost"})` returns `{:error, :not_found}`.
- Case D (if feasible with the test seam) — live session is reaped: start a fake session, clear, assert the session is no longer live (mirror how `delete_agent`/`interrupt_agent` tests assert reaping).

### 3. Add the tool schema to `ToolCatalog`
- In `lib/repo_builder/orchestrator/tool_catalog.ex`, add a map entry near `compact_agent`:
  - `name: "clear_context"`
  - `description`: "Fully reset a worker's context window to blank — reaps its live session and drops its resumable session id so its next task starts a fresh harness session with zero prior history. Use this (not compact_agent) before handing a worker NEW, unrelated work, especially when its context usage is high. Use compact_agent instead when the next task continues prior work."
  - `input_schema`: object with required `"name"` (string, "Target worker name.").

### 4. Add dispatch + handler in `tools.ex`
- Add `defp dispatch("clear_context", orchestrator_id, args), do: clear_context(orchestrator_id, args)` next to the `compact_agent` clause (line 79).
- Implement `@spec clear_context(Ecto.UUID.t(), map()) :: result()` and `defp clear_context/2`:
  ```elixir
  with {:ok, name} <- fetch_string(args, "name"),
       {:ok, worker} <- Agents.get_by_name_for_orchestrator(orchestrator_id, name) do
    _ = Session.Supervisor.stop_session(worker.id)   # reap live session if any
    _ = Agents.set_session(worker.id, nil)           # next command_agent mints a fresh session
    {:ok, idle} = Agents.set_status(worker.id, :idle)
    _ = Dashboard.broadcast_agent_updated(idle)      # confirm exact fn name in step 1
    {:ok, %{"status" => "cleared", "id" => worker.id, "name" => worker.name}}
  end
  ```
  Honor the typed standard: precise `@spec`, `{:ok, _} | {:error, reason}` returns, no raising on the worker-not-found path (the `with` already short-circuits to `{:error, :not_found}`).

### 5. Extend system-prompt guidance
- In `lib/repo_builder/orchestrator/system_prompt.ex`, extend `context_management_block/0` with two bullets:
  - "To fully reset a worker before NEW, unrelated work, use `clear_context` — it returns the worker to a blank context window (next task starts fresh). Prefer this over `compact_agent` when the new task does not depend on prior history."
  - "At high usage (≈80%+), proactively `clear_context` any worker you're about to hand independent new work, and `compact_agent` those continuing their current task."

### 6. Update the system-prompt test
- In `test/repo_builder/orchestrator/system_prompt_test.exs`, add/extend an assertion that the rendered prompt mentions `clear_context` and the clear-vs-compact distinction.

### 7. Add a tool-catalog presence assertion
- In `clear_context_test.exs` (or the existing catalog test if one exists), assert `ToolCatalog.tools/0` includes a tool named `"clear_context"` with a required `"name"` input — guaranteeing it surfaces on both the MCP and pi tool bindings (which render from the catalog).

### 8. Run the full validation suite
- Run every command in **Validation Commands** and fix any compile/type/format/credo/dialyzer/test issues until all are green with zero regressions.
- Optionally, via Tidewave `project_eval`, evaluate `RepoBuilder.Orchestrator.ToolCatalog.tools()` in the live app and confirm the `clear_context` entry is present; and `RepoBuilder.Orchestrator.SystemPrompt`-rendered text contains the new guidance.

## Testing Strategy
### Unit Tests
- `clear_context` nulls a worker's `session_id` and sets status `:idle` (Case A).
- After clearing, the next dispatch path generates a **new, different** session id, proving a fresh harness session (Case B).
- `clear_context` for an unknown worker returns `{:error, :not_found}` (Case C).
- A live session is reaped on clear (Case D, if the session test seam supports it — mirror `interrupt_agent`/`delete_agent` tests).
- `ToolCatalog.tools/0` exposes `clear_context` with the correct required input (catalog presence).
- System prompt renders the clear-vs-compact guidance (system_prompt_test).

### Edge Cases
- Worker with `session_id == nil` (never dispatched): clear is a harmless no-op on the session field, still returns `{:ok, "cleared"}`.
- Worker currently `:running` with a live OS process: `stop_session/1` reaps it before nulling, so no orphaned child (the bug `delete_agent`'s comment guards against).
- Worker owned by a different orchestrator: `get_by_name_for_orchestrator/2` scoping returns `{:error, :not_found}` (no cross-tenant clear).
- Concurrent dispatch racing a clear: clear marks `:idle` and nulls the session; a `command_agent` arriving after will mint a fresh session (acceptable — last write wins; document in Notes).
- Missing `"name"` arg: `fetch_string/2` returns the standard `{:error, …}`.

## Acceptance Criteria
- A new `clear_context` orchestrator tool exists, is dispatchable via `Tools.call/3`, and appears in `ToolCatalog.tools/0` (and therefore on both the MCP controller and pi tool surfaces).
- Calling `clear_context` on a worker reaps any live session, sets `session_id` to `nil`, sets status `:idle`, and broadcasts an agent-updated event.
- After a clear, the next `command_agent` for that worker starts a **new** harness session id distinct from the pre-clear value (verified in test).
- Calling `clear_context` on an unknown / non-owned worker returns `{:error, :not_found}` and changes nothing.
- The orchestrator system prompt documents `clear_context`, the clear-vs-compact distinction, and the proactive-at-≈80% rule; a test asserts this.
- All Validation Commands pass with zero regressions (compile w/ warnings-as-errors, full test suite, format, credo --strict, dialyzer).

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix test test/repo_builder/orchestrator/clear_context_test.exs` — the new tool's unit tests pass.
- `mix test test/repo_builder/orchestrator/system_prompt_test.exs` — system-prompt guidance assertions pass.
- `mix test test/repo_builder/orchestrator/tools_test.exs` — existing tool tests still pass (no regression in dispatch).
- `mix compile --warnings-as-errors` — clean compile; gradual set-theoretic type checker + `warnings_as_errors` pass.
- `mix test --warnings-as-errors` — full ExUnit suite green.
- `mix format --check-formatted` — formatting clean.
- `mix credo --strict` — lint clean, including the "@spec on every public function" gate.
- `mix dialyzer` — no new contract warnings, no stale ignore filters.

## Notes
- **No UI change required.** This is a backend orchestrator-tool feature. The worker list already reflects status via the existing dashboard broadcast; the clear simply transitions the worker to `:idle`. Hence no `Phoenix.LiveViewTest` file is added — the dashboard-router instruction is N/A here. If desired later, a console affordance ("Clear context" per-agent button) could call the same handler, at which point a LiveView integration test would be added.
- **Single tool-surface source.** `compact_agent` lives in exactly three files (`tool_catalog.ex`, `tools.ex`, `system_prompt.ex`); the MCP controller and pi extension both render the catalog dynamically, so adding `clear_context` in those same three places exposes it everywhere with no extra binding edits. Verify with the catalog-presence assertion (Step 7).
- **Why not hide `agent_logs`?** That would only clear Elixir's observability copy, not the harness's real context window. The harness owns the conversation via `session_id`; nulling it is the only mechanism that truly resets the model's context. Logs remain append-only for cost/audit history (intentionally untouched).
- **Heuristic already exists.** `ContextWindow.usage_fraction/3` + `report_cost`'s `@high_usage_threshold 0.8` already compute and surface per-worker context occupancy; this feature only adds the *action* (`clear_context`) and the *instruction* (system prompt) to act on it — no new token-counting code.
- **No new dependencies.**
- **Future extension:** an automatic policy where the orchestrator's dispatch path auto-clears a worker exceeding the threshold before a new unrelated `command_agent` — deferred; this feature keeps the decision in the orchestrator's reasoning (tool + prompt) rather than hard-coding it.
