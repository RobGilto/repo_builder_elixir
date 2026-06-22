# Bug: Spurious holding-pattern resumes cause orchestrator to dismiss turns as "already done"

**Discovered:** 2026-06-22 via postgres log analysis  
**Severity:** Medium — operator messages are not lost, but spurious turns waste compute and confuse the operator  
**Status:** Fixed — Option 1 implemented in `lib/repo_builder/orchestrator/queue.ex`

---

## Symptom

After a worker completes, the orchestrator fires multiple holding-pattern (auto_resume) turns in rapid succession. Each one responds with something like:

> "Duplicate resume signal again — the documenter's work was reviewed and reported several turns ago. Nothing pending, all workers idle, project complete. Standing by."

From the operator's perspective it looks like the orchestrator is refusing to proceed or ignoring new work. Operator messages are actually still queued and processed correctly — but the noise is confusing and wastes compute on billed turns.

Observed on multiple machines running the same orchestrator session.

---

## Evidence

Session `c4cb8958-391f-4175-9eb6-28ea9856238e`, 2026-06-21 ~11:46–12:47 (agent_logs + system_logs):

| Turn | system_logs timestamp | Entry | Outcome |
|---|---|---|---|
| Turn 2 — **correct** auto_resume | 11:46:06 | `auto_resume: holding-pattern resume orch-…-1131138` | Reviewed documenter correctly |
| Turn 3 — spurious | 11:49:14 | `auto_resume: holding-pattern resume orch-…-1148802` | "Duplicate resume signal" |
| Turn 4 — spurious | 11:49:58 | `auto_resume: holding-pattern resume orch-…-1150338` | "Duplicate resume signal" |
| Turn 5 — spurious | 11:50:52 | `auto_resume: holding-pattern resume orch-…-138757` | "Duplicate resume signal" |
| Turn 6 — spurious | 12:47:03 | `auto_resume: holding-pattern resume orch-…-1353282` | "Duplicate resume signal" |
| Turn 7 — **operator** "clear all agents" | 12:47:30 | `queue start: started turn orch-…-1356482` | ✅ Processed correctly |

5 `worker_terminal` fires for a single worker completion. The orchestrator (via `--resume` conversation history) correctly identifies turns 3–6 as repeats and dismisses them. The operator's eventual message at Turn 7 was handled correctly.

The documenter's agent_logs were cascade-deleted by the later "clear all agents" operation (`agent_logs` FK `ON DELETE CASCADE`), which is why no worker session rows appear in the window — but the auto_resume count is consistent with a 4-step prior ADW that completed just before.

---

## Root cause: dual-fire from two code paths

`worker_terminal` (the PubSub message that wakes the Queue's holding pattern) is broadcast via **two independent mechanisms**:

### Path A — `Session.Server.maybe_emit_worker_terminal`
`lib/repo_builder/session/server.ex:530`

Fires once per harness session when the agent's Session.Server processes a terminal event (`Done` or `Error`). Gated on `saw_terminal?` within a single session, so it fires **once per session completion**. For a workflow with N steps — each step executed by a separate agent session — this fires **N times total**.

### Path B — `WorkflowEngine.emit_orchestrator_resume`
Called from two sites:
- `lib/repo_builder/workflow_engine/runner.ex:185` — `Runner.finalize/2` (in-memory path, terminal run only)
- `lib/repo_builder/workers/step_worker.ex:158, 165, 183` — `StepWorker.advance/4` (durable Oban path, terminal run only)

Each site fires once per run completion (`:done` / `:abort`), not per step. So Path B contributes **+1 fire** at the end of the run.

### Combined for a 4-step ADW (plan → build → review → fix)

| Event | Path | Fire count |
|---|---|---|
| plan step agent session Done | A | 1 |
| build step agent session Done | A | 1 |
| review step agent session Done | A | 1 |
| fix step agent session Done | A | 1 |
| `StepWorker.advance(:done)` | B | 1 |
| **Total** | | **5** |

5 signals → 5 auto_resume turns → matches exactly what was observed.

---

## Secondary issue: orchestrator cannot distinguish fresh vs. repeated signals

The auto_resume prompt is identical every time:

```
"Worker documenter completed successfully and returned. Review its work and
decide the next steps (report back, dispatch follow-up work, or stop)."
```

The orchestrator uses `--resume` (full conversation history) and correctly pattern-matches "I already handled this" → dismisses. The system prompt says "you are woken **once per return**" — that contract is broken by the infrastructure sending multiple wakeups.

---

## Fix directions

### Option 1 — Deduplicate at the Queue level (safest, no upstream changes) ✅ IMPLEMENTED

Track a `seen_worker_ids` set in `Queue.State`. On each `{:worker_terminal, %{worker_id: id}}` message, if `id` is already in the set, drop it. Add the id to the set when a signal passes through (both on idle-start and on pending-record). Reset the set only when an operator message arrives — representing a new dispatch context where the same worker returning again would be a fresh, legitimate signal.

**Pro:** No changes to Session.Server or WorkflowEngine. Handles both Path A and Path B duplicates. Timing-independent — dedup works whether fires arrive simultaneously or spread across multiple turns.  
**Con:** Adds state to the Queue.

### Option 2 — Don't fire Path A for workflow-step agents

In `Session.Server.maybe_emit_worker_terminal`, check whether the completing agent is a workflow step (e.g. via a `:workflow_step?` flag set at session start in `Session.Supervisor.start_session/1`) and skip the broadcast. Let `WorkflowEngine` own the single terminal signal for workflow runs.

**Pro:** Clean separation of concerns.  
**Con:** Requires a new flag threaded through session opts; Path A still fires for standalone agents (correct behavior).

### Option 3 — Add a unique nonce to the auto_resume prompt (mitigation only)

Include a monotonically-increasing counter or timestamp so the orchestrator can distinguish a fresh signal from a historical one even in its `--resume` context:

```elixir
defp auto_resume_prompt(info) do
  nonce = System.unique_integer([:positive, :monotonic])
  "Worker #{name} #{outcome} and returned [resume-#{nonce}]. Review its work …"
end
```

**Pro:** Trivial to implement; prevents the orchestrator dismissing turns.  
**Con:** Does not fix the underlying duplicate fires — still wastes billed turns.

---

## Implementation (Option 1)

**Commit:** 2026-06-22, `lib/repo_builder/orchestrator/queue.ex`

### What changed

**`Queue.State`** — new field:
```elixir
field :seen_worker_ids, MapSet.t()
```
Initialised to `MapSet.new()` in `init/1`.

**`maybe_auto_resume/2`** — dedup check added before any action:
```elixir
worker_id = Map.get(info, :worker_id)
duplicate? = is_binary(worker_id) and MapSet.member?(state.seen_worker_ids, worker_id)

cond do
  not Orchestrators.auto_resume?() -> state
  duplicate?                        -> state   # ← NEW: drop silently
  idle?(state)  -> seen |> start_auto_resume(info) |> clear_pending()
  true          -> %{state | pending_resume?: true, ..., seen_worker_ids: seen}
end
```
`add_seen/2` helper puts the `worker_id` into the set (no-op if nil, so messages without a `worker_id` are never deduped and existing tests remain unaffected).

**`clear_pending_resume_for/2` + new `clear_pending_operator/1`** — the operator path now resets `seen_worker_ids` in addition to clearing pending flags. The non-operator `clear_pending/1` (called after an idle auto_resume start) deliberately does NOT reset `seen_worker_ids` so subsequent late-arriving duplicate fires are still suppressed even after the first resume completes.

### Key design decisions

- **Reset scope is operator-context, not per-turn.** Resetting on every turn start would allow a duplicate signal arriving just after a turn completes to slip through. Resetting only on operator messages ties the dedup window to the operator's intent: "I told you to dispatch X, so X returns once."
- **nil `worker_id` is never deduped.** Legacy or test messages without a `worker_id` key pass through unchanged — no behaviour change for existing code paths.
- **No changes to Session.Server or WorkflowEngine.** The fix is entirely contained in the Queue.

### Tests added (`test/repo_builder/orchestrator/queue_holding_pattern_test.exs`)

| Test | Asserts |
|---|---|
| `duplicate worker_id signals are deduped to a single resume` | 2 fires for same worker → 1 resume |
| `duplicate signals across multiple turns are all deduped` | 4 fires for same worker → 1 resume, no pending owed |
| `operator message resets dedup so the same worker can trigger a fresh resume` | dedup clears after operator turn → second return goes through |
| `different worker_ids are not deduped` | 2 distinct workers → 2 independent resumes |

All 939 tests pass.

---

## Relevant files

- `lib/repo_builder/orchestrator/queue.ex` — `maybe_auto_resume/2`, `add_seen/2`, `clear_pending_operator/1`, `clear_pending/1`, `State.seen_worker_ids`
- `lib/repo_builder/session/server.ex:522` — `maybe_emit_worker_terminal/2`
- `lib/repo_builder/workflow_engine/runner.ex:179` — `finalize/2`
- `lib/repo_builder/workers/step_worker.ex:152` — `advance/4`
- `lib/repo_builder/dashboard.ex:206` — `broadcast_worker_terminal/2`
- `lib/repo_builder/orchestrator/system_prompt.ex:121` — "woken once per return" contract
