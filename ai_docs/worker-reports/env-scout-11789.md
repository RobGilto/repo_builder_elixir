# Worker report: env-scout (idle)

Perfect. Now I have enough information to provide a comprehensive report.

## Report: `.env` File Analysis

### 1. **File Existence & Contents**

✅ `.env` exists. Keys defined (redacted):
- `CLAUDE_CODE_PATH` — path to claude binary (critical for ADW workflows)
- `FIRECRAWL_API_KEY` — web scraping tool credentials
- ~~`ANTHROPIC_API_KEY`~~ — commented out in `.env`
- ~~`OPENAI_API_KEY`~~ — commented out in `.env`
- `PORT` — HTTP port (default: 4000)

### 2. **Gitignore Status**

✅ Gitignored: `.gitignore:68` explicitly excludes `/.env`

The `.env.sample` template is committed as reference documentation.

### 3. **Load Mechanism & References**

`.env` is **loaded via `mise.toml`**, not by a dotenv library:

```toml
[env]
_.file = ".env"
CLAUDE_CODE_PATH = "/home/robert/.local/bin/claude"
```

**Mise activation** (`mise activate`) sources `.env` into the shell environment. All variables are then available to the Elixir app via `System.get_env()`.

**Runtime usage in code:**
- `config/runtime.exs` reads: `PORT`, `PHX_SERVER`, `WEBHOOK_SECRET`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `FIRECRAWL_API_KEY`, `ORCHESTRATOR_MCP_BASE_URL`, `REPO_BUILDER_MAX_LINE_BYTES`, `DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST`, `POOL_SIZE`, `ECTO_IPV6`, `DNS_CLUSTER_QUERY`
- `lib/repo_builder/harness/adw.ex` reads: `CLAUDE_CODE_PATH`
- No dotenv-loading library (no `import_config` or `dotenv_load`)

### 4. **Requirement Analysis**

| Variable | Required? | Default/Override | Status |
|----------|-----------|------------------|--------|
| `CLAUDE_CODE_PATH` | ✅ **YES** (ADW) | Fallback: `System.find_executable("claude")` | Set in .env |
| `FIRECRAWL_API_KEY` | ✅ **YES** (firecrawl tool) | None | Set in .env |
| `ANTHROPIC_API_KEY` | ❌ Optional (only if using pi harness) | None | Not set |
| `OPENAI_API_KEY` | ❌ Optional (only if using pi harness) | None | Not set |
| `PORT` | ❌ Optional | Default: 4000 | **Hardcoded in mise.toml** |
| `WEBHOOK_SECRET` | ❌ Optional | None | Not set |
| `ORCHESTRATOR_MCP_BASE_URL` | ❌ Optional | Default: localhost:4000 | Not set |
| `DATABASE_URL` | ✅ **YES** (prod only) | Hardcoded in `config/dev.exs` | Dev uses postgres@localhost/repo_builder_dev |
| `SECRET_KEY_BASE` | ✅ **YES** (prod only) | Hardcoded in `config/dev.exs` | — |

---

## Verdict: **KEEP** `.env`

### Why:
1. **`CLAUDE_CODE_PATH` is critical** — ADW (AI Developer Workflow) requires the claude binary path to spawn nested agent sessions. Without it, all orchestrator agent runs will fail.
2. **`FIRECRAWL_API_KEY` is loaded** — The web research tools need this credential.
3. **Clean separation** — `.env.sample` documents all available tunables; `.env` holds real secrets (gitignored). This is a standard pattern.
4. **Mise integration works** — The project uses `mise.toml [env] _.file = ".env"` to source it, so `mise activate` auto-loads on shell entry.

### Caveats:
- The `.env` file is **not auto-loaded by the Elixir app itself** — it must be sourced by `mise activate` before running `mix phx.server` or tests. If you run `mix` without `mise activate`, the variables won't be available.
- `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` are commented out in your `.env` but documented in `.env.sample` for completeness (they'd only be needed if using Claude/OpenAI harnesses in place of the default Fake harness in dev).

**Action**: Keep `.env` as-is; it's properly gitignored and actively used for runtime configuration.
