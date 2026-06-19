# Bug: Portable ADW steps fail to dispatch slash commands yet report "succeeded"

## Metadata
issue_number: `workflow`
adw_id: `step`
issue_json: `commands`

## Bug Description
When the orchestrator (`orch-877`) launched a portable ADW with `workflow_type = plan_build_review_fix` (run id `15eeb7d5-1163-4969-bbe0-fb6245d90ca4`, harness `adw`) targeting `/data/1.Projects/repo_builder`, every workflow step failed to actually run its slash command, yet the run reported success per step:

- **plan step (log-5275):** the agent replied `"/plan isn't available in this environment"` — the SDK did not recognize `/plan` as a command and treated the prompt as literal text.
- **plan step status (log-5277):** the canonical `step_end` event still reported `status: "succeeded"`.
- **build step (log-5279):** the agent replied `"Unknown command: /build"`.
- **build step status (log-5286):** `step_end` again reported `status: "succeeded"`.
- **review step (log-5288 / log-5291):** with no project `/review` command loaded, the agent fell back to its own built-in notion of "review", concluded it was being asked to review a pull request (not execute a workflow step), found no open PR, and decided the wrong command had been invoked.

**Expected:** each step's slash command (`/plan`, `/build`, `/review`, `/fix`) resolves to the project's `.claude/commands/*.md` definition, runs the real workflow stage against the target repo, and `step_end` reports `succeeded` only when the stage actually executed (and `failed` otherwise).

**Actual:** none of the commands resolve; the steps do no meaningful work; and `step_end` falsely reports `succeeded` for steps that never ran, so the Elixir console swimlane shows a green run that produced nothing.

### Amendment — log-5289 → log-5353 (the dominant root cause: wrong worker cwd)

A second run (ADW agent `orch-adw-21251`) exposed a deeper cause than the two Python-side defects above. The worker session was **rooted in the orchestrator's own working directory (`job-seeking`) instead of the target repo (`/data/1.Projects/repo_builder`)**:

- **log-5310:** the worker terminated with `%Error{reason: :idle_timeout}` after the §6 runtime's 300 s idle timer fired — the agent, fed slash commands it could not resolve from the `job-seeking` cwd, stalled/looped without producing terminal output.
- **log-5312/5313:** the orchestrator correctly diagnosed that `/plan`, `/build`, `/review` 404'd because the worker's cwd was `job-seeking`, whose `.claude/commands/` does not contain them — even though disk verification (log-5336) confirmed the **target** `repo_builder` *does* have `plan.md`, `build.md`, `review.md`. The commands existed; the agent was simply looking in the wrong repo.
- **log-5336:** verification also found `prompt_builder/` code + tests and `ai_docs/prompt-standard-spec.md` had been created (files newer than 20:55), but `.planning/` was never created. So the build-style work partially happened (the agent free-formed it from the prompt text, which embedded the full feature spec, writing via absolute paths), while the plan step's controlled `.planning/` artifact was never produced — direct evidence that the steps did NOT run as commands yet still mutated disk uncontrolled.
- **log-5341:** the orchestrator proposed pivoting to direct worker orchestration (workers writing to `repo_builder` via absolute paths, no slash-command dependency).
- **log-5353:** the session then died with `%Error{reason: :provider_error, message: "provider exited: :port_closed"}` — the `uv`/Python child's port closed (the SDK process exited) before the pivot was implemented.

**Why this changes the fix:** `setting_sources=["project"]` (defect 1) and creating `plan.md` (defect 2) are necessary but **not sufficient** — the SDK reads `.claude/commands/` relative to `cwd`, and `cwd` points at the wrong repo. The argv's `--working-dir` is likewise wrong. The target-repo path was passed only as prose inside the prompt, never as the process cwd. This must be fixed on the **Elixir** side: `start_adw` needs a target working-directory parameter threaded into `opts.cwd` (and thus the adapter's `--working-dir` and the SDK cwd).

## Problem Statement
**Three** defects combine into a silently-broken, cross-repo workflow. Defect 0 (below) is the dominant one revealed by the second run; defects 1–2 are the Python-side problems from the first run.

**0. The worker runs in the wrong directory (Elixir side).** `Orchestrator.Tools.spawn_adw_session/4` hardcodes `cwd: orchestrator_working_dir(orchestrator_id)` (`lib/repo_builder/orchestrator/tools.ex:461`), i.e. the orchestrator's own `working_dir` (`job-seeking`). The `start_adw` tool schema (`tool_catalog.ex:113-129`) has **no** parameter for the target repo, so an ADW that must operate on a *different* repo cannot say so except in prose inside `input`. Consequently the adapter builds `--working-dir job-seeking` and the SDK resolves `.claude/commands/` under `job-seeking`, where `/plan`, `/build`, `/review` do not exist — they 404 even though the target `repo_builder` has them. This also caused the `:idle_timeout` (log-5310) and the partial, uncontrolled disk writes (log-5336).

The original two defects (still real, still need fixing for same-repo runs):

1. **Command dispatch is broken.** The portable runner (`adws/adw_modules/adw_runner.py`) drives the Claude Agent SDK via `ClaudeAgentOptions(cwd=..., model=..., permission_mode="bypassPermissions")` with **no `setting_sources`**. In `claude-agent-sdk` ≥ 0.1.0, `setting_sources` defaults to "load nothing from the filesystem", so the project's `.claude/commands/` directory is never read and the custom slash commands `/build`, `/review`, `/fix` are unknown to the SDK. Additionally, **`.claude/commands/plan.md` does not exist at all** — `/plan` is a phantom command referenced by every portable workflow (`adw_plan_build*.py`, `adw_plan_build_review*.py`, `adw_plan_build_review_fix.py`, `adw_build_in_parallel.py`), so it would fail even after `setting_sources` is fixed. (`/scout`, used by `adw_plan_w_scouts_build_review.py`, is also missing — out of scope but noted.)

2. **Step success is mis-derived.** In `_run_step`, `ok` is set to `False` only when a `ResultMessage.is_error` is observed. A "command not recognized" reply is a *successful* SDK run (the agent produced text), so `ok` stays `True` and `emitter.step_end(...)` emits `status: "succeeded"`. The Elixir decoder (`RepoBuilder.Harness.Adw.EventSchema.decode/2`) faithfully maps `"succeeded" → is_error: false` — it is behaving correctly; the false status originates entirely in the Python runner.

## Solution Statement
Fix the Elixir orchestrator so ADW workers run in the **target** repo, and fix the Python portable runner so commands resolve and non-execution is never reported as success. (Earlier this section said "the Elixir adapter/decoder are correct and need no change" — that was true for the *decoder* but the second run proves the orchestrator's cwd plumbing is the dominant bug and must change.)

0. **Thread a target working directory through `start_adw` (Elixir, primary fix):** add an optional `working_dir` (a.k.a. `target_dir`) parameter to the `start_adw` tool schema; in `spawn_adw_session/4`, use it as `opts.cwd` when present, falling back to `orchestrator_working_dir/1`. Validate it is an existing absolute directory (return a helpful `{:error, ...}` otherwise). This makes the adapter's `--working-dir` and the SDK cwd point at the repo whose `.claude/commands/` actually contain the steps. Document in the tool description that cross-repo ADWs MUST pass `working_dir`.

1. **Load project commands:** pass `setting_sources=["project"]` to `ClaudeAgentOptions` in `adw_runner.py` so the SDK reads `.claude/commands/` from the run's `cwd` (the target repo). This makes `/build`, `/review`, `/fix` resolvable.
2. **Provide the missing `/plan` command:** create `.claude/commands/plan.md` so the `/plan` step every portable workflow depends on resolves to a real planning command (mirroring the existing `build.md`/`review.md`/`fix.md` contract).
3. **Pre-flight command availability:** before running, `adw_runner.run/3` validates that each step's command file exists under `<working_dir>/.claude/commands/<name>.md`; if any is missing it emits a neutral `error` event and fails the run fast, instead of silently "succeeding". This directly closes the "workflow type references a command the runtime doesn't have" class of bug for any future workflow.
4. **Never report a non-executed step as succeeded:** in `_run_step`, treat well-known non-execution markers in the agent's combined output (`"isn't available in this environment"`, `"unknown command"`, `"command not found"`) as a step failure (`ok = False`) so `step_end` reports `failed`. Defensive backstop for any command that resolves at the SDK layer differently than expected.

These are minimal, surgical, and confined to `adws/`.

## Steps to Reproduce
1. From the orchestrator, `start_adw` with `harness: "adw"`, `workflow_type: "plan_build_review_fix"`, and any feature prompt targeting a repo whose `.claude/commands/` lacks `plan.md` (the current state).
2. Observe in the console swimlane / `agent_logs`:
   - the plan step's `text` event contains `"/plan isn't available in this environment"`;
   - the build step's `text` event contains `"Unknown command: /build"`;
   - both `step_end` events report `status: "succeeded"`;
   - the review step misinterprets the task as a PR review.
3. Equivalent local repro without the orchestrator:
   ```bash
   cd /data/1.Projects/repo_builder    # a repo missing .claude/commands/plan.md
   uv run /data/1.Projects/repo_builder_elixir/adws/adw_workflows/adw_plan_build_review_fix.py \
     --prompt "Build a prompt-builder + validator feature" \
     --working-dir "$PWD" --adw-id repro-1 --emit json
   ```
   The emitted JSONL shows `step_end ... "status":"succeeded"` despite `text` lines reporting the commands are unavailable.

## Root Cause Analysis
- **Wrong cwd (dominant, Elixir):** `spawn_adw_session/4` sets `cwd: orchestrator_working_dir(orchestrator_id)` unconditionally (`tools.ex:461`), and `start_adw` exposes no target-dir param (`tool_catalog.ex:113-129`). For a cross-repo ADW (orchestrator in `job-seeking`, target `repo_builder`) the worker therefore spawns in `job-seeking`. The adapter's `--working-dir` (`adw.ex:63`) and the SDK's command-resolution root both become `job-seeking`, whose `.claude/commands/` lacks the steps → every slash command 404s. The agent, unable to dispatch but holding the full spec in the prompt, free-formed partial work (prompt_builder files, log-5336) and otherwise stalled until the §6 idle timer killed it (`%Error{reason: :idle_timeout}`, log-5310); a later run's child port closed → `%Error{reason: :provider_error, message: "provider exited: :port_closed"}` (log-5353). Both are correct §4.1 terminal events — symptoms, not the bug.
- **Dispatch:** `claude-agent-sdk` changed its default so that filesystem settings (including project slash commands in `.claude/commands/`) are **not** loaded unless `setting_sources` explicitly includes `"project"`. `adw_runner.py:91-95` constructs `ClaudeAgentOptions` without it, so the agent sees `/plan`, `/build`, `/review`, `/fix` as plain text. The agent's free-form replies ("isn't available in this environment", "Unknown command", PR-review confusion) are exactly what an LLM produces when handed an unrecognized slash token. Separately, `.claude/commands/plan.md` simply does not exist, so `/plan` is unresolvable regardless of `setting_sources`.
- **False success:** `_run_step` (`adw_runner.py:97-123`) derives `ok` solely from `ResultMessage.is_error`. A command-not-found reply is not an SDK error, so `ok` stays `True` → `step_end(status="succeeded")`. `EventSchema.decode/2` (`step_end` branch, `event_schema.ex:111-132`) correctly maps `"succeeded"` to `is_error: false`; the decoder is not at fault.
- **Net effect:** a deterministic workflow whose steps do nothing reports a fully green run — the worst failure mode (silent), which is what made this hard to spot.

## Relevant Files
Use these files to fix the bug:

- `adws/adw_modules/adw_runner.py` — **primary fix.** Add `setting_sources=["project"]` to `ClaudeAgentOptions`; add pre-flight command-file validation in `run/3`; flip `ok=False` on non-execution markers in `_run_step`.
- `adws/adw_modules/adw_emit.py` — the neutral event emitter; confirm `error`/`step_end` shapes used by the new validation path (no change expected, read-only reference).
- `adws/adw_workflows/adw_plan_build_review_fix.py` — the workflow whose `Step("plan", "/plan")` triggered the report; confirms the command set the runtime must satisfy. No change needed once `/plan` exists.
- `lib/repo_builder/orchestrator/tools.ex` — **primary Elixir fix.** `spawn_adw_session/4` (line ~461) hardcodes `cwd: orchestrator_working_dir/1`; `start_adw_via_adapter/4` (line ~419) builds the worker params. Add target-`working_dir` resolution/validation and use it for `opts.cwd`.
- `lib/repo_builder/orchestrator/tool_catalog.ex` — **Elixir fix.** `start_adw` schema (lines ~110-129): add the optional `working_dir` property + description; note cross-repo ADWs must pass it.
- `lib/repo_builder/orchestrator/system_prompt.ex` — read/adjust: if it documents `start_adw` usage, mention `working_dir` so the orchestrator passes the target repo instead of relying on cwd inheritance.
- `lib/repo_builder/harness/adw.ex` — the adapter that builds `--working-dir <cwd>` from `opts.cwd`. Read-only: confirms that once `opts.cwd` is the target repo, the argv and SDK cwd are correct. No change needed (the bug is the cwd *value* fed in, set in `tools.ex`).
- `lib/repo_builder/harness/adw/event_schema.ex` — the decoder. Read-only: confirms `step_end "failed"/"error" → is_error: true` already works, so once the runner emits `failed` the console reflects it. No change.
- `.claude/commands/build.md`, `.claude/commands/review.md`, `.claude/commands/fix.md` — existing command contracts to mirror when authoring `plan.md` (frontmatter `command:`/`version:`, `$ARGUMENT` variables).
- `adws/adw_tests/test_slash_command.py`, `adws/adw_tests/test_harness.py` — existing Python test patterns to mirror for the new runner tests.
- `test/repo_builder/harness/adw_normalize_test.exs` — existing Elixir decoder test to extend with a regression assertion.
- `BUILD_PROMPT.md` §4 (canonical event contract), §7 (ADW engine) — authoritative semantics for `step_end`/`done` status and `:done.ok` reflecting real outcome.

### New Files
- `.claude/commands/plan.md` — the missing `/plan` slash command, mirroring the `build.md`/`review.md`/`fix.md` contract (frontmatter + `$ARGUMENT` variables + a planning workflow that writes a `specs/*.md` plan for the prompt). Required by all portable `plan_*` workflows.
- `adws/adw_tests/test_adw_runner.py` — Python unit tests for the runner: (a) command-availability pre-flight fails fast with an `error` event when a command file is missing; (b) `_run_step` reports `failed` when the agent output contains a non-execution marker; (c) `ClaudeAgentOptions` is built with `setting_sources` including `"project"`.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 0. Thread a target working directory through `start_adw` (Elixir — dominant fix)
- In `lib/repo_builder/orchestrator/tool_catalog.ex`, add an optional `working_dir` string property to the `start_adw` `input_schema.properties` (description: "Absolute path to the repo the ADW should operate in. REQUIRED for cross-repo work; defaults to the orchestrator's working directory."). Leave `required` as `["input"]`.
- In `lib/repo_builder/orchestrator/tools.ex`:
  - Add a private resolver, e.g. `adw_working_dir(orchestrator_id, args)`: take `blank_to_nil(args["working_dir"])`; if present, validate with `File.dir?/1` (absolute, exists) and return `{:error, "working_dir <path> is not an existing directory"}` otherwise; if absent, fall back to `orchestrator_working_dir(orchestrator_id)`.
  - Thread the resolved dir from `start_adw_via_adapter/4` into `spawn_adw_session/4` and replace `cwd: orchestrator_working_dir(orchestrator_id)` (line ~461) with the resolved target dir.
  - Optionally also pass the target dir to `discovered_adws/1` so an ADW script living in the target repo's `adws/` is discoverable (keep app-root + orchestrator-dir scans; add the target dir). Keep this minimal — the script path is already absolute, so discovery isn't the blocker; only add if trivial.
- Keep `@spec`s on every new public/private function per `BUILD_PROMPT.md` §3; return `{:error, reason()}` (never raise) for a bad dir.
- Update `system_prompt.ex` (if it documents `start_adw`) to instruct passing `working_dir` for cross-repo ADWs.

### 1. Create the missing `/plan` command
- Add `.claude/commands/plan.md` modeled on `.claude/commands/build.md`/`review.md`: YAML frontmatter (`command: plan`, `version: 1.0.0`), an `argument-hint`, `$ARGUMENT` variables (`adw_id`, `spec_file`/prompt, `agent_name` default `plan_agent`), and a `Workflow` that turns the prompt into a written `specs/*.md` plan (it may reuse the conventions in `bug.md`/`feature.md`). Keep it Elixir/Phoenix-aware per `BUILD_PROMPT.md` §3 (typed-Elixir gates) so the produced plan fits this repo's standard.
- Verify `/plan` now exists alongside `/build`, `/review`, `/fix`.

### 2. Load project slash commands in the SDK
- In `adws/adw_modules/adw_runner.py` `_run_step`, add `setting_sources=["project"]` to the `ClaudeAgentOptions(...)` construction (alongside the existing `cwd`, `model`, `permission_mode`). This makes the SDK read `<working_dir>/.claude/commands/`.
- Keep `cwd=args.working_dir` so commands resolve from the **target** repo, not the runner's directory.

### 3. Pre-flight command-availability validation
- In `adws/adw_modules/adw_runner.py` `run/3`, before the step loop, compute the set of commands the workflow needs (from `steps` and from any branch-only commands the workflow may append — at minimum validate the static `steps`; document that branch steps are validated when appended). For each command, strip the leading `/` and any argument suffix (e.g. `/build slice-a` → `build`) and check that `<working_dir>/.claude/commands/<name>.md` exists.
- If any are missing, emit a neutral `error` event via the emitter (`reason="spawn_failed"` or a clear message naming the missing commands) and return a non-zero exit code **without** running steps. This converts the silent failure into a loud, actionable one.
- Apply the same per-command existence check inside the branch path (when `branch(...)` appends `/fix`) before running the appended step; if missing, emit `error` and stop.

### 4. Stop reporting non-executed steps as succeeded
- In `_run_step`, after accumulating `final_text`, lower-case it and check for non-execution markers: `"isn't available in this environment"`, `"unknown command"`, `"command not found"`. If any is present, set `ok = False` (so `step_end` reports `failed`) and emit a `tool_result(step.slug, <marker text>, is_error=True)` for observability.
- Ensure `done(...)` still rolls up `ok_all` so the terminal `done` event reflects `error_during_execution` when any step failed.

### 5. Python tests for the runner
- Create `adws/adw_tests/test_adw_runner.py` mirroring `test_slash_command.py`/`test_harness.py`:
  - **pre-flight**: running a workflow whose steps reference a non-existent command, against a temp `working_dir` with an empty `.claude/commands/`, emits an `error` event and returns non-zero (monkeypatch/capture the emitter or stdout JSONL).
  - **false-success guard**: a monkeypatched `query` that yields an `AssistantMessage` whose text is `"/plan isn't available in this environment"` produces a `step_end` with `status == "failed"`.
  - **setting_sources**: assert the `ClaudeAgentOptions` constructed in `_run_step` includes `"project"` in `setting_sources` (capture via a monkeypatched `ClaudeAgentOptions` or inspect the call).
- Run the Python tests (see Validation Commands).

### 6. Elixir regression assertion (decoder)
- Extend `test/repo_builder/harness/adw_normalize_test.exs` with an assertion that a `step_end` frame with `"status" => "failed"` decodes to `%Event.ToolResult{is_error: true}` and `"status" => "succeeded"` to `is_error: false`. This locks in that once the runner emits `failed`, the console reflects a failed step. (Pure decoder test — no DB/LiveView needed.)

### 7. Elixir test for the `start_adw` working_dir plumbing
- Add/extend a test under `test/repo_builder_web/live/` or `test/repo_builder/orchestrator/` (mirror an existing `start_adw` adapter test, e.g. the `test_orchestrator_adw_shellout`/`adw_tools` tests) asserting that:
  - `start_adw` with `harness: "adw"` and an explicit valid `working_dir` spawns the session with `opts.cwd` equal to that dir (not the orchestrator's), e.g. by capturing the opts passed to `Session.Supervisor.start_session/1` (Mox or a test seam) or asserting the adapter's argv contains `--working-dir <target>`;
  - a non-existent `working_dir` returns a `{:error, _}` and does NOT spawn a session;
  - omitting `working_dir` falls back to the orchestrator's working dir (back-compat).

### 8. Validate
- Run all `Validation Commands` below. Reproduce the bug per "Steps to Reproduce" against a repo without `plan.md` BEFORE the fix (steps falsely succeed), then AFTER the fix (pre-flight errors loudly when commands are missing; with commands present, steps run and report accurate status).

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- `test -f .claude/commands/plan.md && echo "plan.md present"` — the missing command now exists.
- `cd /data/1.Projects/repo_builder_elixir && uv run python -m pytest adws/adw_tests/test_adw_runner.py -q` — new runner tests pass (pre-flight, false-success guard, setting_sources). If the host `pytest`/`uv` Python is unavailable in this environment (known native-dep space-path issue), run on a provisioned host and note the result.
- `cd /data/1.Projects/repo_builder_elixir && uv run python -c "import ast,sys; ast.parse(open('adws/adw_modules/adw_runner.py').read()); print('runner parses')"` — Python syntax check (fallback when pytest can't run).
- **Repro (after fix), missing-command path:**
  ```bash
  tmp=$(mktemp -d); mkdir -p "$tmp/.claude/commands"
  uv run adws/adw_workflows/adw_plan_build.py --prompt "x" --working-dir "$tmp" --adw-id v1 --emit json
  ```
  Expect a neutral `error` event naming the missing commands and a non-zero exit — NOT `step_end ... "succeeded"`.
- `mix test test/repo_builder/harness/adw_normalize_test.exs` — decoder regression (failed→is_error true, succeeded→false) passes.
- `mix test test/repo_builder/orchestrator/` — `start_adw` working_dir plumbing tests pass (explicit dir → that cwd; bad dir → `{:error, _}`, no spawn; omitted → orchestrator dir fallback).
- `mix compile --warnings-as-errors` - Compile clean; gradual set-theoretic checker + `warnings_as_errors` pass.
- `mix test --warnings-as-errors` - Full ExUnit suite, zero failures (no Elixir behavior changed; confirms no regressions).
- `mix format --check-formatted` - Formatting.
- `mix credo --strict` - Lint incl. `@spec` convention.
- `mix dialyzer` - Contract checking, no new warnings, no stale ignore filters.

## Notes
- **No new dependencies.** The fix is config (`setting_sources`), a new command markdown file, and Python control-flow guards. No `mix.exs` change.
- **Elixir scope (revised by the second run).** The *decoder* `EventSchema.decode/2` and the *adapter* `Harness.Adw.command/1` are correct — `command/1` faithfully turns `opts.cwd` into `--working-dir`. But the **value** of `opts.cwd` is wrong: `tools.ex:spawn_adw_session/4` feeds the orchestrator's cwd, and `start_adw` has no target-dir param. So the dominant fix IS on the Elixir side (Step 0), alongside the Python runner fixes. The "ADW is just a portable script" boundary (`adw.ex` moduledoc, `BUILD_PROMPT.md` §10) is preserved — we change only *which directory* the script is told to operate in, not the contract.
- **Idle-timeout & port-closed are downstream symptoms.** `%Error{reason: :idle_timeout}` (log-5310) and `%Error{reason: :provider_error, "provider exited: :port_closed"}` (log-5353) are the §6 runtime correctly reclaiming a stalled/dead child; they need no separate fix and should disappear once steps run in the right repo. If they persist after the cwd fix, investigate the SDK child lifecycle separately.
- **Partial disk writes (log-5336) are expected fallout.** With commands unresolved but the full spec in the prompt, the agent free-formed build work via absolute paths (creating `prompt_builder/`) while the controlled plan artifact (`.planning/`) never appeared. Once commands dispatch in the correct cwd, work flows through `/plan`→`/build`→`/review` and produces the controlled artifacts; the free-form drift stops.
- **Not a LiveView bug.** The console swimlane renders whatever status the canonical events carry; once the runner emits `failed`/`error`, the existing UI shows it. No `Phoenix.LiveViewTest` is required. Optionally confirm visually at `http://localhost:4000` that a re-run of `plan_build_review_fix` now shows a failed step (or a clean run) instead of all-green.
- **Broader follow-up (out of scope, note for the issue tracker):** `/scout` (used by `adw_plan_w_scouts_build_review.py`) is also missing from `.claude/commands/`. The pre-flight validation added here will now surface that loudly. Consider authoring `scout.md` or remapping that workflow in a separate change.
- **SDK behavior reference:** `claude-agent-sdk` ≥ 0.1.0 requires `setting_sources` to opt into filesystem settings/commands; the default loads nothing. Confirm against the installed SDK version on a provisioned host (`setting_sources` field default) if behavior differs — the runner-side import is lazy (`adw_runner.py:81`), so the SDK version is whatever `uv` resolves from the script's `dependencies` pin (`claude-agent-sdk>=0.1.18`).
- **Runtime intelligence used during root-cause:** could not execute Python in this environment (the known "TAC Repos" space-in-path native-dep breakage), so the SDK `setting_sources` default was confirmed from documented behavior and the code paths above; reproduce/confirm on a provisioned host per the Validation Commands. Tidewave `get_logs`/`project_eval` apply to the Elixir side, which is confirmed correct by reading `event_schema.ex`.
