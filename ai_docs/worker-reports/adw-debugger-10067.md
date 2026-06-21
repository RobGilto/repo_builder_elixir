# Worker report: adw-debugger (idle)

Confirmed! There's **NO `CLAUDE_CODE_PATH` in the Phoenix server's environment**. That's the root cause.

Let me create a comprehensive diagnostic report:

## ROOT CAUSE DIAGNOSIS

### Exact Error
The ADW Python script (`adw_plan_build_test_review_local_iso.py`) exits immediately with `{:exit_status, 256}` (OS exit code 1) because of this startup validation failure in `adws/adw_modules/utils.py:170-176`:

```python
required_vars = [
    "CLAUDE_CODE_PATH",
]
missing_vars = [var for var in required_vars if not os.getenv(var)]

if missing_vars:
    error_msg = "Error: Missing required environment variables:"
    for var in missing_vars:
        error_msg += f"\n  - {var}"
    print(error_msg, file=sys.stderr)
    sys.exit(1)  # ← THIS is exit code 1 (appears as 256 in erlexec)
```

### Why the Error is Swallowed
The stderr traceback **is not visible in the UI** because:

1. The ADW harness (`lib/repo_builder/harness/adw.ex`) spawns the Python script via erlexec
2. The session runtime (`lib/repo_builder/session/server.ex`) only keeps the last 2KB of stderr (`@stderr_tail_bytes`)
3. The error happens SO fast (before any JSON output) that the stderr is likely lost or not surfaced to the UI

### Root Cause
**Missing environment variable**: The Phoenix server process (started via `mix phx.server`) does **not** have `CLAUDE_CODE_PATH` in its environment.

When the session server spawns the ADW subprocess at `lib/repo_builder/session/server.ex:664`, it calls:
```elixir
System.get_env()  # ← Gets the Phoenix/BEAM process env
|> Map.merge(Map.new(env))  # ← Merges adapter-provided env (only ADW_EMIT=json + secrets)
```

Since `CLAUDE_CODE_PATH` is not in the BEAM environment and the ADW harness adapter (`lib/repo_builder/harness/adw.ex:99-107`) doesn't add it to the `env` list, the spawned Python process doesn't have it either.

### Recommended Fix

**Option 1 (Quick fix for development)**: Set `CLAUDE_CODE_PATH` before starting the Phoenix server:
```bash
export CLAUDE_CODE_PATH="/home/robert/.local/share/mise/installs/node/25.8.0/bin/claude"
mix phx.server
```

**Option 2 (Proper fix)**: Add `CLAUDE_CODE_PATH` to the ADW harness adapter's `env/1` function in `lib/repo_builder/harness/adw.ex`:

```elixir
@spec env(RepoBuilder.Harness.start_opts()) :: [{String.t(), String.t()}]
defp env(opts) do
  secret_env =
    opts
    |> Map.get(:secrets, %{})
    |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)

  # ADD THIS:
  claude_path = System.get_env("CLAUDE_CODE_PATH") || System.find_executable("claude") || "claude"

  [{"ADW_EMIT", "json"}, {"CLAUDE_CODE_PATH", claude_path} | secret_env]
end
```

**Option 3 (Runtime config)**: Add it to the application config and read from there (for production deployments where `claude` might not be in PATH).

The Python ADW scripts need `CLAUDE_CODE_PATH` to spawn Claude Code as subagents in their workflow steps. The error message confirms: "Error: Missing required environment variables: - CLAUDE_CODE_PATH"
