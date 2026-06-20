# Worker report: scout-current-setup (idle)

I now have a complete picture. Here is the thorough map.

---

# RepoBuilder — Current ADW/Workflow + Prompt-Builder Map

This is a **dual-engine** system. There is an **in-Elixir WorkflowEngine** (deterministic, DB-backed, 3 catalog types) **and** a **portable Python ADW** fleet (the real `/plan → /build → /review → /fix`, plus scouts/parallel) that the Elixir app treats as "just another harness." The prompt side has a **DB-template context** (`Prompts`), a **markdown subagent-template store** (`Orchestrator.Templates`), a **self-contained spec toolkit** (`PromptStandard`), and a **hand-written orchestrator system-prompt string** (`Orchestrator.SystemPrompt`). The two new design docs (adw-primitives, adw-orchestration) are about restructuring area A; prompt-standard-spec/prompt-anatomy are the bones of area B.

---

## A) THE CURRENT ADW / WORKFLOW BUILD

### A.1 Two coexisting workflow engines

| | **In-Elixir `WorkflowEngine`** | **Portable Python ADW fleet** |
|---|---|---|
| Home | `lib/repo_builder/workflow_engine*`, `lib/repo_builder/workflows*`, `lib/repo_builder/workers/` | `adws/*.py`, `adws/adw_workflows/*.py`, `adws/adw_modules/*.py` |
| Kinds | 3 hardcoded catalog slugs (`plan_build`, `plan_build_review`, `plan_build_review_fix`) | ~25 scripts incl. full SDLC, ZTE auto-ship, scouts, build-in-parallel |
| Isolation | None — steps run in-place harness sessions | Git worktrees under `trees/<adw_id>/` with dedicated ports (9100-9114 / 9200-9214) |
| Branching | Deterministic `on_success`/`on_failure` edges in the step map | Python `branch(slug, prior)` callback (e.g. review→fix) |
| Transport | Live GenServer events + durable Oban jobs | Neutral stdout-JSON (`adw.event`-shaped), decoded by `Harness.Adw.EventSchema` |

The seam between them: `start_adw` in `tools.ex` routes on the resolved harness — `"adw"` → Python shell-out adapter; anything else → in-Elixir engine.

### A.2 The in-Elixir WorkflowEngine (area that adw-primitives likely restructures)

**Facade:** `lib/repo_builder/workflow_engine.ex` — `RepoBuilder.WorkflowEngine`
- `start_workflow/2` → creates durable `workflow_runs` row + starts a live `Runner` under `RepoBuilder.WorkflowSupervisor`. Returns `{:ok, run_id, pid}`.
- `enqueue_workflow/2` → durable Oban path (creates run + first `StepWorker` job; `inputs` persisted into `artifacts`). Returns `{:ok, run_id}`.
- `create_workflow_of_type/3` → builds + persists a `Workflow` row from a catalog slug + harness.
- `create_example_workflow/2` → back-compat alias → `plan_build_review_fix`.
- `step_agent_id/2` → `"wf-<run>-<step>"` canonical per-step agent id (shared by Runner + StepWorker).
- `record_step_state/3` → **shared transition seam** both paths call (persists `step_states` + broadcasts `Dashboard.broadcast_workflow_step/2`).
- `emit_orchestrator_resume/2` → re-engages the launching orchestrator's holding pattern on terminal state.
- `now_iso/0`.

**Runner (live state machine):** `lib/repo_builder/workflow_engine/runner.ex` — `RepoBuilder.WorkflowEngine.Runner` (`use GenServer, restart: :temporary`)
- Inner `State` typedstruct: `run, steps, current_step, artifacts, session_agent_id, text_buf`.
- `init/1` → parses steps, sets `current_step`, `{:continue, :run_step}`.
- `handle_continue(:run_step, …)` → marks step running via the shared seam, subscribes to `agent:<id>:events`, renders `step.prompt_template` over `artifacts`, checks `Budget.Guard`, starts a live `Session.Supervisor.start_session/1`.
- `handle_info({:harness_event, %Event.Done{} …})` → captures output into `artifacts[step]`, rolls cost, advances via `on_success`.
- `handle_info({:harness_event, %Event.Error{} …})` → records failed, advances via `on_failure`.
- `advance/2` → `:done`/`:abort` terminals finalize; a binary edge rebinds `current_step` and continues.
- `finalize/2` → persists terminal status + artifacts, broadcasts lane, emits orchestrator resume.
- Budget cap exceeded → step fails (isolated), follows `on_failure`; never crashes the run.

**Catalog (typed registry):** `lib/repo_builder/workflow_engine/catalog.ex` — `RepoBuilder.WorkflowEngine.Catalog`
- `types/0` → `[%TypeDef{slug, label, description}]` (the 3 listed above). **Single source of truth for "what ADWs can I run"** in the in-app path.
- `default_type/0` → `"plan_build_review_fix"`.
- `fetch/1`, `steps/2` (harness-parameterized step-map builders; **hardcoded per slug** in `def steps("plan_build", harness) do…`).
- ⚠️ Note: the 3 step lists are **manually duplicated** (the `plan_build_review_fix` clause even repeats the `review` step map twice — a real authoring wart).

**Step value:** `lib/repo_builder/workflow_engine/step.ex` — `RepoBuilder.WorkflowEngine.Step` (typedstruct)
- Fields: `name, harness, provider?, model?, prompt_template, on_success (default :done), on_failure (default :abort), inputs, outputs, status`.
- `@type status :: :pending | :running | :succeeded | :failed | :cancelled`
- `@type edge :: String.t() | :done | :abort`
- `from_map/1` → builds from JSONB map; `parse_edge/2`.

**Persistence (source of truth):** `lib/repo_builder/workflows.ex` — `RepoBuilder.Workflows` (the only `Repo` caller for these tables)
- `Workflow` schema (`workflows.ex`): `name, type (catalog slug), state (:draft|:active|:archived), steps ([map()] JSONB), metadata`. `changeset/2`.
- `WorkflowRun` schema (`workflow_run.ex`): `workflow_id, orchestrator_id, status (:queued|:running|:succeeded|:failed|:cancelled), current_step, artifacts (map), step_states (map), total_cost_usd (Decimal, nullable), hidden (bool)`.
- Context fns: `list_workflows/0, get_workflow/1, create_workflow/1, update_workflow/2, delete_workflow/1, get_run/1, create_run/1, update_run/2, add_run_cost/2` (preserves NULL-vs-0), `run_cost/1, list_unfinished_runs/0, list_recent_runs/2, hide_finished_runs/0, release_hidden_runs/0, put_step_state/3, run_progress/1`.
- `run_progress/1` → typed per-step view `%{total, completed, current, steps: [%{name, status, cost_usd, started_at, finished_at}]}`.

**Durable execution:** `lib/repo_builder/workers/`
- `step_worker.ex` — `RepoBuilder.Workers.StepWorker` (`use Oban.Worker, queue: :workflows, max_attempts: 3`, unique on `{workflow_run_id, step_name}` across all incomplete states). `enqueue/2`, `perform/1`, `execute/2`, `drive/3`, `run_session/3` (awaits terminal event with `@step_timeout_ms 310_000`), `handle_result/3`, `advance/4` (chains by inserting the next job). Mirrors the Runner's per-step observability via the shared `WorkflowEngine.record_step_state/3` seam.
- `workflow_resume.ex` — `RepoBuilder.Workers.WorkflowResume` (Oban, `max_attempts: 1`). `reconcile/0` re-enqueues `current_step` for every unfinished run (idempotent via the unique key). "M5" crash-resume.
- `cron_trigger.ex` — `RepoBuilder.Workers.CronTrigger`. `trigger/1` durably enqueues a named workflow.

**Supervision:** `lib/repo_builder/application.ex`
- `RepoBuilder.WorkflowSupervisor` — `DynamicSupervisor` (one `:temporary` Runner per running ADW).
- Started after PubSub/Repo, alongside `SessionSupervisor`, `OrchestratorSupervisor`, `OrchestratorQueueSupervisor`, `ExplainSupervisor`, `OrphanReaper`.

### A.3 The portable Python ADW fleet (the "real" workflows)

**Layout** (`adws/VERSION` = `1.7.0`):
- `adws/adw_workflows/adw_*.py` — **5 thin scripts** the Elixir `adw` harness launches (these are what `Definitions.Adw` discovers as the orchestrator-facing ADWs):
  - `adw_plan_build.py`, `adw_plan_build_review.py`, `adw_plan_build_review_fix.py` (with a `branch()` fn for review→fix), `adw_plan_w_scouts_build_review.py`, `adw_build_in_parallel.py`.
  - Each is ~20-30 lines: defines `STEPS = [Step("slug", "/command"), …]` and calls `main(STEPS [, branch])`.
- `adws/adw_*.py` (top-level) — ~25 heavier `*_iso` workflows (the legacy GitHub-issue-driven SDLC: `adw_sdlc_iso.py`, `adw_plan_build_test_review_iso.py`, `adw_sdlc_zte_iso.py`, `adw_ship_iso.py`, etc.) + 8 `*_local_iso` (GitHub-optional, run-record-driven) variants.
- `adws/adw_modules/` — `adw_runner.py`, `adw_emit.py`, `agent.py`, `state.py`, `worktree_ops.py`, `workflow_ops.py`, `git_ops.py`, `github.py`, `harness.py`, `local_ops.py`, `observability.py`, `data_types.py`, `r2_uploader.py`.
- `adws/adw_new.py` — **scaffold generator**: `uv run adw_new.py <name> --steps plan,build,review` emits a new `adw_<name>_iso.py`. `VALID_STEPS = [plan, patch, build, test, review, document, ship]`.
- `adws/adw_slash_command.py` — one-shot single-slash-command runner (no worktree, no state). `normalize_command/1`, `compose_prompt/2`, `build_result/...`, `execute/1`, `main/1`.

**The portable runner core:** `adws/adw_modules/adw_runner.py`
- `@dataclass Step(slug, command)` — slug + a slash command string.
- `main(steps, branch=None)` / async `run(steps, args, branch)` — drives `STEPS` through the **Claude Agent SDK** (`claude_agent_sdk.query`), emitting the neutral contract via `adw_emit.Emitter`.
- `render(command, prompt, prior)` — threads prior step output (`/build` gets the plan appended; `/fix` gets the review).
- `missing_commands(steps, working_dir)` — **pre-flight**: every step's `/cmd` must exist as `<working_dir>/.claude/commands/<name>.md`, else fail loud (neutral `error` event). This is the cross-repo hook: slash commands resolve from the **target** repo.
- `has_non_execution_marker/1` — treats "isn't available in this environment"/"unknown command"/"command not found" in agent output as a step failure (so a non-dispatched command never reports false `succeeded`).
- `branch(slug, prior)` callback lets a workflow append steps dynamically (e.g. review→fix) — **branching lives in Python, not in the Elixir engine**.

**Scouts / parallel fan-out** — **implemented entirely in Python**, zero Elixir change:
- `adw_plan_w_scouts_build_review.py`: `STEPS = [scout_architecture /scout architecture, scout_tests /scout tests, pla...[truncated]
