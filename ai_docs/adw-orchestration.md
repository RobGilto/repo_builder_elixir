# ADW Orchestration Reference — the tac-14 contracts mapped to repo_builder

> Source of truth: the tac-14 reference repo
> `/data/3.Resources/engineering/TAC Repos/repos/tac-14/orchestrator-agent-with-adws/`
> (read-only, external — note the space in "TAC Repos"; quote the path) distilled
> against this repo's engine (`adws/`). This is what `/build-adw-orchestrator` reads
> before writing an orchestration-app spec into a target repo.
> Companion doc: `ai_docs/adw-primitives.md` (the primitive inventory and the
> canonical phase-script skeleton the workflows below are built from).
>
> **Anchor invariant**: every `file:line` anchor in this doc must be re-verified
> against the actual code on read — code is the source of truth, this doc is
> working memory (same rule as `expertise.yaml`, see `ai_docs/agent-experts.md`).
> tac-14 anchors are relative to the reference repo root and are frozen (the repo
> is read-only); repo_builder anchors can drift and MUST be re-checked.

## 1. Reference architecture — the tac-14 six-layer stack

```
┌──────────────────────────────────────────────────────────────────────┐
│ L1  STEP PROMPTS        .claude/commands/*.md  (/plan, /build, …)    │
│       │ invoked by                                                   │
│ L2  PRIMITIVES          adws/adw_modules/                            │
│       │   adw_agent_sdk · adw_database · adw_logging ·               │
│       │   adw_websockets · adw_summarizer · orch_database_models     │
│       │ composed into                                                │
│ L3  WORKFLOWS           adws/adw_workflows/adw_*.py                  │
│       │   (plan_build, plan_build_review, plan_build_review_fix)     │
│       │ launched by                                                  │
│ L4  TRIGGERS            adws/adw_triggers/                           │
│       │   adw_scripts.py (detached uv-run spawner) ·                 │
│       │   adw_manual_trigger.py (CLI: create DB row + spawn)         │
│       │ observed & driven by                                         │
│ L5  ORCHESTRATOR APP    apps/orchestrator_3_stream/                  │
│       │   FastAPI backend (:9403, /ws relay, start_adw/check_adw     │
│       │   MCP tools) + Vue 3 swimlane frontend (:5175)               │
│       │ everything meets at                                          │
│ L6  SHARED STORE        apps/orchestrator_db/  (PostgreSQL)          │
│         ai_developer_workflows · agents · agent_logs · system_logs   │
└──────────────────────────────────────────────────────────────────────┘
```

Reading the layers: prompts do the work, primitives wrap the mechanics, workflows
stitch primitives into a deterministic script, triggers put workflows into
background processes, the orchestrator app launches and watches them, and the
shared store is the single rendezvous point all of it reads/writes.

The same six layers in repo_builder's dialect:

| Layer | tac-14 | repo_builder |
|-------|--------|--------------|
| L1 prompts | `.claude/commands/*.md` | `commands/tac/*.md` → deployed `.claude/commands/` (driven by `execute_template()`, `adws/adw_modules/agent.py:511`) |
| L2 primitives | `adws/adw_modules/{adw_agent_sdk,adw_database,adw_logging,adw_websockets,adw_summarizer}.py` | `adws/adw_modules/{agent,workflow_ops,state,git_ops,github,worktree_ops,utils,data_types,r2_uploader,observability}.py` |
| L3 workflows | `adws/adw_workflows/adw_*.py` (3 scripts, ~390 lines of duplicated boilerplate each) | `adws/adw_*_iso.py` (14 scripts; registry at `adws/adw_modules/workflow_ops.py:31`) |
| L4 triggers | `adws/adw_triggers/{adw_scripts,adw_manual_trigger}.py` | `adws/adw_triggers/{trigger_webhook,trigger_cron}.py` + `adws/adw_slash_command.py` (one-shot runner) |
| L5 orchestrator app | `apps/orchestrator_3_stream/` | shipped template `configs/templates/orchestration/app/` → target `orchestration/` via `scripts/sync_orchestrator.sh` (T2.5, §4) + the 88-line chainer template `adw_orchestrate.py`; `/build-adw-orchestrator` generates *custom* tiers into targets |
| L6 shared store | PostgreSQL (`apps/orchestrator_db/`, migrations 0–9) | `agents/<adw_id>/{run.json, adw_state.json, events.jsonl}` + per-agent `raw_output.jsonl` (file-backed, zero deps — always the truth). Since v0.15.0 the shipped template (vendored tac-12) carries its own SQLite `orchestration/orchestrator_db/` (migrations 0–8) as the app's native store — owned entirely by the app, never the engine's store |

## 2. Doctrine

These rules come straight out of tac-14's design and are non-negotiable in any
generated orchestration app:

1. **Orchestration is deterministic, execution is non-deterministic.** The Python
   layer (workflows, triggers, the app) owns control flow, state, and exit codes;
   the agents own the work. Compare the chainer's own docstring:
   `configs/templates/orchestration/adws/adw_orchestrate.py:18-20` ("deterministic
   Python coordination wrapping non-deterministic agents").
2. **One Agent, One Prompt, One Purpose.** Each workflow step spawns exactly one
   agent with exactly one slash command (tac-14: `/plan <prompt>` then
   `/build <path>`, `adws/adw_workflows/adw_plan_build.py:466-482, 681-694`).
   Steps communicate through deterministic artifacts (Output Contracts — see
   `ai_docs/adw-primitives.md`), never through shared conversation context.
3. **The orchestrator app is a viewer/launcher, never in the execution path.**
   Workflows run as detached background processes
   (`adws/adw_triggers/adw_scripts.py:47-54`: `subprocess.Popen(...,
   start_new_session=True)`, stdio to `DEVNULL`). Killing the app must not kill a
   running ADW; an ADW must finish identically whether or not the app is up.
4. **The store is the only required channel.** Everything an orchestrator needs to
   render or resume lives in the store (tac-14: Postgres rows; repo_builder:
   `adw_state.json` + `events.jsonl`). Realtime push is an optional accelerant.
5. **Realtime is optional and fail-silent.** tac-14's WebSocket client is
   "RESILIENT BY DESIGN: all broadcast methods fail silently if server is
   unavailable; workflow execution continues regardless"
   (`adws/adw_modules/adw_websockets.py:68-71`; max 5 reconnect attempts, then it
   gives up — `:55-57, 183-194`). repo_builder's `emit_event()` carries the same
   doctrine: returns `False`, never raises, never breaks a workflow.

## 3. The four contracts — both dialects

An orchestration app couples to an engine through exactly four contracts. Every
tier in §4 implements some subset; `/build-adw-orchestrator` embeds the correct
dialect for the target it inspects.

### 3.1 Discovery — "what workflows exist?"

| | tac-14 | repo_builder |
|---|--------|--------------|
| Mechanism | glob `adws/adw_workflows/adw_*.py`; workflow type = filename stem minus `adw_` prefix; description = first line of the module docstring | glob `adws/adw_*_iso.py`; name = filename stem; description = first line of the module docstring |
| Anchors | `apps/orchestrator_3_stream/backend/main.py:335` (`discover_adw_workflows`, docstring parse at `:356-368`); filename-only variant at `backend/modules/agent_manager.py:124` | the glob is the *view*; the authoritative registry is `AVAILABLE_ADW_WORKFLOWS` (`adws/adw_modules/workflow_ops.py:31`) mirrored by the `ADWWorkflow` Literal (`adws/adw_modules/data_types.py:28`) |
| Caveat | filesystem is the only registry — a stray `adw_*.py` file becomes launchable | a generated app should cross-check glob results against `AVAILABLE_ADW_WORKFLOWS` and surface drift instead of hiding it; dependent workflows (`adws/adw_triggers/trigger_webhook.py:44`, `DEPENDENT_WORKFLOWS`) must be marked "requires existing adw-id" in any launch UI |

### 3.2 CLI — "how do I launch one?"

| | tac-14 | repo_builder |
|---|--------|--------------|
| Invocation | `uv run adws/adw_workflows/adw_<type>.py --adw-id <uuid>` | `uv run adws/adw_<name>_iso.py <issue-number> [adw-id]` (positional) |
| Where context lives | the workflow fetches prompt, `working_dir`, and model from the DB row's `input_data` JSONB (`adws/adw_workflows/adw_plan_build.py:778-800`); the CLI carries only the id (`:955-967`) | context comes from the GitHub issue plus `agents/<adw_id>/adw_state.json`; entry-point workflows mint the adw-id and worktree, dependent workflows *require* the adw-id of an existing run |
| Spawn pattern | `adw_scripts.run_adw_workflow_async()` builds `["uv","run",<path>,"--adw-id",adw_id]` and detaches (`adws/adw_triggers/adw_scripts.py:43-54`) | the chainer template runs `subprocess.run(["uv","run",<script>,issue_number,adw_id])` per phase, gated on returncode (`configs/templates/orchestration/adws/adw_orchestrate.py:50-52`) |
| One-shot runner | n/a | `uv run adws/adw_slash_command.py <command> [args...] [--adw-id ID] [--json]` — runs any single slash command headless, no worktree |

### 3.3 Store — "where does truth live?"

**tac-14: PostgreSQL** (`DATABASE_URL`; schema in
`apps/orchestrator_db/migrations/`, models in `apps/orchestrator_db/models.py`,
all writes via `adws/adw_modules/adw_database.py`). Four workflow tables:

| Table | Holds | Key columns |
|-------|-------|-------------|
| `ai_developer_workflows` | one row per run (the id IS the adw_id) | `adw_name`, `workflow_type`, `status` ∈ pending\|in_progress\|completed\|failed\|cancelled, `current_step`, `total_steps`/`completed_steps`, `input_data`/`output_data` JSONB, `error_message`/`error_step`, timing (migration `9_ai_developer_workflows.sql:9-52`) |
| `agents` | one row per step-agent | `name` (e.g. `plan-<adw8>`), `model`, `status`, `session_id`, `input_tokens`/`output_tokens`/`total_cost` (`adw_database.py:185-245`) |
| `agent_logs` | the event stream (swimlane squares) | `adw_id`, `adw_step`, `event_category` ∈ hook\|response\|adw_step, `event_type` (StepStart, StepEnd, PreToolUse, PostToolUse, TextBlock, ThinkingBlock, ToolUseBlock, result, Stop), `content`, `payload` JSONB, `summary` (`adw_database.py:333-383`) |
| `system_logs` | app-level log lines | `level`, `message`, `file_path`, `metadata` (`adw_database.py:417-457`) |

(The app side adds `orchestrator_agents`, `orchestrator_chat`, and `prompts` —
chat/session/cost bookkeeping for the L5 app, not part of the workflow contract.)
Step lifecycle writes go through `adw_logging.py`: `log_step_start`/`log_step_end`
(`:94`/`:140`), `log_adw_event` (`:201`), `log_system_event` (`:259`),
`update_adw_status` (`:322`) — each writes the DB row *and* broadcasts over WS.

**repo_builder default: three files under `agents/<adw_id>/`, zero dependencies.**

1. `adw_state.json` — the run row. Written by `ADWState.save()`
   (`adws/adw_modules/state.py:75`), validated against `ADWStateData`
   (`adws/adw_modules/data_types.py:218`), whitelisted to 10 fields
   (`state.py:37`): `adw_id`, `issue_number`, `branch_name`, `plan_file`,
   `issue_class`, `worktree_path`, `backend_port`, `frontend_port`, `model_set`,
   `all_adws`.
2. `events.jsonl` — the event stream. Append-only JSON lines emitted by
   `adws/adw_modules/observability.py`, one event per line, schema `adw.event/1`:

```json
{
  "schema": "adw.event/1",
  "ts": "<ISO-8601 UTC>",
  "adw_id": "a1b2c3d4",
  "source": "agent" | "state" | "workflow",
  "event_type": "agent_call_start",
  "agent_name": "sdlc_implementor" | null,
  "payload": {},
  "summary": "..." | null
}
```

   API: `events_path(adw_id, working_dir=None)`,
   `emit_event(adw_id, source, event_type, payload=None, agent_name=None,
   summary=None, working_dir=None) -> bool`, and
   `read_events(adw_id, working_dir=None) -> List[dict]` (skips malformed lines
   silently, returns `[]` if the file is absent — this is the seam a T1/T2
   orchestrator polls). Emission is fail-silent (returns `False`, never raises)
   and has an env kill switch: `ADW_EVENTS_DISABLED=1`.

   The engine emits from exactly two chokepoints:
   - `prompt_claude_code_with_retry()` (`adws/adw_modules/agent.py:250` — every
     engine agent call passes through it): `agent_call_start` (payload: `model`,
     `agent_name`, best-effort `command`, `output_file`), `agent_call_retry`
     (payload: `attempt`, `retry_code`, `delay`), `agent_call_end` (payload:
     `success`, `retry_code`, `duration_ms`). These are the equivalent of
     tac-14's StepStart/StepEnd.
   - `ADWState.save()` (`adws/adw_modules/state.py:75`): `state_saved` (payload:
     `workflow_step`, full `state` dict). Equivalent of tac-14's
     `update_adw_status`.
   The `"workflow"` source value is reserved for workflow-script-level emissions.

   Path resolution is module-anchored, never cwd-based: it mirrors
   `get_state_path()` (`state.py:68-73`, three `dirname`s up from the module
   file), so events land beside `adw_state.json` in the checkout that owns the
   `adws/` copy — inside an ADW worktree, the worktree's own `adws/` resolves to
   the worktree root. Per-adw_id files mean concurrent ADWs never contend on a
   shared file (contrast L9, §6).

3. `run.json` — the **local launch contract** (`adws/adw_modules/local_ops.py`,
   schema `adw.run/1`): the file-store equivalent of tac-14's
   `ai_developer_workflows` row. An orchestrator (app, script, or chat agent)
   writes it BEFORE spawning — `create_run(adw_id, workflow_type, prompt, ...)`
   with status `pending` — and the GitHub-optional workflow
   (`adws/adw_plan_build_local_iso.py`, CLI: just `<adw-id>`) pulls all task
   context from it. This is tac-14's context inversion: the store carries the
   context, the CLI carries only the id, GitHub becomes optional enrichment.

```json
{
  "schema": "adw.run/1",
  "adw_id": "a1b2c3d4",
  "workflow_type": "plan_build_local",
  "status": "pending|in_progress|completed|failed|cancelled",
  "current_step": "plan", "total_steps": 2, "completed_steps": 0,
  "created_at": "...", "started_at": null, "completed_at": null,
  "duration_seconds": null,
  "input_data": {"prompt": "...", "model": null, "working_dir": null, "issue_number": null},
  "output_data": {"spec_file": null, "branch": null, "worktree": null, "commit": null},
  "error_message": null, "error_step": null
}
```

   Semantics (tac-14 `update_adw_status` parity): `in_progress` sets
   `started_at` exactly once; any terminal status sets `completed_at` +
   `duration_seconds`. Every `update_run` also emits a `run_updated`
   adw.event/1 line; `step_start`/`step_end` events are the swimlane grouping
   markers. `run.json` is a SIBLING of `adw_state.json`, never a replacement —
   `ADWState` keeps its 10-field whitelist and all existing consumers; an
   orchestration app's run list unions run.json, state, and event-only dirs.
   Saves are atomic (tmp + rename), so pollers never see a partial record.
   Tool-level observability needs no fourth file: the engine already streams
   the full Claude session to `agents/<adw_id>/<agent_name>/raw_output.jsonl`
   per agent call (`agent.py`, opened `"w"` — distinct agent names per step
   are mandatory); apps tail and map it (`tool_use`→ToolUseBlock,
   `text`→TextBlock, `thinking`→ThinkingBlock, `result`→result).

### 3.4 Realtime — "how do I see it live?"

**tac-14: WS client → backend `/ws` relay → frontends.** Each workflow process
opens `AdwWebSocketClient` (`adws/adw_modules/adw_websockets.py:60`) to
`ws://127.0.0.1:9403/ws` (`:50-52`) and sends two message families; the backend
(`apps/orchestrator_3_stream/backend/main.py:718`) relays them to every connected
frontend (routing at `:742` and `:789`):

| `type` | `broadcast_type` values | Meaning |
|--------|------------------------|---------|
| `adw_broadcast` | `adw_created`, `adw_updated`, `adw_event` (one swimlane square), `adw_step_change` (StepStart/StepEnd), `adw_status`, `adw_event_summary_update` | run-level lifecycle and event stream (`adw_websockets.py:257-351, 573-598`) |
| `agent_broadcast` | `agent_created`, `agent_status_changed`, `agent_updated` (tokens/cost/session) | per-step agent lifecycle (`adw_websockets.py:357-409`) |

The same backend also pushes chat-side types to the UI (`chat_stream`,
`chat_typing`, `connection_established`, `error`) and serves the poll-based HTTP
fallback: `POST /adws` (list), `GET /adws/{adw_id}`, `POST /adws/{adw_id}/events`
(merges `agent_logs` + `system_logs`), `GET /adws/{adw_id}/summary`
(`backend/main.py:845-983`).

**repo_builder default: none.** Tail the store:
`tail -f agents/<adw_id>/events.jsonl`, or poll
`observability.read_events(adw_id)`. A push channel only appears when a target
repo builds the T2/T3 app — it is never a factory dependency.

## 4. The tier ladder `/build-adw-orchestrator` offers

Each tier is a complete, stable stopping point; T2 contains T1, T3 contains T2.
The builder picks one with the operator and writes one spec for it.

### T1 — headless spine (zero deps)

Trigger CLI + events tail. No server, no UI, nothing new to install.

Contracts used: discovery + CLI + store (poll). Realtime: none.

Minimal file set (in the target):
```
adws/adw_*_iso.py              # existing engine (unchanged)
adws/adw_modules/              # incl. observability.py (the events seam)
adws/adw_orchestrate.py        # phase chainer (templated from
                               #   configs/templates/orchestration/adws/adw_orchestrate.py;
                               #   PHASES list at :34, run_phase at :42)
agents/<adw_id>/adw_state.json # store (written by the engine)
agents/<adw_id>/events.jsonl   # store (written by the engine)
```
Operate with: `uv run adws/adw_orchestrate.py <issue> [adw-id]` +
`tail -f agents/<adw_id>/events.jsonl`. The spec for T1 mostly *documents* this
spine; it may add a tiny `adws/adw_list.py`-style discovery CLI, nothing more.

### T2 — local web app (file-backed, FastAPI + minimal UI)

A small FastAPI backend that serves discovery and the file-backed store over
HTTP, relays tailed `events.jsonl` lines over `/ws`, and launches workflows as
detached subprocesses. The store stays `adw_state.json` + `events.jsonl` —
**no database**.

Contracts used: all four — realtime is a relay over the file store, not a new
source of truth.

Minimal file set (in the target, layout adapted to its apps-dir convention):
```
apps/orchestrator/backend/main.py        # FastAPI: GET /adws (glob + state.json),
                                         #   GET /adws/{adw_id}/events (read_events),
                                         #   POST /adws (spawn detached uv run),
                                         #   WS /ws (tail events.jsonl → broadcast)
apps/orchestrator/backend/pyproject.toml # fastapi, uvicorn (target-repo deps only)
apps/orchestrator/frontend/index.html    # minimal run list + event stream view
apps/orchestrator/.env.sample            # BACKEND_HOST/BACKEND_PORT
apps/orchestrator/start_be.sh
```
WS message shape: reuse tac-14's envelope (`type: "adw_broadcast"`,
`broadcast_type: "adw_event"`, `event: <adw.event/1 dict>`) so a T2 frontend is
forward-compatible with a T3 upgrade. The T2 spec must include an E2E test for
the app (target-repo machinery, e.g. its `/test_e2e`).

### T2.5 — shipped template (the `orchestration` layer default)

Not builder-generated: a **versioned, deterministic app template** deployed at
scaffold time — `configs/templates/orchestration/app/` synced to the target's
top-level `orchestration/` by `scripts/sync_orchestrator.sh` (gated by the
layer's `enables.sync_orchestrator`; re-deployable via
`scripts/sync.sh --what orchestrator`). Since v0.15.0 the template is tac-12's
`orchestrator_3_stream` service **vendored verbatim**: a FastAPI +
claude-agent-sdk backend (:9403, `/ws` relay; the orchestrator chat agent
delegates work to subagents via `create_agent`/`command_agent`, per
`backend/prompts/orchestrator_agent_system_prompt.md`), a Vue 3 + Vite
frontend (:5175), and the app's own SQLite `orchestrator_db/` package
(migrations 0–8) — deployed as `orchestration/{backend,frontend,
orchestrator_db}` reading a single `orchestration/.env` (`.env.sample`).
Three path patches adapt the vendor to that layout:
`backend/modules/file_tracker.py` imports `orchestrator_db.git_utils` via a
two-up `sys.path`, `config.py` `DEFAULT_CODEBASE_PATH` resolves to the target
repo root, and `orchestrator_db/run_migrations.py` loads `orchestration/.env`.
Subagent templates ship into the target's `.claude/agents/` (layer manifest)
and are discovered at runtime by `backend/modules/subagent_loader.py`; the
4 orch commands land in `.claude/commands/`. The SQLite store belongs to
the app only — the engine's file store (`agents/<adw_id>/…`) stays its only
truth and the engine never reads `SQLITE_DB_PATH`. The template carries its own
backend test suite (run in the target); the factory validates it structurally
only (`tests/orchestration_app.bats`). Since v0.18.0 a fourth factory patch
(after the three path patches) adds **read-only ADW discoverability** to the
vendored app: `backend/modules/adw_discovery.py` (workflow catalog via the §3.1
glob, run list via `agents/*/adw_state.json` + `run.json`, event reads) and
`backend/modules/adw_watcher.py` (fail-silent asyncio tailer over
`agents/*/events.jsonl`, byte-offset tracked, `ADW_WATCH_DISABLED=1` kill
switch; since v0.18.2 it also snapshots the §3.1 workflow catalog each tick),
three REST endpoints (`GET /adws/workflows`, `GET /adws`,
`GET /adws/{adw_id}/events`), the reserved §3.4 realtime envelope
(`adw_broadcast`/`adw_event` over `/ws`, plus `adw_state_changed` as the
events-disabled fallback, plus `{"type": "adw_workflows_changed",
"workflows": [...], "count": N}` carrying the full fresh catalog whenever an
`adws/adw_*.py` file is added/removed/edited — full-replace semantics, never
a diff), and a frontend `AdwRunsList.vue` panel + Prompt UI
picker that inserts `adw:<workflow>` / `run:<adw_id>` references. Since
v0.19.0 the app is a **viewer + launcher**: launching goes exclusively
through the `adw.run/1` contract via `backend/modules/adw_launcher.py` —
the write-side twin of `adw_discovery.py` and the ONLY app module allowed
to write under `agents/` (exactly one `run.json` per launch, schema
mirrored from `adws/adw_modules/local_ops.py`, atomic tmp+`os.replace`)
or spawn engine processes (detached: `start_new_session=True`, stdio
DEVNULL). Surfaces: `POST /adws/launch` (REST) and the orchestrator chat
agent's `mcp__mgmt__start_adw` / `mcp__mgmt__check_adw` mgmt tools, with
the system prompt teaching the `adw:`/`run:` routing rules (freeform
prompt → local `adw.run/1` launch via `adw_plan_build_local_iso`;
`#<issue>` → the named issue-driven workflow; dependent workflows refused
without a `run:<adw_id>`). Launches are gated on the §6 port cap
(`ADW_MAX_CONCURRENT`, default 15 — best-effort backpressure, counts
non-terminal `run.json` statuses) with an `ADW_LAUNCH_DISABLED=1` kill
switch. All other surfaces stay strictly read-only (`adw_discovery.py` /
`adw_watcher.py` unchanged), the engine file store remains the only truth,
and the watcher remains the only feedback channel — the launcher adds zero
feedback machinery. `/build-adw-orchestrator` T3 specs should now diff
against this viewer+launcher baseline. This tier is why the builder command
now mostly writes *customization* specs (§7).

### T2.7 — retired (v0.15.0)

v0.14.0's optional MySQL projection plane (idempotent ingest tailer +
fail-open SQL/file facade mirroring the engine's file store) was removed with
the v0.15.0 wholesale template replacement: the vendored tac-12 service
carries its own `orchestrator_db/` (SQLite — the vendor's PostgreSQL store
was migrated so targets need no external DB service) as the app's **native**
store instead of projecting the engine's files. The doctrine T2.7 encoded
survives unchanged — the engine never gains a DB dependency and the file
store remains the only engine truth.

### T3 — full tac-14 port (Postgres + Vue swimlanes + chat orchestrator)

The complete L5+L6 stack: Postgres store with migrations, the WS relay backend,
a Vue 3 swimlane/chat frontend, and a chat orchestrator agent that drives the
engine through MCP tools.

Contracts used: all four, in the tac-14 dialect — *plus* adapter primitives that
translate the target engine's events into DB writes.

Minimal file set (mirrors tac-14):
```
apps/orchestrator_db/migrations/*.sql    # incl. 9_ai_developer_workflows.sql
apps/orchestrator_db/{models.py,run_migrations.py,sync_models.py}
apps/orchestrator/backend/main.py        # FastAPI + /ws relay + /adws endpoints
apps/orchestrator/backend/modules/{config,logger,websocket_manager,
                                   database,orchestrator_service,agent_manager}.py
apps/orchestrator/backend/prompts/orchestrator_agent_system_prompt.md
apps/orchestrator/frontend/src/          # Vue 3 + Pinia: AgentList, EventStream,
                                         #   OrchestratorChat (swimlanes)
adws/adw_modules/{adw_database,adw_logging,adw_websockets}.py  # engine adapters
.env.sample                              # DATABASE_URL, ports, ANTHROPIC_API_KEY
```
The chat orchestrator's ADW tools (registered via claude-agent-sdk
`create_sdk_mcp_server` as the `mgmt` server → tool names `mcp__mgmt__start_adw`,
`mcp__mgmt__check_adw`; `backend/modules/orchestrator_service.py:292-313`):

- **`start_adw(name_of_adw, workflow_type, prompt, description?)`**
  (`backend/modules/agent_manager.py:637`) — validates the workflow file exists
  (discovery contract), inserts the `ai_developer_workflows` row with
  `input_data = {prompt, working_dir, model}`, broadcasts `adw_started`, spawns
  the detached workflow via `adw_scripts.run_adw_workflow_async`, returns the
  `adw_id`.
- **`check_adw(adw_id, tail_count=10, event_type?, include_step_details=false)`**
  (`agent_manager.py:744`) — reads the run row + recent `agent_logs`, formats
  status / step progress / recent activity for the chat.

Postgres DDL ships **only inside a T3 spec**; the T3 spec must also include an
E2E test and must gate `start_adw` on the concurrency cap (§6).

## 5. Module mapping table — tac-14 ↔ repo_builder

| tac-14 (reference) | repo_builder (this factory) | Notes |
|--------------------|------------------------------|-------|
| `adw_logging.py` (`log_step_start`/`log_step_end`/`log_adw_event` → DB + WS) | `adw_modules/observability.py` (`emit_event` → `events.jsonl`) | same role: the one seam workflows log through; step boundaries ↔ `agent_call_start`/`agent_call_end` + `state_saved` |
| `adw_database.py` (asyncpg pool; `ai_developer_workflows`/`agents`/`agent_logs`/`system_logs`) | `ADWState` (`agents/<adw_id>/adw_state.json`, `state.py:75`) + `events.jsonl` | run row ↔ state file; `agent_logs` ↔ events file; no pool, no deps |
| `adw_websockets.py` (`AdwWebSocketClient` → `/ws` relay) | — (none in the factory) | T2/T3 target-repo concern only; reuse its envelope + fail-silent doctrine |
| `adw_agent_sdk.py` (typed in-process Claude Agent SDK layer) | `agent.py` `prompt_claude_code()` / `prompt_claude_code_with_retry()` (`agent.py:250`) — subprocess `claude -p`, JSONL output | both are the single agent-execution chokepoint of their engine |
| `adw_summarizer.py` (Haiku one-line event summaries) | `orchestration/backend/modules/event_summarizer.py` in the shipped template (vendored tac-12) | the `summary` field in `adw.event/1` stays reserved; the app summarizes its own SQLite `agent_logs`, never the engine's events.jsonl |
| `adw_triggers/adw_scripts.py` (detached `uv run … --adw-id` spawner) | `adw_triggers/trigger_webhook.py` (issue webhook → workflow) + `adw_orchestrate.py` chainer template + `adw_slash_command.py` (one-shot) | same L4 role: put a workflow into a background process |
| `adw_workflows/adw_plan_build*.py` (3 scripts, copy-modified) | `adws/adw_*_iso.py` (14 scripts; registry `workflow_ops.py:31`) | repo_builder adds worktree isolation + issue-driven CLI |
| `orch_database_models.py` copy-sync (`apps/orchestrator_db/sync_models.py` copies `models.py` into each app) | factory sync scripts (`scripts/sync_commands.sh`, `scripts/sync_adws.sh`) | identical doctrine: single source of truth + scripted propagation, never hand-copy |
| `apps/orchestrator_db/` migrations | shipped template payload `orchestration/orchestrator_db/migrations/0..8` (runs only in targets) | the factory itself never gains a DB dependency |

## 6. Constraints on concurrent orchestration

Any generated orchestrator must encode these limits (both tracked in
`app_docs/limitations.md`):

- **15-instance port cap (L5).** `get_ports_for_adw()`
  (`adws/adw_modules/worktree_ops.py:176`) maps the adw_id hash `% 15` onto
  backend ports 9100–9114 and frontend ports 9200–9214 (`:190-196`). A 16th
  concurrent ADW silently collides with a live one. Consequence for an app: cap
  concurrent launches at 15 (and realistically lower), surface allocated ports
  per run (they are in `adw_state.json`), and have a T3 `start_adw` refuse or
  queue beyond the cap. The permanent fix (a locked port pool) is future work
  per L5.
- **Non-atomic hook logs (L9).** Harness hooks append to a shared
  `agents/hook_logs/<date>.jsonl`; concurrent ADWs interleave JSON lines in that
  file. `events.jsonl` deliberately avoids the same trap by being per-adw_id —
  one writer per file. A generated app must preserve that property: never
  aggregate runs by appending to a single shared file; merge at read time
  instead.
- **Fail-silent observability (doctrine §2.5).** Neither `emit_event` failures
  nor a down WS relay may affect a workflow's exit code. `ADW_EVENTS_DISABLED=1`
  must always remain a valid operator escape hatch — an app must degrade to
  showing only `adw_state.json` when events are disabled.
- **Drive-loop spend is bounded deterministically, NOT by an LLM
  (deterministic-worker-fleet-gate).** The autonomous `Orchestrator.Driver` is a
  *backstop*, not the engine: the event-driven holding pattern
  (`auto_resume_on_worker_return`) is the primary re-engagement path. The Driver
  must never spend an LLM turn merely to *check* worker liveness/progress — that is
  answered programmatically by `RepoBuilder.Orchestrator.WorkerFleet` from cheap
  runtime state (an indexed `Agents.live_workers_for/1` query + a `SessionRegistry`
  liveness probe + the `heartbeat_at` column, zero tokens). An orchestrator with a
  live, progressing/holding worker fleet (`:active`) is skipped entirely; only
  `:empty`/`:quiescent` fleets are driven, and a per-orchestrator
  `min_drive_interval_ms` cooldown floors the cadence regardless of fleet edge cases.
  The original failure this prevents: a worker legitimately busy for minutes on a long
  external op while the loop re-engaged an Opus orchestrator ≈once a minute, each wake
  re-reading a ~196K-token cached context — 88% of a project's entire token spend.

## 7. What `/build-adw-orchestrator` generates — and what it never does

Since v0.13.0 the default orchestrator app is the **shipped template** (§4,
T2.5; since v0.15.0 the vendored tac-12 `orchestrator_3_stream` service with
its own SQLite `orchestrator_db/`) —
deterministic scaffold payload, not generated. The builder remains the
generative path for T1/T3, custom tiers, and brownfield targets; against a
target that already carries the shipped template it writes
**customization/upgrade specs**, never a from-scratch T2. Generated specs must
embed the local launch contract (`adw.run/1` + `adw_plan_build_local_iso`,
§3.3) and may not assume GitHub on the default path.

**Generates:** exactly one file — `specs/orchestrator-app-<tier>.md` *inside the
target repo* — after inspecting the target (`.repo_builder.json` lockfile,
`adws/` contents, engine dialect, whether `observability.py` events are
available, whether `orchestration/` is already shipped). The spec embeds
the four contracts of §3 in the target's dialect
(discovery glob, CLI shape, store schema — `adw.event/1` for T1/T2, Postgres DDL
only inside T3 — realtime message types), the tier's file tree from §4,
target-native validation commands, and (T2/T3) an E2E test requirement. The app
itself is then built by the normal spec → `/build` path inside the target
(`claude -p "/build specs/orchestrator-app-<tier>.md"`, or via the target's
runner: `uv run adws/adw_slash_command.py /build <spec> --json`).

**Never does:**

- writes app code into repo_builder — the factory hosts no *running*
  application code (CLAUDE.md: "This repo has no application code"); the
  shipped T2.5 app lives under `configs/templates/` as scaffold payload that
  only ever executes in targets;
- adds Postgres, MySQL, WebSocket, FastAPI, or any other dependency to a
  factory or engine file — the factory's whole orchestration surface stays
  `observability.py` + `local_ops.py` (stdlib + existing modules) plus this
  doc; no `adws/**`, `scripts/**`, or `configs/layers/**` file may import a DB
  driver, read `DATABASE_URL`, or contain SQL — PostgreSQL lives ONLY inside
  the shipped `orchestration/` template payload;
- writes to any database from the factory, or runs migrations anywhere;
- references contracts the target doesn't have (no `events.jsonl` polling in a
  spec for a target without `observability.py`; no Postgres DDL outside T3);
- modifies the target's engine — inspection is read-only; the only write is the
  spec file;
- bypasses the spec → `/build` path by emitting app code directly.

## 8. Orchestration E2E test loop — the institutionalized validation process

Validating any change to the shipped orchestration template (`configs/templates/
orchestration/`) means proving it against a **running** app in a real target repo,
not just unit tests. That loop is institutionalized as a reusable harness + runner
so it is the same every time and never re-improvised:

```
upgrade  → restart BE/FE → wait healthy → UI E2E suite (Playwright) → diagnose-on-fail
```

**Shell harness — `scripts/lib/orchestration_e2e.sh` (sourced) + `scripts/orchestration_e2e.sh` (CLI).**
The deterministic half. Functions: `orch_e2e_upgrade` (wraps
`scripts/sync_orchestrator.sh <target>`), `orch_e2e_restart` (backgrounds
`start_be.sh`/`start_fe.sh` — they self-clear their own ports, so re-running IS a
clean restart, no kill step), `orch_e2e_wait_healthy` (polls BE `:9403` / FE `:5175`
with timeouts), `orch_e2e_up` (the one-call bring-up), `orch_e2e_logs --diagnose`
(reads the **newest** `<target>/orchestration/backend/logs/*.log` and greps the pi
failure signatures: `[pi]`, `did not complete cleanly`, `reached_agent_end`,
`blocked`, `no price for`, `not available on`, `Traceback`, stderr), and
`orch_e2e_down` (teardown). One command brings a target up to date and running:
`./scripts/orchestration_e2e.sh /tmp/myapp7 up`.

**Agent-run runner — `/e2e:run_orchestration_e2e` (`commands/tac/e2e/run_orchestration_e2e.md`).**
The non-deterministic half. Calls the harness `up` once, then drives each
orchestration `e2e/test_*.md` through the **Playwright MCP** against
`http://127.0.0.1:5175/`, and on **any** failure pulls `… logs --diagnose` to report
a root cause (not just "failed"). Emits a JSON suite report. Individual
`e2e/test_*.md` tests reference the harness for their Setup rather than duplicating
the lifecycle.

**Why the split.** Doctrine §2.1: orchestration is deterministic (the shell harness
owns upgrade/restart/health/log), execution is non-deterministic (the agent drives
the browser and judges pass/fail). The harness is also sourceable by other scripts;
the runner is the suite-level orchestration the shell can't do.

**Prerequisites / gotchas** (also in the runner command):
- **Playwright MCP** is required and loads at session start. Known-good on a
  Chrome-less host: `claude mcp add --scope user playwright -- npx
  @playwright/mcp@latest --browser chromium --headless` then `npx
  @playwright/mcp@latest install-browser chrome-for-testing`. Firecrawl's browser is
  remote and cannot reach `127.0.0.1` — not a substitute.
- **`sync_orchestrator.sh` upgrades the app, NOT the `adws/` engine.** A target's
  engine catalog can diverge from the factory (e.g. `pi/zai/fast → glm-5.1-air` in a
  target vs `glm-4.5-air` in the factory). Tests that need a "model not in the
  catalog" must derive it from the live `GET /harness` catalog, never hardcode one;
  backend model tests mock `harness_settings.get_catalog` to a fixed catalog.
- **pi/zai is host-gated** (`pi` binary + `ZAI_API_KEY`); the pi tests `skip` (not
  fail) when absent.

## 9. Hotseat orchestrators — the crown (v0.28.0)

The orchestrator's own brain is operator-selectable and live-swappable, separate
from the command-agent harness:

- **Two selections, two files.** `.harness.json` (via `/harness/apply`) governs
  command agents + ADW launches. `.orchestrator.json` (via `/orchestrators*`)
  governs the orchestrator's own model. Keep them distinct (two UI badges).
- **No restart.** `OrchestratorService.process_user_message` rebuilds its
  `ClaudeSDKClient` per message; `_create_claude_agent_options` sources the model
  from `orchestrator_settings.resolve_orchestrator_model()`, so a Settings change
  takes effect on the next message. History is preserved via SDK `resume`.
- **The crown.** `orchestrator_agents` may hold multiple rows; the single-row
  `orchestrator_crown` table points at the one crowned (active) orchestrator
  (`database.set_crown`/`get_crowned_orchestrator`, exactly-one-crowned). `/send_chat`
  resolves the crowned record live; a crown swap is blocked while it is executing.
- **Claude or pi/zai (v0.30.0).** The orchestrator brain runs on **either** the
  Claude Agent SDK (claude/anthropic) **or** the `pi` binary (pi/<provider>, e.g.
  pi/zai → glm-5.1). `orchestrator_settings.validate_selection` accepts a pi
  selection when the catalog mapping + `pi` binary + provider credential validate;
  `orchestrator_runner._RUNNERS` registers both `claude` and `pi`. A pi orchestrator
  reaches the SAME 10 management tools the claude orchestrator uses through an
  **in-process HTTP MCP server** mounted at `/mcp` (`orchestrator_mgmt_mcp.py`,
  built from the harness-neutral `AgentManager.management_tool_registry()` and
  backed by the LIVE `AgentManager`), consumed by pi via the `pi-mcp-adapter`
  extension (`--mcp-config`, `directTools`). The pi chat loop lives in
  `pi_orchestrator_runner.py` (the pi twin of `process_user_message`): it streams
  `pi --mode json` events into the same `orchestrator_chat`/`thinking_block`/
  `tool_use_block` envelopes, records cost from `harness_settings.MODEL_PRICING`,
  and interrupts via process signal. The orchestrator harness stays **independent**
  of the command-agent harness (`.orchestrator.json` vs `.harness.json`).
  Prerequisites for a pi orchestrator: the `pi` binary, the `pi-mcp-adapter`
  extension (`pi install npm:pi-mcp-adapter`), and the provider credential
  (e.g. `ZAI_API_KEY`).
- **Anthropic auth source (claude brain).** For a **claude** orchestrator (and the
  command agents + the event summarizer), the auth handed to the spawned `claude`
  CLI follows the CLI's own precedence — `ANTHROPIC_API_KEY` → `CLAUDE_CODE_OAUTH_TOKEN`
  → stored `claude login` credentials (`~/.claude`) — resolved by
  `modules/anthropic_auth.py` (`resolve_auth_env`/`auth_source`). A **blank or
  placeholder** `ANTHROPIC_API_KEY` (e.g. the shipped `sk-ant-...`) is treated as
  **no key**: `config.py` pops it from `os.environ` at load (the SDK inherits
  `os.environ`, so the placeholder must be neutralized there) and the resolver never
  re-injects it — so a leftover placeholder can never shadow a working subscription/
  OAuth login. The effective source is logged (`api_key`/`oauth_token`/`ambient`),
  never the key/token value. `.env` Anthropic auth is therefore **optional**: leave
  both unset to run on a subscription login.
- **Validated** by `e2e/test_orchestrator_hotseat_swap.md` (crown a different model,
  prove the backend PID is unchanged), `e2e/test_pi_orchestrator.md` (crown a
  pi/zai orchestrator and prove it creates + commands an agent via `/mcp`; skips
  when pi/zai is host-absent), and `e2e/test_orchestrator_ambient_anthropic_auth.md`
  (no usable API key in `.env` → the chat runs on subscription/OAuth auth; skips when
  the host has neither).
- **pi command-agent file tracking is a working-tree git delta (v0.31.2).** A pi
  command agent has no PostToolUse hooks, so file changes are captured at
  `agent_end`. That snapshot is a **true working-tree delta**, not a replay of
  recognized tool calls: `FileTracker.__init__` records a baseline
  (`GitUtils.list_working_tree_changes` — `git status --porcelain
  --untracked-files=all`) at spawn (before pi runs), and `_finalize_pi_file_tracking`
  calls `FileTracker.capture_working_tree_modifications()` before generating the
  summary, unioning every path changed since the baseline into the tracked set. This
  captures files written by **`bash`/heredoc/`mv`/`cp`** or with a **dynamic name**
  (e.g. MiniMax-M2.7's `echo … > random_$(…).txt`) — which carry no `file_path`
  argument and so are invisible to the explicit write/edit fast path — so the **📄
  Produced** block renders at parity with the claude/Write path. Baseline scoping
  means pre-existing dirty files are NOT misattributed to the agent; both new methods
  are fail-soft (empty set / no-op on a non-git dir or git error, never raising).
  Validated by `e2e/test_pi_bash_file_changes.md` (host-gated on pi +
  `MINIMAX_API_KEY`).

## 10. Live `pi --list-models` model selection (v0.32.0)

The harness catalog is tier-keyed — exactly one concrete model per
`(provider, tier)`. A provider like **minimax** collapses all three tiers to a
single id (`MiniMax-M2.7`), so the Settings dropdowns only ever surfaced that one
model, even though the installed `pi` binary knows many more. The live model list
is a **purely additive override** that lets an operator pick **any concrete
model** `pi` actually offers for the chosen provider — only for **pi**; claude is
untouched, and the tier catalog stays the default and source-of-truth.

- **The live source — `modules/pi_models.py`.** A **pure**
  `parse_pi_list_models(text)` (header-skipping, whitespace-trimming columnar
  parse: `provider model context maxOut thinking images`; capability cells → bool;
  ragged lines skipped, never raises — mirrors `pi_events.py`'s hermetic boundary)
  plus `list_pi_models(provider=None, *, refresh=False)` (resolves the `pi` binary
  exactly as `pi_orchestrator_runner._pi_binary`, shells `pi --list-models`
  capturing stdout **to a temp file then reading it** — robust against the
  TTY-buffering quirk — **and stderr**, parsing the two combined: the installed
  `pi` binary prints the model table to **stderr** (stdout is empty), so reading
  only stdout yields an empty list / empty dropdown — caches the full list
  module-side, returns the case-insensitive provider slice) and
  `pi_model_ids(provider)` (the deduped ids
  for the validation merge). **Fail-soft everywhere:** no `pi` binary / non-zero
  exit / unparseable output → a logged WARNING + `[]`, never a raise — enumeration
  is convenience and must never break the tier-default path.
- **The one widened seam — `harness_settings.available_models("pi", provider)`.**
  For pi it now returns the catalog ids **unioned** with
  `pi_models.pi_model_ids(provider)` (deduped, catalog ids first; `pi_models`
  imported lazily to avoid a cycle, fail-soft so an empty live list never drops
  catalog ids). This single change makes a concrete live model **runnable** on
  both the command-agent path (`create_agent`'s create-time validation) and the
  orchestrator hotseat (`orchestrator_settings.validate_selection` /
  `_resolve_pi_model`) — both already accept a concrete pi id *iff*
  `available_models` lists it.
- **Accepting the concrete model.** `harness_settings.validate(...)` /
  `apply_selection(...)` take an optional explicit `model`: when given it is
  accepted iff it is in `available_models` (case-insensitive) and persisted as the
  selection's `model` (which `command_agent_target` already prefers for a
  non-claude harness). Omitted → unchanged tier resolution.
- **The endpoint + the UI.** Read-only `GET /harness/models?harness=pi&provider=…`
  returns `{status, models:[PiModelInfo]}` from `pi_models.list_pi_models`
  (fail-soft; non-pi harness → `[]`). `SettingsModal.vue` adds a pi-only **Model**
  dropdown to both the ⚙ Command Agents tab (`data-testid="model-concrete-select"`)
  and the 👑 Orchestrator hotseat
  (`data-testid="orchestrator-model-concrete-select"`), each fed by
  `harnessService.listPiModels(provider)`. Its first option is "use tier default";
  the rest are the live models with capability labels. Choosing one persists the
  concrete model and the resolved preview reflects it; clearing it (or changing
  provider) falls back to the tier default.
- **Pricing is out of scope.** `pi --list-models` carries no USD rates; an unpriced
  live model honestly resolves to `$0.00` + WARNING via the existing `lookup_price`
  path (capability/context metadata is surfaced as labels only).
- **ADW-launch boundary (intentional).** `launch_env_overrides` passes
  `ADW_HARNESS`/`ADW_PROVIDER` but not a concrete model, so a spawned ADW still
  re-resolves the tier via the engine catalog — honoring a UI-chosen concrete model
  in `start_adw` would need an `ADW_MODEL` override + an engine change, deliberately
  out of scope to keep this orchestration-app-scoped.
- **Validated** by `e2e/test_pi_model_list.md` (the pi Model dropdown is populated
  from `pi --list-models`; a concrete model applies + persists; host-gated on pi +
  `MINIMAX_API_KEY`, skips when absent) plus hermetic `tests/test_pi_models.py` and
  the widened `tests/test_harness_settings.py`.

## 11. Multi-modal image references in the prompt (v0.33.0)

The orchestrator prompt is **text-only**, and the chat contract is deliberately
plain text (`POST /send_chat` forwards a bare string to `client.query(...)` /
appends it as pi's trailing positional arg). To let an operator ask about a
screenshot without copying files into the repo and typing paths, this adds an
**image-address reference** pipeline *around* the message — the lightweight
approach the feature asks for ("a reference of the image address"), **not** base64
content-block embedding. Drag an image → it lands in the repo's uploads dir → its
address appears in the prompt → a vision model reads it. The SDK/pi message
contract, the tier catalog, and persistence are untouched.

- **The upload boundary — `modules/image_uploads.py`.** Fail-soft-but-**loud**
  (NOT one of the fail-silent observability surfaces): pure validators
  (`allowed_image_type` — a png/jpg/jpeg/gif/webp MIME/ext allow-list;
  `safe_basename` — a traversal-safe `<uuid>.<ext>`, the client filename is kept
  only as display metadata and **never** used on disk) split from the IO
  (`save_image` writes under `<working_dir>/.orchestrator/uploads/` and returns the
  path **relative to the working dir** + the absolute path). A rejected / empty /
  oversized (`ORCHESTRATOR_MAX_IMAGE_BYTES`, default 10 MB) / unwritable upload
  raises a clear `ValueError` (logged) — the operator is told why, never left
  guessing. `POST /uploads/image` (multipart) exposes it: success →
  `{status:"success", path:<relative>, abs_path, filename, content_type, bytes}`; a
  bad upload → HTTP 400 + `{status:"error", message}`.
- **Why a reference, not base64 content blocks.** A path reference keeps the
  message a plain string, so neither the claude `client.query(...)` call nor pi's
  trailing positional-arg contract changes, and **command agents inherit it for
  free** (the path is just text the orchestrator can pass along). Vision happens
  through the agent's `Read`/file tool opening the path — claude's `Read` renders
  images visually; pi reads the file when its model is image-capable. The
  orchestrator system prompt has one line telling it to open an image path (e.g.
  under `.orchestrator/uploads/`) with `Read` before responding.
- **Uploads live in the working dir on purpose.** The agent's `cwd` is the working
  dir, so a path **relative to it** resolves for both the orchestrator and any
  command agent it spawns — no absolute host paths leak into prompts, and the
  reference is portable across the orchestrator/agent boundary.
- **Capability hint (advisory, never a gate).** `pi_models.model_supports_images`
  reads the live `images` flag; `harness_settings.supports_images` (claude → always
  True; pi → the flag) and `orchestrator_settings.supports_images` resolve the
  selected model's capability, surfaced as a `supports_images` boolean on
  `GET /harness` (command-agent selection) and `GET /orchestrators` (crowned
  orchestrator). The UI shows a "the selected model doesn't support images — the
  reference will be sent as text" hint when false. The reference **inserts
  regardless** — operators may attach an image then switch to a vision model before
  sending; blocking the insert would be wrong.
- **Frontend.** A reusable `composables/useImageDrop.ts` wires
  `dragover`/`drop`/`paste` + a 📎 file-picker into both prompt inputs
  (`GlobalCommandInput.vue`, `OrchestratorChat.vue`): each image pushes an
  `uploading` thumbnail chip (local `URL.createObjectURL`), uploads via
  `services/imageService.ts`, then on success flips to `ready` and inserts the
  returned path through the host's existing `appendToInput`/`insertCommandReference`
  seam. The hidden `<input type="file">` (`data-testid="prompt-attach-input"`) is
  the deterministic E2E hook — the drop/paste handlers share the same code path.
  Fail-soft UI: a failed upload shows an error chip, never throws into the render.
- **Cleanup is out of scope.** Uploaded files accumulate under
  `.orchestrator/uploads/` (gitignored via the scaffold `.gitignore`); a
  retention/pruning policy is a follow-on chore.
- **Validated** by `e2e/test_orchestrator_image_drop.md` (attach → address
  reference + chip + capability hint; attach/insert host-independent, the pi
  non-image-model tail host-gated) plus hermetic `tests/test_image_uploads.py` and
  the `tests/orchestration_app.bats` structural guards.
