# Feature: Multi-Harness Orchestrator Agent (the orchestrator that selects & dispatches agents)

## Metadata
issue_number: `c`
adw_id: `orchbrain`
issue_json: `{"title":"Build the conversational Orchestrator Agent: a meta-agent that selects, creates, and dispatches worker agents from a single prompt — across Claude and pi (and future) harnesses, for both the orchestrator and its workers","body":"Today the console (/) forces the operator to manually 'select an agent' before a prompt can run (ConsoleLive.run_prompt/4 flashes 'Select an agent before running'). The reference app (tactical-agentic-coding/tac-14/orchestrator-agent-with-adws/apps/orchestrator_3_stream) instead makes the orchestrator itself an LLM agent whose tools are create_agent/command_agent/list_agents/check_agent_status/interrupt_agent/start_adw; the operator types one prompt and the orchestrator chooses which agents to spawn and dispatches work to them. Replicate that orchestrator BRAIN in this Elixir/Phoenix platform in a harness-blind, extensible way: the management-tool LOGIC lives once in Elixir (calling the existing Agents, Session.Supervisor and WorkflowEngine seams), and each harness binds those tools through its native mechanism (Claude = MCP over HTTP via .mcp.json; pi = a TypeScript extension via -e + pi.registerTool, since pi ships no MCP). The orchestrator must be 'just another harness session' (role: :orchestrator) so adding a harness-as-orchestrator is one optional-behaviour implementation + one registry flag, with ZERO edits to the canonical Event types, the worker Session runtime, or the Agent schema's harness openness. Workers already run on any registered harness via Session.Supervisor — that stays unchanged. This issue delivers the backend brain + minimal console wiring (route the prompt to the orchestrator, stream its thinking/tool-use and the spawned workers' events); rich visual parity is tracked separately in issue-b (console-ui-parity)."}`

## Feature Description

Make the console's orchestrator a real, conversational **meta-agent** instead of a manual selector. The operator types one prompt; an LLM **orchestrator** decides which worker agents to create or reuse, dispatches tasks to them, monitors them, and reports back — all streamed live into the existing console.

The orchestrator is implemented as **"just another harness session"** with `role: :orchestrator`. The novel capability — the set of agent-management *tools* the orchestrator can call (`create_agent`, `command_agent`, `list_agents`, `check_agent_status`, `interrupt_agent`, and optionally `start_adw`) — is implemented **once in Elixir** as a pure, `@spec`'d context (`RepoBuilder.Orchestrator.Tools`) that drives the seams the platform already exposes: `RepoBuilder.Agents`, `RepoBuilder.Session.Supervisor`, `RepoBuilder.WorkflowEngine`, and the `RepoBuilder.Dashboard`/`console:events` PubSub feed.

Each harness binds those tools through **its own native mechanism**, behind a new optional behaviour `RepoBuilder.Harness.Orchestrating`:

- **Claude Code** — natively supports MCP servers declared in `.mcp.json`. The orchestrator's Claude session is launched with a generated `.mcp.json` pointing at a **Phoenix-hosted MCP-over-HTTP endpoint** scoped to that orchestrator. Claude calls the tools; the endpoint runs the Elixir tool logic.
- **pi** (`@earendil-works/pi-coding-agent`, formerly `@mariozechner/pi-coding-agent`) — ships **no MCP by design**; custom tools come from a TypeScript **extension** loaded with `-e`. We ship a small `pi` extension (`pi.registerTool(...)`) whose handlers `fetch` the same Phoenix tool API. (See memory `pi-harness-tooling`.)

Because the tool *logic* is harness-agnostic Elixir and the *binding* is one optional-behaviour callback per harness, adding a new orchestrator-capable harness is one module + one registry flag — consistent with the platform's "add a harness = one adapter module + one config entry" guarantee (BUILD_PROMPT.md §10). Worker agents already run on any registered harness via `Session.Supervisor`, unchanged.

## User Story

As an **operator running multiple AI coding agents from one console**
I want to **type a single natural-language request and have an orchestrator decide which agents to spin up (on Claude or pi) and dispatch the work to them**
So that **I no longer have to manually pick a target agent for every prompt, and I can watch the orchestrator's reasoning, its tool calls, and every spawned worker's output stream live in one place.**

## Problem Statement

`RepoBuilderWeb.ConsoleLive` currently makes the **human** the orchestrator: `run_prompt/4` (`lib/repo_builder_web/live/console_live.ex:366`) refuses to run unless `selected_agent_id` is set ("Select an agent before running"), and the `:orchestrator` role is only a **display label** stamped on streamed harness text (`console_live.ex:466`) — there is no agent that actually *chooses* or *dispatches* workers. The platform has every primitive needed to dispatch work (durable `Agents`, the erlexec `Session` runtime, the `WorkflowEngine`, the `console:events` feed) but **no brain that wires a prompt to those primitives**. The existing `issue-b` spec rebuilds the console's *look* but explicitly defers the conversational orchestrator ("adapted, not faked"). The orchestrator brain is therefore unbuilt, and it must be built without locking to one harness — the platform's defining constraint is multi-harness support for **both** the orchestrator and its workers (BUILD_PROMPT.md §1, §10).

## Solution Statement

Introduce an **Orchestrator** runtime that is harness-blind at its core and harness-bound only at its edges:

1. **Persistence** — a new `orchestrators` context/schema (durable orchestrator identity + resumable `session_id` + cost), and a minimal additive extension of the `agents` schema (`orchestrator_id`, `session_id`, `model`, `system_prompt`) so a spawned worker remembers which orchestrator owns it and which CLI session to resume. No change to `harness` openness.
2. **Tool logic, once** — `RepoBuilder.Orchestrator.Tools`, a pure `@spec`'d context implementing `create_agent` / `command_agent` / `list_agents` / `check_agent_status` / `interrupt_agent` (+ optional `start_adw`) by calling `Agents`, `Session.Supervisor`, and `WorkflowEngine`. Each returns a normalized `{:ok, result_map} | {:error, reason}` and never raises.
3. **One server-side tool surface** — `RepoBuilderWeb.OrchestratorMCPController`, a Phoenix endpoint speaking **MCP over HTTP (JSON-RPC 2.0: `initialize` / `tools/list` / `tools/call`)**, scoped to an orchestrator id and guarded by a per-orchestrator bearer token. Both bindings (Claude's native MCP and the pi extension) reach this one surface, so tool behavior is identical regardless of harness.
4. **A per-harness binding** — a new **optional** behaviour `RepoBuilder.Harness.Orchestrating` with `orchestrator_spawn/2` returning the extra argv/env (and writing any per-session config file, e.g. `.mcp.json`) needed to attach the tools and resume the orchestrator's session. `Claude` and `Pi` implement it; harnesses that don't are workers-only. A registry flag `:orchestrating` advertises the capability.
5. **The orchestrator session** — `RepoBuilder.Orchestrator.Server` runs an orchestrator turn as a harness session (reusing the erlexec spawning/streaming/normalize path) seeded with the orchestrator system prompt and the tool binding, resuming `session_id` per turn. Its canonical events stream to the console exactly like worker events.
6. **Console wiring** — `ConsoleLive` routes the command-panel prompt to the orchestrator (not a manually selected worker), removing the hard "select an agent" gate; it renders the orchestrator's text/thinking/tool-use as chat and shows spawned workers appearing in the roster as the orchestrator creates them. Manual single-agent run remains available as a fallback.

CI/test coverage runs against the keyless **Fake** harness and direct context/endpoint tests; real Claude/pi orchestration is a documented manual acceptance step (consistent with the platform's existing "live CLI acceptance is the only manual step").

## Relevant Files

Use these files to implement the feature:

- `BUILD_PROMPT.md` — authoritative spec; §1/§10 (multi-harness for orchestrator+workers; "add a harness = one module + config"), §3 (typed style), §4 (canonical event contract + redaction), §6 (session runtime, secrets), §7 (workflow engine), §8 (persistence/Decimal boundary), §9 (LiveView), §13 (testing/Fake harness).
- `README.md` — run instructions / project overview.
- `AGENTS.md` — repo conventions (Phoenix 1.8 + LiveView; CSS rules).
- `ai_docs/typed-elixir-standard.md` — **(always)** the enforced typed standard (`@spec` gate, structs, wire-vs-domain rule 6, Decimal rule 10).
- `BUILD_PROMPT.md` §4 + §10 + `ai_docs/typed-elixir-standard.md` — harness adapters / event contract / extensibility (this feature adds an optional behaviour and a registry flag).
- `ai_docs/adw-orchestration.md` — ADW/workflow engine internals (for the optional `start_adw` tool).
- `lib/repo_builder/harness.ex` — the mandatory `command/1` + `normalize/2` behaviour and `start_opts` type; the new optional `Orchestrating` behaviour lives beside `Harness.CustomSpawn`.
- `lib/repo_builder/harness/custom_spawn.ex` — **pattern to mirror** for an optional, opt-in harness behaviour.
- `lib/repo_builder/harness/registry.ex` — single source of truth for harness config; extend reads to expose the `:orchestrating` capability flag (no new config key beyond the map entry).
- `lib/repo_builder/harness/claude.ex` — Claude adapter; implement `Orchestrating` (generate `.mcp.json`, add `--mcp-config`/`--resume`, inject system prompt).
- `lib/repo_builder/harness/pi.ex` — pi adapter; implement `Orchestrating` (add `-e <ext>` + session resume + `--append-system-prompt`/`--system-prompt`, pass tool-endpoint env).
- `lib/repo_builder/harness/fake.ex` — keyless Fake adapter; extend so it can play a **canned orchestrator** (emit a scripted tool-call sequence) for deterministic CI tests of the full loop.
- `lib/repo_builder/session/server.ex` — erlexec session GenServer; the orchestrator reuses its spawning/streaming/normalize/broadcast path. Read to thread the optional `Orchestrating` spawn hook + resume opts without breaking worker sessions.
- `lib/repo_builder/session/supervisor.ex` — `start_session/1`, `interrupt/1`, `whereis/1`; used by `command_agent`/`interrupt_agent`.
- `lib/repo_builder/agents.ex` — agents context (the ONLY `Repo` caller for `agents`); add `@spec`'d helpers (`create_worker/2`, `get_by_name_for_orchestrator/2`, `set_session/2`, list-by-orchestrator).
- `lib/repo_builder/agents/agent.ex` — agent schema/changeset; add additive fields + a worker changeset (keep `harness` open via `validate_inclusion(Registry.known())`).
- `lib/repo_builder/logs.ex` — logs context; reuse `persist_event/2`, `list_recent/2`, `list_recent_global/1`, `cost_rollup!/1`, `create_system_log/1` for `check_agent_status` and orchestrator-action logging.
- `lib/repo_builder/dashboard.ex` — PubSub seam (`broadcast_event/2` → `console:events`, lanes, workflow topics); orchestrator + worker events flow through here, so the console already receives them.
- `lib/repo_builder/workflow_engine.ex` — `start_workflow/2`, `create_example_workflow/2`; backs the optional `start_adw` tool.
- `lib/repo_builder_web/live/console_live.ex` — route prompt → orchestrator, drop the hard "select an agent" gate, render orchestrator chat + auto-add spawned workers to the roster.
- `lib/repo_builder_web/components/console_components.ex` — existing chat bubble / thinking / tool-use card components reused to render orchestrator output.
- `lib/repo_builder_web/router.ex` — mount the MCP-over-HTTP endpoint + token plug under an internal scope.
- `lib/repo_builder_web/endpoint.ex` — confirm body parsing/pipeline for the JSON-RPC endpoint.
- `config/config.exs` — harness registry map (add `orchestrating:` flag + per-harness orchestrator tooling descriptor); orchestrator base config (model defaults, MCP base URL).
- `config/runtime.exs` — `:harness_secrets` (orchestrator needs the same provider keys); orchestrator MCP base URL / internal token settings.
- `priv/repo/migrations/` — new migrations (create `orchestrators`; extend `agents`).
- `specs/issue-b-adw-consoleui-sdlc_planner-orchestration-console-ui-parity.md` — sibling spec (the SKIN); keep UI changes here minimal and compatible.

### New Files

- `lib/repo_builder/harness/orchestrating.ex` — the optional `@callback orchestrator_spawn(start_opts, tool_ctx) :: {extra_args, extra_env}` behaviour (mirrors `Harness.CustomSpawn`).
- `lib/repo_builder/orchestrator.ex` — `Orchestrators` context (the ONLY `Repo` caller for `orchestrators`): `get_or_create_default/1`, `fetch/1`, `set_session/2`, `add_cost/2`, `mint_token/1`/`verify_token/2`.
- `lib/repo_builder/orchestrator/orchestrator.ex` — Ecto schema for `orchestrators` (`typedstruct`-style `@type t`, `@enforce`/changeset, closed `status` enum, Decimal cost).
- `lib/repo_builder/orchestrator/tools.ex` — pure, `@spec`'d tool logic (`create_agent`/`command_agent`/`list_agents`/`check_agent_status`/`interrupt_agent`/`start_adw`), each `(orchestrator_id, args_map) :: {:ok, map()} | {:error, reason()}`.
- `lib/repo_builder/orchestrator/tool_catalog.ex` — the JSON-Schema tool definitions (name/description/input schema) shared by `tools/list` and the pi extension manifest, so both bindings advertise identical tools.
- `lib/repo_builder/orchestrator/server.ex` — `Orchestrator.Server` GenServer: runs an orchestrator turn as a harness session (resume per turn), tracks status/cost, broadcasts.
- `lib/repo_builder/orchestrator/system_prompt.ex` — builds the orchestrator system prompt (port of the reference `orchestrator_agent_system_prompt.md`, with `{{TOOLS}}`/`{{HARNESSES}}` injected from the registry).
- `lib/repo_builder_web/controllers/orchestrator_mcp_controller.ex` — MCP-over-HTTP (JSON-RPC 2.0) endpoint: `initialize`, `tools/list`, `tools/call` → `Orchestrator.Tools`.
- `lib/repo_builder_web/plugs/orchestrator_token.ex` — per-orchestrator bearer-token auth plug for the MCP endpoint.
- `priv/orchestrator/pi_extension/orchestrator-tools.ts` (+ `package.json`) — the pi extension: `pi.registerTool` for each tool, handlers `fetch` the MCP/JSON endpoint using `PI_ORCH_BASE_URL` + `PI_ORCH_TOKEN` env.
- `priv/repo/migrations/<ts>_create_orchestrators.exs` — `orchestrators` table (binary_id PK, JSONB metadata, Decimal cost).
- `priv/repo/migrations/<ts>_add_orchestrator_fields_to_agents.exs` — add `orchestrator_id`, `session_id`, `model`, `system_prompt` to `agents`.
- `test/repo_builder/orchestrator/tools_test.exs` — unit tests for each tool against the Fake harness + sandboxed Repo.
- `test/repo_builder_web/controllers/orchestrator_mcp_controller_test.exs` — JSON-RPC contract + token-auth tests.
- `test/repo_builder/orchestrator/server_test.exs` — orchestrator turn drives the canned Fake orchestrator end-to-end (tool calls create/command workers).
- `test/repo_builder_web/live/test_orchestrator_agent_test.exs` — `Phoenix.LiveViewTest` integration: type a prompt → orchestrator session starts → a worker appears in the roster → orchestrator chat + worker events render (assert the right `console:events` broadcasts).

## Implementation Plan

### Phase 1: Foundation
Establish persistence and the harness-blind tool surface before any harness binding.
- Add the `orchestrators` schema/table + `Orchestrators` context (default orchestrator, resumable `session_id`, Decimal cost, per-orchestrator token mint/verify).
- Extend `agents` additively (`orchestrator_id`, `session_id`, `model`, `system_prompt`) + new `Agents` worker helpers; keep `harness` open.
- Implement `Orchestrator.Tools` (pure logic) + `Orchestrator.ToolCatalog` (shared schemas) against `Agents`/`Session.Supervisor`/`WorkflowEngine`/`Logs`, fully unit-tested with the Fake harness.
- Stand up `OrchestratorMCPController` (JSON-RPC: `initialize`/`tools/list`/`tools/call`) + `OrchestratorToken` plug + router scope, contract-tested independently of any CLI.

### Phase 2: Core Implementation
Make the orchestrator runnable as a harness session and bind tools per harness.
- Add the optional `Harness.Orchestrating` behaviour + a `Registry.orchestrating?/1` capability read driven by an `orchestrating: true` map entry.
- Implement `Orchestrating` for `Claude` (generate `.mcp.json` referencing the HTTP MCP endpoint + token; add `--mcp-config`, `--resume <session_id>`, system-prompt injection) and `Pi` (`-e priv/orchestrator/pi_extension`, session resume `--session`/`-c`, `--append-system-prompt`, pass `PI_ORCH_BASE_URL`/`PI_ORCH_TOKEN` env).
- Thread the optional spawn hook + resume opts through `Session.Server`/`Orchestrator.Server` without altering the worker path; build `Orchestrator.SystemPrompt`.
- Teach `Fake` to play a canned orchestrator (scripted `tool_use` frames) so the whole loop is exercised key-free in CI.

### Phase 3: Integration
Wire the brain into the console and prove the end-to-end loop.
- `ConsoleLive`: route the command-panel prompt to `Orchestrator.Server` (start/resume the default orchestrator), drop the hard "select an agent" gate (keep manual single-agent run as an explicit fallback), render orchestrator text/thinking/tool-use as chat, and auto-insert spawned workers into the roster stream as `agent_created`-style events arrive.
- Ensure orchestrator + worker events both flow over `console:events` (they already do via `Dashboard.broadcast_event/2`) and that reconnect backfills via `Logs.list_recent_global/1`.
- Add the LiveView integration test + optional Tidewave/Playwright screenshot; run the full validation gate.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Research & confirm conventions (no code)
- Read `BUILD_PROMPT.md` §1/§3/§4/§6/§7/§8/§9/§10/§13, `ai_docs/typed-elixir-standard.md`, and `ai_docs/adw-orchestration.md` (for `start_adw`).
- Read `lib/repo_builder/harness/custom_spawn.ex` to mirror the optional-behaviour pattern exactly.
- Confirm via Tidewave `get_docs`/`get_source_location`: `Session.Server` opts (`:session_id`, `:agent_db_id`, `:secrets`), `Dashboard.broadcast_event/2` topic, and `WorkflowEngine.start_workflow/2` return shape.

### 2. Persistence: `orchestrators` schema + context
- Create migration `create_orchestrators` (binary_id PK; `harness :string`, `model :string`, `session_id :string`, `system_prompt :text`, `status` (`:idle|:running|:error`), `working_dir :string`, `total_cost_usd :decimal`, `token_hash :string`, `metadata :map` JSONB, timestamps).
- Create `RepoBuilder.Orchestrator.Orchestrator` schema (`@type t`, `@enforce_keys`/`typedstruct` per standard, closed `status` Enum, changeset with `validate_inclusion(:harness, Registry.known())`).
- Create `RepoBuilder.Orchestrators` context (only `Repo` caller for `orchestrators`): `@spec`'d `get_or_create_default/1`, `fetch/1`, `set_session/2`, `add_cost/2` (float→Decimal at the boundary, rule 10), `mint_token/1` (returns plaintext, stores hash), `verify_token/2`.

### 3. Persistence: extend `agents` for ownership + resume
- Migration `add_orchestrator_fields_to_agents`: add `orchestrator_id` (binary_id FK, nullable, indexed), `session_id :string`, `model :string`, `system_prompt :text`.
- Update `RepoBuilder.Agents.Agent`: extend `@type t` + `schema` + a new `worker_changeset/2` (casts the new fields; `harness` stays open via `validate_inclusion(Registry.known())`).
- Update `RepoBuilder.Agents`: add `@spec`'d `create_worker/2` (name+harness+orchestrator_id), `get_by_name_for_orchestrator/2`, `set_session/2`, `list_for_orchestrator/1`. No `Repo` access leaks out of the context.

### 4. Tool catalog + pure tool logic (Fake-harness tested)
- Create `RepoBuilder.Orchestrator.ToolCatalog`: `@spec tools() :: [tool_def()]` with name/description/JSON-input-schema for `create_agent`, `command_agent`, `list_agents`, `check_agent_status`, `interrupt_agent`, `start_adw` (single source for `tools/list` + the pi manifest).
- Create `RepoBuilder.Orchestrator.Tools`: each `@spec call(tool :: String.t(), orchestrator_id :: Ecto.UUID.t(), args :: map()) :: {:ok, map()} | {:error, reason())`:
  - `create_agent` → `Agents.create_worker/2` (default harness from orchestrator/args), broadcast an `agent_created` console event.
  - `command_agent` → resolve worker by name (scoped), `Session.Supervisor.start_session/1` resuming the worker `session_id`, set status `:running`; fire-and-forget (return "dispatched").
  - `list_agents` → `Agents.list_for_orchestrator/1`.
  - `check_agent_status` → status + `Logs.list_recent/2` (tail) + `Logs.cost_rollup!/1`.
  - `interrupt_agent` → `Session.Supervisor.interrupt/1`.
  - `start_adw` → `WorkflowEngine.create_example_workflow/2` + `start_workflow/2`, return `run_id` (optional; gate behind a flag if engine wiring slips).
  - Never raise; map all failures to `{:error, reason}`. Log each invocation via `Logs.create_system_log/1`.
- **Write `test/repo_builder/orchestrator/tools_test.exs`** covering each tool happy-path + error (unknown agent, at-capacity, duplicate name) against the Fake harness and the sandbox Repo.

### 5. MCP-over-HTTP endpoint + token plug
- Create `RepoBuilderWeb.Plugs.OrchestratorToken`: extract bearer token, `Orchestrators.verify_token/2`, assign `:orchestrator_id`, 401 on mismatch.
- Create `RepoBuilderWeb.OrchestratorMCPController`: handle JSON-RPC 2.0 `initialize` (capabilities), `tools/list` (from `ToolCatalog`), `tools/call` (dispatch to `Orchestrator.Tools`, wrap result in MCP `{content:[{type:"text",text:...}], isError}`). Pure JSON in/out; no protocol guesswork beyond these three methods.
- Router: internal scope `/orchestrator/:orchestrator_id/mcp` through the token plug; confirm `endpoint.ex` JSON body parsing.
- **Write `test/repo_builder_web/controllers/orchestrator_mcp_controller_test.exs`**: `tools/list` returns the catalog; `tools/call create_agent` creates a worker row; bad/missing token → 401.

### 6. Optional `Orchestrating` behaviour + registry capability
- Create `RepoBuilder.Harness.Orchestrating` (`@callback orchestrator_spawn(Harness.start_opts(), tool_ctx :: map()) :: {[String.t()], [{String.t(), String.t()}]}`), mirroring `Harness.CustomSpawn` docs/shape. `tool_ctx` carries `:orchestrator_id`, `:mcp_base_url`, `:token`, `:resume_session_id`, `:cwd`.
- `Registry`: add `@spec orchestrating?(harness) :: boolean()` reading an `orchestrating: true` map entry; add `@spec orchestrating_harnesses() :: [String.t()]`.
- `config/config.exs`: set `orchestrating: true` on `"claude"` and `"pi"` (and `"fake"` in dev); add orchestrator base settings (default model per harness, MCP base URL). `config/runtime.exs`: orchestrator MCP base URL + internal token salt; ensure `:harness_secrets` cover the orchestrator.

### 7. Implement `Orchestrating` for Claude and pi
- `Harness.Claude`: `@impl RepoBuilder.Harness.Orchestrating` `orchestrator_spawn/2` → write `<cwd>/.mcp.json` (`type:"http"`, url = `mcp_base_url`, bearer header = token); return args `["--mcp-config", path, "--append-system-prompt", sys_prompt | resume?]` (+ `--resume <id>` when present). Secrets stay in env (never argv).
- `Harness.Pi`: `orchestrator_spawn/2` → return args `["-e", priv_ext_path, "--append-system-prompt", sys_prompt | resume?]` (`--session <id>`/`-c` when resuming) and env `[{"PI_ORCH_BASE_URL", url}, {"PI_ORCH_TOKEN", token}]`. Note the deprecated→`@earendil-works/pi-coding-agent` package in install docs.
- Create `priv/orchestrator/pi_extension/` (`orchestrator-tools.ts` + `package.json`): register each `ToolCatalog` tool; handlers `fetch` the endpoint with the env token; return tool result text to pi.
- Create `RepoBuilder.Orchestrator.SystemPrompt` (`@spec build(orchestrator, registry_view) :: String.t()`) porting the reference instructions with injected tool list + available harnesses.

### 8. Orchestrator session runtime
- Thread the optional spawn hook into spawning: in `Session.Server.handle_continue(:spawn, ...)` (or a thin orchestrator-only path), when launching an orchestrator, call `adapter.orchestrator_spawn/2` (if the harness implements `Orchestrating`) and merge its `{args, env}` with the base `command/1` output — **without** touching the worker spawn path or the canonical event flow.
- Create `RepoBuilder.Orchestrator.Server` (GenServer): `run_turn(orchestrator_id, prompt)` → resolve orchestrator, mint/lookup token, build `tool_ctx`, start a session (status `:running`), stream canonical events through the existing `Dashboard.broadcast_event/2` + persist via `Logs`, capture the new `session_id` + cost on `Done`, set status `:idle`. Interrupt support via `Session.Supervisor.interrupt/1`.
- Extend `Harness.Fake` to emit a **canned orchestrator** sequence (text → `tool_use create_agent` → `tool_use command_agent` → text → done) so the full loop runs without an API key. Wire it so the Fake "tool calls" actually hit `Orchestrator.Tools` (e.g. Fake orchestrator script `curl`s the MCP endpoint, or the test drives `Tools` directly while Fake supplies the chat frames).
- **Write `test/repo_builder/orchestrator/server_test.exs`**: a Fake orchestrator turn results in a worker row + `command_agent` dispatch + the expected `console:events` broadcasts.

### 9. Console wiring (LiveView)
- **Write `test/repo_builder_web/live/test_orchestrator_agent_test.exs` first** (drives the new behavior): mount `ConsoleLive`, submit a prompt with no agent selected, assert (a) no "Select an agent" flash, (b) an orchestrator chat bubble renders, (c) a spawned worker appears in the roster stream, (d) the right `console:events` messages broadcast (use the Fake harness + PubSub assertions).
- `ConsoleLive`: change `run`/`run_prompt` to call `Orchestrator.Server.run_turn/2` on the default orchestrator instead of requiring `selected_agent_id`; keep a clearly-labeled "run on selected agent" fallback path. Subscribe to `console:events` (already wired) and add a `handle_info` clause to insert orchestrator-created workers into the `:lanes`/roster stream. Render orchestrator `text`/`thinking?`/`tool_call` via the existing chat/thinking/tool-use components.
- Ensure reconnect backfill uses `Logs.list_recent_global/1` so a refresh re-hydrates orchestrator + worker history.

### 10. Validation
- Run the full **Validation Commands** below; fix until green with zero regressions.
- Optional: `mix phx.server` + Tidewave `project_eval` to drive `Orchestrator.Tools.call/3` live, `execute_sql_query` to confirm `orchestrators`/`agents` rows, `get_logs` to inspect any stacktrace; optional Playwright screenshot of `http://localhost:4000`.
- Document the **manual** real-CLI acceptance (Claude orchestrator + pi orchestrator each spawning a worker) in the PR, mirroring the platform's existing "live CLI acceptance is the only manual step."

## Testing Strategy

### Unit Tests
- `Orchestrator.Tools` — every tool: happy path + each `{:error, reason}` branch (unknown agent, duplicate name, `:at_capacity`, unknown harness), asserted against the Fake harness and the sandbox `Repo`.
- `Orchestrators` context — `get_or_create_default/1` idempotency, `set_session/2`, `add_cost/2` float→Decimal boundary, `mint_token`/`verify_token` (hash never stored in plaintext; wrong token rejected).
- `Agents` worker helpers — `create_worker/2` scoping, `get_by_name_for_orchestrator/2` isolation between orchestrators, `harness` openness preserved.
- `OrchestratorMCPController` — JSON-RPC `initialize`/`tools/list`/`tools/call` shapes; MCP error wrapping (`isError: true`); token plug 401s.
- `Orchestrating` adapters — `Claude.orchestrator_spawn/2` writes a valid `.mcp.json` and emits `--mcp-config`/`--resume`; `Pi.orchestrator_spawn/2` emits `-e`/session-resume args + endpoint env; secrets never appear in argv.
- `Registry.orchestrating?/1` / `orchestrating_harnesses/1` reflect config.

### Edge Cases
- Prompt submitted with **no** agent selected → orchestrator runs (no flash); manual fallback still works when an agent IS selected.
- `command_agent` on a non-existent / archived worker → `{:error, :not_found}` surfaced as MCP `isError`, not a crash.
- `Session.Supervisor` at capacity (`{:error, :at_capacity}`) during `command_agent` → graceful tool error.
- Duplicate `create_agent` name within one orchestrator → unique-constraint error mapped cleanly; same name under a different orchestrator is allowed.
- Orchestrator turn with no tool calls (pure chat answer) → renders, no workers created.
- Token missing/expired/wrong-orchestrator on the MCP endpoint → 401, no tool execution.
- Resume of a worker/orchestrator whose `session_id` is `nil` (first turn) vs set (subsequent turns).
- Harness without `Orchestrating` (e.g. `cursor`) selected as orchestrator → clear `{:error, :not_orchestrator_capable}`; still usable as a worker.
- Malformed JSON-RPC body / unknown method → JSON-RPC error object, never a 500 crash.
- Secret redaction: orchestrator `raw` frames persisted are redacted (reuse §4.1 path); tokens/keys never logged or in argv.
- LiveView reconnect mid-orchestration backfills from `Logs.list_recent_global/1`.

## Acceptance Criteria
- Submitting a prompt in the console with **no agent selected** no longer flashes "Select an agent"; it starts/continues the default orchestrator and renders its reply.
- The orchestrator, via tools, can **create** a worker (new `agents` row scoped to the orchestrator) and **dispatch** a command to it (`Session.Supervisor` session starts), with both reflected live in the console roster + event stream.
- The **same** `Orchestrator.Tools` logic backs both harness bindings: a Claude orchestrator (MCP via `.mcp.json`) and a pi orchestrator (TS extension via `-e`) each produce identical tool effects (verified by the Fake-harness loop in CI; real CLIs in manual acceptance).
- Adding a new orchestrator-capable harness requires only (a) implementing `Harness.Orchestrating` and (b) an `orchestrating: true` registry entry — **zero** edits to canonical `Event` types, the worker `Session` runtime, or `Agent.harness` openness (assert by diff review + a registry test).
- Worker agents continue to run on **any** registered harness via `Session.Supervisor`, unchanged.
- Orchestrator and worker events both stream over `console:events`; reconnect backfills history.
- The full validation gate passes with zero regressions, including the new LiveView integration test.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix deps.get` — fetch any newly pinned deps (only if a dep is added; see Notes).
- `mix ecto.migrate` — apply the `orchestrators` + `agents` migrations cleanly (and `mix ecto.rollback` once to prove reversibility).
- `mix test test/repo_builder/orchestrator/tools_test.exs` — tool logic.
- `mix test test/repo_builder_web/controllers/orchestrator_mcp_controller_test.exs` — JSON-RPC + token contract.
- `mix test test/repo_builder/orchestrator/server_test.exs` — Fake orchestrator end-to-end loop.
- `mix test test/repo_builder_web/live/test_orchestrator_agent_test.exs` — LiveView integration (prompt → orchestrator → spawned worker renders).
- `mix compile --warnings-as-errors` — clean compile; gradual set-theoretic type checker + `warnings_as_errors` pass.
- `mix test --warnings-as-errors` — full suite, zero failures.
- `mix format --check-formatted` — formatting.
- `mix credo --strict` — lint incl. the `@spec`-on-every-public-function gate.
- `mix dialyzer` — contract checking, no new warnings, no stale ignores.

## Notes
- **Relationship to `issue-b` (console-ui-parity):** that spec is the SKIN (visual parity); this is the BRAIN. Keep `ConsoleLive`/component edits here minimal and forward-compatible so `issue-b` can layer richer visuals on top. The orchestrator chat/thinking/tool-use already have components to reuse.
- **MCP server implementation choice:** the plan hand-rolls the minimal MCP-over-HTTP surface (`initialize`/`tools/list`/`tools/call`) in a Phoenix controller to avoid an unverified dependency and keep the server fully under our control (Claude speaks HTTP MCP natively; pi reaches the same endpoint from its extension). If hand-rolling proves costly, evaluate an Elixir MCP server library (e.g. `hermes_mcp`) and, if adopted, pin it in `mix.exs` per BUILD_PROMPT.md §2 and record it here. The repo already runs an MCP server in dev (Tidewave) as precedent.
- **pi package name:** install/docs must use `@earendil-works/pi-coding-agent` (the `@mariozechner/...` package is deprecated). pi ships **no MCP**; the binding is a TypeScript extension via `-e` (`pi.registerTool`). See memory `pi-harness-tooling`.
- **No new Elixir runtime dep is strictly required** for the hand-rolled path; the pi extension needs Node at runtime, which pi already requires.
- **Security:** the MCP endpoint is internal and per-orchestrator-token scoped; tokens and provider keys live in env only (never argv, never DB, never logs — reuse the §4.1 redaction + §6 secret-resolution paths). Bind the endpoint to localhost in dev.
- **Multi-turn model:** an orchestrator turn = one harness invocation resumed via `session_id` (Claude `--resume`, pi `--session`/`-c`), matching the reference's resumable-session design rather than a long-lived interactive process — this fits the existing one-shot `Session.Server` shape.
- **Scope guard:** `start_adw`/`check_adw` are included but flagged optional; if `WorkflowEngine` wiring risks the milestone, ship the 5 agent-management tools first and add ADW tools in a follow-up. Sub-agent nesting, AI event summaries, file-change tracking, and autocomplete from the reference are explicitly **out of scope** here.
