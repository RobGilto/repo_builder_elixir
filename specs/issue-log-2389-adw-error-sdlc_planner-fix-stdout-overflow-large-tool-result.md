# Bug: Worker session killed by "stdout overflow" on a legitimate large tool-result frame

## Metadata
issue_number: `log-2389`
adw_id: `error`
issue_json: `{"title":"Agent error at log-2389: stdout overflow","body":"Got an error from an agent. The error appeared at log-2389 (agent_logs.seq_no = 2389): a Claude worker (claude-opus-4-5, session worker-Y4O7smecdiIogqmX) emitted %Error{message: \"stdout overflow\", reason: :provider_error, retryable: false} immediately after a `Read` tool_call/usage pair, terminating the run."}`

> Note: this was an ad-hoc `/bug` report keyed off the in-app log drilldown number `log-2389`, not a GitHub issue. The metadata fields above reflect the parsed `/bug` invocation; the authoritative bug evidence is the `agent_logs` row at `seq_no = 2389` reproduced below.

## Bug Description
A live worker session driving the **Claude** harness (`claude-opus-4-5`, session `worker-Y4O7smecdiIogqmX`) was terminated mid-run with a canonical terminal error:

```
%RepoBuilder.Harness.Event.Error{
  message: "stdout overflow",
  reason: :provider_error,
  retryable: false
}
```

persisted at `agent_logs.seq_no = 2389` (`event_type = "error"`, `harness = "claude"`). The immediately-preceding events were:

| seq_no | event_type | tool | notes |
|---|---|---|---|
| 2387 | tool_call | `Read` | worker asks the harness to read a file |
| 2388 | usage | — | per-message usage for that turn |
| 2389 | **error** | — | `stdout overflow` → child killed, run aborted |

**Expected behavior:** a `Read` of a large file (or any large but well-formed tool result) streams back as a single newline-terminated `stream-json` frame, is decoded/normalized normally, and the run continues.

**Actual behavior:** the single JSONL frame carrying the `Read` result exceeded the **1 MiB `max_line_bytes`** backpressure cap before its terminating newline arrived. The session runtime classified the stream as *hostile*, sent SIGTERM/SIGKILL to the child, emitted `%Error{reason: :provider_error, message: "stdout overflow"}`, and stopped — destroying an otherwise-healthy agent run.

## Problem Statement
The session runtime's anti-flood guard (`RepoBuilder.Session.Server`, `BUILD_PROMPT.md` §6 rule 6) uses a single hard byte cap (`max_line_bytes`, default `1_048_576` = 1 MiB) to detect a hostile, never-newline-terminated stdout stream. That same cap also fires on a **legitimate** single `stream-json` frame that simply happens to be larger than 1 MiB — e.g. a `Read` tool result containing a large file, a `git diff`, or (now that workers can be granted Firecrawl, see `0d7039e`/firecrawl-grant) a multi-megabyte web-scrape result embedded in one `user`/tool_result line. The cap cannot, by construction, distinguish "runaway/newline-less" from "large but valid and newline-terminated" until the newline arrives, and 1 MiB is far too low for the tool outputs these workers now legitimately produce.

## Solution Statement
Keep the backpressure guard (it is a real OOM protection — `BUILD_PROMPT.md` §6 rule 6), but raise the default ceiling to a value that comfortably accommodates legitimate large single-line `stream-json` frames while still bounding a truly runaway stream. Concretely:

1. Raise the `:session` `max_line_bytes` default from `1_048_576` (1 MiB) to `16_777_216` (16 MiB) in `config/config.exs` (the new ceiling for prod/dev). This is a >16× headroom increase that covers large file reads / diffs / scrapes while remaining a hard OOM backstop (a single 16 MiB un-newlined line is still treated as hostile).
2. Make the ceiling overridable at deploy time via `config/runtime.exs` (env var `REPO_BUILDER_MAX_LINE_BYTES`), so operators driving extremely large-output tools can tune it without a code change — consistent with the existing per-session config seam (`cfg_value/4` already reads `opts`/`cfg`).
3. Improve the overflow `%Error{}` message to include the cap that was exceeded (`"stdout overflow (line exceeded <N> bytes)"`) and log a `Logger.warning` when the guard fires, so a future overflow is debuggable from the message alone rather than requiring source spelunking.
4. Leave `config/test.exs` `max_line_bytes` deliberately small (`1_048_576` or smaller) so the existing overflow unit test still exercises the guard cheaply; add a regression test proving a large-but-valid newline-terminated frame is **not** treated as overflow.

This is the minimal, surgical fix: it changes a default + an env override + the error message/log, and adds one regression test. It does not alter the framing algorithm, the canonical event contract, or the spawn/lifecycle logic.

## Steps to Reproduce
1. Start a Claude worker session whose task causes the harness to call the `Read` tool on a file larger than ~1 MiB (or any tool whose single `stream-json` result frame exceeds 1 MiB before a newline).
2. Observe the worker terminate with `%Error{message: "stdout overflow", reason: :provider_error}`.

Deterministic reproduction (no live harness needed) — inject a crafted oversized, newline-terminated stdout chunk into `RepoBuilder.Session.Server` via the existing Mock-adapter test seam (`send(pid, {:stdout, os_pid, big_valid_line <> "\n"})`) with the current 1 MiB cap and assert the run is wrongly killed (see `test/repo_builder/session/server_test.exs:78` for the existing overflow-path harness to mirror).

Confirmed live evidence (already in the DB):
```sql
SELECT seq_no, harness, model, event_type, payload, session_id
FROM agent_logs WHERE seq_no = 2389;
-- payload => {"message":"stdout overflow","reason":"provider_error","retryable":false}
-- preceding seq_no 2387 tool_call name = "Read"
```

## Root Cause Analysis
`RepoBuilder.Session.Server.handle_info({:stdout, os_pid, chunk}, …)` (`lib/repo_builder/session/server.ex:346-359`) runs:

```elixir
if no_newline?(bin) and byte_size(bin) > state.max_line_bytes do
  state = dispatch(error_event(state, "stdout overflow", :provider_error), state)
  _ = :exec.stop(os_pid)
  {:stop, :normal, %{state | buf: ""}}
else
  ...
end
```

`max_line_bytes` is sourced in `build_state/2` (`server.ex:150`) via `cfg_value(opts, cfg, :max_line_bytes, 1_048_576)`, and `config/config.exs:288` / `config/test.exs:142` both pin it to `1_048_576` (1 MiB).

The guard's intent (`BUILD_PROMPT.md` §6 rule 6) is to defend against a hostile child that floods stdout with no newline — an unbounded line that would OOM the BEAM. But the predicate `no_newline?(bin) and byte_size(bin) > max_line_bytes` **also** matches a legitimate single `stream-json` frame larger than the cap whose terminating `"\n"` simply hasn't been received yet. Claude's `stream-json` output emits each `user`/tool_result block as **one JSONL line**; a `Read` of a large file (the CLI's `Read` tool reads up to 2000 lines) or a Firecrawl scrape (workers can now be granted Firecrawl) produces a single line well over 1 MiB. The 1 MiB default was chosen before workers had large-output tooling and is now too low, so the protection misfires on healthy runs.

The fix is therefore to raise the default ceiling (with an env override) rather than to change framing — the algorithm is correct; only the threshold is mis-sized for the current workload.

## Relevant Files
Use these files to fix the bug:

- `lib/repo_builder/session/server.ex` — **primary.** Contains the overflow guard (`handle_info({:stdout, …})`, lines 346-359), the `max_line_bytes` state field (line 74) and its default sourcing (`build_state/2`, line 150; `cfg_value/4`, line 157), and `error_event/3` (line 677). The error message + `Logger.warning` improvement lands here.
- `config/config.exs` — `:repo_builder, :session` block (lines 284-289). Raise `max_line_bytes` default to `16_777_216`.
- `config/runtime.exs` — add a `REPO_BUILDER_MAX_LINE_BYTES` env override that merges into `config :repo_builder, :session` so prod can tune the ceiling without a redeploy.
- `config/test.exs` — `:repo_builder, :session` block (lines 138-143). Keep `max_line_bytes` small so the existing overflow guard test stays cheap; do **not** raise it here.
- `test/repo_builder/session/server_test.exs` — existing framing/terminal-synthesis tests, including the overflow test at line 78 (`"an un-newline-terminated stream past the byte cap emits Error stdout overflow"`) and the multibyte-split test at line 141 that demonstrates the `send(pid, {:stdout, os_pid, chunk})` injection seam. Add the regression test here.

### New Files
None. (The regression test is added to the existing `test/repo_builder/session/server_test.exs`; no new modules are required.)

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Raise the default `max_line_bytes` ceiling
- In `config/config.exs`, change the `:repo_builder, :session` `max_line_bytes:` from `1_048_576` to `16_777_216` (16 MiB).
- Add a short comment on that line explaining the cap is a hostile-stream OOM backstop sized to also pass legitimate large single-line `stream-json` frames (large `Read`/diff/Firecrawl tool results), per `BUILD_PROMPT.md` §6 rule 6.

### 2. Add a runtime env override
- In `config/runtime.exs`, read `System.get_env("REPO_BUILDER_MAX_LINE_BYTES")`, and when present and a valid positive integer (`String.to_integer/1` guarded), merge it into the existing `:repo_builder, :session` config (use `Application.get_env(:repo_builder, :session, [])` + `Keyword.put/3` + `Application.put_env/3`, or add it to whatever pattern `runtime.exs` already uses for the `:session` block — if none exists, add a guarded block). Leave all other `:session` keys untouched.
- This keeps `max_line_bytes` operator-tunable per `BUILD_PROMPT.md` §6 without a code change, mirroring the existing `cfg_value/4` precedence (per-call `opts` > env `cfg` > literal default).

### 3. Make the overflow error self-describing (message + log)
- In `lib/repo_builder/session/server.ex`, in the `handle_info({:stdout, os_pid, chunk}, …)` overflow branch (lines 350-353), change the emitted message from `"stdout overflow"` to include the cap, e.g. `"stdout overflow (line exceeded #{state.max_line_bytes} bytes)"`.
- Add a `Logger.warning("session #{state.session_id}: stdout overflow — single line exceeded #{state.max_line_bytes} bytes; killing child")` immediately before the `dispatch/2` call so the condition is visible in the live logs.
- Preserve `reason: :provider_error` and the existing `:exec.stop/1` + `{:stop, :normal, …}` control flow exactly — only the message string and an added log line change. Keep `error_event/3`'s `@spec` and signature intact (it already takes the message string).

### 4. Keep the test cap small (no change needed, verify)
- Confirm `config/test.exs` `max_line_bytes` stays at `1_048_576` (or smaller) so the existing overflow guard test (`server_test.exs:78`) still triggers cheaply with its own per-call `max_line_bytes: 1_000` override. Do not raise it.

### 5. Update the existing overflow test assertion
- In `test/repo_builder/session/server_test.exs:78`, the test asserts `%Event.Error{message: "stdout overflow", reason: :provider_error}`. Since the message now embeds the byte cap, relax that assertion to match the new prefix — e.g. assert the received error's `message` starts with `"stdout overflow"` (`String.starts_with?/2`) and `reason == :provider_error`, keeping the test green.

### 6. Add a regression test: a large-but-valid frame is NOT overflow
- In `test/repo_builder/session/server_test.exs`, under the `"terminal-state synthesis & framing (Mock adapter)"` describe block, add a test that:
  - starts a session with a Mock adapter and a generous `max_line_bytes` (e.g. `2_000_000`), mirroring the start pattern used by the overflow test at line 78 and the multibyte test at line 141;
  - injects, via `send(pid, {:stdout, os_pid, chunk})`, a single **valid, newline-terminated** JSON line whose byte size is comfortably larger than the **old** 1 MiB default but under the test cap (e.g. a `text_delta`/tool-result frame padded to ~1.5 MiB, terminated with `"\n"`);
  - asserts the session normalizes it into the expected canonical event (e.g. `assert_receive {:harness_event, %Event.TextDelta{…}}`) and does **NOT** receive `%Event.Error{reason: :provider_error}` (`refute_receive {:harness_event, %Event.Error{reason: :provider_error}}` within a short timeout), i.e. the run is not killed.
- Name it clearly, e.g. `"a large but newline-terminated frame above the old 1 MiB default is not treated as overflow"`.

### 7. Run the validation suite
- Run every command in the `Validation Commands` section and confirm all are green with zero regressions.

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- `mix test test/repo_builder/session/server_test.exs` — the session runtime suite, including the updated overflow assertion (Step 5) and the new large-valid-frame regression test (Step 6). The new test FAILS before Step 1/Step 6 (the 1.5 MiB valid frame is wrongly killed under the 1 MiB default; here it runs under a generous cap and must pass) and PASSES after the fix.
- `mix compile --warnings-as-errors` - Compile clean; the gradual set-theoretic type checker and `warnings_as_errors` must pass.
- `mix test --warnings-as-errors` - Run the full ExUnit suite (spawns Postgres-backed cases) with zero failures.
- `mix format --check-formatted` - Ensure code is formatted.
- `mix credo --strict` - Lint, including the "every public function has an `@spec`" convention.
- `mix dialyzer` - `@spec`/contract checking with no new warnings and no stale ignore filters.

## Notes
- **No new dependencies** are required; this is a config-default + error-message + test change only.
- **Why raise rather than redesign:** the framing algorithm and the overflow guard are correct per `BUILD_PROMPT.md` §6 rule 6 — the guard must exist to bound an un-newline-terminated stream (no inbound flow control on erlexec/Ports). The defect is purely that the 1 MiB threshold predates large-output worker tooling (`Read` of large files, and Firecrawl grants per commit `0d7039e` / the firecrawl-grant work). 16 MiB preserves the OOM backstop while clearing realistic single-frame sizes.
- **`cost_usd`/Decimal, secrets, redaction** are untouched — the change does not enter the persistence or redaction paths.
- **Not a LiveView bug.** The symptom surfaces in the LiveView console feed (`log-2389` is the `agent_logs.seq_no` drilldown number), but the root cause and fix are entirely in the session GenServer + config. A `Phoenix.LiveViewTest` is therefore not the right validation seam; the `RepoBuilder.Session.Server` unit test (Step 6) that injects crafted stdout is the precise regression guard. No LiveView integration test is added.
- **Runtime evidence captured via Tidewave:** `get_logs` surfaced the persisted `agent_logs` INSERTs; `execute_sql_query` confirmed `seq_no = 2389` is `harness = "claude"`, `event_type = "error"`, `payload = {"message":"stdout overflow","reason":"provider_error","retryable":false}`, preceded by a `Read` `tool_call` (seq_no 2387); `get_source_location` pinned the emitter to `lib/repo_builder/session/server.ex`.
- **Operator mitigation (immediate):** until deployed, an operator can already raise the ceiling for a session via the per-call `max_line_bytes` opt or by setting `config :repo_builder, :session, max_line_bytes: …`; Step 2 formalizes this as the `REPO_BUILDER_MAX_LINE_BYTES` env override.
