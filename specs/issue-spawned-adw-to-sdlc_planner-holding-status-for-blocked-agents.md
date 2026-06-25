# Bug: Worker held up pending external input is mis-reported as "Succeeded" with no way to resume

## Metadata
issue_number: `spawned`
adw_id: `to`
issue_json: `run`

> Note: the `issue_number`/`adw_id`/`issue_json` values above are placeholder tokens
> the planner received verbatim (this bug was filed conversationally, not from a GitHub
> issue). The bug is fully described below.

## Bug Description

An orchestrator-spawned **worker** agent was dispatched to do work that used the
Playwright MCP tool. The tool blocked because a **browser login** was required (a
human/external action). While the worker was held up waiting on that login:

- **Symptom 1 (wrong status):** the UI showed the worker as **"Succeeded"** even though
  it had not actually completed its task — it had merely *stopped* because it was blocked
  on an external condition.
- **Symptom 2 (no resumption):** because it was treated as a completed success, the
  worker did **not** proceed forward once conditions were good (login done), and there
  was no first-class way to put it back to work.

**Expected behavior:** a worker that stops because it is *blocked on an external/human
action* (browser login, a credential, a manual step) should be shown in a distinct
**"holding"** state — NOT "Succeeded" and NOT "failed" — and the orchestrator (or
operator) should be able to **resume/ping it again to continue** once the blocking
condition clears.

**Actual behavior:** the platform has only two terminal outcomes for a worker —
`%Event.Done{ok: true}` (→ swimlane `:succeeded`, persistent status `:idle`) and
`%Event.Error{}` (→ `:failed`/`:error`). A "blocked, paused, resumable" stop is
indistinguishable from a genuine completion, so it is rendered "Succeeded" and the
worker is considered done.

## Problem Statement

The canonical terminal contract and every consumer downstream of it (the swimlane lane,
the persistent `agents.status`, the console status mapping, and the orchestrator
holding-pattern Queue) collapse "worker stopped because it is blocked pending external
input" into "worker completed successfully" (`%Event.Done{ok: true}`). There is no
**holding** state, so a blocked worker is (a) visually mislabeled "Succeeded" and (b)
has no first-class resume affordance for the orchestrator to continue it once the
blocking condition is resolved.

## Solution Statement

Introduce a first-class, minimal **holding** terminal classification, modeled as a new
`reason` value on the existing `%Event.Done{}` variant — `:held_pending_input` (it is a
*clean* stop, so `ok: true` is preserved; it is just not a *completion*). Detect it at
the worker's terminal via a small, pure, fully-tested `RepoBuilder.Agents.Holding`
module (mirroring the existing `RepoBuilder.Agents.Handover` protocol):

1. **Primary (deterministic) signal** — a `:holding <reason>` final-message token the
   worker emits, taught to every spawned worker through a system-prompt protocol clause
   (exactly parallel to the existing `:handover <path>` convention).
2. **Best-effort heuristic** — a conservative phrase scan of the terminal text
   (`"waiting for you to log in"`, `"requires a browser login"`, …) so the *original
   Playwright incident* (where the worker did not know to emit the signal) is still
   caught, without false positives on normal completions.

A held worker then:

- broadcasts a **`:holding`** swimlane lane (not `:succeeded`),
- has its persistent `agents.status` set to **`:holding`** (a new `Ecto.Enum` value;
  the column is stored as a string, so **no migration is needed**),
- maps to a distinct **"Holding"** badge in the console (not "Succeeded"),
- is **NOT reaped/deleted** and **keeps its resumable `session_id`**, and
- causes the orchestrator Queue's holding pattern to enqueue a **holding-aware** resume
  turn that tells the orchestrator the worker is blocked, NOT done, and can be resumed
  with `command_agent` once the condition is cleared.

Resumption reuses the **existing** `command_agent` path: it resolves the worker by name,
reuses its persisted `session_id` (`Claude --resume` / `pi --session`), and flips the
status back to `:running`. No new resume mechanism is required — only that holding does
not destroy the worker or its session.

## Steps to Reproduce

1. Start the app (`scripts/pg.sh start`, then `iex -S mix phx.server`) and open the
   console at `http://localhost:4000`.
2. From the orchestrator, spawn a worker and `command_agent` it with a task that invokes
   a tool requiring an interactive browser login (e.g. a Playwright MCP flow against a
   site that is not logged in).
3. The worker stops while blocked on the login. Observe its terminal `%Event.Done{ok:
   true}` (Claude `result subtype: success`, or the pi clean-exit synthesis).
4. **Bug:** the console shows the worker as **"Succeeded"** (`console_live.ex` maps
   `%Event.Done{ok: true}` → `:succeeded`), the swimlane row turns `:succeeded`
   (`session/server.ex` `maybe_broadcast_lane`), the persistent status is set to `:idle`
   (`logs/writer.ex` `update_status_quietly`), and the orchestrator is auto-resumed to
   "review its work" — even though nothing was completed and there is no holding state to
   resume from.

> Deterministic test-level repro (no real CLI): drive a `Done` whose `final_text` ends
> with `:holding browser login required` (or contains a known holding phrase) through the
> worker session / console and assert the status is `:holding`, not `:succeeded`. This is
> the basis for the regression tests below.

## Root Cause Analysis

The terminal contract has exactly two outcomes and every consumer assumes a `Done{ok:
true}` is a *completion*:

- **`lib/repo_builder/harness/event.ex`** — `Done.reason` enumerates terminal-stop kinds
  (`:success | :clean_exit | :agent_end | … | :sigterm_on_blocking_step`) but has **no
  value for "stopped because blocked pending external input"**. A blocked, resumable stop
  is therefore forced to look like a success.
- **`lib/repo_builder/session/server.ex`** — `maybe_broadcast_lane(%Event.Done{ok:
  true}, …)` → `lane(:succeeded)`; `maybe_emit_worker_terminal/2` sets `ok? =
  match?(%Event.Done{ok: true}, event)`, so the orchestrator is told the worker
  *completed successfully*.
- **`lib/repo_builder/logs/writer.ex`** — `update_status_quietly/2` maps `%Event.Done{ok:
  true}` → persistent status `:idle`.
- **`lib/repo_builder_web/live/console_live.ex:2335`** — `status = if event.ok, do:
  :succeeded, else: :failed`. This is the exact line that rendered **"Succeeded"** for
  the held worker.
- **`lib/repo_builder/orchestrator/queue.ex`** — `maybe_auto_resume/2` has branches for
  handover, context-limit wind-down, force-retire, and normal resume, but **none for a
  worker that paused pending external input**; a `Done{ok: true}` with no handover signal
  falls through to `normal_resume/2`, which treats it as "completed and returned".

There is no representation of, nor policy for, "the worker is blocked on an external
condition, keep it and let it be resumed." That missing state is the root cause.

## Relevant Files

Use these files to fix the bug:

- `BUILD_PROMPT.md` — §4 (canonical event contract; the closed `Done.reason` union is the
  single contract surface we extend), §6 (session runtime / terminal synthesis), §8
  (persistence + `Ecto.Enum` for closed-domain status columns), §9 (LiveView swimlane +
  status rendering). Authoritative spec; read first.
- `ai_docs/typed-elixir-standard.md` — the enforced typed standard (**always** row of the
  conditional-docs router): `@spec` on every public function, `typedstruct`/`@enforce_keys`,
  precise unions, tagged-tuple returns, wire-vs-domain at boundaries.
- `lib/repo_builder/harness/event.ex` — the canonical `Event` sum type. Add the single new
  `Done.reason` value `:held_pending_input` here (one deliberate, documented contract
  addition; no new variant, no new field).
- `lib/repo_builder/agents/handover.ex` — the existing pure "platform-detects /
  worker-acts" signal+prompt protocol. The new `Holding` module mirrors its shape exactly;
  read it as the template.
- `lib/repo_builder/agents/agent.ex` — the `agents` schema. Add `:holding` to the `status`
  `Ecto.Enum` `values:` list and the `@type status` union (no migration — column is `:string`).
- `lib/repo_builder/logs/writer.ex` — `update_status_quietly/2`; add the holding→`:holding`
  status mapping.
- `lib/repo_builder/session/server.ex` — the worker session GenServer. Classify the terminal
  `Done` as holding (signal/heuristic) for worker sessions; route the `:holding` lane; carry
  `holding?`/`holding_reason` on the worker-terminal `info`.
- `lib/repo_builder/orchestrator/queue.ex` — `maybe_auto_resume/2`; add the holding branch
  (no reap; holding-aware resume; dedup like `normal_resume`).
- `lib/repo_builder/orchestrator/tools.ex` — `command_agent/2` already resumes a worker by
  name via its persisted `session_id` and sets `:running` (the resume path; no change needed
  beyond confirming holding does not null the session). The worker system-prompt assembly
  (~line 1365, where `Handover.protocol_clause/0` is injected) is where `Holding.protocol_clause/0`
  is appended.
- `lib/repo_builder/dashboard.ex` — `broadcast_worker_terminal/2`; extend the `info` typespec
  with the optional `holding?`/`holding_reason` fields (additive, back-compatible).
- `lib/repo_builder_web/live/console_live.ex` — `handle_info({:agent_event, _, %Event.Done{}, _})`
  (line ~2335) maps `Done` → console status. Make it map `:held_pending_input` → `:holding`.
  Also check the "all finished" / clearable-status helpers do not treat `:holding` as finished.
- `lib/repo_builder_web/components/console_components.ex` — the `@statuses` attr list (~line 33),
  `status_cat_class/1`, `status_dot_class/1`, and the active-worker roster filter (~line 3266,
  `status in [:idle, :running]`). Add `:holding` so it renders distinctly and stays visible/resumable.

### New Files

- `lib/repo_builder/agents/holding.ex` — pure, harness-blind holding-protocol helper
  (`parse_signal/1`, `detect/1`, `classify/1`, `protocol_clause/0`, `holding_resume_prompt/2`),
  mirroring `RepoBuilder.Agents.Handover`. No process state, no harness, no `Repo` — fully
  unit-testable.
- `test/repo_builder/agents/holding_test.exs` — unit tests for the `Holding` module.
- `test/repo_builder/orchestrator/queue_holding_test.exs` — Queue holding-branch tests (no
  reap; holding resume enqueued; dedup; operator supersede), using the injected `starter`/`tools`.
- `test/repo_builder_web/live/test_holding_status_test.exs` — `Phoenix.LiveViewTest`
  integration test proving a holding worker terminal renders a distinct "Holding" status and
  NOT "Succeeded" (fails before the fix, passes after).

## Step by Step Tasks

IMPORTANT: Execute every step in order, top to bottom.

### 1. Add the `:held_pending_input` terminal reason to the canonical contract

- In `lib/repo_builder/harness/event.ex`, add `:held_pending_input` to the `Done.reason`
  field's union (after `:sigterm_on_blocking_step`). Update the `Done` `@moduledoc` to note
  that `:held_pending_input` is a **clean, resumable stop** (worker blocked pending external
  input): `ok: true`, but NOT a completion.
- This is the **single deliberate contract edit** (BUILD_PROMPT §4); no new variant, no new
  field, so the closed sum type and every `case`/`with` on the event *struct* is unaffected.
- Grep for any exhaustive match on a `Done`'s `.reason` value (`grep -rn "Done{reason:" lib test`)
  and confirm none require a new clause (interpolations like `"reason=#{event.reason}"` are safe).

### 2. Create the pure `RepoBuilder.Agents.Holding` protocol module

- Create `lib/repo_builder/agents/holding.ex` mirroring `Agents.Handover`:
  - `@spec parse_signal(String.t() | nil) :: {:ok, String.t()} | :none` — match the LAST
    `:holding <reason>` token in the worker's final message (regex `~r/:holding\s+(.+)/`,
    trim trailing punctuation/backticks, take the rest of the line as the reason; empty ⇒ `:none`).
  - `@spec detect(String.t() | nil) :: {:ok, String.t()} | :none` — a **conservative** scan
    for a small, documented set of "blocked on external/human action" phrases, e.g.
    `"waiting for you to log in"`, `"log in to the browser"`, `"requires a browser login"`,
    `"please sign in"`, `"authenticate in the browser"`, `"manual login required"`. Case-insensitive.
    Returns `{:ok, matched_reason}` or `:none`. Keep the list small to avoid false positives on
    normal successful completions.
  - `@spec classify(String.t() | nil) :: {:ok, String.t()} | :none` — `parse_signal/1` first,
    then `detect/1` (signal wins).
  - `@spec protocol_clause() :: String.t()` — a worker-facing clause: "If you cannot proceed
    because you are blocked on an external or human action (a browser login, a credential, a
    manual step that only a human can do), do NOT report success. End your final message with
    EXACTLY `:holding <short reason>` on its own line and STOP. You will be placed in a
    HOLDING state (not retired); once the blocking condition is resolved you will be resumed to
    continue from where you left off." (mirror `Handover.protocol_clause/0` tone/format).
  - `@spec holding_resume_prompt(String.t(), String.t()) :: String.t()` — the orchestrator
    auto-resume text naming the holding worker + reason: it is **blocked, not done**; once the
    condition is cleared, resume it with `command_agent` (its session is preserved); otherwise
    leave it holding. Do NOT delete it.
- Every public function carries an `@spec`; the module holds no state and touches no `Repo`/harness.

### 3. Add `:holding` to the persistent agent status enum

- In `lib/repo_builder/agents/agent.ex`, add `:holding` to the `status` `Ecto.Enum`
  `values: [:idle, :running, :error, :holding]` and to `@type status :: :idle | :running |
  :error | :holding`. No migration (the column is `:string`; `Ecto.Enum` casts/loads the new
  value transparently).
- Grep for exhaustive matches on an agent's `status` atom (`grep -rn "status in \[\|status ==" lib`)
  and update any that must account for holding (see Tasks 7 and 8 for the known UI ones).

### 4. Map the holding terminal to the persistent `:holding` status

- In `lib/repo_builder/logs/writer.ex`, `update_status_quietly/2`: add a clause **before** the
  generic `%Event.Done{ok: true} -> :idle` clause:
  `%Event.Done{reason: :held_pending_input} -> :holding`.

### 5. Classify holding in the session runtime and route the `:holding` lane / worker-terminal

- In `lib/repo_builder/session/server.ex`:
  - Add a small `@spec classify_holding(Event.t(), State.t()) :: Event.t()` helper that, for a
    **worker** session (state has `agent_db_id`) and a `%Event.Done{ok: true}` whose `reason` is
    not already `:held_pending_input`, runs `Holding.classify(Done.final_text)` and, on `{:ok,
    reason}`, returns the event with `reason: :held_pending_input` (optionally folding the reason
    into `final_text` for display). Otherwise returns the event unchanged. Apply it at the top of
    `dispatch/2` (or immediately before dispatching a terminal event) so the rewritten event flows
    through the existing persist/lane/worker-terminal machinery uniformly.
  - `maybe_broadcast_lane/2`: add `defp maybe_broadcast_lane(%Event.Done{reason:
    :held_pending_input}, state), do: lane(state, :holding, state.session_id)` **before** the
    `%Event.Done{ok: true}` clause. Widen the `lane/3` status type to `:running | :succeeded |
    :failed | :holding` and its `@spec`.
  - `maybe_emit_worker_terminal/2`: compute `holding? = match?(%Event.Done{reason:
    :held_pending_input}, event)` and `holding_reason` (from the event), and include both in the
    broadcast `info` map. Keep `ok?` as-is (a held Done is still `ok: true`); the Queue keys off
    `holding?`.
- Leave the `Done` event's `ok: true` intact — holding is a clean stop, and persistence/cost
  rollups stay correct.

### 6. Add the Queue holding branch (no reap; holding-aware resume)

- In `lib/repo_builder/orchestrator/queue.ex`, `maybe_auto_resume/2`: after the handover branch
  and before `resume_or_wind_down/2`, add: if `Map.get(info, :holding?)` is true, route to a new
  `@spec hold(State.t(), map()) :: State.t()` that:
  - does **NOT** delete/reap the worker and does **NOT** wind it down (a held worker must survive
    so it can be resumed),
  - when `Orchestrators.auto_resume?()` is enabled, enqueues ONE holding-aware resume turn
    (`Holding.holding_resume_prompt(name, reason)`) via the existing `resume_with/3` idle/pending
    machinery, reusing the same duplicate-suppression as `normal_resume/2` (so a held worker does
    not spam resume turns), and
  - when auto-resume is disabled, leaves the worker holding for the operator to resume manually
    (the persistent `:holding` status + console badge make it discoverable).
- Confirm `command_agent/2` (`tools.ex`) is the resume path and that holding does **not** null
  `session_id` anywhere (unlike `clear_context`), so a resume reuses the worker's CLI session.

### 7. Teach workers the holding protocol (system prompt)

- In `lib/repo_builder/orchestrator/tools.ex`, where the worker system prompt is assembled
  (the block that interpolates `Handover.protocol_clause()` ~line 1365), also append
  `RepoBuilder.Agents.Holding.protocol_clause()` so every spawned worker learns to emit
  `:holding <reason>` when blocked on external/human input.

### 8. Extend the worker-terminal broadcast typespec (additive)

- In `lib/repo_builder/dashboard.ex`, extend the `broadcast_worker_terminal/2` `info` map
  typespec with `optional(:holding?) => boolean()` and `optional(:holding_reason) => String.t()
  | nil`. Update the docstring to mention the holding fields. Back-compatible: existing callers
  that omit them are unaffected (Queue treats absent as `holding?: false`).

### 9. Render "Holding" distinctly in the console (UI)

- In `lib/repo_builder_web/live/console_live.ex`, `handle_info({:agent_event, agent_id,
  %Event.Done{} = event, log_no}, socket)` (~line 2335): replace `status = if event.ok, do:
  :succeeded, else: :failed` with a clause that yields `:holding` when `event.reason ==
  :held_pending_input`, else the existing succeeded/failed mapping.
- Check the finished/clearable helpers (`@finished_workflow_statuses`, the
  `status != :running` / `status in [:succeeded, :failed, :cancelled]` predicates around lines
  774, 1593–1598, 3540) and ensure a `:holding` agent is **not** treated as finished/clearable in
  a way that hides it — a holding worker should remain visible and resumable.
- In `lib/repo_builder_web/components/console_components.ex`:
  - add `:holding` to the `@statuses` attr `values:` list (~line 33),
  - add `status_cat_class(:holding)` and `status_dot_class(:holding)` clauses with a distinct
    style (e.g. an amber/yellow dot — `bg-amber-500` — clearly different from the emerald
    "succeeded"), and a "Holding" human label wherever statuses are labeled,
  - add `:holding` to the active-worker roster filter (~line 3266, `status in [:idle, :running,
    :holding]`) so held workers stay listed and resumable.

### 10. Unit-test the `Holding` module

- Create `test/repo_builder/agents/holding_test.exs`:
  - `parse_signal/1`: matches `:holding browser login required`, takes the last token line,
    trims trailing punctuation/backticks, returns `:none` for nil/empty/no-match.
  - `detect/1`: positive on each documented phrase (case-insensitive); **negative** on normal
    successful-completion text (e.g. "Done. All tests pass.") to prove no false positives.
  - `classify/1`: signal beats heuristic; `:none` when neither present.

### 11. Test the session classification + status mapping

- Add/extend a session-server test asserting that a **worker** terminal `%Event.Done{ok: true,
  final_text: "…:holding browser login required"}` (a) broadcasts a `:holding` swimlane lane
  (not `:succeeded`), (b) emits a `{:worker_terminal, info}` with `holding?: true`, and (c) the
  agent's persisted status becomes `:holding` (via `Logs.Writer`). Add a regression case: a
  worker `Done{ok: true}` with ordinary final text still yields `:succeeded` lane + `:idle` status.
- Use the `RepoBuilder.Harness.Fake` adapter / Mox registry seam and `start_supervised!/1`;
  synchronize with `Process.monitor`/`:sys.get_state` (no `Process.sleep`), per AGENTS.md.

### 12. Test the Queue holding branch

- Create `test/repo_builder/orchestrator/queue_holding_test.exs` using the injected `starter`
  (deterministic busy/idle) and a fake `tools` to assert which tool was issued:
  - a `{:worker_terminal, %{holding?: true, …}}` does **NOT** call `delete_agent` (no reap),
  - with `auto_resume?` enabled + idle queue, exactly one holding-aware resume turn is started
    (and its prompt names the worker as holding, not done),
  - a duplicate holding signal for the same worker is suppressed,
  - an operator message supersedes/clears a pending holding resume.

### 13. LiveView integration test (the UI is LiveView — required)

- Create `test/repo_builder_web/live/test_holding_status_test.exs` (`Phoenix.LiveViewTest`):
  drive a worker `%Event.Done{ok: true, reason: :held_pending_input}` (or a `Done` whose
  `final_text` carries the holding signal) through the console's PubSub path and assert, via
  `has_element?/2` on the agent/swimlane status element ID, that it shows a **Holding** badge and
  **not** "Succeeded". This fails before the fix (Done→:succeeded) and passes after.
- Optionally capture a screenshot of `http://localhost:4000` via Tidewave Web vision mode (or the
  Playwright MCP tools) as visual proof the badge renders.

### 14. Run the full validation suite

- Run every command in **Validation Commands** and fix anything that is not green.

## Validation Commands

Execute every command to validate the bug is fixed with zero regressions. (Start Postgres
first: `scripts/pg.sh start`.)

- `mix test test/repo_builder/agents/holding_test.exs` — the new `Holding` unit tests pass.
- `mix test test/repo_builder/orchestrator/queue_holding_test.exs` — the Queue holding-branch
  tests pass (no reap, holding resume, dedup, operator supersede).
- `mix test test/repo_builder_web/live/test_holding_status_test.exs` — the LiveView test proves a
  held worker renders "Holding", not "Succeeded".
- `mix compile --warnings-as-errors` — clean; the gradual set-theoretic checker and
  `warnings_as_errors` pass (new `Done.reason` value, new `:holding` status, new lane status).
- `mix test --warnings-as-errors` — the full ExUnit suite (Postgres-backed) is green, zero failures.
- `mix format --check-formatted` — formatted.
- `mix credo --strict` — lint passes, incl. the `@spec`-on-every-public-function gate (the new
  `Holding` module + new public helpers).
- `mix dialyzer` — no new contract warnings; no stale ignore filters (`list_unused_filters: true`).
  Pay attention to the widened `lane/3` status type and the additive `broadcast_worker_terminal/2`
  typespec.

## Notes

- **No new dependency** and **no migration**: `agents.status` is stored as a `:string`, so
  adding the `:holding` `Ecto.Enum` value is a code-only change; the holding terminal is a new
  *value* on the existing `Done.reason` union, not a new event variant or field.
- **Single contract edit, by design.** The only canonical-contract change is one new
  `Done.reason` value (`:held_pending_input`). This deliberately models holding as a *kind of
  terminal stop* (which is exactly what `reason` discriminates) rather than a new `Event` variant
  or a cross-cutting boolean — keeping the closed sum type and its exhaustive matches intact
  (BUILD_PROMPT §4).
- **Detection is layered for robustness.** The explicit `:holding <reason>` signal (taught via
  the worker system prompt) is the reliable, forward-looking path and mirrors the proven
  `:handover` protocol. The conservative phrase heuristic exists only to catch the *original*
  Playwright-login incident, where the worker did not know to signal; it is kept narrow and is
  unit-tested for no false positives so normal completions are never mis-flagged as holding.
- **Resumption reuses existing plumbing.** A held worker keeps its persisted `session_id` and is
  never deleted, so the existing `command_agent` tool (Claude `--resume` / pi `--session`)
  resumes it and flips it back to `:running`. The orchestrator decides when conditions are good,
  exactly as the bug requested ("ping them again to continue").
- **Conditional-docs routing** (per `.claude/commands/conditional_docs.md`): this touches the
  harness event contract (BUILD_PROMPT §4 + typed-standard rule 6, wire-vs-domain), the session
  runtime/terminal synthesis (§6), persistence/`Ecto.Enum` (§8), and the LiveView dashboard (§9);
  the **always** row (`ai_docs/typed-elixir-standard.md`) applies throughout.
- **Runtime intelligence (Tidewave).** When verifying live, use `get_logs` to read a held
  worker's terminal frames, `project_eval` to drive a `Done{reason: :held_pending_input}` through
  the session/console without a real CLI, and `execute_sql_query`
  (`SELECT name, status FROM agents WHERE status = 'holding';`) to confirm the persisted status.
- **Known gap (out of scope, mirrors the existing `terminate/2` note in `session/server.ex`):** a
  hard `Process.exit(pid, :kill)` / brutal supervisor shutdown bypasses terminal dispatch, so a
  worker killed that way cannot be classified holding — a boot/periodic sweep would be needed to
  cover it, which is intentionally not in this surgical fix.
```
