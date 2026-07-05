# Bug: Worktree session teardown silently discards uncommitted worker output (`git worktree remove --force`)

## Metadata
issue_number: `worktree-loss`
adw_id: `safecommit`
issue_json: `n/a` (freeform bug report — worktree-isolated ADW implementer workers can retire at context limit without ever committing, losing the entire implementation)

## Bug Description
A worktree-isolated worker (project `isolation_mode: :worktree`, or an explicit
per-worker `isolation: "worktree"` override) does all of its work inside
`<scratch>/<run_id>` on branch `adw/<run_id>`. When the session ends — for ANY
reason: graceful `:handover` retirement, `force_retire`, `delete_agent`,
`stop_session/1`, or a crash — `RepoBuilder.Session.Server.terminate/2` calls
`cleanup_workspace/1` (`lib/repo_builder/session/server.ex:752`, clause at `:1478`),
which delegates to `RepoBuilder.Projects.Worktree.cleanup/1`
(`lib/repo_builder/projects/worktree.ex:47`). That function runs

```
git worktree remove --force <path>
```

`--force` removes the tree **even when it contains uncommitted modifications and
untracked files** — everything not yet committed to `adw/<run_id>` is destroyed.
The docstring claims "The branch is kept", which is true but vacuous when the worker
never committed: the kept branch is identical to its base.

**Observed incident (evidence trail):** task ledger
`3655aaf1-d4c9-4e0e-88c0-d1f87a03967f` (2026-07-05, orchestrator `6b5d8aaa…`).
Worker `cancel-implementer-claude` (claude-opus-4-8) completed the full ADWS-tab
cancel spec implementation in `/tmp/rb_worktrees/d6d8c38a-dd84-4df4-aebe-4b7a9906ff71`
— per the orchestrator's harvest: implementation done, `mix format`/`credo` green,
12 new tests green. It then hit its context limit and was retired **without ever
committing**. The orchestrator verified via refs/reflog that branch
`adw/d6d8c38a-dd84-4df4-aebe-4b7a9906ff71` was still identical to `dev`
("Created from dev" only). The worktree directory was force-removed on session
teardown; the entire implementation was lost and the ledger escalated. The three
orphaned `adw/*` branches still in this repo (`git branch --list 'adw/*'`), all
pointing exactly at `dev` HEAD, are the fossil record.

**Expected:** work performed in an isolated worktree survives session teardown —
the whole point of the `adw/<run_id>` branch is to be the durable handoff artifact
("keeping the branch for review", per the comment at `session/server.ex:1476`).

**Actual:** only *committed* work survives; the platform destroys dirty state
unconditionally, and nothing in the flow (dispatch prompt, wind-down directive,
teardown) commits or preserves it.

## Problem Statement
The single teardown choke point for worktree-backed sessions
(`Worktree.cleanup/1`) discards uncommitted work with `--force`, and the
context-limit handover protocol (`RepoBuilder.Agents.Handover`) never instructs a
worktree-isolated worker to commit before it is reaped. Hours of agent work (and
real token spend) can be irrecoverably lost on every retirement, crash, or delete
of a worker that did not happen to commit.

## Solution Statement
Fix at the platform choke point so **every** teardown path is covered, with a
belt-and-braces prompt fix at the worker layer:

1. **Safety commit in `Worktree.cleanup/1`** (the surgical core fix). Before
   removing the tree, detect dirty state (`git status --porcelain` in the worktree,
   non-empty output). If dirty, stage and commit everything **on the worktree's own
   `adw/*` branch** with an explicit identity (so a missing global git config can't
   fail the commit):
   `git -C <path> add -A` then
   `git -C <path> -c user.name="RepoBuilder" -c user.email="repo-builder@local" commit -m "wip(platform): safety commit on session teardown" --no-verify`.
   Then proceed with the existing `git worktree remove --force` + `prune`.
   If the safety commit FAILS while the tree is dirty, do **not** force-remove:
   attempt a non-force `git worktree remove` (git itself then refuses on a dirty
   tree, leaving the work on disk) and log a warning — destroying work is the only
   unacceptable outcome. `cleanup/1` stays `:ok`-typed, fail-soft, and idempotent
   (an already-removed path takes the existing tolerant path; a clean tree commits
   nothing and behaves exactly as today).
2. **Handover protocol tells worktree workers to commit.** Extend
   `Handover.wind_down_prompt/1` and `Handover.protocol_clause/0` with one
   instruction placed BEFORE the handover-doc step: if working on an isolated
   `adw/*` worktree branch, first commit all work
   (`git add -A && git commit -m "wip: handover"`) so the branch — not just the
   doc — carries the implementation. This gives a meaningful commit message and
   worker-authored granularity when the worker cooperates; the platform safety
   commit remains the guarantee when it does not.

No schema changes, no new dependencies, no behavior change for `:direct`
(non-worktree) sessions.

## Steps to Reproduce
1. In a git repo, provision a worktree via the same seam the session runtime uses:
   `{:ok, info} = RepoBuilder.Projects.Worktree.checkout(repo_root, run_id: "repro-1")`.
2. Write a file inside `info.path` (e.g. `File.write!(Path.join(info.path, "work.txt"), "hours of work")`) — do **not** commit.
3. Tear down the way `Session.Server.terminate/2` does: `RepoBuilder.Projects.Worktree.cleanup(info)`.
4. Observe: the worktree dir is gone, and `git -C <repo_root> log adw/repro-1` shows
   no commit beyond the base — `work.txt` is unrecoverable. (This is exactly what
   `git log adw/d6d8c38a-dd84-4df4-aebe-4b7a9906ff71` shows in this repo after the
   2026-07-05 incident.)
5. End-to-end variant: spawn a worktree-isolated worker, let it edit files without
   committing, then `RepoBuilder.Session.Supervisor.stop_session(agent_id)` — same loss.
   (Tidewave `project_eval` can drive steps 1–4 against the live app; the DB-side
   evidence is queryable via `execute_sql_query` on `task_ledgers` / `progress_entries`
   for ledger `3655aaf1-…`.)

## Root Cause Analysis
Two layers, one root:

- **Mechanism:** `Worktree.cleanup/1` (`worktree.ex:47-52`) uses
  `git worktree remove --force`. `--force` exists there to tolerate locked/dirty
  trees so teardown never wedges — but it conflates "don't block teardown" with
  "discard the operator's data". `Session.Server.cleanup_workspace/1`
  (`server.ex:1478`) routes every worktree-backed session through it from
  `terminate/2`, so all exit paths (handover reap in
  `Orchestrator.Queue.handle_handover`, `force_retire`, `delete_agent`,
  crash) converge on the destructive call.
- **Protocol gap:** the wind-down/handover contract
  (`Handover.wind_down_prompt/1`, `protocol_clause/0`) instructs the worker to
  write `ai_docs/<name>-handover.md` and emit `:handover <path>` — but never to
  commit. A worker that followed the protocol perfectly (as
  `cancel-implementer-claude` did, modulo the doc) still loses its code because the
  branch was never advanced.
- **Why it went unnoticed:** the happy path (WorkflowEngine `Runner` runs) commits
  as part of the workflow's own steps before teardown, and `WorktreeGC` only
  reclaims *merged* trees — so the loss only manifests on the
  orchestrator-worker retirement path, which is newer and rarer.

## Relevant Files
Use these files to fix the bug:

- `lib/repo_builder/projects/worktree.ex` — `cleanup/1` (line 47) is the destructive
  choke point; the safety commit + dirty-detection + non-force fallback land here.
  Private `git/2` runner already exists for shelling out; follow its shape. Update
  the `cleanup/1` docstring (it currently claims the branch preserves work).
- `lib/repo_builder/agents/handover.ex` — `wind_down_prompt/1` (line 95) and
  `protocol_clause/0` (line 148) gain the "commit your worktree work first"
  instruction step.
- `lib/repo_builder/session/server.ex` — **reference only** (`cleanup_workspace/1`
  clause at line 1478 shows every worktree session funnels through
  `Worktree.cleanup/1`; no edits needed here — fixing the seam fixes all callers).
- `lib/repo_builder/orchestrator/queue.ex` — **reference only** (handover reap /
  `force_retire` paths at lines 601–622, 864+ that trigger the teardown; unchanged).
- `test/repo_builder/projects/worktree_test.exs` — existing worktree unit tests;
  add the `cleanup/1` safety-commit cases here.
- `test/repo_builder/agents/handover_test.exs` — existing prompt-contract tests
  (lines 88–101 assert `wind_down_prompt` content); extend for the new commit
  instruction so the prompt contract is pinned.
- `ai_docs/typed-elixir-standard.md` — typed standard: every new/changed public
  function keeps a precise `@spec`; no raising in the teardown path.

### New Files
None — both fixes land in existing modules and existing test files.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Add dirty-state detection and the safety commit to `Worktree.cleanup/1`
- In `lib/repo_builder/projects/worktree.ex`, add a private
  `@spec dirty?(String.t()) :: boolean()` helper: `git -C <path> status --porcelain`
  via the existing `git/2` runner, `true` when exit 0 with non-empty trimmed output.
  (A missing path or git failure returns `false` — the tolerant/idempotent path.)
- Add a private `@spec safety_commit(String.t()) :: :ok | {:error, term()}` that runs,
  inside the worktree path: `add -A`, then
  `-c user.name=RepoBuilder -c user.email=repo-builder@local commit --no-verify -m "wip(platform): safety commit on session teardown"`.
  Return `{:error, out}` if either command exits non-zero.
- Rewrite `cleanup/1`: when `dirty?(path)`, attempt `safety_commit(path)`.
  - On `:ok` (or when clean): keep today's `worktree remove --force` + `prune`.
  - On `{:error, _}` with a dirty tree: call `worktree remove` **without** `--force`
    (git refuses and preserves the tree), `Logger.warning/1` that the tree was left
    in place with its path, still return `:ok` (fail-soft; `terminate/2` must never
    raise). Add `require Logger` to the module.
- Update the `cleanup/1` `@doc` to state the new contract: "uncommitted work is
  safety-committed to the run's `adw/*` branch before removal; a dirty tree that
  cannot be committed is left on disk rather than destroyed."

### 2. Extend the handover protocol prompts
- In `lib/repo_builder/agents/handover.ex`, in BOTH `wind_down_prompt/1` (the
  numbered "Do this, in order" list) and `protocol_clause/0` (the numbered list),
  insert a new step **1** before the handover-doc step (renumber the rest):
  "If you are working in an isolated git worktree (your cwd is on an `adw/*`
  branch), COMMIT all work now: `git add -A && git commit -m \"wip: handover\"`.
  The branch is the durable artifact; uncommitted changes do not survive retirement."

### 3. Unit tests — `test/repo_builder/projects/worktree_test.exs`
- Add a `describe "cleanup/1 safety commit"` block using the file's existing tmp-repo
  fixtures:
  - **dirty tree is committed then removed:** checkout a worktree, write an
    uncommitted file (plus an untracked file), `cleanup/1`, assert `:ok`, the
    worktree dir is gone, and `git log adv… <branch>` / `git show <branch>:<file>`
    from the main repo shows the safety commit containing both files
    (message `wip(platform): safety commit on session teardown`).
  - **clean tree behaves exactly as before:** checkout, no edits, `cleanup/1`,
    assert dir gone and the branch still points at the base commit (no extra commit).
  - **idempotent / already-removed:** `cleanup/1` twice; second call `:ok`.
- These tests fail before the fix (the dirty-tree case finds no commit and the file
  content is unrecoverable) and pass after — the regression pin for this bug.

### 4. Prompt-contract tests — `test/repo_builder/agents/handover_test.exs`
- Extend the existing `wind_down_prompt` tests (and add a `protocol_clause/0`
  assertion if not present) to require the worktree-commit instruction
  (`assert prompt =~ "git add -A"` / `=~ "adw/"`), pinning the new protocol step.

### 5. Run the `Validation Commands`
- Execute every command in `Validation Commands`; all must pass with zero failures.

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- `mix test test/repo_builder/projects/worktree_test.exs` — the new safety-commit
  cases (reproduce the loss before the fix; prove preservation after).
- `mix test test/repo_builder/agents/handover_test.exs` — prompt contract including
  the new commit step.
- `mix compile --warnings-as-errors` - Compile clean; the gradual set-theoretic type checker and `warnings_as_errors` must pass.
- `mix test --warnings-as-errors` - Run the full ExUnit suite (spawns Postgres-backed cases) with zero failures.
- `mix format --check-formatted` - Ensure code is formatted.
- `mix credo --strict` - Lint, including the "every public function has an `@spec`" convention.
- `mix dialyzer` - `@spec`/contract checking with no new warnings and no stale ignore filters.

## Notes
- The fix is deliberately at `Worktree.cleanup/1`, not in the Queue/Handover reap
  code: every exit path (graceful handover, force-retire, `delete_agent`, crash,
  `stop_session/1`) already funnels through `Session.Server.terminate/2 →
  cleanup_workspace/1 → Worktree.cleanup/1`, so one seam covers them all — including
  future callers.
- `--no-verify` on the safety commit is required: a target repo's commit hooks
  (formatters, linters) must not be able to block emergency preservation.
- The inline `-c user.name/-c user.email` avoids depending on git identity being
  configured in the scratch environment (worktrees under `/tmp/rb_worktrees`).
- `WorktreeGC` needs no change: it only reclaims **merged** trees, and the safety
  commit advances `adw/*` past the trunk, keeping unmerged work protected by the
  existing "unmerged trees are never auto-reclaimed" rule.
- Related but out of scope (tracked as separate bugs): the MiniMax provider-level
  worker crash that preceded this incident, and the rate-limit turn failures that
  exhausted the ledger's replan budget.
- No LiveView/UI surface is touched — no LiveView integration test required.
