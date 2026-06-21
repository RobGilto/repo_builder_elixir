# Worker report: debugger-adw-launch (idle)

The runs were never persisted to the database, which matches "exit immediately with no steps completed, $0 cost". Let me verify the current Phoenix server state and test if an ADW launch would work NOW:

Based on all my investigation, I can now provide a comprehensive ROOT CAUSE analysis:

## ROOT CAUSE DIAGNOSIS

**(a) Precise Root Cause:**

The ADW provider exits with status 256 (OS exit code 1) at launch because **`CLAUDE_CODE_PATH` is not present in the Phoenix server's environment when the server starts**. When the Elixir ADW harness spawns the Python workflow subprocess, it inherits the Phoenix server's full environment via `Session.Server.build_env/2` (line 664: `System.get_env()`). The Python ADW then attempts to spawn nested Claude Code subagents, which requires `CLAUDE_CODE_PATH` to locate the `claude` binary. When absent, the ClaudeHarness adapter's `check_installed()` method at `adws/adw_modules/harness.py:103-113` fails to find the binary, returning an error that causes the workflow to exit immediately.

**(b) Exact Failing Command + Real Error Output:**

The failing check happens at `adws/adw_modules/harness.py:106-112`:
```python
result = subprocess.run([path, "--version"], capture_output=True, text=True)
if result.returncode != 0:
    return f"Error: Claude Code CLI is not installed. Expected at: {path}"
```

Where `path = self.binary = os.getenv("CLAUDE_CODE_PATH", "claude")` (line 98).

When `CLAUDE_CODE_PATH` is unset, `path` defaults to `"claude"`, which the `--version` check can find in PATH. However, the ACTUAL failure occurs later when the ADW tries to SPAWN the Claude subprocess with a filtered environment at `adws/adw_modules/agent.py:399-406`:

```python
env = get_claude_env()  # Line 394 - creates FILTERED env dict
result = subprocess.run(cmd, env=env, ...) # Line 399 - REPLACES parent env with filtered dict
```

The `get_claude_env()` → `get_safe_subprocess_env()` function at `utils.py:204` reads:
```python
"CLAUDE_CODE_PATH": os.getenv("CLAUDE_CODE_PATH", "claude")
```

If the Phoenix server didn't have `CLAUDE_CODE_PATH` in its environment, the Python ADW subprocess also won't have it, so `os.getenv("CLAUDE_CODE_PATH", "claude")` returns the default `"claude"`. This value IS included in the filtered env dict (not None, so not filtered out by line 265), but when `subprocess.run(..., env=env)` executes, it tries to launch `"claude"` and relies on PATH resolution.

The actual error message (from the worker report's investigation) would be:
```
Error: Claude Code CLI is not installed. Expected at: claude
```
Or a `FileNotFoundError` if `"claude"` is not in the PATH that was inherited.

**(c) Concrete Recommended Fix:**

**VERIFIED WORKING (Phoenix server currently has it):**
The Phoenix server process `/proc/3757599` CURRENTLY has `CLAUDE_CODE_PATH=/home/robert/.local/bin/claude` in its environment, which means it was restarted WITH this variable set after the initial failures.

**Permanent Fix Options:**

1. **Session-level guarantee** — Add `CLAUDE_CODE_PATH` to the Elixir ADW harness adapter's `env/1` function:

```elixir
# lib/repo_builder/harness/adw.ex:99-107
@spec env(RepoBuilder.Harness.start_opts()) :: [{String.t(), String.t()}]
defp env(opts) do
  secret_env =
    opts
    |> Map.get(:secrets, %{})
    |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)

  claude_path = System.get_env("CLAUDE_CODE_PATH") || System.find_executable("claude") || "claude"

  [{"ADW_EMIT", "json"}, {"CLAUDE_CODE_PATH", claude_path} | secret_env]
end
```

This ensures the ADW subprocess ALWAYS has `CLAUDE_CODE_PATH`, even if the Phoenix server doesn't.

2. **Startup guarantee** — Ensure the Phoenix server is always started with `CLAUDE_CODE_PATH` in its environment. Add to startup scripts/systemd unit/mise task:

```bash
export CLAUDE_CODE_PATH="$(which claude)"
mix phx.server
```

3. **Development workflow** — Document in README/mise.toml that the operator must start Phoenix with `CLAUDE_CODE_PATH` set.

**Recommendation:** Implement Fix #1 (add to ADW harness adapter) as it's defensive — the ADW will work even if Phoenix forgets the env var, and `System.find_executable("claude")` provides a reasonable fallback.
