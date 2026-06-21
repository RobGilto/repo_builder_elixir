# Worker report: debugger-adw-exit (idle)

Perfect! Let me create a final summary:

## Implementation Complete ✅

**Implemented the SAFER GATED variant** of the SIGTERM fix as requested:

### Changes Made

**1. Added `partial?` field to `Event.Done` (event.ex:143)**
- New field: `field :partial?, boolean(), default: false`
- New reason atom: `:sigterm_on_blocking_step`
- Backward compatible — defaults to `false`

**2. Added blocking-command detection to Session.Server (server.ex)**
- New state field: `blocking_command?: boolean(), default: false`
- Detection: `blocking_command_detected?/1` checks stderr for `"phx.server"` pattern
- Stderr handler now sets flag when pattern detected (line 373)

**3. Implemented gated SIGTERM handling (server.ex:595-633)**
- `clean_exit?({:exit_status, status}, state)` now checks:
  - Status 0: always clean
  - Status 143 (SIGTERM): clean **ONLY IF** `blocking_command?: true`
  - All other exits: not clean
- `maybe_synthesize_terminal/2` emits:
  - `Done{partial?: true, reason: :sigterm_on_blocking_step}` for SIGTERM + blocking
  - `Done{partial?: false, reason: :clean_exit}` for status 0
  - `Error{reason: :provider_error}` for other failures
- Idle timeout behavior:
  - With `blocking_command?: true`: skip Error, let `:DOWN` emit Done{partial?: true}
  - With `blocking_command?: false`: emit Error{:idle_timeout} immediately (existing behavior preserved)

**4. Logs.Writer status mapping (writer.ex:174)**
- `Done{ok: true}` → `:idle` (both `partial?: false` and `partial?: true`)
- No code change needed — pattern already matches both

### Tests Added

**Session.Server tests (16 total, +6 new):**
1. `blocking_command_detected?/1` detects `"phx.server"` in stderr
2. `sigterm?/1` detects exit status 143 (36608 raw)
3. `clean_exit?/2` gates SIGTERM based on `blocking_command?` flag (both branches)
4. Idle timeout with `blocking_command?: false` still emits Error (existing behavior)
5. Stderr with blocking pattern sets the flag

**Logs.Writer tests (+4 new):**
1. `Done{ok: true, partial?: false}` → `:idle`
2. `Done{ok: true, partial?: true}` → `:idle`
3. `Done{ok: false}` → `:error`
4. `Error{}` → `:error`

### Validation Gate Results

✅ `mix compile --warnings-as-errors` — clean  
✅ `mix format --check-formatted` — clean  
✅ `mix credo --strict` — 2681 mods/funs, 0 issues  
✅ `mix test --warnings-as-errors` — **935 tests passed** (including all 6 new SIGTERM tests)  
✅ `mix dialyzer` — **no new warnings** in modified files (2 pre-existing warnings in unrelated console_live.ex)

### Files Changed
- `lib/repo_builder/harness/event.ex` — +2 lines (new field + reason)
- `lib/repo_builder/session/server.ex` — +63 lines net (gated SIGTERM logic)
- `test/repo_builder/session/server_test.exs` — +94 lines (6 new tests)
- `test/repo_builder/logs/writer_test.exs` — +83 lines (4 new tests)

**Total: 4 files, +242 lines**

The implementation correctly handles the original bug: a Phoenix server (`mix phx.server`) running as validation verification that gets SIGTERM'd by the idle timeout will now emit `Done{ok: true, partial?: true}` instead of `Error`, marking the agent as `:idle` (success) rather than `:error` (failure), **BUT ONLY** when the blocking pattern is detected. Any other SIGTERM (without the pattern) remains an error, preventing false positives.
