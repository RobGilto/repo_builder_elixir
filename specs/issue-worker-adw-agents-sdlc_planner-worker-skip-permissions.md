# Bug: Claude worker agents spawned by the orchestrator lack `--dangerously-skip-permissions` and hang

## Metadata
issue_number: `worker`
adw_id: `agents`
issue_json: `spawned`

## Bug Description
When the orchestrator dispatches a Claude **worker** (via the `command_agent`
tool), the spawned `claude -p …` session does **not** receive the
`--dangerously-skip-permissions` flag. Because the session runs headless under the
erlexec runtime (no interactive TTY to approve permission prompts), the worker
stalls/fails the moment it needs a permission decision (e.g. a `Bash`/`Write`
tool), instead of doing the work autonomously.

- **Expected:** an orchestrator-spawned Claude worker runs autonomously to
  completion, like the orchestrator's own session and like the Python ADWs.
- **Actual:** the worker's argv omits `--dangerously-skip-permissions`, so it
  blocks on interactive permission prompts that can never be answered in a
  headless spawn. Observed in the console center stream (worker event rows
  `#ev-row-196`/`197`/`198`), where workers stop progressing.

## Problem Statement
Claude workers created by the orchestrator must be able to act autonomously in a
non-interactive session, but the worker spawn path never marks the session
autonomous, so the Claude adapter withholds the permission-skip flag. The fix must
make orchestrator-spawned workers autonomous **without** loosening permissions for
genuinely interactive/manual sessions, and without touching the already-correct
orchestrator and Python-ADW paths.

## Solution Statement
Mark the orchestrator-spawned worker session **autonomous** at the single Claude
worker spawn site (`Orchestrator.Tools.command_agent/2`) by passing a `config`
carrying the `:autonomous` flag (atom key) into `Session.Supervisor.start_session/1`.
The Claude adapter's existing `autonomous?/1` → `permission_args/1` seam
(`claude.ex:115-126`) then appends `--dangerously-skip-permissions`. This reuses
the established mechanism the orchestrator session already uses (`orchestrator:
true`), keeps the change to one opts list, and leaves the gate intact for any
session that is not explicitly autonomous.

Key correctness detail: `autonomous?/1` reads **atom** keys (`:orchestrator`,
`:autonomous`), while a worker's persisted `config` (`Agent.config`, a JSONB
`:map`) has **string** keys. The flag must therefore be set as the atom key
`:autonomous` (e.g. `config: Map.put(worker.config, :autonomous, true)`), not the
string `"autonomous"`, or the adapter will not see it.

## Steps to Reproduce
1. In the console, ensure the `main`/worker tier (or a created worker) uses the
   `claude` harness with a model.
2. Have the orchestrator `create_agent` then `command_agent` a worker with a
   prompt that requires a tool needing permission (e.g. "create a file …" →
   `Write`, or "run `mix test`" → `Bash`).
3. Observe the worker session: its argv (via `ps`/logs) lacks
   `--dangerously-skip-permissions`; the worker stalls/fails at the first
   permission-gated tool instead of completing.
4. Contrast with the orchestrator's own session (config `orchestrator: true`) and
   a Python ADW run (`adws/adw_slash_command.py:291` sets
   `dangerously_skip_permissions=True`) — both proceed autonomously.

## Root Cause Analysis
- `lib/repo_builder/harness/claude.ex` `command/1` appends the skip flag only via
  `permission_args/1`, which returns `["--dangerously-skip-permissions"]` **only
  when** `autonomous?(opts.config)` is true — i.e. `config[:orchestrator] == true`
  or `config[:autonomous] == true` (atom keys), per `claude.ex:115-126`. The
  moduledoc deliberately withholds the flag from a "plain worker".
- `lib/repo_builder/orchestrator/tools.ex` `command_agent/2` builds the worker
  session `opts` (lines 254-265) with **no `config` key at all**, so the adapter
  receives `config: %{}` (the `Map.get(opts, :config, %{})` default) →
  `autonomous?` is false → no flag.
- The orchestrator's own session (`orchestrator/server.ex`) passes
  `config: %{orchestrator: true}`, which is why the orchestrator works but its
  workers do not. The Python ADW path is unaffected (handles skip itself). The
  `spawn_adw_session/4` opts (tools.ex:397) pass `config: worker.config` but target
  the **ADW (Python) harness**, not a Claude worker, so they are not the bug.
- Net: there is exactly **one** Claude-worker spawn site (`command_agent/2`) and
  it never marks the session autonomous → the headless worker can never clear a
  permission prompt.

## Relevant Files
Use these files to fix the bug:

- `lib/repo_builder/orchestrator/tools.ex` — `command_agent/2` (lines 245-272) is
  the single Claude-worker spawn site; its `opts` (line 254) must carry
  `config: Map.put(worker.config, :autonomous, true)`. (`worker_provider/1` already
  reads `config["provider"]` separately, so provider plumbing is unaffected.)
- `lib/repo_builder/harness/claude.ex` — `command/1` (line 75), `permission_args/1`
  + `autonomous?/1` (lines 115-126). No change needed; this is the seam the fix
  triggers. Confirm the atom-key contract.
- `lib/repo_builder/agents/agent.ex` — `Agent.config` is `field :config, :map,
  default: %{}` with string keys (cast from params, line 38/51). Explains the
  atom-vs-string-key requirement.
- `lib/repo_builder/orchestrator/server.ex` — reference for the autonomous pattern
  (`config: %{orchestrator: true}`) already used by the orchestrator session.
- `lib/repo_builder/session/server.ex` — confirms `opts[:config]` is threaded into
  the adapter's `command/1` unchanged (sanity for the fix).
- `BUILD_PROMPT.md` — §3 typed style, §4 harness contract, §6 session runtime; the
  fix stays within these.
- `test/repo_builder/harness/claude_normalize_test.exs` — existing Claude adapter
  test module location/conventions to extend with a `command/1` permission-arg
  assertion (or add a sibling test file).

### New Files
- `test/repo_builder/harness/claude_command_permission_test.exs` — Claude adapter
  unit test for `command/1`: an autonomous worker session (`config: %{autonomous:
  true}`) and an orchestrator session (`config: %{orchestrator: true}`) both yield
  argv containing `--dangerously-skip-permissions`; a session with `config: %{}`
  (and a string-keyed `%{"autonomous" => true}`) does **not**. (May instead be
  folded into the existing `claude_normalize_test.exs` if preferred.)
- `test/repo_builder/orchestrator/command_agent_autonomous_test.exs` — asserts
  `command_agent/2` builds session opts whose `config` makes the session
  autonomous (drives via the public tool path with the session spawn faked/Fake
  harness, or asserts the opts/`config` carries `:autonomous`).

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Reproduce + confirm the seam
- Read `BUILD_PROMPT.md` §4/§6 and `.claude/commands/conditional_docs.md` (pull any
  matching docs). Use Tidewave `get_source_location` on `Claude.command/1`,
  `permission_args/1`, `autonomous?/1`, and `Tools.command_agent/2` to re-confirm
  the exact lines.
- Reproduce in the live app with Tidewave `project_eval`:
  `RepoBuilder.Harness.Claude.command(%{prompt: "hi", config: %{}})` → assert the
  argv does NOT contain `--dangerously-skip-permissions`; then with
  `config: %{autonomous: true}` → assert it DOES. Capture as the before/after
  evidence.

### 2. Add the failing adapter test (red)
- Create `test/repo_builder/harness/claude_command_permission_test.exs` asserting:
  (a) `config: %{autonomous: true}` ⇒ argv includes the flag; (b) `config:
  %{orchestrator: true}` ⇒ includes it; (c) `config: %{}` and `config:
  %{"autonomous" => true}` (string key) ⇒ excludes it. Run it to confirm (a)
  passes (the adapter already supports it) and that the orchestrator-worker gap is
  about the caller, not the adapter — documenting the atom-key requirement.

### 3. Apply the surgical fix
- In `lib/repo_builder/orchestrator/tools.ex` `command_agent/2`, add to the `opts`
  (line 254 block): `config: Map.put(worker.config, :autonomous, true)`. This marks
  the orchestrator-spawned worker session autonomous via the atom key the adapter
  reads, while preserving any existing string-keyed worker config.
- Do NOT change `claude.ex`, the orchestrator session path, or `spawn_adw_session/4`
  (Python ADW). Keep the change to this one opts list.

### 4. Add the caller-level test (red→green)
- Create `test/repo_builder/orchestrator/command_agent_autonomous_test.exs` that
  drives `command_agent` (Fake/stubbed session spawn) and asserts the worker
  session is started autonomous — e.g. by asserting the opts/`config` passed to
  `Session.Supervisor.start_session/1` carries `:autonomous => true`, or by using
  the `claude` harness `command/1` against the resulting config. Confirm it fails
  before Step 3's edit and passes after.

### 5. Regression sweep
- Confirm the orchestrator session still emits the flag (unchanged) and that a
  manually/interactively created session WITHOUT an autonomous/orchestrator flag
  still does NOT (the gate remains for non-orchestrator callers). Confirm the
  Python ADW path is untouched.

### 6. Validate
- Run all **Validation Commands**; fix until green with zero regressions. Use
  Tidewave `get_logs` if a worker run still stalls, and re-run the Step 1
  `project_eval` to prove the live argv now carries the flag for an autonomous
  worker.

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- `mix test test/repo_builder/harness/claude_command_permission_test.exs` — adapter
  emits the flag for autonomous/orchestrator configs, withholds it otherwise
  (incl. string-keyed config).
- `mix test test/repo_builder/orchestrator/command_agent_autonomous_test.exs` —
  `command_agent` spawns the worker session autonomous.
- `mix test test/repo_builder/harness/claude_normalize_test.exs` — existing Claude
  adapter tests still green.
- `mix test test/repo_builder/orchestrator/ test/repo_builder/harness/` — no
  regressions in the orchestrator/harness suites.
- `mix compile --warnings-as-errors` — clean compile; set-theoretic checker +
  warnings pass.
- `mix test --warnings-as-errors` — full suite green, zero regressions.
- `mix format --check-formatted` — formatted.
- `mix credo --strict` — lint incl. every-public-fn-`@spec`.
- `mix dialyzer` — no new contract warnings, no stale ignores.
- Tidewave (live app) before/after: `project_eval`
  `RepoBuilder.Harness.Claude.command(%{prompt: "x", config: %{autonomous: true}})`
  argv contains `--dangerously-skip-permissions`; with `config: %{}` it does not.

## Notes
- **Why autonomous-by-default for orchestrator workers is correct:** this is a
  headless orchestration platform — there is no human approval channel for a
  spawned worker, so an un-skipped worker is functionally inert. The orchestrator
  session and the Python ADWs already run autonomously; this aligns workers with
  them. The permission gate intentionally remains for sessions a human drives
  interactively (no `:orchestrator`/`:autonomous` flag).
- **Atom vs string keys** is the subtle trap: `Agent.config` is JSONB with string
  keys, but `autonomous?/1` matches atom keys. Set `:autonomous` (atom). Do not
  switch the adapter to string keys — `orchestrator/server.ex` already passes the
  atom key, and changing the adapter would risk that path.
- **Scope guard:** exactly one line changes in `command_agent/2`; no schema,
  migration, or dependency changes. `spawn_adw_session/4` (ADW/Python harness) and
  `start_adw` are out of scope (already correct).
- **Optional hardening (not required):** consider a session-runtime invariant that
  any session with `agent_db_id` spawned by the orchestrator defaults to
  autonomous, so a future second worker spawn site can't reintroduce this gap. Note
  it; do not implement unless the team wants the broader guard.
