# Bug: Session.Server.terminate/2 DB op races sandbox teardown — noisy [error] log in tests

## Metadata
issue_number: `test`
adw_id: `failed`
issue_json: ``

## Bug Description

When running `mix test`, a noisy `[error]` log line appears mid-run:

```
[error] Postgrex.Protocol (#PID<0.431.0> ({Postgrex.Protocol, "repo_builder_test"})) disconnected:
  ** (DBConnection.ConnectionError) owner #PID<0.1824.0> exited
    ...
    (repo_builder 0.1.0) lib/repo_builder/os_pid_ledger.ex:26: RepoBuilder.OsPidLedger.delete_by_marker/1
    (repo_builder 0.1.0) lib/repo_builder/session/server.ex:357: RepoBuilder.Session.Server.delete_ledger_quietly/1
    (repo_builder 0.1.0) lib/repo_builder/session/server.ex:346: RepoBuilder.Session.Server.terminate/2
```

All 370 tests pass, but the `[error]` line appears because `Session.Server.terminate/2` attempts a `Repo.delete_all/1` after the Ecto sandbox connection has been released. The `rescue/catch` in `delete_ledger_quietly/1` prevents any crash or test failure, but Postgrex's protocol process logs the disconnection at the `[error]` level independently — below the Elixir exception layer — so the rescue/catch cannot suppress it.

The code comment in `delete_ledger_quietly/1` already acknowledges this intent: *"Also keeps test teardown quiet once the sandbox owner exits."* — but the current implementation does not achieve that goal.

## Problem Statement

`RepoBuilder.SessionCase` registers only one `on_exit` callback: `Sandbox.stop_owner(pid)`. Several test files that use `SessionCase` start live `Session.Server` processes (via `WorkflowEngine.start_workflow` or `Session.Supervisor.start_session`) but do **not** register a `drain_sessions` `on_exit`. As a result, `Sandbox.stop_owner` (the only `on_exit` callback) fires while one or more `Session.Server` processes are still executing their `terminate/2` callback, which calls `Repo.delete_all/1`. The sandbox connection owner exits, causing Postgrex to emit an `[error]` log even though the Elixir-level exception is caught.

Affected test files (start live sessions, no drain):
- `test/repo_builder/workflow_engine_test.exs`
- `test/repo_builder/multi_harness_test.exs`
- `test/repo_builder/session/server_test.exs`
- `test/repo_builder/session/supervisor_test.exs`
- `test/repo_builder/session/stderr_surfacing_test.exs`
- `test/repo_builder/secret_redaction_e2e_test.exs`
- `test/repo_builder/orchestrator/server_test.exs`
- `test/repo_builder/orchestrator/tools_test.exs`
- `test/repo_builder/orchestrator/cost_report_test.exs`
- `test/e2e/adw_e2e_test.exs` (has its own `drain_sessions` on_exit — but the root fix should live in `SessionCase`)

## Solution Statement

Add a `drain_sessions/0` helper and a corresponding `on_exit` callback directly to `RepoBuilder.SessionCase.setup/1`, registered **after** `stop_owner` so it fires **first** under ExUnit's LIFO on_exit ordering:

```
on_exit(fn -> Sandbox.stop_owner(pid) end)   # registered 1st → runs 2nd
on_exit(&drain_sessions/0)                    # registered 2nd → runs 1st (LIFO) ✓
```

`drain_sessions/0` polls `DynamicSupervisor.count_children(RepoBuilder.SessionSupervisor)` until `active: 0` (or a safety timeout), ensuring every `Session.Server.terminate/2` has completed before the sandbox connection is released.

Since the `adw_e2e_test.exs` also registers its own `drain_sessions`, the local copy becomes redundant and should be removed to avoid double-registration (both are idempotent, but cleanliness matters).

## Steps to Reproduce

```bash
cd /data/1.Projects/repo_builder_elixir
mix test --warnings-as-errors 2>&1 | grep -E "\[error\].*DBConnection"
```

Expected: no output. Actual: one or more `[error] Postgrex.Protocol ... DBConnection.ConnectionError owner ... exited` lines.

## Root Cause Analysis

ExUnit's `on_exit` callbacks fire in **LIFO** order (last-registered runs first).

`RepoBuilder.SessionCase.setup/1` registers **one** `on_exit`:
```elixir
on_exit(fn -> Sandbox.stop_owner(pid) end)  # only callback → runs immediately on exit
```

Test files that start sessions (e.g. `workflow_engine_test.exs`) do **not** register any additional `on_exit`. So on test exit:

1. `Sandbox.stop_owner(pid)` runs — releases the shared DB sandbox connection.
2. Session.Server processes that were started by the test are still alive, finishing their `terminate/2` → `delete_ledger_quietly` → `Repo.delete_all`.
3. Postgrex's protocol process detects the connection owner has exited and logs `[error]`.
4. The Elixir `rescue/catch` in `delete_ledger_quietly` swallows the exception — no crash — but the protocol-layer log cannot be suppressed from application code.

`adw_e2e_test.exs` accidentally avoids this for its own tests by registering `on_exit(&drain_sessions/0)` in its module-level setup, placing it after the SessionCase `stop_owner` registration. Under LIFO, `drain_sessions` fires first and waits for all `Session.Server` processes to exit before `stop_owner` releases the sandbox. All other `SessionCase` test files lack this guard.

## Relevant Files

- **`test/support/session_case.ex`** — the `SessionCase` template; this is where `drain_sessions/0` and its `on_exit` registration must be added.
- **`test/e2e/adw_e2e_test.exs`** — has a redundant local `drain_sessions/0` that can be removed once the fix is in `SessionCase`.
- **`lib/repo_builder/session/server.ex`** — `terminate/2` / `delete_ledger_quietly/1`; no code change needed here (the rescue/catch is correct; the fix is in test setup ordering).
- **`lib/repo_builder/os_pid_ledger.ex`** — `delete_by_marker/1`; no change needed.
- **`test/repo_builder/workflow_engine_test.exs`** — representative of affected tests; no change needed once `SessionCase` is fixed.

### Relevant docs

- `ai_docs/typed-elixir-standard.md` — always required (any public function change needs `@spec`).
- `BUILD_PROMPT.md §13` — test conventions; Mox/FakeHarness; `SessionCase`; Ecto sandbox.
- `BUILD_PROMPT.md §6` — session runtime lifecycle; `terminate/2`; orphan reaper role of `os_pid_ledger`.

## Step by Step Tasks

### 1. Add `drain_sessions/0` and its on_exit to `SessionCase`

In `test/support/session_case.ex`:

- Define a module-level private helper `drain_sessions/0` that polls
  `DynamicSupervisor.count_children(RepoBuilder.SessionSupervisor)` with up to
  200 × 20 ms (4 s) max wait — matching the pattern already used in `adw_e2e_test.exs`.
- In the `setup tags do` block, register the drain callback **after** the existing
  `stop_owner` registration so that LIFO fires it first:

  ```elixir
  setup tags do
    pid = Sandbox.start_owner!(RepoBuilder.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)   # registered 1st → runs 2nd (LIFO)
    on_exit(&drain_sessions/0)                    # registered 2nd → runs 1st (LIFO)

    unless tags[:async], do: Mox.set_mox_global()

    :ok
  end
  ```

- Add an `@spec` for `drain_sessions/0` (returns `:ok`).

### 2. Remove the redundant `drain_sessions` from `adw_e2e_test.exs`

In `test/e2e/adw_e2e_test.exs`:

- Delete the `defp drain_sessions/1` private function (it is now provided by `SessionCase`).
- Delete the `setup do on_exit(&drain_sessions/0) end` block (it is now provided by `SessionCase`).
- `SessionCase` exposes `drain_sessions/0` via `import RepoBuilder.SessionCase`, so any remaining direct call works — but there are none left after this step.

  > **Note:** `drain_sessions/1` in `adw_e2e_test.exs` currently takes an `attempts` parameter for recursion. The new version in `SessionCase` should keep the same signature as a private helper (default-arg head + recursive body) but only needs to be module-private (no `@doc`, no export).

### 3. Run full validation

Verify the [error] log is gone and the suite stays green (see Validation Commands).

## Validation Commands

```bash
# Confirm the noisy [error] log is eliminated
cd /data/1.Projects/repo_builder_elixir && mix test --warnings-as-errors 2>&1 | grep -c "\[error\].*DBConnection"
# Expected output: 0

# Full suite must stay green
mix test --warnings-as-errors

# Formatting
mix format --check-formatted

# Lint (every public fn has @spec)
mix credo --strict

# Type / contract checking
mix dialyzer

# Compiler must be warning-free
mix compile --warnings-as-errors
```

## Notes

- `Sandbox.stop_owner/1` is called on the PID returned by `start_owner!`, which is a **separate** process from the test process. In `shared: true` mode (all `async: false` tests), the sandbox connection is released only when `stop_owner` is explicitly called — not when the test process itself exits. This means the LIFO ordering of `on_exit` is the correct mechanism to guarantee ordering.
- `drain_sessions/0` polls `DynamicSupervisor.count_children/1`, which is a synchronous call to the supervisor. Because OTP GenServer's `terminate/2` runs synchronously before the process exits, `count_children` returning `%{active: 0}` guarantees that every `Session.Server.terminate/2` — including the `delete_ledger_quietly` DB call — has fully completed.
- No production code changes are needed. The orphan-reaper safety net (`OsPidLedger` + `OrphanReaper`) already handles any ledger rows that are missed (e.g. in a true crash). The fix only corrects test teardown ordering.
- Dialyzer: `drain_sessions/0` is a `defp` helper; no `@spec` is required by the Credo rule (only public functions need specs). However, an optional `@spec` improves documentation; add it if desired.
