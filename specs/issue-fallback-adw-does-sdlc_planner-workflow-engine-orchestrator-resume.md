# Bug: WorkflowEngine-path ADWs never re-engage the orchestrator (holding-pattern gap)

## Metadata
issue_number: `fallback`
adw_id: `does`
issue_json: `not`

## Bug Description
The orchestrator holding pattern (issue-log-2618-followup) re-engages an idle
orchestrator exactly once when a dispatched **worker** returns. This works for both
worker-dispatch paths that create a durable agent row carrying an `orchestrator_id`:
`command_agent`, and the real ADW shell-out (`start_adw` → `start_adw_via_adapter`).

It does **not** work when the orchestrator launches an ADW through the in-app
**WorkflowEngine fallback** (`start_adw` → `start_adw_via_engine`, the
Fake-harness/deterministic path). That path runs the ADW as a `workflow_runs` row + a
`WorkflowEngine.Runner` GenServer and **never creates an agent row**, so the
worker-terminal wakeup source (`Session.Server.maybe_emit_worker_terminal/2`, which keys
off `agent_db_id` → the agent row's `orchestrator_id`) never fires. When such an ADW
reaches a terminal `:succeeded`/`:failed` state, the orchestrator's `Queue` is never
signalled.

- **Expected:** when an orchestrator-launched WorkflowEngine ADW finishes, the
  orchestrator is re-engaged once (same holding-pattern contract) to review the result
  and decide next steps — event-driven, coalesced, no polling.
- **Actual:** the WorkflowEngine run finishes silently; the orchestrator (if otherwise
  idle) hangs and never follows up, exactly like the original log-2618 hang — but for the
  engine path instead of the worker path.

## Problem Statement
A WorkflowEngine ADW run has no link back to the orchestrator that started it, and its
terminal transition emits no worker-terminal signal on the
`orchestrator:<id>:workers` topic the `Queue` subscribes to. Two things are missing: (1)
the run does not record which orchestrator (if any) launched it; (2) the run's terminal
site never broadcasts a holding-pattern wakeup.

## Solution Statement
Surgical, mirrors the existing worker-terminal seam and the established "shared transition
seam" pattern (`WorkflowEngine.record_step_state/3`):

1. **Link the run to its launching orchestrator.** Add a nullable
   `orchestrator_id` column to `workflow_runs` (FK → `orchestrators`, `on_delete:
   :nilify_all`), expose it on the `WorkflowRun` schema/changeset, thread it from
   `start_adw_via_engine` through `WorkflowEngine.start_workflow/2` into
   `Workflows.create_run/1`. `nil` = "not orchestrator-launched" (every other caller is
   unchanged and stays `nil`).

2. **Emit the holding-pattern wakeup at the run's terminal site.** Add one shared seam
   `WorkflowEngine.emit_orchestrator_resume/2` that, when `run.orchestrator_id` is set,
   calls `Dashboard.broadcast_worker_terminal/2` with
   `%{worker_id: run.id, name: <label>, ok?: status == :succeeded}` — the exact
   `%{worker_id, name, ok?}` shape the `Queue`'s `maybe_auto_resume/2`/`auto_resume_prompt/1`
   already consume. Call it from the live `Runner.finalize/1` (the path the orchestrator
   actually uses) and, for parity with every other Runner/StepWorker mirror in this
   engine, from the durable `StepWorker` terminal helpers too (a no-op when
   `orchestrator_id` is `nil`).

No `Queue` change is needed — it already re-engages on `{:worker_terminal, info}`. This
closes the engine-path amnesia while preserving the anti-spam/coalescing guarantees of
the existing holding pattern.

## Steps to Reproduce
1. Use an orchestrator on a harness whose `start_adw` resolves to the **engine** path
   (i.e. NOT the ADW shell-out adapter harness) — e.g. the Fake harness in tests, or via
   `SessionCase`/console with auto-resume enabled.
2. Have the orchestrator call `start_adw` with a valid `workflow_type` so
   `start_adw_via_engine/3` runs (`{:ok, %{"status" => "started", "run_id" => …}}`).
3. Let the WorkflowEngine run reach a terminal `:succeeded`/`:failed`.
4. Observe: nothing is broadcast on `orchestrator:<id>:workers`; the idle orchestrator is
   never auto-resumed (it hangs). Compare with `start_adw_via_adapter` / `command_agent`,
   which do re-engage.

Tidewave runtime reproduction (before the fix): with the app running, use `project_eval`
to subscribe to `RepoBuilder.Dashboard.subscribe_orchestrator_workers(orch_id)`, start an
engine workflow via `WorkflowEngine.start_workflow/2` (Fake harness), drive it to
terminal, and confirm **no** `{:worker_terminal, _}` arrives. Use `execute_sql_query` to
confirm `workflow_runs` has no `orchestrator_id` column (pre-migration) / a `NULL`
`orchestrator_id` for the run.

## Root Cause Analysis
The holding-pattern wakeup is sourced exclusively from a **session tied to an agent row**:
`Session.Server.maybe_emit_worker_terminal/2`
(`lib/repo_builder/session/server.ex:506-536`) only fires when `state.agent_db_id` is set
and `Agents.get_agent/1` returns a row with an `orchestrator_id`. The WorkflowEngine
fallback (`RepoBuilder.Orchestrator.Tools.start_adw_via_engine/3`,
`lib/repo_builder/orchestrator/tools.ex:394-408`) models the ADW as a `workflow_runs` row
driven by `WorkflowEngine.Runner`; its step sessions start with `workflow_run_id:` and
**no `agent_db_id`** (`runner.ex:105-111`), and there is no agent row at all. So the
wakeup source structurally cannot fire for this path.

Furthermore, the run itself has no record of which orchestrator launched it
(`workflow_runs` has no `orchestrator_id`; `Workflows.add_run_cost/2` even hard-codes
`orchestrator_id: nil` in its telemetry, `workflows.ex:74`), and the Runner's terminal
transition `finalize/1` (`runner.ex:179-184`) only broadcasts the swimlane lane +
per-workflow update — never the `orchestrator:<id>:workers` holding-pattern signal. The
result is engine-path amnesia: the orchestrator promises autonomous follow-up but the
engine path silently drops the terminal event. This was explicitly called out as a
known gap in the log-2618 follow-up spec's Notes ("Verified non-issues") and is the bug
fixed here.

## Relevant Files
Use these files to fix the bug:

- `lib/repo_builder/orchestrator/tools.ex` — `start_adw/2` (`379-389`) and
  `start_adw_via_engine/3` (`394-408`). Thread `orchestrator_id` into the engine path so
  the created run records its launcher. **Change here.**
- `lib/repo_builder/workflow_engine.ex` — `start_workflow/2` (`17-38`) creates the run;
  accept `opts[:orchestrator_id]` and pass it to `Workflows.create_run/1`. Add the shared
  `emit_orchestrator_resume/2` seam next to `record_step_state/3`. **Change here.**
- `lib/repo_builder/workflow_engine/runner.ex` — `finalize/1` (`179-184`) is the live
  terminal site; call the new seam there with the run's terminal `ok?`. **Change here.**
- `lib/repo_builder/workers/step_worker.ex` — `finalize_success`/`finalize_failure`
  (`~154-161, 177-178`) are the durable terminal sites; call the same seam for parity
  (no-op when `orchestrator_id` is `nil`). **Change here (parity).**
- `lib/repo_builder/workflows.ex` — `create_run/1` (`42-47`) delegates to the changeset;
  add `:orchestrator_id` to the cast list. **Change here.**
- `lib/repo_builder/workflows/workflow_run.ex` — schema/`t()`/`changeset/2`; add the
  `orchestrator_id` field, type, cast, and FK constraint. **Change here.**
- `lib/repo_builder/dashboard.ex` — `broadcast_worker_terminal/2` (`187-198`) and
  `subscribe_orchestrator_workers/1` (`175-177`): the existing, unchanged seam the new
  emit reuses. No change; referenced so the emit shape stays exact (`%{worker_id, name, ok?}`).
- `lib/repo_builder/orchestrator/queue.ex` — `maybe_auto_resume/2` /
  `maybe_consume_pending_resume/1` / `auto_resume_prompt/1`: already consume
  `{:worker_terminal, info}`. **No change** — documented so the fix isn't duplicated.
- `config/test.exs` — ships `auto_resume_on_worker_return: false` (deterministic suite);
  new engine-resume tests force the flag per-scope, like the existing queue tests. No
  change to the file.
- `BUILD_PROMPT.md` §7 (workflow engine), §8 (schemas/migrations) — authoritative spec
  for the engine + persistence conventions.
- `ai_docs/typed-elixir-standard.md` — the enforced typed standard (always); rule 10 for
  the cost/Decimal boundary, rule 6 wire-vs-domain.
- `ai_docs/adw-orchestration.md` — the ADW/workflow engine + durable-trigger reference
  (Runner/StepWorker parity).
- `AGENTS.md` — Phoenix v1.8 + LiveView guidelines for the integration test.

### New Files
- `test/repo_builder/workflow_engine/orchestrator_resume_test.exs` — unit test proving an
  orchestrator-launched engine run broadcasts `{:worker_terminal, %{ok?: …}}` on terminal
  (fails before the fix), and that a run with `orchestrator_id: nil` broadcasts nothing.
- `priv/repo/migrations/<timestamp>_add_orchestrator_id_to_workflow_runs.exs` — add the
  nullable FK column + index.
- `test/repo_builder_web/live/test_orchestrator_adw_resume_test.exs` — `Phoenix.LiveViewTest`
  proving the console re-engages (queue becomes busy again) after an orchestrator-launched
  engine ADW finishes, rather than staying idle.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Reproduce and confirm the root cause via Tidewave (runtime intelligence)
- With the app running (`scripts/pg.sh start` first if needed), use Tidewave `project_eval`
  to: generate an orchestrator id, `Dashboard.subscribe_orchestrator_workers/1`, build a
  Fake-harness workflow (`WorkflowEngine.create_workflow_of_type/3`), `start_workflow/2`,
  drive it to terminal, and confirm **no** `{:worker_terminal, _}` is delivered (the
  failing baseline).
- Use `execute_sql_query` to confirm `workflow_runs` has no `orchestrator_id` column yet.
- Note the reproduction in the PR/commit description.

### 2. Add the `orchestrator_id` column to `workflow_runs` (migration)
- Create `priv/repo/migrations/<timestamp>_add_orchestrator_id_to_workflow_runs.exs`:
  `alter table(:workflow_runs)` → `add :orchestrator_id, references(:orchestrators, type:
  :binary_id, on_delete: :nilify_all)`; then `create index(:workflow_runs,
  [:orchestrator_id])`. Nullable (most runs are not orchestrator-launched). Follow the
  binary_id FK convention used by `20260616143725_add_orchestrator_id_to_agent_logs.exs`.

### 3. Expose `orchestrator_id` on the `WorkflowRun` schema
- In `lib/repo_builder/workflows/workflow_run.ex`: add `field :orchestrator_id,
  :binary_id`, add `orchestrator_id: Ecto.UUID.t() | nil` to `@type t`, add
  `:orchestrator_id` to the `cast/3` list, and add
  `foreign_key_constraint(:orchestrator_id)`. Keep `validate_required` unchanged
  (`orchestrator_id` is optional).

### 4. Persist it through the context + facade
- `lib/repo_builder/workflows.ex`: no signature change needed — `create_run/1` already
  passes params through the changeset; confirm `:orchestrator_id` flows. (Leave the
  hard-coded `orchestrator_id: nil` in `add_run_cost/2`'s telemetry as-is — out of scope;
  optionally pass `run.orchestrator_id` there if trivial, but do not expand scope.)
- `lib/repo_builder/workflow_engine.ex`: in `start_workflow/2`, read
  `opts[:orchestrator_id]` and include it in the `Workflows.create_run/1` params. Keep the
  `@spec` precise (`keyword()` already covers it). Do not change `enqueue_workflow/2`
  (orchestrator does not use the durable trigger; the column stays `nil` there).

### 5. Add the shared terminal-resume seam
- In `lib/repo_builder/workflow_engine.ex`, add
  `@spec emit_orchestrator_resume(WorkflowRun.t(), boolean()) :: :ok` /
  `def emit_orchestrator_resume(run, ok?)`:
  - When `run.orchestrator_id` is `nil` → `:ok` (no-op).
  - Otherwise build a friendly label (e.g. fetch `Workflows.get_workflow(run.workflow_id)`
    and use its `type`/`name`, falling back to `"workflow"`) and call
    `Dashboard.broadcast_worker_terminal(run.orchestrator_id, %{worker_id: run.id, name:
    label, ok?: ok?})`. Wrap defensively so a DB blip never breaks the terminal path
    (mirror the quiet `rescue/catch` style used by `maybe_emit_worker_terminal/2`).
- Keep the info shape EXACTLY `%{worker_id, name, ok?}` (what `Queue` consumes).

### 6. Emit at the live Runner terminal
- In `lib/repo_builder/workflow_engine/runner.ex` `finalize/1`: after persisting the
  terminal status and broadcasting the lane, call
  `WorkflowEngine.emit_orchestrator_resume(run, status == :succeeded)`. The `run` returned
  by `Workflows.update_run/2` already carries `orchestrator_id`. Preserve the existing
  `@spec` and return shape.

### 7. Emit at the durable StepWorker terminal (parity)
- In `lib/repo_builder/workers/step_worker.ex`, in the success and failure finalizers
  (`finalize_success`/`finalize_failure` and the abort branch), call
  `WorkflowEngine.emit_orchestrator_resume(run, <succeeded?>)` after the lane broadcast.
  This is a no-op for the (current) non-orchestrator durable runs but keeps the
  Runner/StepWorker mirror intact and forward-safe.

### 8. Add the engine-resume unit test (fails before, passes after)
- Create `test/repo_builder/workflow_engine/orchestrator_resume_test.exs` (use
  `RepoBuilder.SessionCase`, `async: false` — the Runner starts a Fake session):
  1. **Orchestrator-launched run re-engages:** generate `orchestrator_id`,
     `Dashboard.subscribe_orchestrator_workers(orchestrator_id)`, create a Fake-harness
     workflow, `WorkflowEngine.start_workflow(workflow, orchestrator_id: orchestrator_id,
     inputs: %{"input" => "x"})`, then `assert_receive {:worker_terminal, %{worker_id:
     ^run_id, ok?: true}}`.
  2. **Non-orchestrator run is silent:** same but `start_workflow/2` with no
     `orchestrator_id`; `refute_receive {:worker_terminal, _}`.
  3. (Optional) **Failure maps to `ok?: false`:** drive a failing step (Fake error path)
     and assert `ok?: false`.

### 9. Add the LiveView re-engagement integration test
- Create `test/repo_builder_web/live/test_orchestrator_adw_resume_test.exs`
  (`RepoBuilderWeb.ConnCase`, `async: false`), modeled on
  `test_orchestrator_holding_pattern_test.exs`:
  - In `setup`, force `auto_resume_on_worker_return: true` (app-env, restored on exit),
    `Orchestrators.get_or_create_default()`, and pre-start a controllable `Queue` for the
    orchestrator (pluggable `:starter` that records started prompts) so the auto-resume
    turn is deterministic.
  - `live(conn, ~p"/")`, then start a Fake-harness engine workflow tied to the
    orchestrator (`WorkflowEngine.start_workflow(workflow, orchestrator_id: orch.id, …)`)
    and let it run to terminal so the real seam broadcasts `{:worker_terminal, …}`.
  - Assert the controllable starter receives an `:auto_resume` turn (prompt mentions
    "Review") AND the console renders the orchestrator busy again
    (`has_element?(view, "#orchestrator-queue", "Busy")`) rather than staying idle.
  - Optionally capture a screenshot of `http://localhost:4000` via Tidewave Web vision
    mode (or Playwright MCP) as visual proof of re-engagement.

### 10. Run the full validation suite
- Run every command in `Validation Commands`; all green, zero regressions. Re-run the
  Tidewave reproduction from Step 1 to confirm `{:worker_terminal, _}` now arrives.

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- `mix ecto.migrate` — apply the new `workflow_runs.orchestrator_id` migration (and
  `mix ecto.rollback --step 1 && mix ecto.migrate` once to prove the migration is
  reversible/round-trips cleanly).
- `mix test test/repo_builder/workflow_engine/orchestrator_resume_test.exs` — the engine
  re-engagement unit test (broadcast case fails before the fix, passes after).
- `mix test test/repo_builder_web/live/test_orchestrator_adw_resume_test.exs` — the
  LiveView re-engagement proof.
- `mix test test/repo_builder/workflow_engine/ test/repo_builder/orchestrator/ test/repo_builder/session/`
  — engine, orchestrator (queue/holding pattern/tools), and session suites stay green.
- `mix compile --warnings-as-errors` — clean compile; gradual set-theoretic type checker
  and `warnings_as_errors` pass.
- `mix test --warnings-as-errors` — full ExUnit suite, zero failures.
- `mix format --check-formatted` — formatting.
- `mix credo --strict` — lint, including the every-public-function-has-`@spec` gate.
- `mix dialyzer` — no new contract warnings; no stale ignore filters.

## Notes
- **No new dependencies.** The fix is one nullable FK column + a one-arg threading + a
  shared terminal emit seam reusing the existing `Dashboard.broadcast_worker_terminal/2`.
- **Why mirror the worker path instead of faking an agent row.** The wakeup contract is
  already `{:worker_terminal, %{worker_id, name, ok?}}` on `orchestrator:<id>:workers`.
  Emitting that directly from the engine's terminal site (keyed by the run's recorded
  `orchestrator_id`) is the smallest change that honours the holding-pattern promise for
  the engine path, without inventing a synthetic agent row or touching the `Queue`.
- **Loop-safety / anti-spam preserved.** The `Queue` already coalesces bursts to one
  resume and lets operator messages supersede it; emitting once per engine-run terminal
  inherits all of that. An auto-resume turn that starts no new engine run cannot
  retrigger itself.
- **Out of scope (documented):** the durable Oban path is not used by the orchestrator
  today, so Step 7 is parity insurance, not a functional requirement of this bug. The
  hard-coded `orchestrator_id: nil` in `Workflows.add_run_cost/2` telemetry is left
  unchanged (cost-attribution concern, separate issue).
- **Tidewave** is the primary reproduction/verification tool here (`project_eval` to drive
  `WorkflowEngine.start_workflow/2` and watch the workers topic; `execute_sql_query` to
  confirm `workflow_runs.orchestrator_id`; `get_logs` to confirm no errors on the terminal
  path).
