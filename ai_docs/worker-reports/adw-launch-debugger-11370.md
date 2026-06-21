# Worker report: adw-launch-debugger (idle)

**Report**:

### Root Cause

The incorrect runtime.exs edit adding `ANTHROPIC_API_KEY` to `harness_secrets` for both "claude" and "adw" was based on a misunderstanding of the authentication model:

- **OAuth authentication** (used by the local `claude` CLI): Credentials stored in `~/.claude/`, automatically accessible via inherited `HOME` environment
- **API key authentication**: Requires explicit `ANTHROPIC_API_KEY` env var (only used by the "pi" harness when it calls Anthropic models)

### Environment Inheritance Mechanism

The spawn path at `lib/repo_builder/session/server.ex:285` (`build_env/2`):

```elixir
defp build_env(env, marker) do
  System.get_env()                        # ← INHERITS FULL PARENT ENV (HOME, PATH, XDG_*, etc.)
  |> Map.merge(Map.new(env))              # ← Merges harness-specific additions
  |> Map.put("REPO_BUILDER_SESSION_MARKER", marker)
  |> Enum.reject(fn {_k, v} -> v == "" end)
  |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
end
```

This means **all** child processes (claude, adw, pi) automatically get:
- `HOME=/home/robert` (where `~/.claude/` OAuth credentials live)
- `PATH` (for locating binaries)
- All other ambient shell environment

### Comparison: claude vs adw Harness Spawn

**Claude harness** (`lib/repo_builder/harness/claude.ex:411-416`):
```elixir
defp env(opts) do
  opts
  |> Map.get(:secrets, %{})
  |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)
end
```
- Returns ONLY the secret env vars
- OAuth works because HOME is inherited via `build_env/2`

**ADW harness** (`lib/repo_builder/harness/adw.ex:102-111`):
```elixir
defp env(opts) do
  secret_env =
    opts
    |> Map.get(:secrets, %{})
    |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)

  claude_path =
    System.get_env("CLAUDE_CODE_PATH") || System.find_executable("claude") || "claude"

  [{"ADW_EMIT", "json"}, {"CLAUDE_CODE_PATH", claude_path} | secret_env]
end
```
- Returns secret env vars PLUS `ADW_EMIT=json` and `CLAUDE_CODE_PATH`
- OAuth works because HOME is inherited via `build_env/2`
- `CLAUDE_CODE_PATH` is correctly resolved (falls back to `System.find_executable("claude")`)

### Manual Verification

```bash
$ uv run adws/adw_workflows/adw_plan_build.py --prompt "test" --working-dir /tmp --adw-id test123 --emit json
{"schema_version": 1, "type": "session_started", "adw_id": "test123", ...}
```
- No exit 256/1
- No missing CLAUDE_CODE_PATH error
- Confirms OAuth auth works

### The Fix

**Reverted** config/runtime.exs:36,41 (removed incorrect ANTHROPIC_API_KEY entries for "claude" and "adw"):

```diff
 config :repo_builder, :harness_secrets, %{
-  "claude" => %{"ANTHROPIC_API_KEY" => System.get_env("ANTHROPIC_API_KEY")},
   "pi" => %{
     "OPENAI_API_KEY" => System.get_env("OPENAI_API_KEY"),
     "ANTHROPIC_API_KEY" => System.get_env("ANTHROPIC_API_KEY")
-  },
-  "adw" => %{"ANTHROPIC_API_KEY" => System.get_env("ANTHROPIC_API_KEY")}
+  }
 }
```

### Why the Original ADW Exit 256 Happened

The worker report at `ai_docs/worker-reports/adw-debugger-10067.md` diagnosed a missing `CLAUDE_CODE_PATH` issue, but the current codebase already has the fix (adw.ex:108-111). The report is stale. The actual exit 256 would have occurred if:

1. The Phoenix server was started in an environment where `claude` was NOT in PATH
2. AND `CLAUDE_CODE_PATH` was not set
3. AND the ADW Python validation at `adws/adw_modules/utils.py:170-176` failed

But `System.find_executable("claude")` successfully finds the mise-installed claude binary at `/home/robert/.local/share/mise/installs/node/25.8.0/bin/claude`, so the spawn should work.

### Should the runtime.exs Edit Be Reverted?

**YES** - reverted in the edit above. The correct model:
- **OAuth harnesses** (claude, adw): NO `harness_secrets` entry needed
- **API key harnesses** (pi with Anthropic provider): Keep the `ANTHROPIC_API_KEY` entry in `harness_secrets["pi"]`
