# Bug: No takeover path onto an existing `adw/*` worktree — fresh workers can't continue a prior worker's branch, forcing risky over-limit continuations

## Metadata
issue_number: `worktree-takeover`
adw_id: `takeover`
issue_json: `n/a` (freeform bug report — fresh orchestrator workers cannot see the adw/* worktree branch of a prior worker, forcing same-worker continuations near the context limit; the worker then dies uncommitted and the work is lost)

## Bug Description
When a worktree-isolated worker needs to be replaced (context limit approaching,
crash, harness swap), the orchestrator cannot spawn a fresh worker that continues
on the prior worker's `adw/<run_id>` worktree/branch. The worktree key is derived
inside the session runtime as `opts[:run_id] || opts[:agent_id] || session_id`
(`RepoBuilder.Session.Server.maybe_worktree/4`, `session/server.ex:1442-1453`),
and the orchestrator dispatch path (`AgentOps.command_agent/2`,
`agent_ops.ex:146-164`) never passes `:run_id` — so every worker's worktree is
keyed on its **own** agent id. There is no `create_agent`/dispatch argument to
target an existing worktree run id, and even if the key matched,
`Worktree.provision/3` (`worktree.ex:328-344`) cannot re-attach after teardown:
the tree dir is removed on session exit while the branch is kept
(`cleanup/1`, "The branch is kept"), and a re-checkout runs
`git worktree add <path> -b adw/<run_id> <base>` — which **fails** because `-b`
refuses to create a branch that already exists.

**Observed incident (evidence trail):** task ledger
`3655aaf1-d4c9-4e0e-88c0-d1f87a03967f` (2026-07-05, orchestrator `6b5d8aaa…`).
Progress entries at 14:00:55 and 14:14:27 both record the orchestrator resuming
the SAME worker with the explicit rationale "fresh worker can't see its adw/*
worktree branch". Boxed in, it kept riding `cancel-implementer-claude` ever
closer to the context ceiling; at 14:27 the worker retired at the limit without
committing and the entire ADWS-tab-cancel implementation was lost (branch
`adw/d6d8c38a…` still identical to `dev`).

**Expected:** the handover protocol's own contract — "a fresh worker continues
from your document" (`Handover.protocol_clause/0`) — is honorable for
worktree-isolated work: the orchestrator spawns a replacement worker that lands
in the SAME `adw/<run_id>` worktree/branch and picks up where the retiree left off.

**Actual:** a replacement worker always gets a brand-new worktree/branch based
off the trunk; the prior branch is invisible to it, so "continue the work" is
only possible by resuming the dying worker.

## Problem Statement
The worktree run key is an internal fallback chain the orchestrator cannot
influence, and the provisioning function cannot re-attach to a kept `adw/*`
branch after its tree was removed. Together these make worker replacement —
the core move of the context-limit handover protocol — impossible for
worktree-isolated work, which is the platform's default isolation mode
(`Projects.default_isolation()` ships `:worktree`).

## Solution Statement
Add a supported **takeover** path along the existing seams, in two halves:

1. **Re-attachable provisioning (`Worktree.provision/3`).** When the worktree dir
   is absent but the branch `adw/<run_id>` already exists
   (`git rev-parse --verify --quiet refs/heads/adw/<run_id>` succeeds), provision
   with `git worktree add <path> <branch>` (attach, no `-b`) instead of
   `-b <branch> <base>`. This makes `Worktree.checkout/2` idempotent across the
   full lifecycle (dir present → reuse; dir gone + branch kept → re-attach;
   neither → create), preserving all prior commits on the branch.
2. **Operator-facing takeover key (`create_agent` → dispatch → session).** Add an
   optional `"worktree_run_id"` string argument to the `create_agent` tool:
   - validated up front (non-empty, path/branch-safe charset `^[A-Za-z0-9._-]+$`
     — it becomes both a scratch-dir segment and a branch suffix), stored on the
     worker's `config` exactly like the existing `"isolation"` override;
   - threaded at dispatch time: `command_agent/2` adds
     `run_id: worker.config["worktree_run_id"]` (nil-safe — absent key keeps
     today's `agent_id` fallback) to the `Session.Supervisor.start_session/1`
     opts, which `maybe_worktree/4` already prefers first in its fallback chain;
   - documented in the tool catalog so the brain knows the recipe: to continue a
     retired worker's work, pass the retired worker's agent id (its worktree key)
     as `worktree_run_id` on the replacement worker.

No schema migration (the key rides in the existing `config` JSONB like
`"isolation"`), no new dependency, zero behavior change when the argument is
omitted.

## Steps to Reproduce
1. Provision + tear down a worktree the way a worker session does
   (Tidewave `project_eval` or IEx):
   ```elixir
   {:ok, info} = RepoBuilder.Projects.Worktree.checkout(repo_root, run_id: "takeover-1")
   # commit something on the branch, then simulate session teardown:
   :ok = RepoBuilder.Projects.Worktree.cleanup(info)
   # dir gone, branch adw/takeover-1 kept — now try to continue:
   RepoBuilder.Projects.Worktree.checkout(repo_root, run_id: "takeover-1")
   ```
   **Before the fix:** `{:error, "fatal: a branch named 'adw/takeover-1' already exists"}`.
2. Orchestrator level: spawn worker A with worktree isolation, let it work, retire
   it; call `create_agent` for a replacement — there is no argument that can point
   worker B at worker A's worktree; B's session lands in
   `<scratch>/<B-agent-id>` on `adw/<B-agent-id>` off the trunk.
3. Historical trail: `select inserted_at, summary from progress_entries where
   task_ledger_id = '3655aaf1-d4c9-4e0e-88c0-d1f87a03967f' order by inserted_at;`
   — the 14:00:55 / 14:14:27 entries name the constraint verbatim.

## Root Cause Analysis
- **Key derivation is closed.** `maybe_worktree/4` prefers `opts[:run_id]`, but
  the only caller that sets `:run_id` is the WorkflowEngine Runner path; the
  orchestrator worker dispatch (`command_agent/2`) builds its opts without it, so
  the fallback (`opts[:agent_id]`) always wins and the key is the worker's own id.
  Nothing in `create_agent`'s validated argument surface
  (`agent_ops.ex:54-94`, catalog schema in `tool_catalog.ex`) can override it.
- **Provisioning can't re-attach.** `provision/3` has exactly two cases: dir
  exists (reuse) or `worktree add -b` (create-new-branch). The teardown contract
  deliberately keeps the branch (`cleanup/1` doc, `session/server.ex:1476`
  "keeping the branch for review") — but that kept branch then *blocks* the `-b`
  re-creation. The two halves of the lifecycle contradict each other.
- **Design gap, not regression:** worktree isolation (agentic-layer adaptor
  Phase 4) was built around one-worker-one-run; the graceful-handover protocol
  (fresh worker continues from the doc) arrived later and its worktree
  implication was never wired. The orchestrator discovered the gap at runtime and
  worked around it with same-worker continuations — the risky pattern that lost
  the work.

## Relevant Files
Use these files to fix the bug:

- `lib/repo_builder/projects/worktree.ex` — `provision/3` (line 328) gains the
  branch-exists re-attach case; add a private `branch_exists?/2` using the
  existing `git/2` runner. `checkout/2`'s `@doc` gains the re-attach clause.
- `lib/repo_builder/orchestrator/tools/agent_ops.ex` — `create_agent/2`
  (line 54): validate + persist `"worktree_run_id"` (mirror
  `validate_isolation/1` at line 838 and `maybe_put_isolation/2` at line 849).
  `command_agent/2` (line 146): add `run_id:` to the session opts from
  `worker.config["worktree_run_id"]`.
- `lib/repo_builder/orchestrator/tool_catalog.ex` — `create_agent` tool schema
  (near the existing `"isolation"` property at line 72) gains the
  `"worktree_run_id"` property with the takeover recipe in its description.
- `lib/repo_builder/session/server.ex` — **reference only**: `maybe_worktree/4`
  (line 1442) already prefers `opts[:run_id]`; no change needed.
- `lib/repo_builder/agents/handover.ex` — `retired_resume_prompt/2` (line 122):
  one-sentence addition telling the orchestrator that a worktree-isolated
  retiree's branch is continuable by spawning the fresh worker with
  `worktree_run_id: <retired worker's agent id>`.
- `test/repo_builder/projects/worktree_test.exs` — provisioning lifecycle tests;
  the re-attach regression case lands here.
- `test/repo_builder/orchestrator/tools_test.exs` — `create_agent` argument
  validation tests (isolation precedent); extend for `worktree_run_id`.
- `test/repo_builder/orchestrator/tool_manifest_snapshot_test.exs` +
  `test/support/fixtures/orchestrator/tool_manifest.json` — the catalog snapshot
  pins tool schemas; regenerate/extend the fixture for the new property.
- `test/repo_builder/agents/handover_test.exs` — prompt-contract tests; extend
  `retired_resume_prompt/2` assertion.
- `ai_docs/typed-elixir-standard.md` — typed standard for the new/changed
  functions (`@spec` on every public function; wire strings validated at the
  boundary, never `String.to_atom/1`).

### New Files
None — all changes land in existing modules, tests, and the manifest fixture.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. `Worktree.provision/3` — re-attach to a kept branch
- In `lib/repo_builder/projects/worktree.ex`, add
  `@spec branch_exists?(String.t(), String.t()) :: boolean()` — `git/2` with
  `["rev-parse", "--verify", "--quiet", "refs/heads/" <> branch]`, exit 0 ⇒ true.
- In `provision/3`, keep the dir-exists reuse case first; then branch on
  `branch_exists?(repo_root, branch)`:
  - exists ⇒ `git(repo_root, ["worktree", "add", path, branch])` (attach);
  - absent ⇒ the existing `["worktree", "add", path, "-b", branch, base]`.
  Both return the same `{:ok, %{path, branch, repo}}` / `{:error, out}` shape.
- Update the `checkout/2` `@doc`: "idempotent across teardown — an existing
  worktree dir is reused; a kept `adw/*` branch whose dir was removed is
  re-attached with its commits intact."

### 2. `create_agent` — validated `worktree_run_id` argument
- In `agent_ops.ex`, add
  `@spec validate_worktree_run_id(map()) :: {:ok, String.t() | nil} | {:error, reason()}`:
  absent ⇒ `{:ok, nil}`; a string matching `~r/^[A-Za-z0-9._-]+$/` ⇒ `{:ok, id}`;
  anything else ⇒ a descriptive `{:error, …}` (it becomes a filesystem path
  segment and a git branch suffix — reject up front at the WireType boundary).
- Add the clause to `create_agent/2`'s `with` (beside `validate_isolation/1`) and
  persist via `maybe_put_worktree_run_id(config, id)` (mirror
  `maybe_put_isolation/2`) under `config["worktree_run_id"]`.

### 3. `command_agent` — thread the key into the session
- In the dispatch opts (`agent_ops.ex:146-164`), add
  `run_id: worktree_run_id(worker)` where the private helper reads
  `worker.config["worktree_run_id"]` (nil when absent/not a map — nil keeps the
  session runtime's existing `agent_id` fallback byte-identical).

### 4. Tool catalog + handover prompt
- In `tool_catalog.ex`, add the `"worktree_run_id"` string property to the
  `create_agent` schema beside `"isolation"`: "Continue an EXISTING adw/* worktree
  branch: pass the retired/prior worker's agent id (its worktree key). The new
  worker's sessions run in that worktree on that branch, with all prior commits.
  Omit for a fresh branch. Only meaningful with worktree isolation."
- In `handover.ex` `retired_resume_prompt/2`, append one sentence: "If the worker
  was worktree-isolated, spawn the replacement with `worktree_run_id` set to the
  retired worker's agent id so it continues the same `adw/*` branch."

### 5. Tests
- `test/repo_builder/projects/worktree_test.exs` — the core regression
  (fails before step 1, passes after): checkout run `takeover-1`, commit a file
  on the branch inside the worktree, `cleanup/1` (dir gone, branch kept),
  `checkout/2` again with the same run id ⇒ `{:ok, info}` with the SAME branch,
  dir re-created, and the committed file present (`git show`/`File.exists?`).
  Companion: a fresh run id still takes the `-b` create path.
- `test/repo_builder/orchestrator/tools_test.exs` — `create_agent` with
  `"worktree_run_id" => "abc-123"` stores it on the worker's config;
  `"worktree_run_id" => "../evil"` (and `""`) are rejected with `{:error, _}`;
  omitted leaves config unchanged. Dispatch-side: `command_agent` opts include
  `run_id: "abc-123"` for such a worker and `run_id: nil` otherwise (assert via
  the existing session-start capture pattern used by the isolation tests).
- `test/repo_builder/orchestrator/tool_manifest_snapshot_test.exs` — update
  `test/support/fixtures/orchestrator/tool_manifest.json` for the new
  `create_agent` property (run the snapshot test's regeneration path).
- `test/repo_builder/agents/handover_test.exs` — `retired_resume_prompt/2`
  mentions `worktree_run_id`.

### 6. Run the `Validation Commands`
- Execute every command in `Validation Commands`; all must pass.

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- `mix test test/repo_builder/projects/worktree_test.exs` — re-attach lifecycle
  (reproduces the `-b already exists` failure before the fix; proves takeover after).
- `mix test test/repo_builder/orchestrator/tools_test.exs` — `create_agent`
  validation + dispatch threading.
- `mix test test/repo_builder/orchestrator/tool_manifest_snapshot_test.exs` —
  catalog snapshot in sync.
- `mix test test/repo_builder/agents/handover_test.exs` — retirement prompt names
  the takeover recipe.
- `mix compile --warnings-as-errors` - Compile clean; the gradual set-theoretic type checker and `warnings_as_errors` must pass.
- `mix test --warnings-as-errors` - Run the full ExUnit suite (spawns Postgres-backed cases) with zero failures.
- `mix format --check-formatted` - Ensure code is formatted.
- `mix credo --strict` - Lint, including the "every public function has an `@spec`" convention.
- `mix dialyzer` - `@spec`/contract checking with no new warnings and no stale ignore filters.

## Notes
- **Companion bugs from the same incident (separate plans, complementary fixes):**
  `specs/issue-worktree-loss-adw-safecommit-sdlc_planner-preserve-uncommitted-worktree-work.md`
  (safety-commit dirty worktrees on teardown — makes the kept branch actually
  carry the work this takeover path re-attaches to) and
  `specs/issue-rate-limit-stall-adw-transientstall-sdlc_planner-exempt-transient-provider-errors-from-stall-budget.md`.
  This plan is independently landable; together the three close the loss chain.
- **Concurrent takeover is out of scope:** two live workers sharing one worktree
  would fight over the working tree. The takeover recipe (in the catalog
  description and the retirement prompt) is worded for a REPLACEMENT worker after
  the prior one retired; enforcing single-occupancy at spawn time (e.g. rejecting
  a `worktree_run_id` whose worktree is attached to a live session) is a possible
  follow-up, not part of the minimal fix.
- The charset guard on `worktree_run_id` is the typed WireType→DomainType boundary
  for this feature: the raw string reaches `Path.join/2` and a `git` argv, so it
  is validated once at the tool boundary and treated as opaque after.
- `Worktree.checkout/2` re-attach also benefits the WorkflowEngine resume path
  (same `provision/3`), where a resumed run whose worktree dir was pruned
  currently hits the same `-b` failure.
- No LiveView/UI surface changes — no LiveView integration test required.
