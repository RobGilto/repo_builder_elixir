# Bug: Planning-Mode Wizard launches a run that never touches the target repo

## Metadata
issue_number: `just`
adw_id: `did`
issue_json: `a`

## Bug Description
An operator registered a target repo (`/data/1.Projects/Firebird/`) and ran the
Planning-Mode Wizard (`/plan`) end-to-end. The wizard reported a launched run and
persisted a Plan artifact, but **no files materialized in the target repo** — nothing was
created, modified, or committed under `/data/1.Projects/Firebird/`.

- **Expected:** launching a plan for a project runs the workflow's steps *inside that
  project's working directory*, using a real harness, so the planned work (plan → build →
  …) actually writes/changes files in the target repo.
- **Actual:** the run executes in an empty managed scratch workspace (e.g.
  `priv/workspaces/<token>/`, which is empty afterward) using the no-op `fake` harness, so
  the target repo is never touched. The DB shows a "launched" run + a persisted Plan, but
  there is zero on-disk effect on the target repo — a silent no-op.

## Problem Statement
The wizard's launch path scopes the run to the project **only in the database**
(`workflow_runs.project_id`) and never threads the project's `root_path` as the session
working directory (`cwd`) nor its `isolation_mode`. The in-app catalog `Runner` then
spawns every step session with no `cwd`, so work lands in an ephemeral scratch workspace
instead of the target repo. The launch also defaults to the `fake` harness (a
demo/test adapter that emits canned events and performs no file I/O), guaranteeing the run
does nothing real even if a `cwd` were set.

## Solution Statement
Thread the target project's working directory and isolation mode through the entire launch
path — `PlanningLive` → `WorkflowEngine.start_workflow/2` → `Runner` →
`Session.Supervisor.start_session/1` — so each step session runs *in the target repo*
(`cwd: project.root_path`), honouring `isolation_mode` (worktree vs direct). Stop
launching planned runs on the no-op `fake` harness: resolve a real launch harness from the
project's `default_harness` and refuse to "launch" silently when no real harness is
available (surface an actionable error instead of a no-op). Keep the change additive and
back-compatible: every existing `start_workflow/2` caller that passes no `:cwd` keeps
today's managed-scratch behaviour.

## Steps to Reproduce
1. Register a target repo at `/projects` (e.g. `/data/1.Projects/Firebird/`).
2. Go to `/plan`, pick that project, state a goal, choose a workflow type, and launch.
3. Observe the wizard reports a launched run and redirects to `/plans/:id`.
4. `ls -la /data/1.Projects/Firebird/` — unchanged; nothing was created.
5. Inspect the run's scratch workspace under `priv/workspaces/<token>/` — empty.

## Root Cause Analysis
Three compounding defects in the launch path created by the Planning-Mode Wizard (Phase 6):

1. **`Runner` never sets the session `cwd`** — `lib/repo_builder/workflow_engine/runner.ex`
   `start_step_session/5` calls `Session.Supervisor.start_session(agent_id:, harness:,
   prompt:, workflow_run_id:)` with **no `cwd`**. `Session.Server.resolve_workspace/3`
   therefore falls to the managed per-session scratch workspace (`managed? == true`), so
   the step never runs in the target repo. This is the primary cause of "nothing
   materialized".
2. **`WorkflowEngine.start_workflow/2` doesn't forward a working directory** — it reads
   only `:orchestrator_id`, `:project_id`, `:inputs` from opts and passes nothing about
   *where* to run; the `Runner` has no `cwd`/`isolation_mode` to thread.
3. **The wizard launches on the `fake` harness** —
   `lib/repo_builder_web/live/planning_live.ex` `start_run/3` builds the workflow with
   `preview.harness`, which defaults (via `Planner.resolve/1`) to `project.default_harness
   || "fake"`. The `fake` adapter (`config :repo_builder, :harnesses`) emits canned events
   and writes no files, so the run is a no-op regardless of `cwd`.

Net effect: `workflow_runs.project_id` is set (DB scoping works), but the actual execution
has no path to the target repo and no real harness, so the run silently produces nothing.

## Relevant Files
Use these files to fix the bug:

- `lib/repo_builder_web/live/planning_live.ex` — the wizard's `start_run/3`; must pass
  `cwd: project.root_path`, `isolation_mode: project.isolation_mode`, and a *real* launch
  harness into `start_workflow/2`, and must refuse to launch on a no-op harness.
- `lib/repo_builder/workflow_engine.ex` — `start_workflow/2`; must accept and forward
  `:cwd` and `:isolation_mode` opts into the `Runner` child spec (additive; nil ⇒ unchanged).
- `lib/repo_builder/workflow_engine/runner.ex` — `init/1` (carry `cwd`/`isolation_mode` in
  `State`) and `start_step_session/5` (pass `cwd:`, `isolation_mode:`, `run_id:` to
  `Session.Supervisor.start_session/1`); record the worktree on the run when isolated.
- `lib/repo_builder/session/server.ex` — `resolve_workspace/3` + `maybe_worktree/4`
  already honour `opts[:cwd]`/`opts[:isolation_mode]`/`opts[:run_id]` (Phase 4); no change
  expected, but confirm the worktree path records onto the run via `Workflows.record_worktree/2`.
- `lib/repo_builder/workflows.ex` — `record_worktree/2` (reuse to persist the worktree
  path/branch for the UI handoff when `isolation_mode == :worktree`).
- `lib/repo_builder/plans/planner.ex` — `resolve/1` default harness; align the preview's
  harness with the real launch harness so the preview does not advertise `fake`.
- `config/config.exs` — the `:harnesses` registry; confirm which harnesses are real/
  autonomous (`Harness.Registry.autonomous?/1`) to pick a sensible non-`fake` default.
- `BUILD_PROMPT.md` §6 (session runtime / workspace resolution) and §7 (workflow engine) —
  the contract the fix must preserve.

### New Files
- `test/repo_builder/workflow_engine/runner_cwd_test.exs` — proves the `Runner` threads the
  launch `cwd`/`isolation_mode` into the step session (observable via the provisioned
  `adw/<run_id>` worktree branch on a git fixture, mirroring the Phase 4
  `session/worktree_session_test.exs` approach).
- `test/repo_builder_web/live/test_planning_wizard_target_repo_test.exs` — a
  `Phoenix.LiveViewTest` integration test: walking the wizard launches a run whose step
  session runs in the project's `root_path` (and on a real harness, not `fake`), and that a
  no-real-harness project is refused with an actionable error rather than a silent no-op.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Forward a working directory through `WorkflowEngine.start_workflow/2`
- Read `:cwd` and `:isolation_mode` from `opts` in `start_workflow/2` and pass them into the
  `Runner` child spec (`{Runner, workflow:, run:, inputs:, cwd:, isolation_mode:}`).
- Keep them optional: omitted ⇒ `nil` ⇒ today's managed-scratch behaviour. Update the
  `@spec` and the function's `@doc` to mention the new opts. Do NOT change `enqueue_workflow/2`
  (the durable Oban path) in this fix — keep the change surgical to the live `Runner` path.

### 2. Thread `cwd`/`isolation_mode` into the `Runner` and onto the session
- Add `cwd` and `isolation_mode` fields to `Runner.State` (both `enforce: false`).
- In `init/1`, read them from `opts` and store them in state.
- In `start_step_session/5`, pass `cwd: state.cwd`, `isolation_mode: state.isolation_mode`,
  and `run_id: run.id` to `Session.Supervisor.start_session/1` (the session runtime already
  honours these from Phase 4). When `cwd` is `nil`, pass nothing new (unchanged).
- When `isolation_mode == :worktree`, after the worktree-backed session starts, persist the
  worktree path/branch onto the run via `Workflows.record_worktree/2` for the UI handoff
  (guard for the non-git fallthrough where no worktree is provisioned).

### 3. Make the wizard launch in the target repo on a real harness
- In `PlanningLive.start_run/3`, pass `cwd: project.root_path` and
  `isolation_mode: project.isolation_mode` to `WorkflowEngine.start_workflow/2`.
- Resolve the launch harness: prefer `project.default_harness`; if it is blank or `"fake"`,
  do NOT silently launch — return an actionable `{:error, :no_real_harness}` that the
  `handle_event("launch", …)` renders as a flash/error ("This project has no real harness
  configured — set a default harness on the project before launching"). Reserve `fake` for
  tests/demos only.
- Ensure the workflow is built with the resolved real harness
  (`WorkflowEngine.create_workflow_of_type(name, type, harness)`), and that
  `Planner.resolve/1`'s preview harness matches it (so the preview never advertises `fake`
  while the launch uses something else).

### 4. Align the planner preview harness
- In `Plans.Planner.resolve/1`, change the harness default so the preview reflects the same
  real launch harness resolution (project default; never silently `fake` for a real launch
  preview). Keep `fake` available only when explicitly passed (tests).

### 5. Add the Runner cwd/isolation regression test
- Create `test/repo_builder/workflow_engine/runner_cwd_test.exs`: build a throwaway git
  fixture repo (as in `session/worktree_session_test.exs`), create a workflow of a catalog
  type on the `fake` harness, and `start_workflow(workflow, cwd: repo, isolation_mode:
  :worktree, …)`. Assert the step session provisioned the `adw/<run_id>` branch in the
  fixture repo (observable proof the `cwd`/`isolation_mode` reached the session), and that
  with `cwd: nil` no worktree/branch is created (back-compat).

### 6. Add the wizard integration test
- Create `test/repo_builder_web/live/test_planning_wizard_target_repo_test.exs`
  (`Phoenix.LiveViewTest`): register a fixture project whose `root_path` is a git fixture
  and whose `default_harness` is a real (test-registered) harness; walk the wizard to launch
  and assert the run is created scoped to the project AND its step session ran in the
  project's `root_path` (observe the worktree branch when isolation is `:worktree`, else
  assert `managed_workspace? == false`/cwd via the run record). Add a second case: a project
  with no real harness (or `fake`) is refused at launch with the actionable error and NO
  run is created.

### 7. Run the validation commands
- Execute every command in `Validation Commands` and confirm zero failures and zero new
  warnings.

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- `mix test test/repo_builder/workflow_engine/runner_cwd_test.exs` - The `Runner` threads
  `cwd`/`isolation_mode` to the step session (worktree branch observed); `nil` cwd is
  unchanged.
- `mix test test/repo_builder_web/live/test_planning_wizard_target_repo_test.exs` - The
  wizard launches a run that executes in the target repo on a real harness; a no-real-harness
  project is refused with an actionable error and no run.
- `mix test test/repo_builder/workflow_engine/ test/repo_builder/session/ test/repo_builder_web/live/planning_live_test.exs` -
  No regression in the engine, session, or wizard suites.
- `mix compile --warnings-as-errors` - Compile clean under the set-theoretic checker.
- `mix test --warnings-as-errors` - Full ExUnit suite green.
- `mix format --check-formatted` - Formatting clean.
- `mix credo --strict` - Lint + `@spec` gate clean.
- `mix dialyzer` - No new contract warnings; do not touch existing ignore filters.

## Notes
- **Why not the ADW shell-out path?** For *real* substantive cross-repo work the platform
  also offers the portable Python ADW (`harness: "adw"` + `working_dir`, via the
  orchestrator's `start_adw`). The wizard intentionally launches the in-app catalog
  `WorkflowEngine`; this fix makes that path operate on the target repo correctly. Routing
  the wizard through the `adw` harness is a larger follow-up (out of scope for this bug) —
  but note that once `cwd` is threaded, selecting the `adw` harness in the wizard will also
  resolve `/plan`→`/build` against the target repo's `.claude/commands` (the Phase 3
  resolver), which is the path that produces the richest real work.
- **Prompt fidelity (follow-up, not this fix):** the catalog steps render placeholder
  prompts (`"Plan the work for: {{input}}"`), not the stack-correct command bodies the
  wizard previews via `Commands.Resolver`. After this fix the run will execute in the target
  repo on a real harness; feeding the *resolved* step bodies as the step prompts is a
  separate enhancement (track it; do not expand this surgical fix).
- The session runtime already honours `cwd`/`isolation_mode`/`run_id` (Phase 4,
  `session/server.ex` `maybe_worktree/4`) and `SlashExpander` already resolves commands for
  the project mapped to that cwd — so the only missing wiring is between the catalog
  `Runner`/`start_workflow` and the session spawn, plus the wizard's harness default.
- Use Tidewave when reproducing: `get_logs` to read the step session's terminal events,
  `execute_sql_query` to confirm `workflow_runs.project_id`/`worktree_path` for the launched
  run, and `project_eval` to start a workflow with/without `:cwd` and observe the resolved
  session workspace.
