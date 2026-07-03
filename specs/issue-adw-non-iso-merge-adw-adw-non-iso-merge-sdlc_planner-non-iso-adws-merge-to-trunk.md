# Feature: Non-Iso ADW Workflows Merge to Trunk

## Metadata
issue_number: `adw-non-iso-merge`
adw_id: `adw-non-iso-merge`
issue_json: `null`

## Feature Description
Today, exactly one code path in this platform ever merges an ADW's work back into the
project's trunk branch: `adws/adw_ship_iso.py`, invoked only by the `adw_sdlc_zte_iso.py`
zero-touch-execution chain. Every other ADW workflow variant — the GitHub `*_iso.py`
composites that stop after opening a PR, the GitHub-optional `*_local_iso.py` composites
whose `ship` step is a no-op ("commit only, no push"), and the native Elixir
`WorkflowEngine.Catalog` types (`plan_build`, `plan_build_review`,
`plan_build_review_fix`, `spec_implement_test_review`) run either directly against the
main working tree (no branch at all) or in a `git worktree` whose branch is recorded on
`workflow_runs.worktree_branch` but never merged — leaves committed work permanently
stranded. This feature adds an explicit, trunk-aware merge step to every ADW workflow
whose name/type does not already carry an `iso`-ship contract, so that finishing a
non-iso ADW run always ends with its changes landed on the repository's actual trunk
branch, not abandoned in a worktree or an unmerged branch. It also fixes the existing
`adw_ship_iso.py`/`worktree_ops.py`/`git_ops.py` hardcoding of the literal branch name
`"main"`, which is wrong for this repo (whose trunk is `dev`) and would silently
misbehave (checkout of a nonexistent/stale `main`) if invoked here today.

## User Story
As a developer running ADW workflows (via the Python `adws/` CLI or the in-app
Elixir workflow catalog)
I want every non-iso workflow variant to merge its finished work into the repository's
real trunk branch when it completes successfully
So that I never have to manually discover and merge stranded worktree/feature branches,
and the platform behaves correctly regardless of whether the repo's trunk is named
`main`, `dev`, or something else

## Problem Statement
1. **Python harness**: `run_local_workflow`'s `ship` step (`adws/adw_modules/workflow_ops.py:999-1002`)
   is a hardcoded no-op comment ("push/PR stay optional... keeping the default
   offline") that never merges. The GitHub `*_iso.py` composites call
   `finalize_git_operations` (push + open PR) but stop there — no merge. Only
   `adw_ship_iso.py`, reachable solely through `adw_sdlc_zte_iso.py`, performs an actual
   `git merge --no-ff` into trunk, and it hardcodes the target branch name as the
   literal string `"main"` in three places (`adw_ship_iso.py:94,103,125`), plus two more
   hardcodes in supporting modules (`worktree_ops.py:59`, `git_ops.py:260`). This repo's
   actual trunk is `dev` — there is no local or remote `main` branch at all, so
   `adw_ship_iso.py` would fail outright (or worse, silently target a stale `main` if one
   existed from history) if run here today.
2. **Elixir catalog/engine**: none of `Catalog.types/0`'s workflow types
   (`plan_build`, `plan_build_review`, `plan_build_review_fix`,
   `spec_implement_test_review`) have any merge step or edge. Workflows with
   `isolation_mode: :worktree` provision a branch via
   `RepoBuilder.Projects.Worktree.checkout/2` and record it on `workflow_runs` purely for
   passive UI display (`projects_live.ex:551-552` shows the branch name as text) — no
   merge action exists anywhere in `lib/`.
3. There is no reusable, dynamic trunk-detection helper anywhere in the codebase (Python
   or Elixir). The closest precedents are `Worktree.current_branch/1` (git
   `branch --show-current`, used as a worktree base) and
   `Projects.Profiler.git_metadata/1` (same primitive, used to populate
   `Project.default_branch`) — both read the *currently checked-out* branch, which is a
   reasonable heuristic but not a true default-branch lookup, and neither is reused by
   the ADW ship path.

## Solution Statement
- Introduce one shared, dynamic trunk-detection helper per language (Python:
  `adws/adw_modules/git_ops.py::get_trunk_branch`; Elixir:
  `RepoBuilder.Projects.Worktree.detect_trunk/1`, built on the existing
  `current_branch/1` pattern but preferring `git symbolic-ref refs/remotes/origin/HEAD`
  when a worktree/checkout is not itself on trunk), and replace every hardcoded `"main"`
  git-operation reference (`adw_ship_iso.py`, `worktree_ops.py`'s fallback chain,
  `git_ops.py:260`) with a call to it.
- Give the Python `local_iso` `ship` step (`workflow_ops.py:999-1002`) real behavior:
  merge the worktree branch into the detected trunk (fetch/checkout trunk/merge
  `--no-ff`/push if a remote exists, else just merge locally when there is no `origin`),
  mirroring `adw_ship_iso.py::manual_merge_to_main` but generalized and shared via a new
  `adw_modules/merge_ops.py` helper used by both `adw_ship_iso.py` and
  `run_local_workflow`'s `ship` step.
- Give the GitHub `*_iso.py` composites (that are not already part of a ZTE-style chain
  ending in `adw_ship_iso.py`) an explicit final "ship" invocation too, so a plain
  `adw_plan_build_iso.py` run also lands on trunk instead of stopping at an open PR.
  Concretely: after `finalize_git_operations` succeeds, each `*_iso.py` composite's
  `main()` calls the shared merge helper (or, if it prefers to stay PR-based, calls
  `git_ops.merge_pr` via `gh pr merge` — the plan defers this design choice to the
  Step-by-Step Tasks section, defaulting to local `git merge` for parity with
  `adw_ship_iso.py`).
- Add a new terminal `merge` step (data-defined, following the existing
  `on_success`/`on_failure` edge pattern used by `plan_build_review_fix`'s `fix` branch)
  to every `RepoBuilder.WorkflowEngine.Catalog` type that uses
  `isolation_mode: :worktree`, implemented as a new "deterministic Elixir step" kind in
  `Runner` (not a harness-driven session step) that calls a new
  `RepoBuilder.Projects.Worktree.merge/2` context function performing the trunk-aware
  merge, and updates `workflow_runs` status/fields accordingly. Direct-mode
  (`isolation_mode: nil`) workflows are already working on the trunk checkout directly
  and need no merge step — the plan documents this exemption explicitly with a short
  rationale.
- Keep `RepoBuilder.Adw.Scaffold`/`adws/adw_new.py` byte-parity intact: any new `ship`
  templating logic added to `adw_new.py` must be mirrored in `Scaffold.render_iso/2`
  and covered by the existing parity test in `test/repo_builder/adw/combos_test.exs`.

## Relevant Files
Use these files to implement the feature:

- `BUILD_PROMPT.md` — §7 (Workflow/ADW Engine: step-as-data model, `on_success`/
  `on_failure` edges, durable transition contract, Oban for retriable side effects), §4
  (canonical harness event contract — clarifies that a new "Elixir-native step kind"
  is a deliberate departure from the harness-session pipe), §10 (open-registry
  extensibility pattern, useful precedent for gating merge behavior by
  `isolation_mode`/a new `:mergeable` flag), §3 (typed style guide — `@spec` everywhere,
  tagged tuples, no raising on the expected path), §8 (context modules own all I/O).
- `README.md` — project overview/run instructions, for the Validation Commands section.
- `AGENTS.md` — contributor conventions / five-command green gate, if present.
- `adws/adw_ship_iso.py` — the only current merge implementation
  (`manual_merge_to_main`, lines 58-147); source of the hardcoded `"main"` literals
  (lines 94, 103, 125) to fix, and the template for the new shared merge helper.
- `adws/adw_modules/workflow_ops.py` — `run_local_workflow` (lines 830-1047), especially
  the no-op `ship` branch (lines 999-1002) that needs real merge behavior, and
  `_local_setup_worktree` (line 790).
- `adws/adw_modules/local_ops.py` — confirmed to have zero git/merge logic (run.json
  launch-record contract only); referenced for context, not modified unless the run
  record needs a new `merged_sha`/`merge_status` field.
- `adws/adw_modules/git_ops.py` — git primitives (`get_current_branch`, `push_branch`,
  `commit_changes`, `finalize_git_operations` at line 260 with its own `!= "main"`
  hardcode, `merge_pr`/`approve_pr` via `gh pr merge`). New `get_trunk_branch` helper
  belongs here.
- `adws/adw_modules/worktree_ops.py` — `create_worktree` (lines 15-78), whose
  `for base in ("origin/main", "main", "master"):` fallback chain (line 59) must be
  replaced with a call to the new trunk-detection helper (with `dev` correctly
  resolving).
- `adws/adw_sdlc_zte_iso.py` — the ZTE chain and the only current invoker of
  `adw_ship_iso.py` (lines 190-217); confirms the "ship gated on tests+review passing"
  precedent the plan's new merge steps should imitate for failure handling.
- `adws/adw_modules/data_types.py` — registry of workflow/script names (lines ~37, 47-48,
  182, 211) that may need a new entry if a shared merge helper module is registered
  there, and to confirm `"main"` appears elsewhere only as an unrelated `ModelTier`
  literal (not a branch name) so it is not touched.
- `adws/adw_new.py` — `make_script`, the generator whose ship/merge templating for new
  scaffolded scripts must stay in parity with `RepoBuilder.Adw.Scaffold`.
- `lib/repo_builder/adw/scaffold.ex`, `lib/repo_builder/adw/combo.ex`,
  `lib/repo_builder/adw/combos.ex` — Elixir scaffolding generator for new Python ADW
  scripts (`Scaffold.render_iso/2`, `iso_step_block/1`); must mirror any `adw_new.py`
  ship-step template changes to keep the byte-parity golden test green.
- `lib/repo_builder/workflow_engine/catalog.ex` — `Catalog.types/0`/`Catalog.steps/2`,
  where new terminal `merge` steps are added as data (edges) to
  `plan_build`, `plan_build_review`, `plan_build_review_fix`,
  `spec_implement_test_review` for `isolation_mode: :worktree` runs.
- `lib/repo_builder/workflow_engine/runner.ex` — `Runner` GenServer; `handle_continue(:run_step, ...)`
  currently always starts a harness `Session` (lines ~113-136) — needs a new branch for
  a deterministic (non-harness) `merge` step kind, `maybe_record_worktree/1` (lines
  144-159) for context on the existing `worktree_path`/`worktree_branch` persistence,
  and `handle_info/2` (lines 169-182) for how step completion currently drives
  `advance/2` (the merge step must follow the same durable-transition contract).
- `lib/repo_builder/projects/worktree.ex` — `checkout/2`, `provision/3` (line 76,
  `:default_branch` opts seam), `current_branch/1` (line 97-109, the git primitive
  pattern to extend into `detect_trunk/1`); new `merge/2` function belongs here, keeping
  all git I/O inside this context module per BUILD_PROMPT.md §8.
- `lib/repo_builder/projects/profiler.ex` — `git_metadata/1` (lines 87-93), the other
  existing consumer of `branch --show-current`; may be worth switching to the new
  `detect_trunk/1` helper for a more correct `Project.default_branch`, noted as an
  optional improvement, not required scope.
- `lib/repo_builder/projects/project.ex` — `Project.default_branch` field/type
  definition, referenced when deciding whether the merge step should default to this
  stored value or always re-detect live.
- `lib/repo_builder/workflows.ex` — context module wrapping `workflow_runs`
  (`worktree_path`/`worktree_branch` persistence, comment at line 94 about "UI's
  PR/merge handoff"); needs new fields/functions if merge status/SHA is persisted per
  run.
- `lib/repo_builder_web/live/projects_live.ex` — lines 551-552 currently render
  `run.worktree_branch` as passive text; update to also show merge status (e.g.
  "merged into dev @ `<sha>`" vs "unmerged branch").
- `priv/repo/migrations/` — likely needs a new migration adding `merged_sha`/
  `merge_status`/`merge_error` columns to `workflow_runs` (follow existing migration
  conventions, binary_id PKs, see the most recent migration file for style).
- `test/repo_builder/adw/combos_test.exs` — existing scaffold/parity test; extend if
  the `ship` template changes.
- `test/repo_builder/workflow_engine/catalog_test.exs`,
  `test/repo_builder/workflow_engine/runner_cwd_test.exs` — existing native-engine
  tests to extend with merge-step coverage.
- `adws/adw_tests/` — Python test directory (no current `test_ship*.py`/
  `test_merge*.py`); new tests belong here, following the mocking conventions of
  existing files like `test_local_ops.py`.

### New Files
- `adws/adw_modules/merge_ops.py` — shared trunk-aware merge helper
  (`get_trunk_branch`, `merge_branch_into_trunk`) used by `adw_ship_iso.py` and
  `run_local_workflow`'s `ship` step; consolidates what is currently duplicated/hardcoded
  logic in `adw_ship_iso.py::manual_merge_to_main` and `worktree_ops.py`'s fallback list.
- `adws/adw_tests/test_merge_ops.py` — unit tests for the new merge helper (mocking
  `subprocess`/`git`/`gh` calls): trunk detection via `symbolic-ref`, fallback when no
  remote exists, merge conflict surfaced as `(False, error)`, branch restoration on
  failure.
- `adws/adw_tests/test_ship_iso_trunk_detection.py` — regression test proving
  `adw_ship_iso.py` no longer hardcodes `"main"` and instead calls the shared helper
  (mock `get_trunk_branch` to return `"dev"` and assert `git checkout dev` /
  `git pull origin dev` / `git push origin dev` are invoked).
- `priv/repo/migrations/<timestamp>_add_merge_fields_to_workflow_runs.exs` — adds
  `merge_status` (enum-like string: `unmerged | merged | failed`), `merged_sha`,
  `merge_error` columns to `workflow_runs`.
- `test/repo_builder/projects/worktree_merge_test.exs` — unit tests for
  `Worktree.detect_trunk/1` and `Worktree.merge/2` (dynamic trunk detection against a
  real temp git repo fixture, successful merge, conflict/failure path,
  no-remote-vs-remote push behavior).
- `test/repo_builder_web/live/test_workflow_merge_status_test.exs` — LiveView
  integration test driving a `:worktree`-isolation workflow run to completion and
  asserting the merge step executes, `workflow_runs.merge_status` becomes `merged`, and
  the ConsoleLive/ProjectsLive UI renders the merged status/SHA instead of a bare branch
  name.

## Implementation Plan
### Phase 1: Foundation — shared trunk detection
Build the dynamic trunk-detection primitive in both languages before touching any
merge/ship call sites, since every subsequent change depends on it. Python:
`adw_modules/git_ops.py::get_trunk_branch(cwd) -> str`, preferring (in order)
`git symbolic-ref refs/remotes/origin/HEAD` (strips `refs/remotes/origin/`), falling
back to `git remote show origin | grep "HEAD branch"`, falling back to
`git branch --show-current` if there is no `origin` remote at all (offline/local-only
repos), and finally `"main"` only as a last-resort constant if none of the above
resolve (documented as a deliberate degrade-to-historical-default, not a silent
failure). Elixir: `RepoBuilder.Projects.Worktree.detect_trunk/1`, same precedence,
implemented via `System.cmd/3`, returning `{:ok, branch}` / `{:error, reason}` per the
typed style guide (no raising). Add unit tests for both immediately (temp git repo
fixtures) before any caller is changed.

### Phase 2: Core Implementation — merge behavior per non-iso workflow class
2a. Python: build `adw_modules/merge_ops.py` (`merge_branch_into_trunk(branch_name,
cwd, logger) -> (bool, Optional[str])`) generalizing `adw_ship_iso.py`'s
`manual_merge_to_main`, parameterized on the detected trunk instead of the literal
`"main"`, and handling the no-remote case (skip `fetch`/`pull`/`push`, just local
merge) for fully offline repos. Rewire `adw_ship_iso.py` to call it. Rewire
`worktree_ops.py::create_worktree`'s fallback chain to try `origin/<trunk>`, `<trunk>`,
then the historical `main`/`master` literals last (preserves backward compatibility for
repos that really are named `main`). Fix `git_ops.py:260`'s `!= "main"` guard to compare
against the detected trunk.
2b. Python: replace `run_local_workflow`'s no-op `ship` step (`workflow_ops.py:999-1002`)
with a real call to `merge_ops.merge_branch_into_trunk`, persisting the resulting
`merged_sha`/error onto the `run.json` record (extend `local_ops.py`'s state schema
with `merge_status`/`merged_sha` fields, following its existing `update_state`-style
functions).
2c. Python: for the GitHub `*_iso.py` composites (`adw_build_iso.py`,
`adw_plan_build_iso.py`, `adw_plan_build_review_iso.py`, etc.) that are not already
chained by `adw_sdlc_zte_iso.py` into `adw_ship_iso.py`, add an explicit final call to
the shared merge helper (or `git_ops.merge_pr`, decided per composite based on whether
it already has an open PR) after `finalize_git_operations` succeeds, so a standalone
run of any of these composites also lands on trunk. Gate this behind the same
test/review-passing checks the ZTE chain already uses.
2d. Elixir: add a new `merge` step kind to `WorkflowEngine.Catalog.steps/2` for every
type with `isolation_mode: :worktree`, appended as the final `on_success` edge
(mirroring the existing `fix`-branch edge pattern in `plan_build_review_fix`). Add
`RepoBuilder.Projects.Worktree.merge/2` (fetch/checkout trunk/merge `--no-ff`/push,
returning `{:ok, %{sha: sha}} | {:error, reason}`), reusing `detect_trunk/1` from
Phase 1.
2e. Elixir: extend `Runner` with a deterministic-step execution path: when a step's
`kind` (new field on the step map, defaulting to `:harness` for backward compatibility)
is `:merge`, `handle_continue(:run_step, ...)` calls `Worktree.merge/2` directly instead
of starting a harness `Session`, then synchronously drives the same `advance/2`
transition + `workflow_runs` persistence that `handle_info/2` uses for harness-driven
steps (satisfying BUILD_PROMPT.md §7's "persist before advance" durable-transition
rule).

### Phase 3: Integration — persistence, UI, and generator parity
Add the `merge_status`/`merged_sha`/`merge_error` migration and wire it through
`RepoBuilder.Workflows` (context functions to read/update these fields). Update
`ProjectsLive`/`ConsoleLive` to render merge outcome instead of a bare branch name.
Update `RepoBuilder.Adw.Scaffold.render_iso/2`/`iso_step_block/1` (and, in Python,
`adw_new.py::make_script`) so newly scaffolded ADW scripts get the corrected
merge-helper-based `ship` step template rather than the old hardcoded-`"main"`/no-op
templates — keep the combos byte-parity golden test green
(`test/repo_builder/adw/combos_test.exs`, `test/support/fixtures/adw/*.golden`).

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Trunk detection primitives
- Implement `adw_modules/git_ops.py::get_trunk_branch` with the fallback precedence
  described in Phase 1.
- Write `adws/adw_tests/test_merge_ops.py`'s trunk-detection cases first (TDD), covering:
  symbolic-ref success, `origin` present but symbolic-ref missing (falls back to
  `remote show origin`), no `origin` remote (falls back to `branch --show-current`), and
  the last-resort `"main"` default.
- Implement `RepoBuilder.Projects.Worktree.detect_trunk/1` with the same precedence via
  `System.cmd/3`; add `@spec detect_trunk(Path.t()) :: {:ok, String.t()} | {:error, term()}`.
- Write `test/repo_builder/projects/worktree_merge_test.exs`'s `detect_trunk/1` cases
  against a real temp git repo fixture built in test setup (mirrors existing
  `Worktree` test conventions).

### 2. Shared Python merge helper
- Create `adws/adw_modules/merge_ops.py` with `merge_branch_into_trunk/3`, generalizing
  `adw_ship_iso.py::manual_merge_to_main` to accept a `trunk_branch` parameter (from
  `get_trunk_branch`) and to skip fetch/pull/push when no `origin` remote exists.
- Finish `test_merge_ops.py`'s merge-behavior cases: successful merge, merge conflict
  surfaced as `(False, error_message)` with original branch restored, no-remote local-only
  merge path.
- Rewire `adw_ship_iso.py` to call `merge_ops.merge_branch_into_trunk` instead of its
  inline `manual_merge_to_main`, passing the detected trunk. Delete the now-dead
  `manual_merge_to_main` body (or keep as a thin wrapper if other callers exist — grep
  first).
- Write `adws/adw_tests/test_ship_iso_trunk_detection.py` proving `adw_ship_iso.py` no
  longer hardcodes `"main"`.
- Update `worktree_ops.py::create_worktree`'s fallback chain to prefer
  `origin/<detected_trunk>` / `<detected_trunk>` before the legacy `main`/`master`
  literals.
- Fix `git_ops.py:260`'s `finalize_git_operations` guard to compare against the detected
  trunk, not the literal `"main"`.

### 3. Python local_iso ship step becomes a real merge
- Replace `workflow_ops.py`'s no-op `elif step == "ship":` branch (lines 999-1002) with a
  call to `merge_ops.merge_branch_into_trunk`, capturing success/failure into the
  `run.json` state (extend `local_ops.py` with `merge_status`/`merged_sha` fields and an
  `update_merge_result`-style helper, following existing `local_ops.py` update-function
  patterns).
- Add/extend a Python test (in `adws/adw_tests/`, e.g. `test_workflow_ops_ship.py` or
  extend `test_local_ops.py`) asserting `run_local_workflow`'s `ship` step now performs
  and records a real merge, mocking `merge_ops.merge_branch_into_trunk`.

### 4. GitHub `*_iso.py` composites ship on their own
- Audit which `*_iso.py` composites are reachable only standalone (not already chained
  by `adw_sdlc_zte_iso.py`) and add a final merge/ship call after
  `finalize_git_operations` succeeds and tests/review (if present in that composite's
  step list) pass. Gate identically to the ZTE chain's existing pass/fail checks.
- Extend or add Python tests covering at least one representative composite's new
  ship-on-success and skip-ship-on-test-failure behavior.

### 5. Elixir native engine: data-defined `merge` step
- Add a `kind` field to the step-map type used by `Catalog.steps/2` (default `:harness`,
  new value `:merge`), updating `@type` definitions and any `@spec`s referencing the step
  map shape.
- Add a terminal `merge` step + `on_success`/`on_failure` edges to `plan_build`,
  `plan_build_review`, `plan_build_review_fix`, and `spec_implement_test_review` for
  `isolation_mode: :worktree` runs only; leave `isolation_mode: nil` (direct-mode)
  workflows untouched with a one-line moduledoc/comment explaining why (already on
  trunk).
- Extend `test/repo_builder/workflow_engine/catalog_test.exs` to assert the new `merge`
  step/edges appear for worktree-isolated types and are absent for direct-mode.

### 6. Elixir native engine: deterministic step execution + merge context function
- Implement `RepoBuilder.Projects.Worktree.merge/2` (`@spec merge(Path.t(), keyword()) ::
  {:ok, %{sha: String.t()}} | {:error, term()}`), reusing `detect_trunk/1`.
- Extend `Runner.handle_continue(:run_step, ...)` to branch on step `kind`: `:merge`
  calls `Worktree.merge/2` synchronously instead of starting a harness `Session`, then
  performs the same persist-then-advance sequence as the harness-driven path.
- Extend `test/repo_builder/workflow_engine/runner_cwd_test.exs` (or add a new
  `runner_merge_test.exs`) covering: successful merge advances to `:done` and persists
  `merge_status: "merged"` + `merged_sha`; merge failure advances via `on_failure` and
  persists `merge_status: "failed"` + `merge_error`.

### 7. Persistence + UI wiring
- Add migration `priv/repo/migrations/<timestamp>_add_merge_fields_to_workflow_runs.exs`
  (`merge_status`, `merged_sha`, `merge_error` on `workflow_runs`).
- Extend `RepoBuilder.Workflows` with typed accessor/update functions for the new
  fields.
- Update `lib/repo_builder_web/live/projects_live.ex` (and `ConsoleLive` if it also
  renders worktree branches) to show merge status/SHA instead of a bare branch string.
- Add `test/repo_builder_web/live/test_workflow_merge_status_test.exs`: mount the
  LiveView, drive (or seed) a `:worktree`-isolation workflow run through completion,
  assert `merge_status` becomes `"merged"` and the rendered markup reflects it (and that
  the canonical PubSub event for run completion still fires as before).

### 8. Generator parity (Elixir Scaffold + Python adw_new.py)
- Update `adws/adw_new.py::make_script`'s `ship` step template to use the new
  `merge_ops`-based logic (for `:iso` flavor) and the real-merge `ship` behavior (for
  `:local_iso` flavor).
- Mirror the same template change in `lib/repo_builder/adw/scaffold.ex`
  (`render_iso/2`/`iso_step_block/1`).
- Regenerate/update the golden fixture
  `test/support/fixtures/adw/adw_plan_build_review_iso.py.golden` and confirm
  `test/repo_builder/adw/combos_test.exs`'s parity assertion still passes.

### 9. Full validation
- Run the full `Validation Commands` list below and fix any regression before
  considering the feature complete.

## Testing Strategy
### Unit Tests
- Python: `test_merge_ops.py` (trunk detection + merge behavior, mocked subprocess/git),
  `test_ship_iso_trunk_detection.py` (no hardcoded `"main"` regression),
  extended `test_local_ops.py`/`test_workflow_ops_ship.py` (local `ship` step now merges
  and records state).
- Elixir: `worktree_merge_test.exs` (`detect_trunk/1`, `merge/2` against a real temp git
  fixture — success, conflict, no-remote), `catalog_test.exs` (new `merge` step/edges
  present only for worktree isolation), `runner_merge_test.exs` (deterministic step
  execution path advances/persists correctly on both success and failure),
  `combos_test.exs` (scaffold parity still holds after template changes).

### Edge Cases
- Repo has no `origin` remote at all (fully local/offline) — merge must skip
  fetch/pull/push and still succeed locally.
- Repo's trunk really is named `main` (not `dev`) — detection and merge must still work
  (regression-proof the common case, not just this repo's `dev`).
- Merge conflict — must surface as `{:error, reason}` / `(False, message)`, restore the
  original branch, and drive the workflow to a failure/abort state (not silently succeed
  or hang).
- Worktree branch has zero commits ahead of trunk (no-op merge) — should still complete
  successfully without erroring on "nothing to merge."
- Concurrent ADW runs both targeting the same trunk branch — document as a known
  limitation (serialize via existing worktree/lock mechanisms if any exist; otherwise
  note as a follow-up, do not silently corrupt trunk).
- `adw_ship_iso.py` invoked directly (not via ZTE) on a repo whose trunk is `dev` —
  must succeed post-fix where it previously would have failed/misbehaved.
- Direct-mode (`isolation_mode: nil`) Elixir workflows — confirm no merge step is
  injected and no regression to their existing behavior.

## Acceptance Criteria
- No git-operation call site anywhere in `adws/` or `lib/` hardcodes the literal branch
  name `"main"` without going through the shared trunk-detection helper (the only
  allowed exception is the documented last-resort default inside the helper itself).
- Running any `*_local_iso.py` workflow to completion results in its worktree branch
  being merged into the repo's actual trunk (verified against a test repo whose trunk is
  `dev`), not left stranded, with `run.json` reflecting `merge_status: "merged"` and a
  `merged_sha`.
- Running any standalone `*_iso.py` composite (not chained via ZTE) to completion also
  results in a merge into trunk (or a documented, intentional PR-based alternative if
  that design is chosen in Task 4), not merely an open, unmerged PR.
- Every `RepoBuilder.WorkflowEngine.Catalog` type using `isolation_mode: :worktree`
  ends with a `merge` step that lands the worktree branch on trunk, persists
  `merge_status`/`merged_sha`/`merge_error` on `workflow_runs`, and surfaces the outcome
  in the LiveView UI.
- Direct-mode (`isolation_mode: nil`) Elixir workflows are unaffected (no merge step
  added, no behavior change).
- All new and existing tests pass; the combos byte-parity golden test remains green
  after generator template updates.
- `mix compile --warnings-as-errors`, `mix test --warnings-as-errors`,
  `mix format --check-formatted`, `mix credo --strict`, and `mix dialyzer` all pass with
  zero new warnings.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix test test/repo_builder/projects/worktree_merge_test.exs` - validate trunk
  detection and merge context function.
- `mix test test/repo_builder/workflow_engine/catalog_test.exs` - validate new `merge`
  step/edges are present only for worktree-isolated types.
- `mix test test/repo_builder/workflow_engine/runner_merge_test.exs` - validate the
  deterministic merge step executes and persists correctly on success/failure.
- `mix test test/repo_builder/adw/combos_test.exs` - validate scaffold/generator parity
  still holds.
- `mix test test/repo_builder_web/live/test_workflow_merge_status_test.exs` - validate
  the LiveView renders merge outcome for a completed worktree-isolated run.
- `cd adws && uv run pytest adw_tests/test_merge_ops.py adw_tests/test_ship_iso_trunk_detection.py -v` -
  validate Python trunk detection and merge helper behave correctly, including the
  no-hardcoded-`"main"` regression test.
- `cd adws && uv run pytest adw_tests/ -v` - full Python ADW test suite, zero
  regressions.
- `mix compile --warnings-as-errors` - Compile clean; the gradual set-theoretic type
  checker and `warnings_as_errors` must pass.
- `mix test --warnings-as-errors` - Run the full ExUnit suite (spawns Postgres-backed
  cases) with zero failures.
- `mix format --check-formatted` - Ensure code is formatted.
- `mix credo --strict` - Lint, including the "every public function has an `@spec`"
  convention.
- `mix dialyzer` - `@spec`/contract checking with no new warnings and no stale ignore
  filters.

## Notes
- No new dependency is required for this feature — all git operations use the existing
  `System.cmd/3` (Elixir) and `subprocess`/`git`/`gh` CLI (Python) patterns already used
  by `Worktree` and `git_ops.py`/`worktree_ops.py`.
- Design decision deferred to implementation time (flagged explicitly in Task 4): for
  standalone GitHub `*_iso.py` composites, whether "ship" means a local `git merge`
  (parity with `adw_ship_iso.py`) or a `gh pr merge` via the already-implemented but
  currently-unused `git_ops.merge_pr`. Recommend defaulting to local merge for
  consistency with the ZTE chain's behavior, but note `merge_pr` as a lower-risk
  alternative (respects branch protection / required reviews on GitHub) worth discussing
  with the operator before implementation.
- The new Elixir `:merge` step kind is a deliberate, explicit departure from
  `Runner`'s existing "every step is a harness session" assumption (BUILD_PROMPT.md §4)
  — implementers should double check no other code (e.g. cost/telemetry aggregation
  that assumes every step produced a harness `Event`) implicitly assumes step
  homogeneity before wiring this in.
- Concurrent-merge safety (two ADW runs merging into the same trunk simultaneously) is
  explicitly out of scope for this plan beyond documenting it as a known limitation;
  revisit if it becomes a real operational issue.
- Use Tidewave's `project_eval`/`execute_sql_query` during implementation to verify
  `workflow_runs.merge_status`/`merged_sha` land correctly against the live dev database
  after a real worktree-isolated run, and `get_logs` to inspect any merge-step failures
  surfaced through the harness event pipe.
