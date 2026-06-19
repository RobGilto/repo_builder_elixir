# Feature: Orchestrator-granted firecrawl research tools for worker agents

## Metadata
issue_number: `the`
adw_id: `orchestrator`
issue_json: `to`

## Feature Description
Let the orchestrator **grant a worker agent the firecrawl MCP toolset** (web
`scrape` / `crawl` / `search` / `map` / `extract`) so a researcher-type worker can do
live web research. Whether a given worker gets firecrawl is a **per-worker capability
flag** the orchestrator sets when it spawns or updates a worker (`create_agent` /
`update_agent`). The flag is stored in the worker's open `Agent.config` map — it is
**not** a secret.

There is exactly **one** firecrawl credential for the whole app: `FIRECRAWL_API_KEY`,
read from the environment (`.env` / OS env) at startup. It is **never** persisted to the
database, never placed in argv, and is scrubbed from logs — exactly like the existing
`ANTHROPIC_API_KEY`/`OPENAI_API_KEY` handling. No settings UI, no per-tenant keys, and
no encryption are added (explicitly out of scope).

This closes a real gap: today **only the orchestrator** gets MCP tools (via a
per-session `.mcp.json` written by `Claude.orchestrator_spawn/2`). A spawned worker has
**no MCP seam at all**, so the orchestrator cannot delegate web research to a worker
even though it can see the work needs doing. This feature adds the missing worker-side
MCP binding, gated by the capability flag, with firecrawl as the first (and only)
tool wired in.

## User Story
As an operator driving the orchestrator
I want the orchestrator to be able to spawn a worker **with firecrawl web-research tools**
So that a researcher worker can scrape/search the live web during a task, without me
hand-wiring MCP config or exposing the API key anywhere but `.env`.

## Problem Statement
Worker agents are spawned through each harness adapter's `command/1`
(`lib/repo_builder/harness/claude.ex:74-96`), which builds argv with **no**
`--mcp-config` flag — so a worker runs with only its CLI's native tools. The MCP
binding (`.mcp.json` + `--mcp-config --strict-mcp-config`) lives exclusively in the
`Orchestrating.orchestrator_spawn/2` callback (`claude.ex:27-49`), which **workers
never reach** (only orchestrator sessions do, via
`Session.Server.maybe_orchestrator_spawn/4`, `session/server.ex:209,221-224`).

Consequently the orchestrator has no way to give a worker web-research tools. The
operator's intent — "spawn a researcher that can crawl the web" — is unsatisfiable
today. Separately, there is no place to declare a per-worker tool capability, and no
plumbing to deliver a tool's API key to (only) the workers that need it.

## Solution Statement
Two cleanly separated concerns:

1. **Capability (non-secret, in DB):** a `"tools"` list in the worker's `Agent.config`
   (e.g. `["firecrawl"]`). The orchestrator sets it through new optional `tools` params
   on the `create_agent` and `update_agent` meta-tools. `Agent.config` is the existing
   open `:map` field that already carries `provider` + template provenance
   (`agents/agent.ex:38`, built by `agent_config/2` in `tools.ex:178-184`).

2. **Credential (secret, in env only):** a new `:tool_secrets` runtime config block,
   `%{"firecrawl" => %{"FIRECRAWL_API_KEY" => System.get_env("FIRECRAWL_API_KEY")}}`,
   read at startup in `config/runtime.exs` (mirrors the existing `:harness_secrets`
   block, `runtime.exs:35-41`). `Session.Server.resolve_secrets/2`
   (`session/server.ex:178-190`) is extended to fold in the tool secrets **only for the
   tools the worker actually has enabled** (read from the session config), so the key
   reaches the spawned process env of firecrawl-enabled workers and no others.

The worker spawn path of `Claude.command/1` is extended: when the session config
requests one or more MCP tools, it writes a worker `.mcp.json` to the session cwd
declaring the firecrawl **stdio** server (`npx -y firecrawl-mcp`, with its
`FIRECRAWL_API_KEY` supplied via `${FIRECRAWL_API_KEY}` env-expansion so the literal
key is **not** written to disk), and appends
`--mcp-config <path> --strict-mcp-config --allowedTools mcp__firecrawl__*` so an
autonomous worker can call the tools without an interactive prompt. Native worker tools
(Write/Edit/Bash) are untouched. The orchestrator's own spawn is unaffected (its config
carries `%{orchestrator: true}` and no `"tools"` key, so the new branch is inert).

Finally, the orchestrator system prompt is extended with a short "research tools" note
so the LLM knows it *can* grant firecrawl to a researcher worker and how.

**Harness scope:** firecrawl-over-MCP is wired for **both** worker harnesses, Claude and
pi, behind the same harness-agnostic capability flag.

- **Claude** uses native `--mcp-config <path> --strict-mcp-config` — a clean allow-list
  with no ambient servers.
- **pi** speaks MCP through the operator's globally-installed `pi-mcp-adapter` extension
  (`npm:pi-mcp-adapter`, wired in `~/.pi/agent/settings.json`), which auto-loads in
  `--mode json` print runs and registers an `--mcp-config <path>` flag plus the `mcp`
  proxy tool. The decisive gating lever is **extension loading**, not config files: pi's
  `--no-extensions` (`-ne`) suppresses discovery of the auto-loaded adapter, so a worker
  without a grant has **no** `mcp` tool at all. A *granted* pi worker omits `-ne` (the
  adapter auto-loads) and is passed `--mcp-config <session file>` declaring firecrawl;
  `FIRECRAWL_API_KEY` is inherited from the worker's process env (injected by
  `resolve_secrets/2`), so the firecrawl stdio server the adapter spawns picks it up
  without the key touching disk.

  Caveat (documented, accepted): pi's adapter `--mcp-config` overrides only the
  agent-dir config slot; `loadMcpConfig` still merges `~/.config/mcp/mcp.json` (a
  user-global file) and any cwd `.mcp.json`/`.pi/mcp.json`. So a *granted* pi worker may
  also see the operator's own other global MCP servers (lazy, operator-owned — not a
  security exposure for this single-operator local tool). A *non-granted* pi worker is
  cleanly denied via `-ne`. Strict subtraction for granted pi workers would require
  patching the adapter or emptying `~/.config/mcp/mcp.json` and is out of scope.

This is a deliberate tightening: today pi workers run bare `pi --mode json` (no `-ne`),
so they silently inherit the adapter **and every server** in the operator's config
(firecrawl included) — ungated. After this feature, ungated pi workers get `-ne` (no
MCP), and firecrawl is an explicit, orchestrator-granted capability. A worker whose
harness can't honor a requested tool spawns without it (no error; logged once).

## Relevant Files
Use these files to implement the feature:

- `config/runtime.exs` — Adds the `:tool_secrets` block (read from OS env at startup),
  alongside the existing `:harness_secrets` (`runtime.exs:35-41`). Single source of the
  one app-wide `FIRECRAWL_API_KEY`.
- `lib/repo_builder/session/server.ex` — `resolve_secrets/2` (`:178-190`) folds tool
  secrets in for the worker's enabled tools; `start_opts`/`State` already thread
  `config` and `secrets` to the adapter (`:196-206`). The worker config (`state.config`)
  is where the `"tools"` list is read to decide which tool secrets to merge.
- `lib/repo_builder/harness/claude.ex` — `command/1` (`:74-96`) is the **worker** spawn
  path; extend it to write a worker `.mcp.json` + append `--mcp-config`/
  `--strict-mcp-config`/`--allowedTools mcp__firecrawl__*` when the config requests
  tools. Reuse the `.mcp.json`-in-cwd + secrets-in-env patterns already established by
  `orchestrator_spawn/2`/`mcp_config_json/1` (`:27-68`) and `env/1` (`:332-337`).
- `lib/repo_builder/harness/pi.ex` — `command/1` (`:63-82`) is the **worker** spawn path
  (orchestrator uses `orchestrator_spawn/2` `:29-51`). Extend it: when the config enables
  tools, write a pi session MCP file and append the adapter's `--mcp-config <path>` (let
  the adapter auto-load — omit `-ne`); when no tools are enabled, append `--no-extensions`
  (`-ne`) to deny ambient MCP. `env/1` (`:373-381`) already injects secrets — the
  firecrawl key rides there. Confirm `append_approve/2` (`:96-103`) still fires for
  autonomous workers.
- `lib/repo_builder/harness/mcp_tools.ex` *(new)* — a small, typed, harness-agnostic
  helper that turns a list of enabled tool names into the `mcpServers` JSON fragment, the
  Claude `allowedTools` patterns, and the `secret_keys` each tool needs. Keeps tool→server
  knowledge in one place so adding a second tool later is a data edit, not adapter surgery.
  Both the Claude and pi adapters consume the **same** `mcp_servers/1` fragment.
- `lib/repo_builder/orchestrator/tools.ex` — `create_agent/2` (`:89-124`, via
  `agent_config/2` `:178-184`) and `update_agent/2` (`:495+`) read a new optional
  `tools` arg and persist it into `Agent.config["tools"]`. `worker_session_config/1`
  (`:952-953`) already threads `config` (string keys) into the session — the `"tools"`
  list rides along unchanged.
- `lib/repo_builder/orchestrator/tool_catalog.ex` — `create_agent` (`:23+`) and
  `update_agent` (`:122+`) input-schemas gain an optional `tools` array property
  (enum of known tool names, currently `["firecrawl"]`) with a clear description.
- `lib/repo_builder/orchestrator/system_prompt.ex` — Add a concise "RESEARCH TOOLS"
  note so the orchestrator knows firecrawl exists and how to grant it.
- `lib/repo_builder/agents/agent.ex` — `config` field (`:38`); no schema change needed
  (open map), but confirm `worker_changeset/1` casts `config` (it does, `:71-81`).
- `lib/repo_builder/agents.ex` — `create_worker/2`, `update_worker/2` (`:53+`); no
  change (params flow through `config`). Read-only reference.
- `lib/repo_builder/harness/redact.ex` — Read-only reference confirming secrets are
  scrubbed from persisted `raw` frames; verify `FIRECRAWL_API_KEY` is covered (it
  redacts secret values by the session's secret map, so it is automatically covered).
- `lib/repo_builder/harness/registry.ex` — Read-only; confirms which harnesses exist and
  the `command/1` contract.
- `BUILD_PROMPT.md` — §3 (typed style), §4.3 (harness adapters), §6 (session runtime &
  secrets-in-env invariant), §8 (DB behind contexts), §10 (extensibility).
- `AGENTS.md`, `README.md` — conventions and run instructions.
- `ai_docs/typed-elixir-standard.md` — the enforced typed standard (always-on row of
  `.claude/commands/conditional_docs.md`): `@spec` on every public function, precise
  types over `map()`/`any()`.

### New Files
- `lib/repo_builder/harness/mcp_tools.ex` — typed catalog mapping enabled tool names →
  `{mcp_servers_json_fragment, allowed_tool_patterns}`; the single place that knows
  firecrawl is `npx -y firecrawl-mcp` (stdio) with `FIRECRAWL_API_KEY`.
- `test/repo_builder/harness/mcp_tools_test.exs` — unit tests for the catalog helper
  (known tool → server fragment + allowed patterns; unknown tool ignored; empty list →
  no MCP).
- `test/repo_builder/harness/claude_worker_mcp_test.exs` — adapter test: `command/1`
  with `config["tools"] == ["firecrawl"]` writes a `.mcp.json` (declaring the firecrawl
  stdio server, key via `${FIRECRAWL_API_KEY}` expansion — literal key absent from the
  file) and appends `--mcp-config`/`--strict-mcp-config`/`--allowedTools mcp__firecrawl__*`;
  with no tools it writes no file and adds no MCP args; the key never appears in argv.
- `test/repo_builder/harness/pi_worker_mcp_test.exs` — adapter test: `Pi.command/1` with
  `config["tools"] == ["firecrawl"]` writes a pi session MCP file (firecrawl stdio
  server) and appends `--mcp-config <path>` **without** `-ne`; with no tools it appends
  `--no-extensions` and writes no MCP file; in neither case does `FIRECRAWL_API_KEY`
  appear in argv (the key rides in `env/1`).
- `test/repo_builder/session/tool_secrets_test.exs` — `resolve_secrets/2` folds
  `FIRECRAWL_API_KEY` into the env **only** when the session config enables firecrawl;
  absent otherwise.
- `test/repo_builder/orchestrator/firecrawl_grant_test.exs` — `Tools.call("create_agent",
  …, %{"tools" => ["firecrawl"]})` persists `config["tools"] == ["firecrawl"]`;
  `update_agent` adds/removes it; `tool_catalog` advertises the `tools` param.

## Implementation Plan
### Phase 1: Foundation
Establish the two separated concerns and the single tool→server knowledge point.
- Add the `:tool_secrets` runtime block (one `FIRECRAWL_API_KEY` from env).
- Create the typed `Harness.McpTools` catalog helper: `enabled` tool list →
  `mcp_servers/1` (JSON-encodable map fragment) + `allowed_tools/1` (patterns) +
  `secret_keys/1` (which env keys a tool needs). Firecrawl is the only entry.
- Extend `Session.Server.resolve_secrets/2` to merge tool secrets for the session
  config's enabled tools using `McpTools.secret_keys/1` + the `:tool_secrets` config.

### Phase 2: Core Implementation
Wire the worker MCP binding (both harnesses) and the orchestrator grant surface.
- Extend `Claude.command/1`: when `opts.config` enables tools, write a worker
  `.mcp.json` (via `McpTools.mcp_servers/1`, key referenced as `${FIRECRAWL_API_KEY}`)
  and append `--mcp-config <abs path> --strict-mcp-config --allowedTools <patterns>`.
  Factor a private `worker_mcp_args/1` so the orchestrator path stays untouched.
- Extend `Pi.command/1` (worker path): when tools are enabled, write a pi session MCP
  file from the same `McpTools.mcp_servers/1` fragment and append `--mcp-config <abs
  path>` (omit `-ne` so the auto-loaded adapter handles it); when none are enabled,
  append `--no-extensions` to deny ambient MCP. The orchestrator path
  (`orchestrator_spawn/2`) is untouched.
- Add the optional `tools` param to `create_agent`/`update_agent` (tool_catalog schemas
  + tools.ex handlers): validate against `McpTools.known/0`, persist into
  `Agent.config["tools"]`.
- Add the "RESEARCH TOOLS" note to the orchestrator system prompt.

### Phase 3: Integration
- Confirm end-to-end that `config["tools"]` set by `create_agent` flows through
  `worker_session_config/1` → `Session.Server` → the harness `command/1` and produces
  the right binding per harness (Claude: `.mcp.json` + `--mcp-config`/
  `--strict-mcp-config`/`--allowedTools`; pi: session MCP file + `--mcp-config`, no
  `-ne`), with `FIRECRAWL_API_KEY` present in the child env and absent from argv (and,
  for Claude, absent as a literal from `.mcp.json`). Verify both orchestrator spawns are
  unchanged. Verify an **ungated** pi worker now spawns with `-ne` (no MCP) — a
  deliberate tightening from today's ambient behavior.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Read the contract docs and anchor the seams
- Read `BUILD_PROMPT.md` §3, §4.3, §6, §10; `ai_docs/typed-elixir-standard.md`; `AGENTS.md`.
- Use Tidewave `get_source_location` on `RepoBuilder.Harness.Claude.command/1`,
  `RepoBuilder.Harness.Claude.orchestrator_spawn/2`,
  `RepoBuilder.Session.Server.resolve_secrets/2`,
  `RepoBuilder.Orchestrator.Tools.create_agent/2`, and
  `RepoBuilder.Orchestrator.ToolCatalog.tools/0` to anchor edits.
- Confirm the firecrawl MCP invocation: stdio server `npx -y firecrawl-mcp`, credential
  env var `FIRECRAWL_API_KEY`, Claude tool-name prefix `mcp__<serverkey>__*` (use
  server key `"firecrawl"` ⇒ tools advertised as `mcp__firecrawl__firecrawl_scrape`,
  `…_search`, `…_crawl`, `…_map`, `…_extract`; allow-pattern `mcp__firecrawl__*`).
- Confirm the pi seam: workers run bare `pi --mode json` today (`pi.ex:63-82`), which
  auto-loads the operator's `npm:pi-mcp-adapter`; the adapter registers `--mcp-config
  <path>` and the `mcp` proxy tool. pi's `--no-extensions` (`-ne`) disables discovery of
  that adapter (explicit `-e` still works). The adapter's `--mcp-config` overrides only
  the agent-dir slot and still merges `~/.config/mcp/mcp.json` — so gating is by
  extension loading (`-ne`), not config files. Verify with Tidewave/manual:
  `pi --mode json -ne -p "list MCP servers"` shows none; without `-ne` shows the
  operator's servers.

### 2. Add the `:tool_secrets` runtime config
- In `config/runtime.exs`, next to `:harness_secrets`, add:
  ```elixir
  config :repo_builder, :tool_secrets, %{
    "firecrawl" => %{"FIRECRAWL_API_KEY" => System.get_env("FIRECRAWL_API_KEY")}
  }
  ```
- Add a `.env.example`/README note documenting `FIRECRAWL_API_KEY` (one key, app-wide,
  loaded from env; never committed). Do **not** add a dotenv dependency — the value is
  read via `System.get_env` exactly like the existing keys.

### 3. Create the typed `Harness.McpTools` catalog helper (new file)
- `lib/repo_builder/harness/mcp_tools.ex`, module `RepoBuilder.Harness.McpTools`.
- Define a closed `@type tool :: :firecrawl` and the public API, each `@spec`'d:
  - `@spec known() :: [String.t()]` → `["firecrawl"]`.
  - `@spec enabled([String.t()] | nil) :: [tool()]` — parse a config `"tools"` list
    (string keys, JSONB) into the closed atom set, dropping unknowns (never
    `String.to_atom` on untrusted input — use a closed string→atom lookup).
  - `@spec mcp_servers([tool()]) :: %{String.t() => map()}` — e.g. for `[:firecrawl]`:
    `%{"firecrawl" => %{"command" => "npx", "args" => ["-y", "firecrawl-mcp"], "env" => %{"FIRECRAWL_API_KEY" => "${FIRECRAWL_API_KEY}"}}}`. `{}` for `[]`.
  - `@spec allowed_tools([tool()]) :: [String.t()]` — `["mcp__firecrawl__*"]` for
    `[:firecrawl]`.
  - `@spec secret_keys([tool()]) :: [{String.t(), String.t()}]` — `[{"firecrawl",
    "FIRECRAWL_API_KEY"}]`, used by `resolve_secrets/2` to pull from `:tool_secrets`.
- Keep all firecrawl-specific knowledge here so a second tool is a data addition.

### 4. Unit-test the catalog helper (early validation)
- `test/repo_builder/harness/mcp_tools_test.exs`: `enabled(["firecrawl","bogus"]) ==
  [:firecrawl]`; `enabled(nil) == []`; `mcp_servers([:firecrawl])` has the stdio shape
  with `${FIRECRAWL_API_KEY}` (not a literal key); `allowed_tools([:firecrawl]) ==
  ["mcp__firecrawl__*"]`; `mcp_servers([]) == %{}`.

### 5. Extend `Session.Server.resolve_secrets/2` to fold in tool secrets
- Read the session config's enabled tools (`McpTools.enabled(config["tools"])`).
- For each `{tool, env_key}` from `McpTools.secret_keys/1`, look up `:tool_secrets` →
  tool → env_key, reject nil, and `Map.merge` into the resolved secret map (after the
  existing per-harness merge; explicit `opts[:secrets]` still wins last).
- Keep the `@spec` precise; the function still returns `map()` of string⇒string.

### 6. Extend `Claude.command/1` worker MCP binding
- Add a private `@spec worker_mcp_args(map()) :: {[String.t()], :ok}` (or return just
  the extra args list) that:
  - computes `tools = McpTools.enabled(opts.config["tools"])`; returns `[]` when empty;
  - else `cwd = Path.expand(opts.cwd)`, writes `Path.join(cwd, ".mcp.json")` with
    `Jason.encode!(%{"mcpServers" => McpTools.mcp_servers(tools)})` (mkdir_p! first;
    write with restrictive perms — reuse the orchestrator file-write approach);
  - returns `["--mcp-config", path, "--strict-mcp-config", "--allowedTools" |
    McpTools.allowed_tools(tools)]` (one `--allowedTools` per pattern, matching how
    `--disallowedTools` is spread in `orchestrator_spawn/2`).
- Append those args in `command/1` (worker path only — guard that `opts.config` is a
  map and lacks `:orchestrator`/`orchestrator: true`, so the orchestrator path that
  already declares MCP via `orchestrator_spawn/2` is never double-bound).
- Note: `opts.config` keys are **strings** for workers (JSONB) but the autonomous flag
  is the atom `:autonomous`; read `"tools"` as a string key.
- Keep `FIRECRAWL_API_KEY` out of argv entirely — it only ever appears as the env var
  (Step 5) and as the `${FIRECRAWL_API_KEY}` placeholder text inside `.mcp.json`.

### 7. Adapter test for the worker MCP binding (new file)
- `test/repo_builder/harness/claude_worker_mcp_test.exs`: call `Claude.command/1` with a
  temp `cwd` and `config: %{"tools" => ["firecrawl"]}`; assert the returned args contain
  `--mcp-config`, `--strict-mcp-config`, `--allowedTools`, `mcp__firecrawl__*`; read the
  written `.mcp.json` and assert it declares the `firecrawl` stdio server and contains
  the literal string `${FIRECRAWL_API_KEY}` but **not** any `fc-…` value; assert no arg
  contains `FIRECRAWL_API_KEY`. With `config: %{}` assert no `.mcp.json` and no
  `--mcp-config`. (Use an `on_exit` to clean the temp dir.)

### 8. Extend `Pi.command/1` worker MCP binding
- Add a private `@spec worker_mcp_args(map()) :: [String.t()]` for the pi adapter that:
  - computes `tools = McpTools.enabled(opts.config["tools"])`;
  - when empty → returns `["--no-extensions"]` (deny the operator's auto-loaded
    `pi-mcp-adapter` so an ungated worker has no `mcp` tool);
  - when non-empty → `cwd = Path.expand(opts.cwd)`, writes a dedicated pi session MCP
    file `Path.join(cwd, ".pi-mcp.json")` (distinct from Claude's `.mcp.json`) with
    `Jason.encode!(%{"mcpServers" => McpTools.mcp_servers(tools)})`, and returns
    `["--mcp-config", path]` (NO `-ne` — the adapter must auto-load to honor the flag).
- Append those args in `command/1` after the existing flags, worker path only — guard on
  `opts.config` not being an orchestrator config (the orchestrator uses
  `orchestrator_spawn/2` and must not get `-ne`/`--mcp-config`). Read `"tools"` as a
  string key (JSONB), consistent with `append_approve/2`'s atom/string handling.
- The firecrawl stdio server inherits `FIRECRAWL_API_KEY` from the pi process env
  (already injected by `env/1` ← `resolve_secrets/2`); do not write the key into the pi
  MCP file. Keep the key out of argv.
- Document inline the accepted caveat: the adapter still merges `~/.config/mcp/mcp.json`,
  so a granted pi worker may also see the operator's other global servers (lazy,
  operator-owned). Ungated workers are cleanly denied via `-ne`.

### 9. Adapter test for the pi worker MCP binding (new file)
- `test/repo_builder/harness/pi_worker_mcp_test.exs`: `Pi.command/1` with a temp `cwd`
  and `config: %{"tools" => ["firecrawl"]}` → args contain `--mcp-config` and the
  `.pi-mcp.json` path, do **not** contain `--no-extensions`; the written `.pi-mcp.json`
  declares the firecrawl stdio server; no arg contains `FIRECRAWL_API_KEY`. With
  `config: %{}` → args contain `--no-extensions`, no `--mcp-config`, no MCP file written.
  (Use `on_exit` to clean the temp dir.)

### 10. Add the `tools` grant param to create_agent / update_agent
- `tool_catalog.ex`: add an optional `"tools"` property to both `create_agent` and
  `update_agent` input-schemas — `{"type" => "array", "items" => {"type" => "string",
  "enum" => ["firecrawl"]}}` with a description ("Grant MCP research tools to this
  worker, e.g. firecrawl web scrape/search/crawl. Omit for none.").
- `tools.ex`: in `create_agent/2`, thread the validated tools into the persisted config
  — extend `agent_config/2` (or fold after it) so `config["tools"]` is set when a
  non-empty, known tools list is given; ignore unknown names (or return a helpful error
  listing `McpTools.known/0` — prefer erroring on a fully-unknown name, mirroring
  `template_not_found/1`). In `update_agent/2`, allow setting/replacing `config["tools"]`
  (merge into the existing config so other keys — provider/template — are preserved).
- Keep all new functions `@spec`'d with precise types.

### 11. Orchestrator tools/grant test (new file)
- `test/repo_builder/orchestrator/firecrawl_grant_test.exs`: via `Tools.call/3` (or the
  private handlers through the public seam used by existing tool tests), assert
  `create_agent` with `%{"tools" => ["firecrawl"]}` persists
  `Agents.get_agent(id).config["tools"] == ["firecrawl"]` and preserves `provider`;
  `update_agent` adds then clears it; an all-unknown tools list returns an error naming
  the known tools; `ToolCatalog.tools()` includes the `tools` property on `create_agent`.

### 12. Surface firecrawl in the orchestrator system prompt
- `system_prompt.ex`: add a short "RESEARCH TOOLS" line — e.g. *"Workers can be granted
  web-research tools. Pass `tools: ["firecrawl"]` to `create_agent`/`update_agent` to
  give a researcher worker firecrawl (scrape/search/crawl/map/extract). Grant only to
  workers that need live web access."* Update `system_prompt_test.exs` to assert the
  prose is present.

### 13. Runtime verification (Tidewave)
- With the app running and `FIRECRAWL_API_KEY` exported, use Tidewave `project_eval` to:
  - call `RepoBuilder.Harness.McpTools.mcp_servers([:firecrawl])` and confirm the shape;
  - build a worker `start_opts` map with `config: %{"tools" => ["firecrawl"]}` and call
    `RepoBuilder.Harness.Claude.command/1`, confirming the `.mcp.json` + flags; then
    `RepoBuilder.Harness.Pi.command/1`, confirming `--mcp-config <.pi-mcp.json>` and no
    `-ne`; and with `config: %{}` confirm pi gets `--no-extensions` and Claude gets no
    MCP args;
  - call `RepoBuilder.Session.Server`-equivalent `resolve_secrets` path (or eval the
    private via a thin public test seam) to confirm the key folds in only when enabled.
- Manually confirm the pi gating lever: `pi --mode json -ne -p "list MCP servers"` shows
  none; without `-ne`, the operator's servers (incl. firecrawl) appear.
- Use `get_logs` to confirm no secret value is logged. (No browser/LiveView UI in this
  feature, so no screenshot step.)

### 14. Run the validation suite
- Run every command in `Validation Commands`; fix until all green with zero regressions.

## Testing Strategy
### Unit Tests
- `McpTools`: `enabled/1` parsing (known/unknown/nil), `mcp_servers/1` shape (stdio,
  `${FIRECRAWL_API_KEY}` placeholder, no literal key), `allowed_tools/1`, `secret_keys/1`.
- `Claude.command/1` worker path: MCP args + `.mcp.json` written when tools enabled;
  none when not; key never in argv; key never literal in the file.
- `Pi.command/1` worker path: `--mcp-config <.pi-mcp.json>` + MCP file when tools
  enabled (no `-ne`); `--no-extensions` and no MCP file when not; key never in argv.
- `Session.Server.resolve_secrets/2`: `FIRECRAWL_API_KEY` folded in only for firecrawl-
  enabled config; per-session `opts[:secrets]` override still wins.
- `Tools` create/update: `config["tools"]` persisted/updated/cleared; provider/template
  preserved; unknown-only tools list rejected with a helpful message.
- `system_prompt`: research-tools prose present.

### Edge Cases
- **No tools granted (Claude)** → no `.mcp.json`, no `--mcp-config`, no key in env
  (unchanged worker behavior).
- **No tools granted (pi)** → `--no-extensions` appended, no MCP file, no key in env.
  This is a deliberate change: today's ungated pi worker silently inherits the operator's
  adapter + all servers; after this feature it gets clean denial.
- **`FIRECRAWL_API_KEY` unset** → secret rejected (nil) so it never reaches env; the
  `.mcp.json` still references `${FIRECRAWL_API_KEY}`, and firecrawl tools simply fail at
  runtime with no key (no crash, no key leak). Note this in `Notes`.
- **Orchestrator spawn (both harnesses)** → carries `%{orchestrator: true}`, no `"tools"`
  key ⇒ the new worker branch is inert; orchestrator binding via `orchestrator_spawn/2`
  is unchanged (Claude keeps its HTTP MCP; pi keeps its `-e` extension, no `-ne`).
- **Granted pi worker also sees operator's global servers** → accepted caveat: the
  adapter merges `~/.config/mcp/mcp.json`; those are the operator's own lazy servers, not
  a security exposure for this single-operator tool. Strict subtraction is out of scope.
- **Unknown tool name** in the grant → ignored by `McpTools.enabled/1`; an all-unknown
  grant errors at the tool boundary with the known-tools list.
- **Secret never in argv / never in logs** → asserted in both adapter tests; `Redact`
  covers the value because it is in the session secret map.
- **MCP file collision** → Claude writes `.mcp.json`, pi writes `.pi-mcp.json`; a worker
  is a single harness, and the orchestrator writes to a different session cwd — never the
  same file.

## Acceptance Criteria
- The orchestrator can spawn a worker with `create_agent(name:, tools: ["firecrawl"])`
  and that worker's `Agent.config["tools"]` is `["firecrawl"]`; `update_agent` can add
  or clear the grant while preserving other config keys.
- A Claude worker with firecrawl granted is spawned with a `.mcp.json` declaring the
  `npx -y firecrawl-mcp` stdio server and with `--mcp-config <path> --strict-mcp-config
  --allowedTools mcp__firecrawl__*`; a worker without the grant gets none of that.
- A pi worker with firecrawl granted is spawned with `--mcp-config <.pi-mcp.json>` (the
  auto-loaded `pi-mcp-adapter` honors it) and **without** `--no-extensions`; a pi worker
  without the grant is spawned with `--no-extensions` (no `mcp` tool / no MCP).
- `FIRECRAWL_API_KEY` is read once from the environment (`.env`/OS env), reaches the
  child process **env** of firecrawl-enabled workers only, **never** appears in argv,
  **never** is written as a literal into `.mcp.json` (uses `${FIRECRAWL_API_KEY}`
  expansion), is **never** persisted to the DB, and is scrubbed from logs.
- No settings UI, no DB column, no encryption, no per-tenant keys are introduced.
- The orchestrator system prompt documents the firecrawl grant.
- The orchestrator's own spawn behavior is byte-for-byte unchanged.
- `mix compile --warnings-as-errors`, `mix format --check-formatted`,
  `mix credo --strict`, `mix dialyzer`, and `mix test --warnings-as-errors` are all green.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix test test/repo_builder/harness/mcp_tools_test.exs` — the tool catalog helper.
- `mix test test/repo_builder/harness/claude_worker_mcp_test.exs` — Claude worker MCP
  binding (.mcp.json + flags; key not in argv; `${FIRECRAWL_API_KEY}` placeholder).
- `mix test test/repo_builder/harness/pi_worker_mcp_test.exs` — pi worker MCP binding
  (`--mcp-config` + no `-ne` when granted; `--no-extensions` when not; key not in argv).
- `mix test test/repo_builder/session/tool_secrets_test.exs` — key folds into env only
  when firecrawl is enabled.
- `mix test test/repo_builder/orchestrator/firecrawl_grant_test.exs` — create/update_agent
  grant persistence + tool_catalog schema.
- `mix test test/repo_builder/orchestrator/system_prompt_test.exs` — research-tools prose.
- `mix test --warnings-as-errors` — full ExUnit suite, zero failures.
- `mix compile --warnings-as-errors` — clean compile; set-theoretic checker + warnings.
- `mix format --check-formatted` — formatting.
- `mix credo --strict` — lint incl. the every-public-function-`@spec` rule.
- `mix dialyzer` — contract checking; no new warnings, no stale ignores.

## Notes
- **No new Elixir/Mix dependencies.** Firecrawl runs as an out-of-process MCP server the
  worker's CLI launches (`npx -y firecrawl-mcp`); the Elixir app only writes the MCP
  config and supplies the env var. `npx`/Node must be on PATH in the worker's environment
  (document in the README alongside `FIRECRAWL_API_KEY`). The pi path additionally relies
  on the operator's already-installed `npm:pi-mcp-adapter` (verified present at
  `~/.local/share/mise/installs/node/*/lib/node_modules/pi-mcp-adapter`, v2.4.0, wired in
  `~/.pi/agent/settings.json`). If the adapter is absent, a granted pi worker simply has
  no `mcp` tool (no crash); document that pi MCP requires `pi install npm:pi-mcp-adapter`.
- **Why `${FIRECRAWL_API_KEY}` expansion in `.mcp.json`** instead of inlining the key:
  Claude Code expands `${VAR}` from the process env when reading `.mcp.json`, so the
  literal secret never lands on disk. The key is delivered to the worker process env by
  the existing `resolve_secrets/2` → `env/1` path (secrets-in-env invariant, §6). If a
  future Claude version drops `${VAR}` support, the fallback is to inline the value into
  a `0600` file in the ephemeral session cwd — the same trust model as the orchestrator
  bearer token already in `.mcp.json` (`claude.ex:38`); this is a one-line change in
  `McpTools.mcp_servers/1`.
- **Capability vs. secret separation** is the core design: the *grant* is non-secret
  config the orchestrator owns and can show/audit; the *key* is a single app-wide secret
  in env. This deliberately avoids encrypted settings / per-tenant keys (out of scope per
  the request) while leaving `resolve_secrets/2`'s per-session `opts[:secrets]` override
  as the seam where a DB-backed or encrypted source could later plug in without touching
  adapters.
- **pi gating is by extension loading, not config files.** The `pi-mcp-adapter`
  `--mcp-config` flag overrides only the agent-dir config slot; `loadMcpConfig` still
  merges `~/.config/mcp/mcp.json` (present here) + cwd `.mcp.json`/`.pi/mcp.json`, so it
  cannot *subtract* servers. The reliable lever is `--no-extensions` (`-ne`), which
  suppresses discovery of the auto-loaded adapter entirely (explicit `-e` still works) —
  so an ungated pi worker has no `mcp` tool at all. A granted pi worker omits `-ne` and
  passes `--mcp-config <session file>` to declare firecrawl deterministically; the
  firecrawl key reaches the spawned server via the pi process env. The remaining
  imperfection (a granted pi worker also sees the operator's other global servers from
  `~/.config/mcp/mcp.json`) is accepted for this single-operator tool; strict isolation
  would require patching the adapter or isolating `PI_CODING_AGENT_DIR` per session
  (risky — it also holds pi's model/auth state) and is out of scope.
- **pi `.pi-mcp.json` filename** is deliberately distinct from Claude's `.mcp.json` so the
  two adapters never contend for the same cwd file; pi's `--mcp-config` reads any path.
- **Extensibility:** adding a second research tool (e.g. another MCP server) is a data
  edit in `McpTools` (one entry: server fragment, allowed pattern, secret key) plus a
  one-word enum addition in the tool_catalog schemas — no adapter or session changes.
