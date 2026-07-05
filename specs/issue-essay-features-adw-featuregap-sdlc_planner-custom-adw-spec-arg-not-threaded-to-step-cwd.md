# Bug: ADW Builder does not thread the typed `spec` argument into the step session's cwd, so the agent reads the wrong spec

## Metadata
issue_number: `essay-features`
adw_id: `featuregap`
issue_json: `i think the ADW custom does not pickup the spec argument when I supplied it in the ADW spec field. I was working in the writer-app and supplied "specs/issue-essay-features-adw-featuregap-sdlc_planner-essay-app-feature-parity.html" but it seems to be looking at the wrong spec`

## Bug Description

When an operator assembles a **custom ADW** in the ⌘K ADW Builder (`RepoBuilderWeb.ConsoleLive.AdwBuilderPanel`), types a spec path (or any spec content) into the **SPEC (optional)** textarea, and clicks **▶ Launch ADW**, the launched run does **not** execute inside the operator's active project (the writer-app). Instead, each step's session is spawned in a default **ephemeral managed scratch workspace** under `priv/workspaces/`, because `launch_adw_builder/4` (`lib/repo_builder_web/live/console_live/adw_builder_panel.ex:398-455`) calls `WorkflowEngine.start_workflow/2` with only the `inputs:` keyword and no `cwd:` / `isolation_mode:` / `project_id:`.

The visible symptom is that the agent that receives `Spec (optional): specs/issue-essay-features-adw-featuregap-sdlc_planner-essay-app-feature-parity.html` (the `{{spec}}` artifact rendered into the per-step `prompt_template`, e.g. `Catalog.default_prompt_template("plan")` → `"Plan the work for: {{input}}\n\nSpec (optional): {{spec}}"`) cannot open that file from its workspace cwd, so it falls back to "some" spec it can see — a stale plan from a previous run, a default planf3 template, or a hallucinated summary — and the user observes the run acting on the **wrong spec**.

Observed (live): the writer-app operator's `adws/.combos/<name>.json` sidecar correctly persists the typed spec, the launched `workflows` row's `steps[*].prompt_template` correctly contains the `{{spec}}` placeholder, and `workflow_runs.artifacts["spec"]` correctly holds the typed path — so the spec IS being threaded into the run record — but the step session spawned by `WorkflowEngine.Runner.run_harness_step/3` → `Session.Supervisor.start_session/1` (`lib/repo_builder/workflow_engine/runner.ex:140`) runs with `cwd: nil, isolation_mode: nil`, which `Session.Server.resolve_workspace/3` (`lib/repo_builder/session/server.ex:1418-1430`) translates to `{workspace_path(cfg, …), true}` — i.e. a brand-new managed scratch dir, not `orchestrator.working_dir` (the writer-app's `root_path`).

Expected: the agent's session cwd is the operator's project root (the writer-app, where the typed `specs/…html` path actually exists), so the agent opens the operator's spec verbatim and plans/builds against it.

## Problem Statement

`launch_adw_builder/4` (`lib/repo_builder_web/live/console_live/adw_builder_panel.ex`) launches the launched workflow's Runner with only `:inputs`, omitting the three target-repo seam options that `WorkflowEngine.start_workflow/2` (`lib/repo_builder/workflow_engine.ex:30`) already accepts and the planning-wizard path (`lib/repo_builder_web/live/planning_live.ex:264-275`) already passes:

```elixir
# planning_live.ex:264 — already correct
WorkflowEngine.start_workflow(workflow,
  project_id: project.id,
  cwd: project.root_path,
  isolation_mode: project.isolation_mode,
  inputs: %{"input" => goal}
)
```

vs. the ADW Builder:

```elixir
# adw_builder_panel.ex:440 — missing the target-repo seam
WorkflowEngine.start_workflow(wf, inputs: inputs)
```

The Runner (`lib/repo_builder/workflow_engine/runner.ex:64-89`) consumes these options into `state.cwd` and `state.isolation_mode`, then `Session.Supervisor.start_session/1` (`runner.ex:140`) threads them into `Session.Server.resolve_workspace/3`, where a `nil` cwd falls back to the per-session managed workspace. The operator's typed spec path (a project-relative `specs/…` path) does not exist in that scratch workspace, so the agent reads a different spec (or hallucinates one) and the user sees "looking at the wrong spec".

This is the same defect shape as the planning-wizard target-repo bug fixed in `lib/repo_builder_web/live/planning_live.ex:264` and the regression-test `test/repo_builder_web/live/test_planning_wizard_target_repo_test.exs`, but on the ADW Builder launch surface instead of the planning wizard's.

## Solution Statement

Surgical, single-function fix in `launch_adw_builder/4`. Thread the operator's active project's target-repo seam into `WorkflowEngine.start_workflow/2` exactly the way `planning_live.ex:start_run/4` already does:

1. **Resolve the active project** (a typed `RepoBuilder.Projects.fetch_project/1` call on `socket.assigns.active_project_id`, with a `nil` ⇒ `nil`/`:direct` fall-through so a project-less console still launches — back-compat for the existing test suites and for any operator not yet on the project switcher).
2. **Thread three opts** into `WorkflowEngine.start_workflow/2`:
   - `project_id: project.id` — scopes the persisted `workflow_runs` row (nullable per BUILD_PROMPT §8; `nil` ⇒ the platform itself, the back-compatible default).
   - `cwd: project.root_path` — the agent's session cwd, so the typed `specs/…` path resolves.
   - `isolation_mode: project.isolation_mode` — the `:direct` / `:worktree` choice the operator picked on the project, honored by `Session.Server.maybe_worktree/4` (`lib/repo_builder/session/server.ex:1437+`).
3. **Leave everything else unchanged**: the typed spec still flows through `inputs: %{"input" => initial_prompt, "spec" => spec}`, the `Catalog.default_prompt_template/1` still renders `{{spec}}` into each step's `prompt_template`, the `TitleHumanizer` still runs, and the post-launch `adw_spec: ""` / `adw_prompt: ""` reset still fires. No new files, no schema/migration changes, no event-contract changes, no new deps, no harness-adapter changes.

The fix is identical in shape to the planning-wizard fix that closed the same defect on a different launch surface — copy the pattern, do not invent a new one.

## Steps to Reproduce

1. Open `http://localhost:4000/`, open the ⌘K modal, toggle the **ADW** chip to enter ADW Builder mode.
2. In the **WORKFLOW NAME** field type any combo name (e.g. `essay-features-featuregap`).
3. In **SPEC (optional)** paste a project-relative spec path, e.g.
   `specs/issue-essay-features-adw-featuregap-sdlc_planner-essay-app-feature-parity.html`.
4. In **INITIAL PROMPT** type any feature/task description.
5. Click **+ plan** (or **+ plan_f3**) and **+ build** in the ADD STEP palette.
6. Make sure the project's working directory is set to the writer-app (the default — the global project switcher or the modal's `📁` picker).
7. Click **▶ Launch ADW**.
8. Expected: the workflow run's `workflow_runs.project_id` equals the writer-app project's id, `workflow_runs.worktree_path` is the writer-app's worktree (for `:worktree` projects) or `nil` (for `:direct`), the per-step session cwd is the writer-app, the `{{spec}}` substitution in the plan step's `prompt_template` resolves to the typed path, and the agent opens that path verbatim.
9. Observed (bug): `workflow_runs.project_id` is `nil`, the step session runs in a fresh `priv/workspaces/<session_id>/` (the default `workspace_path/3` fallback in `Session.Server.resolve_workspace/3`), the typed spec path does not exist in that scratch workspace, and the agent reads whatever spec it can find (often a stale one or a hallucinated summary) — the user observes "looking at the wrong spec".

Tidewave verification (per `AGENTS.md` and `BUILD_PROMPT.md` §1):
- `project_eval` → `RepoBuilder.Workflows.list_recent_for_project(project.id, 5)` and observe the freshly-launched run's `project_id` is `nil` (regression).
- `project_eval` → `RepoBuilder.Workflows.get_run!(run_id).artifacts` and confirm the typed spec IS persisted under `"spec"` (the artifact is correctly threaded; the bug is on the session-runtime side, not the input-artifact side).
- `execute_sql_query` → `SELECT project_id, status FROM workflow_runs ORDER BY inserted_at DESC LIMIT 1;` and observe `project_id IS NULL` on the freshly-launched run (regression).

## Root Cause Analysis

`launch_adw_builder/4` (`lib/repo_builder_web/live/console_live/adw_builder_panel.ex:398-455`) was authored in the same change as the SPEC + INITIAL PROMPT inputs (commit `9f1e1c3 feat: ADW Builder combos + custom per-step ADWs with durable observability`), with the right `inputs:` plumbing but without the corresponding target-repo plumbing. The author tested the inputs round-trip (the spec DOES land in `workflow_runs.artifacts["spec"]`) but did not extend the launch to include `cwd:` / `isolation_mode:` / `project_id:`.

The planning-wizard launch (`lib/repo_builder_web/live/planning_live.ex:264-275`) has the canonical pattern. The orchestrator tools' adapter path (`lib/repo_builder/orchestrator/tools/adw.ex:242-265`) has it too (`spawn_adw_session/5` resolves `cwd` and `isolation_mode` from `adw_target_project/2` and threads them into `Session.Supervisor.start_session/1`). The ADW Builder is the only launch surface that builds a typed `%Workflow{}` + runs it through `WorkflowEngine.start_workflow/2` and skips the target-repo seam.

The Runner consumes the seam (`lib/repo_builder/workflow_engine/runner.ex:64-89` → `cwd: Keyword.get(opts, :cwd), isolation_mode: isolation_mode`), and the Session runtime honors it (`lib/repo_builder/session/server.ex:1418-1430` → `resolve_workspace/3`: `cwd: nil` ⇒ `{workspace_path(cfg, …), true}`, `cwd: <project root_path>` ⇒ `{<project root_path>, false}`). So the whole downstream is already spec'd and tested — the ADW Builder is just the missing caller.

### Why "wrong spec" surfaces

The agent receives `Spec (optional): specs/issue-essay-features-adw-featuregap-sdlc_planner-essay-app-feature-parity.html` from the rendered `{{spec}}` artifact. In a scratch workspace, that path does not exist. The agent's natural fallback is to scan its cwd for any `specs/*.{html,md}` (`specs/issue-*.html`), and the workspace either has none (the agent works the task with no spec — "wrong spec" = no spec) or has a stale spec from a previous run (`specs/issue-…html` from a prior plan) — the user observes that the ADW "is looking at the wrong spec". The defect is not in the spec substitution (that works) but in the cwd the agent ends up in (wrong).

### Secondary symmetry break

`start_adw_via_engine/4` (`lib/repo_builder/orchestrator/tools/adw.ex:73-94`) — the engine-path fallback for the orchestrator's `start_adw` tool — has the same defect (it does NOT pass `cwd:` / `isolation_mode:` / `project_id:` to `WorkflowEngine.start_workflow/2`). Out of scope for this bug: the user's report is on the ADW Builder surface and the orchestrator adapter path (`start_adw_via_adapter/4`) already has the target-repo seam. Fixing the engine-path too is a follow-up; the ADW Builder is the highest-traffic and the one the user is hitting.

## Relevant Files

Use these files to fix the bug:

- `lib/repo_builder_web/live/console_live/adw_builder_panel.ex` — `launch_adw_builder/4` at lines 398-455. The fix lives in this single function: read `socket.assigns.active_project_id`, look up the project via `Projects.fetch_project/1`, and add three keyword arguments to `WorkflowEngine.start_workflow/2` (`project_id:`, `cwd:`, `isolation_mode:`). Add the `alias RepoBuilder.Projects` near the top of the module (alongside `RepoBuilder.Adw.{Combos, StepSpec}` etc.).
- `lib/repo_builder_web/live/planning_live.ex` — `start_run/4` at lines 256-275. The canonical reference for the target-repo seam pattern (`project_id: project.id, cwd: project.root_path, isolation_mode: project.isolation_mode, inputs: %{"input" => goal}`); mirror this verbatim, only changing `inputs` to keep the spec. Do NOT change this file — it is the reference.
- `lib/repo_builder/workflow_engine.ex` — `start_workflow/2` at lines 29-58. Accepts `project_id:`, `cwd:`, `isolation_mode:` in opts (already documented). Do NOT change this file — it already does the right thing.
- `lib/repo_builder/workflow_engine/runner.ex` — `init/1` at lines 62-90. Reads `opts[:cwd]` and `opts[:isolation_mode]` into `State.cwd`/`State.isolation_mode`. `run_harness_step/3` at lines 112-130 calls `Session.Supervisor.start_session/1` with `cwd: state.cwd, isolation_mode: state.isolation_mode`. Do NOT change this file — the Runner already honors the seam.
- `lib/repo_builder/session/server.ex` — `resolve_workspace/3` at lines 1418-1430 (`opts[:cwd]` ⇒ use it, `nil` ⇒ managed workspace) and `maybe_worktree/4` at lines 1437-1454 (honors `opts[:isolation_mode] == :worktree`). Do NOT change this file — the session runtime already honors the seam.
- `lib/repo_builder/projects.ex` — `fetch_project/1` at line 33 (`{:ok, Project.t()} | {:error, :not_found}`, the typed contract used by the planning wizard). Use this to resolve the active project from `socket.assigns.active_project_id`.
- `lib/repo_builder/projects/project.ex` — the `%Project{}` schema with `root_path :: String.t() | nil` and `isolation_mode :: :direct | :worktree` (closed `Ecto.Enum`). Confirms the fields the fix reads.
- `test/repo_builder_web/live/test_planning_wizard_target_repo_test.exs` — the regression test for the planning-wizard target-repo launch (lines 70-91, the `walk_to_preview` and `await_run_terminal` helpers). Model the new LiveView test on this one; it already sets up a git-backed project, points the worktree scratch base at it, walks the LiveView, and waits for the run to terminate.
- `test/repo_builder_web/live/test_adw_builder_combos_test.exs` — the existing ADW Builder LiveView test (mount `~p"/"`, type spec + prompt, add steps, click Launch, assert the launched workflow's `steps[*].prompt_template` matches the catalog default). Extends the new LiveView test with the target-repo seam assertions.
- `test/repo_builder_web/live/test_adw_builder_custom_adw_test.exs` — the per-step prompt + harness picker test (combines `Combos` + `Definitions` app-env override for tmp dirs). The `tmp` + `Application.put_env` + `on_exit` cleanup pattern is reusable for the new test.
- `test/support/conn_case.ex` (and any helpers under `test/support/`) — the standard `ConnCase` LiveView helpers used by every LiveView test in this repo.
- `BUILD_PROMPT.md` §3 (typed coding standard — preserved `@spec`s, tagged tuples, no raising), §7 (workflow engine — `WorkflowEngine.start_workflow/2` is the single launch seam), §8 (persistence — `workflow_runs.project_id` is the nullable target-repo FK, `nil` = the platform itself), §9 (LiveView dashboard — the ADW Builder lives in the console's ⌘K modal).
- `ai_docs/typed-elixir-standard.md` — rule 6 (wire vs domain — `Project.t()` over `map()`, tagged tuples over raising), the enforced `@spec` discipline.
- `ai_docs/adw-orchestration.md` — the ADW/wf-engine seam map; the `WorkflowEngine.start_workflow/2` opts are the canonical launch contract the fix honors.
- `AGENTS.md` — Phoenix 1.8 / LiveView guidelines; the new test follows the `Phoenix.LiveViewTest` + `ConnCase, async: false` pattern.
- `specs/issue-1261634-adw-ui_slowness-sdlc_planner-fix-plan-f3-custom-adw-spec-handover.md` — the related plan_f3 spec-handover fix (different symptom on a different step name; the `{{spec}}` substitution contract it documents is the same one this fix honors).
- `.claude/commands/conditional_docs.md` — `(always)` row applies; the **Workflow/ADW engine** row (BUILD_PROMPT §7 + `ai_docs/adw-orchestration.md`) applies; the **LiveView dashboard** row (BUILD_PROMPT §9 + AGENTS.md) applies; the **Ecto schemas** row (BUILD_PROMPT §8) applies to `workflow_runs.project_id`; the **Tests** row (BUILD_PROMPT §13) applies to the new LiveView integration test.

### New Files

- `test/repo_builder_web/live/test_adw_builder_spec_arg_threaded_to_cwd_test.exs` — `Phoenix.LiveViewTest` integration test. Setup: register a git-backed `Projects.Project` with `root_path` pointing at a tmp dir and `isolation_mode: :direct` (matches the writer-app operator's setup; also covers `:worktree` in a sibling test). Mount `~p"/"`, open the ADW Builder, set the **SPEC (optional)** textarea to a project-relative spec path (`specs/issue-essay-features-adw-featuregap-sdlc_planner-essay-app-feature-parity.html`), set **INITIAL PROMPT**, add `plan → build` steps, click **▶ Launch ADW**. Asserts:
  1. The freshly-created `workflow_runs` row has `project_id == project.id` (regression — was `nil` before the fix).
  2. `workflow_runs.artifacts["spec"]` equals the typed spec path verbatim (the input-artifact path; this assertion pre-existed and now lives next to the project_id assertion).
  3. `RepoBuilder.Workflows.get_run!(run_id).artifacts["input"]` equals the typed INITIAL PROMPT.
  4. The launched workflow's `steps` contain `{{spec}}` in the plan step's `prompt_template` (the catalog default, unchanged).
  5. When the run terminates, the run's `worktree_path` (for `:worktree`) equals `<project.root_path>`-subdir, NOT a `priv/workspaces/<id>` path (regression — was a scratch workspace before the fix).
  6. (Mock the harness session via the registry injection seam used by `test_planning_wizard_target_repo_test.exs:31-35` so the plan step terminates without spawning an external CLI.) Fails before the fix (project_id is nil; cwd is the scratch workspace) and passes after.
- A sibling test in the same file for `:isolation_mode = :worktree`, asserting the run's `worktree_branch` is provisioned in `<project.root_path>` (observable proof the cwd reached the session), mirroring the planning-wizard regression test at `test_planning_wizard_target_repo_test.exs:88-101`.

## Step by Step Tasks

IMPORTANT: Execute every step in order, top to bottom.

### 1. Thread the target-repo seam from the ADW Builder into `WorkflowEngine.start_workflow/2`

- Read `launch_adw_builder/4` (`lib/repo_builder_web/live/console_live/adw_builder_panel.ex:398-455`) and confirm it currently calls `WorkflowEngine.start_workflow(wf, inputs: inputs)` with only the `inputs:` opt.
- Add `alias RepoBuilder.Projects` to the module's alias block at the top (`lib/repo_builder_web/live/console_live/adw_builder_panel.ex:11-17`), alongside the existing `RepoBuilder.Adw.{Combos, StepSpec}` aliases. Keep the existing imports.
- Inside `launch_adw_builder/4`, immediately before the `with {:ok, wf} <- Workflows.create_workflow(...)` block, resolve the active project from the socket:
  ```elixir
  project_opts =
    case socket.assigns[:active_project_id] do
      nil ->
        []

      project_id ->
        case Projects.fetch_project(project_id) do
          {:ok, project} ->
            [
              project_id: project.id,
              cwd: project.root_path,
              isolation_mode: project.isolation_mode
            ]

          {:error, :not_found} ->
            []
        end
    end
  ```
- Splice the resolved opts into the `WorkflowEngine.start_workflow/2` call:
  ```elixir
  {:ok, _run_id, _pid} <- WorkflowEngine.start_workflow(wf, [inputs: inputs] ++ project_opts)
  ```
  The `[inputs: inputs] ++ project_opts` shape preserves the existing `inputs:` key when `project_opts == []` (project-less console, back-compat) and adds the three target-repo opts when an active project is found. Keyword-list concat is deterministic for unique keys; `inputs:` is the only key already in the list, so no collision.
- Document the new behavior in a brief comment immediately above the `WorkflowEngine.start_workflow/2` call:
  ```elixir
  # Thread the operator's active project into the run (agentic-layer adaptor seam,
  # fix ADW Builder target-repo launch): a `nil` active_project_id ⇒ the existing
  # no-cwd / managed-scratch behavior (every pre-existing caller is unchanged); a
  # resolved project ⇒ `cwd: project.root_path, isolation_mode: project.isolation_mode`
  # so each step session runs IN the operator's repo and the typed spec path resolves.
  ```
- Keep the typed `inputs` shape (`%{"input" => initial_prompt, "spec" => spec}`) unchanged so the `{{spec}}` substitution behavior is preserved — the bug is on the cwd side, not the input-artifact side.

### 2. LiveView integration test — spec arg threads through to the step session's cwd

- Create `test/repo_builder_web/live/test_adw_builder_spec_arg_threaded_to_cwd_test.exs` using `use RepoBuilderWeb.ConnCase, async: false` (the LiveView shared sandbox reaches the spawned Runner + Session via the existing convention).
- Setup: mirror `test_planning_wizard_target_repo_test.exs:31-44` for harness registry injection (point "claude" at the safe canned-event Fake adapter so a real harness never spawns an external CLI). Add a helper `git_project(attrs)` that creates a tmp git-backed project, registers it via `Projects.create_and_profile/1`, and `on_exit`s the cleanup. Configure `:worktree, scratch_base` to a tmp sibling dir under the project's tmp base.
- Test 1 — direct isolation:
  - Create a `git_project(%{"isolation_mode" => "direct"})`.
  - Mount `~p"/"`, open the ADW Builder, set `adw_set_spec` to the project-relative spec path the user typed, set `adw_set_prompt` to a feature description, add `plan → build` steps, click `run_adw_builder`.
  - Find the freshly-created `workflow_runs` row scoped to the project (via `Workflows.list_recent_for_project(project.id, 1)` — back-compat helper).
  - Assert `run.project_id == project.id` (regression: was `nil`).
  - Assert `run.artifacts["spec"]` equals the typed spec path verbatim.
  - Assert `run.artifacts["input"]` equals the typed INITIAL PROMPT.
  - Assert the run's persisted `steps[*].prompt_template` for the plan step equals `Catalog.default_prompt_template("plan")` (the `{{spec}}` substitution contract is intact; the fix does not change the template).
  - Await the run terminal (helper mirrors `test_planning_wizard_target_repo_test.exs:55-61`).
  - Assert `run.worktree_path` is `nil` (direct mode) and `run.worktree_branch` is `nil`.
- Test 2 — worktree isolation:
  - Same setup with `git_project(%{"isolation_mode" => "worktree"})`.
  - Launch the same custom ADW.
  - Await terminal.
  - Assert `run.worktree_branch == "adw/#{run.id}"` and the branch survives in the project's repo via `git branch --list "adw/#{run.id}"` (observable proof the cwd reached the session — the same shape as `test_planning_wizard_target_repo_test.exs:88-101`).
  - Assert `run.worktree_path` starts with `<project.root_path>`'s parent and contains the worktree subdir (NOT a `priv/workspaces/<id>` path).
- Both tests fail before the fix (`project_id` is `nil`; the run's worktree path is in `priv/workspaces/…`) and pass after.

### 3. Defensive: cover the orchestrator `start_adw_via_engine/4` defect shape (out-of-scope note + lightweight guard)

- Add a one-line `# TODO(issue-adw-engine-launch-cwd): start_adw_via_engine/4 has the same defect shape; tracked separately.` comment immediately above `WorkflowEngine.start_workflow/2` in `lib/repo_builder/orchestrator/tools/adw.ex:73-94`. Do NOT change behavior in this bug — the user's report is on the ADW Builder surface only and changing the engine path is a separate ticket. The note preserves the audit trail so the next reader does not silently miss it.
- Document this out-of-scope note in the plan's **Notes** section so the reviewer is not surprised by the untouched engine-path call site.

### 4. Run the full validation gate

- Last step. Run every command in the **Validation Commands** section below; fix any failures and re-run until every command exits 0.
- Capture an optional Playwright screenshot of `http://localhost:4000` showing the ADW Builder panel with the SPEC field populated (per the project's Phoenix LiveView guidelines in `AGENTS.md`, §9 of `BUILD_PROMPT.md`) as visual proof the UI surface is unchanged.

## Validation Commands

Execute every command to validate the bug is fixed with zero regressions.

- `mix test test/repo_builder_web/live/test_adw_builder_spec_arg_threaded_to_cwd_test.exs --warnings-as-errors` — the new LiveView integration test. **Fails before fix** (`project_id IS NULL`; worktree path under `priv/workspaces/`). **Passes after fix** (`project_id == project.id`; worktree path under the project root for `:worktree`; `nil` worktree path for `:direct`).
- `mix test test/repo_builder_web/live/test_adw_builder_combos_test.exs --warnings-as-errors` — the existing ADW Builder spec/prompt tests stay green (back-compat — the `inputs:` opt shape is unchanged, so the existing assertions about `steps[*].prompt_template` still hold).
- `mix test test/repo_builder_web/live/test_adw_builder_custom_adw_test.exs --warnings-as-errors` — the per-step prompt + harness picker tests stay green (no behavior change on the harness / per-step prompt surface).
- `mix test test/repo_builder_web/live/test_adw_builder_save_combo_test.exs --warnings-as-errors` — the save-combo tests stay green (no change to the sidecar persistence surface).
- `mix test test/repo_builder_web/live/test_adw_builder_palette_plan_f3_test.exs --warnings-as-errors` — the palette + step-atom tests stay green (no change to the palette / step-atom surface).
- `mix test test/repo_builder_web/live/test_planning_wizard_target_repo_test.exs --warnings-as-errors` — the planning-wizard target-repo regression stays green (the planning wizard still passes `cwd:` / `isolation_mode:` / `project_id:` to `WorkflowEngine.start_workflow/2`; this fix mirrors its pattern).
- `mix test test/repo_builder/workflow_engine/ --warnings-as-errors` — the workflow engine unit tests stay green (no change to `Runner`, `Catalog`, `Step`, etc.).
- `mix test test/repo_builder/projects/ --warnings-as-errors` — the projects context tests stay green (no change to `Projects` or `Project`).
- `mix compile --warnings-as-errors` — gradual set-theoretic compiler green; the new `alias` and the new keyword-list shape preserve the existing `@spec` contract on `launch_adw_builder/4`.
- `mix test --warnings-as-errors` — full ExUnit suite (Postgres-backed test cases) green; zero regressions.
- `mix format --check-formatted` — every changed file formatted per the project standard.
- `mix credo --strict` — lint passes, including `Credo.Check.Readability.Specs` on the new helper closure inside `launch_adw_builder/4`.
- `mix dialyzer` — `@spec`/contract check clean; no new warnings.
- Tidewave runtime verification (per `BUILD_PROMPT.md` §1 / `AGENTS.md` Troubleshooting): with the app running on `http://localhost:4000`, execute via `project_eval` against a freshly-launched ADW:
  1. `RepoBuilder.Workflows.list_recent_for_project(project.id, 1) |> hd |> Map.get(:project_id)` — returns the project's id (was `nil` before fix).
  2. `RepoBuilder.Workflows.list_recent_for_project(project.id, 1) |> hd |> Map.get(:artifacts) |> Map.get("spec")` — returns the typed spec path verbatim.
  3. `RepoBuilder.Workflows.list_recent_for_project(project.id, 1) |> hd |> Map.get(:worktree_branch)` — returns `"adw/#{run_id}"` for `:worktree` projects, `nil` for `:direct` (was always `nil` before fix because the scratch workspace has no git repo).
- Manual end-to-end reproduction (Tidewave or shell): launch the same custom ADW via the ADW Builder on the writer-app project with the spec path `specs/issue-essay-features-adw-featuregap-sdlc_planner-essay-app-feature-parity.html`; the agent's plan-step session output references the typed spec path verbatim (i.e. the plan body quotes the spec), not a stale or hallucinated one.

## Notes

- **Scope discipline**: this fix is one function call change in one file (`launch_adw_builder/4`), plus one new LiveView integration test. No schema/migration changes, no event-contract changes, no harness-adapter changes, no new dependencies. The fix mirrors the existing `lib/repo_builder_web/live/planning_live.ex:start_run/4` pattern verbatim — same three opts, same `Keyword` shape, same `nil` ⇒ unchanged fallback.
- **Why `Project.t()` over a raw `root_path` string**: `Projects.fetch_project/1` returns the typed `%Project{}` so the `@spec` discipline on the new closure is enforced (Dialyzer narrows the union on the success branch, per `ai_docs/typed-elixir-standard.md` rule 6 — wire vs domain). The closure returns a keyword list; the typed `Project.t()` ensures `project.id`, `project.root_path`, and `project.isolation_mode` are non-`nil` and well-typed.
- **Why `[inputs: inputs] ++ project_opts` and not `Keyword.merge/2`**: `Keyword.merge/2` silently drops later duplicates of the same key; the explicit concat makes the merge order obvious and avoids any future maintainer confusion if the two keyword lists ever gain a colliding key.
- **Why a typed-comment-only TODO on the engine path**: `start_adw_via_engine/4` in `lib/repo_builder/orchestrator/tools/adw.ex:73-94` has the same defect shape. The user's report is on the ADW Builder surface, the planning-wizard fix is the reference pattern, and the engine-path call site would be a separate, narrowly-scoped bug ticket (it has different args shape — `orchestrator_id:` not `project_id:`, and the orchestrator session runtime contract is different from the workflow-engine contract). Adding the comment preserves the audit trail without scope creep.
- **What this fix does NOT change**:
  - The `inputs: %{"input" => initial_prompt, "spec" => spec}` shape is unchanged — the `{{spec}}` substitution contract is preserved.
  - The `Catalog.default_prompt_template/1` is unchanged — the prompt templates still render `{{spec}}` for `plan`, `plan_f3`, `patch`, and `_other` fallback.
  - The `Combos.save/2` sidecar persistence is unchanged — saved combos still carry the typed spec.
  - The post-launch `adw_spec: ""` / `adw_prompt: ""` reset is unchanged — the builder clears on launch.
  - The harness selection (`adw_harness || orchestrator_harness || "fake"`), per-step harness/provider/model overrides, and the `TitleHumanizer` async humanization are unchanged.
- **Tidewave verification note**: `project_eval` is hermetic — it cannot spawn a real harness CLI, so the new test uses the same registry-injection seam as `test_planning_wizard_target_repo_test.exs:31-35` (point `"claude"` at the `"fake"` canned-event adapter). The `await_run_terminal/1` helper waits for the run to terminate on the `fake` adapter before asserting on the persisted state.
- **Plan filename**: `specs/issue-essay-features-adw-featuregap-sdlc_planner-custom-adw-spec-arg-not-threaded-to-step-cwd.md`. The `essay-features` issue number and `featuregap` adw_id are derived from the spec path the user pasted (`specs/issue-essay-features-adw-featuregap-sdlc_planner-essay-app-feature-parity.html`); they are freeform placeholders since no GitHub issue exists for the report.