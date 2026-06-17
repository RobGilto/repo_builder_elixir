# Feature: Full agent-CRUD orchestrator tooling (`update_agent`, `delete_agent`, `read_system_logs`, `check_adw`)

## Metadata
issue_number: `full`
adw_id: `agent-CRUD`
issue_json: `orchestrator`

## Feature Description
The orchestrator agent already exposes a harness-blind tool surface
(`RepoBuilder.Orchestrator.ToolCatalog` + `RepoBuilder.Orchestrator.Tools`) that
lets an AI orchestrator manage its worker agents: `create_agent`, `list_agents`,
`check_agent_status`, `command_agent`, `interrupt_agent`, and `start_adw`. This
covers **C**reate and **R**ead of agent definitions but has no **U**pdate or
**D**elete, and no way to inspect system logs or a launched ADW run.

This feature adopts the tooling pattern proven in the reference app
`/data/1.Projects/tactical-agentic-coding/tac-14/orchestrator-agent-with-adws/apps/orchestrator_3_stream/`
(Python/FastAPI + Claude Agent SDK in-process MCP server) and completes the
agent lifecycle in this Elixir platform by adding four tools:

1. **`update_agent`** — edit a worker's `system_prompt`, `model`, and/or
   `harness` by name (the reference app has no update tool; this goes beyond it
   to deliver full CRUD).
2. **`delete_agent`** — remove a worker by name, stopping any live session first
   and broadcasting the removal so the console roster updates live (mirrors the
   reference app's `delete_agent`).
3. **`read_system_logs`** — page through `system_logs` with `offset`/`limit` plus
   optional `level` and `message_contains` filters (mirrors the reference app's
   `read_system_logs`).
4. **`check_adw`** — inspect a workflow run by id (status, current step, cost,
   artifacts), pairing with the existing `start_adw` (mirrors the reference
   app's `check_adw`).

Because the Elixir MCP-over-HTTP controller
(`RepoBuilderWeb.OrchestratorMCPController`) is already **catalog-driven**
(`tools/list` maps over `ToolCatalog.tools()`, `tools/call` dispatches through
`Tools.call/3`), adding entries to the catalog + logic automatically advertises
and wires the new tools for the Claude (native MCP) binding. The pi binding is a
**hardcoded TypeScript mirror** (`priv/orchestrator/pi_extension/orchestrator-tools.ts`)
that must be updated by hand to stay in sync.

## User Story
As an **AI orchestrator agent** driving worker agents on this platform
I want to **update and delete the workers I create, read recent system logs, and
check the status of ADW runs I launch**
So that I can **manage the full lifecycle of my agents and observe my own
workflow runs without an operator manually intervening in the dashboard.**

## Problem Statement
The orchestrator can spawn workers (`create_agent`) and observe them
(`list_agents`, `check_agent_status`) but cannot correct a worker's
configuration (wrong model/prompt/harness) or remove a worker it no longer
needs. It also cannot read the platform's `system_logs` (where its own tool
invocations are recorded) or follow up on an ADW it launched with `start_adw` —
`start_adw` returns a `run_id` with no companion read tool. The result is a
half-complete management surface: an orchestrator that creates state it cannot
revise, delete, or observe to completion.

## Solution Statement
Extend the single source of truth (`ToolCatalog.tools/0`) with four new
`tool_def()` entries and implement their handlers once in harness-blind Elixir
(`RepoBuilder.Orchestrator.Tools`), driving only existing context seams
(`Agents`, `Logs`, `Workflows`, `Session.Supervisor`, `Dashboard`). Add the
small context-layer functions the handlers need (`Agents.update_worker/2`,
`Logs.query_system_logs/1`, `Dashboard.broadcast_agent_deleted/1`), mirror the
four definitions into the pi extension, and add a live console handler so a
deleted worker disappears from the roster. The MCP controller and JSON-RPC
envelope need **no change** — they are already generic over the catalog. Every
new public function carries an `@spec`; every failure is a tagged tuple; nothing
raises (the `Tools.call/3` boundary already rescues/catches).

## Relevant Files
Use these files to implement the feature:

- `lib/repo_builder/orchestrator/tool_catalog.ex` — **edit.** The single source
  of truth for tool name/description/`input_schema`. Append the four new
  `tool_def()` entries (`update_agent`, `delete_agent`, `read_system_logs`,
  `check_adw`). `names/0` derives from this; the MCP `tools/list` maps over it.
- `lib/repo_builder/orchestrator/tools.ex` — **edit.** The harness-blind tool
  logic. Add four `dispatch/3` clauses and four private handlers plus helpers
  (`worker_update_params/1`, `ensure_uuid/1`, `non_neg_int/2`,
  `system_log_summary/1`, `run_summary/1`, `decimal_to_string/1`). Add
  `Workflows` to the alias list. Handlers must return `{:ok, map()} |
  {:error, reason()}` and never raise.
- `lib/repo_builder/agents.ex` — **edit.** Add `update_worker/2` (uses
  `Agent.worker_changeset/2` so `model`/`system_prompt`/`harness` are castable —
  the plain `changeset/2` does NOT cast those fields and requires `provider`).
  `delete_agent/1` already exists.
- `lib/repo_builder/agents/agent.ex` — **read.** Confirms `worker_changeset/2`
  casts `:model`, `:system_prompt`, `:harness`, and validates harness against the
  registry; `validate_required([:name, :harness, :orchestrator_id])` is satisfied
  by the existing struct data on update.
- `lib/repo_builder/logs.ex` — **edit.** Add `query_system_logs/1` (limit/offset/
  level/message_contains) with a safe string→atom level whitelist (never
  `String.to_atom/1` on input, per AGENTS.md). `create_system_log/1` and
  `list_system_logs/1` already exist.
- `lib/repo_builder/logs/system_log.ex` — **read.** `level` is
  `Ecto.Enum[:debug,:info,:warn,:error]`; `message`, `metadata`, timestamps.
- `lib/repo_builder/workflows.ex` — **read.** `get_run/1` returns
  `WorkflowRun.t() | nil`; used by `check_adw`.
- `lib/repo_builder/workflows/workflow_run.ex` — **read.** Fields available to
  `check_adw`: `status`, `current_step`, `artifacts`, `total_cost_usd` (nullable).
- `lib/repo_builder/dashboard.ex` — **edit.** Add `broadcast_agent_deleted/1`
  mirroring `broadcast_agent_created/1` (broadcasts `{:agent_deleted, agent}` on
  the `console:events` topic — an additive seam, NOT a canonical `Event` variant).
- `lib/repo_builder/session/supervisor.ex` — **read.** `stop_session/1` (by agent
  id; `{:error, :not_found}` if no live session) reaps a worker's child before
  delete. `interrupt/1` is the existing best-effort interrupt.
- `lib/repo_builder_web/controllers/orchestrator_mcp_controller.ex` — **read /
  no change.** Already catalog-driven; the four tools surface automatically over
  MCP. Confirm no hardcoded tool list exists (there is none).
- `lib/repo_builder_web/live/console_live.ex` — **edit.** Add a
  `handle_info({:agent_deleted, %Agent{}}, socket)` clause mirroring the existing
  `{:agent_created, ...}` handler (around line 683): drop the worker from
  `:agents`, `:agent_names`, `:statuses` and `stream_delete` its `:lanes` row.
- `priv/orchestrator/pi_extension/orchestrator-tools.ts` — **edit.** The
  hardcoded pi binding mirror. Append the four tool definitions (`name`,
  `description`, `parameters`) to the `tools` array so pi advertises them; the
  `execute` loop and `callTool` HTTP bridge already handle dispatch generically.
- `test/repo_builder/orchestrator/tools_test.exs` — **edit.** Add `describe`
  blocks for `update_agent`, `delete_agent`, `read_system_logs`, `check_adw`
  (happy path + error branches), following the existing Fake-harness/SessionCase
  pattern.
- `test/repo_builder_web/controllers/orchestrator_mcp_controller_test.exs` —
  **edit (light).** Extend the `tools/list` assertion to confirm the four new
  names are advertised; optionally add one `tools/call` round-trip for
  `delete_agent`.

### New Files
- `test/repo_builder_web/live/test_agent_crud_roster_test.exs` — a
  `Phoenix.LiveViewTest` integration test that mounts `ConsoleLive`, broadcasts
  `{:agent_created, agent}` then `{:agent_deleted, agent}` on `console:events`
  (or drives `Tools.call("delete_agent", ...)`), and asserts the roster/lane row
  appears then disappears. Validates the additive UI seam.

### Relevant docs (per `.claude/commands/conditional_docs.md`)
- `ai_docs/typed-elixir-standard.md` — **(always)** the enforced typed coding
  standard (`@spec` on every public fn, `typedstruct`/`@enforce_keys`, precise
  types, tagged tuples, wire-vs-domain). Gated by `--warnings-as-errors`,
  `mix credo --strict` (`Credo.Check.Readability.Specs`), `mix dialyzer`.
- `BUILD_PROMPT.md` §10 (add a harness/tool = config + one seam; the open
  identity that makes the catalog the single source of truth), §8 (contexts are
  the only `Repo` callers; cost float→Decimal; nil-vs-0 preserved), §9 (LiveView
  streams + additive console seams), §13 (Mox/Fake testing, crash isolation).
- `pi-harness-tooling` (memory) — pi ships NO MCP; custom tools come from a TS
  extension; the `.ts` mirror is a binding only, logic lives once in Elixir.

## Implementation Plan
### Phase 1: Foundation
Add the minimal context-layer primitives the new handlers depend on, each
`@spec`'d and behind its context module (no `Repo` access leaks into `Tools`):
- `RepoBuilder.Agents.update_worker/2` — worker-aware update via
  `worker_changeset/2` (so `model`/`system_prompt`/`harness` are castable).
- `RepoBuilder.Logs.query_system_logs/1` — filtered/paginated read with a safe
  level whitelist and `ilike` message match; add `offset: 2` to the
  `import Ecto.Query` list.
- `RepoBuilder.Dashboard.broadcast_agent_deleted/1` — `{:agent_deleted, agent}`
  on `console:events` (additive seam).

### Phase 2: Core Implementation
- Append the four `tool_def()` entries to `ToolCatalog.tools/0` (stable order:
  after the existing tools, to avoid disturbing any position-sensitive readers).
- Implement the four handlers + private helpers in `Tools`, wired into
  `dispatch/3`. `delete_agent` best-effort stops the live session before delete;
  `update_agent` rejects an empty change set; `check_adw` validates the run id is
  a UUID and returns `{:error, :not_found}` for an unknown run;
  `read_system_logs` clamps limit/offset and maps filters.
- Each handler logs via the existing `log_invocation/4` (automatic in
  `Tools.call/3`) and keeps tool-arg values out of `system_logs`
  (`redact_args/1` already logs only keys).

### Phase 3: Integration
- Mirror the four definitions into `priv/orchestrator/pi_extension/orchestrator-tools.ts`.
- Add the `{:agent_deleted, %Agent{}}` handler to `ConsoleLive` so a worker the
  orchestrator deletes vanishes from the rail roster + swimlane live.
- Extend the MCP controller test (tools/list advertises the new names) and add
  the LiveView roster integration test.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Add `Agents.update_worker/2`
- In `lib/repo_builder/agents.ex`, add:
  - `@spec update_worker(Agent.t(), map()) :: {:ok, Agent.t()} | {:error, Ecto.Changeset.t()}`
  - Body: `agent |> Agent.worker_changeset(stringify_keys(params)) |> Repo.update()`
    (reuse the existing private `stringify_keys/1`).
- Rationale: the existing `update_agent/2` uses `Agent.changeset/2`, which does
  NOT cast `:model`/`:system_prompt` and requires `:provider`; it cannot update
  worker fields. `worker_changeset/2`'s `validate_required([:name, :harness,
  :orchestrator_id])` is satisfied by the persisted struct's existing values.

### 2. Add `Logs.query_system_logs/1`
- In `lib/repo_builder/logs.ex`, extend the `import Ecto.Query` to include
  `offset: 2`.
- Add:
  - `@spec query_system_logs(keyword()) :: [SystemLog.t()]`
  - Options: `:limit` (default 50, clamp to a sane max e.g. 200), `:offset`
    (default 0), `:level` (string or nil), `:message_contains` (string or nil).
  - Order `desc: :inserted_at, desc: :id`; apply `limit`/`offset`.
  - Level filter: map the incoming string through a fixed whitelist
    `%{"debug" => :debug, "info" => :info, "warn" => :warn, "error" => :error}`
    (never `String.to_atom/1` on input); an unknown/blank level is ignored (no
    filter). Add a private `@spec maybe_level(query, String.t() | nil)` and
    `maybe_contains(query, String.t() | nil)` using `ilike(l.message, ^"%...%")`.
- Keep all `Repo` access in this context module (§8).

### 3. Add `Dashboard.broadcast_agent_deleted/1`
- In `lib/repo_builder/dashboard.ex`, add a `@doc` + `@spec`'d
  `broadcast_agent_deleted/1` mirroring `broadcast_agent_created/1`:
  - `@spec broadcast_agent_deleted(RepoBuilder.Agents.Agent.t()) :: :ok`
  - Broadcast `{:agent_deleted, agent}` on the `@events_topic`
    (`"console:events"`). Document it as an additive seam (NOT a canonical
    `Event` variant), matching the existing `broadcast_agent_created/1` note.

### 4. Add the four tool definitions to `ToolCatalog`
- In `lib/repo_builder/orchestrator/tool_catalog.ex`, append four `tool_def()`
  maps to the list returned by `tools/0`, after `start_adw`:
  - `update_agent`: `properties` = `name` (string, required), `system_prompt`
    (string), `model` (string), `harness` (string); `required: ["name"]`.
    Description notes at least one updatable field must be provided and harness
    is validated against the registry.
  - `delete_agent`: `properties` = `name` (string, required); `required:
    ["name"]`. Description notes any live session is stopped first.
  - `read_system_logs`: `properties` = `limit` (integer), `offset` (integer),
    `level` (string enum debug|info|warn|error), `message_contains` (string);
    `required: []`.
  - `check_adw`: `properties` = `run_id` (string, required); `required:
    ["run_id"]`. Description notes it returns status/current_step/cost/artifacts
    and pairs with `start_adw`.
- Keep descriptions concise and operator-readable (they reach the model verbatim
  in `tools/list`).

### 5. Implement the four handlers in `Tools`
- In `lib/repo_builder/orchestrator/tools.ex`:
  - Add `Workflows` to the `alias RepoBuilder.{...}` list.
  - Add four `dispatch/3` clauses: `update_agent`, `delete_agent`,
    `read_system_logs`, `check_adw`.
  - `update_agent/2`:
    - `fetch_string(args, "name")` → `Agents.get_by_name_for_orchestrator/2`.
    - Build params from `worker_update_params/1` (include only present non-blank
      `harness`/`model`/`system_prompt`); if empty → `{:error, "no updatable
      fields provided"}`.
    - `Agents.update_worker/2`; on `{:error, %Ecto.Changeset{}}` →
      `changeset_reason/1`. On success return `{:ok, %{"id","name","harness",
      "model","status"}}` (string keys, `to_string(status)`).
  - `delete_agent/2`:
    - Resolve worker; `_ = Session.Supervisor.stop_session(worker.id)`
      (ignore `{:error, :not_found}`); `Agents.delete_agent(worker)`; on success
      `_ = Dashboard.broadcast_agent_deleted(worker)` and return
      `{:ok, %{"status" => "deleted", "id" => worker.id, "name" => worker.name}}`;
      on changeset error → `changeset_reason/1`.
  - `read_system_logs/2`:
    - Build opts from `positive_int(args["limit"], 50)`, `non_neg_int(args["offset"],
      0)`, `blank_to_nil(args["level"])`, `blank_to_nil(args["message_contains"])`;
      map rows through `system_log_summary/1`; return
      `{:ok, %{"logs" => [...], "count" => n}}`.
  - `check_adw/2`:
    - `fetch_string(args, "run_id")` → `ensure_uuid/1` (`Ecto.UUID.cast/1`;
      `:error` → `{:error, "invalid run_id"}`) → `Workflows.get_run/1`;
      `nil → {:error, :not_found}`; else `{:ok, run_summary/1}` with
      `run_id`, `status` (to_string), `current_step`, `cost_usd`
      (`decimal_to_string/1`, nil→nil preserving unpriced), `artifacts`.
  - Add private `@spec`'d helpers: `worker_update_params/1`, `non_neg_int/2`,
    `ensure_uuid/1`, `system_log_summary/1`, `run_summary/1`,
    `decimal_to_string/1`. Match the existing inference-only spec style where
    Dialyzer narrows (mirror `positive_int/2`'s comment if needed).

### 6. Unit-test the four tools (`tools_test.exs`)
- In `test/repo_builder/orchestrator/tools_test.exs`, add `describe` blocks:
  - `update_agent`: updates `model`/`system_prompt`/`harness` on a created
    worker (assert persisted via `Agents.get_by_name_for_orchestrator/2`);
    unknown worker → `{:error, :not_found}`; no updatable fields → `{:error, _}`;
    invalid harness → `{:error, _}`.
  - `delete_agent`: deletes a created worker (assert
    `get_by_name_for_orchestrator/2` now `{:error, :not_found}`) and broadcasts
    `{:agent_deleted, %{name: ...}}` (subscribe via `Dashboard.subscribe_events()`
    then `assert_receive`); unknown worker → `{:error, :not_found}`.
  - `read_system_logs`: after a tool call has logged (any `Tools.call`), returns
    `{:ok, %{"logs" => list, "count" => n}}`; `message_contains` filter narrows;
    `level` filter narrows; bad/blank level is ignored (no crash).
  - `check_adw`: launch via `start_adw`, then `check_adw` with the returned
    `run_id` returns `{:ok, %{"status" => _}}`; unknown UUID → `{:error,
    :not_found}`; non-UUID `run_id` → `{:error, "invalid run_id"}`. Reuse the
    existing `assert_run_terminal/2` drain helper so spawned step sessions settle.

### 7. Mirror the tools into the pi extension
- In `priv/orchestrator/pi_extension/orchestrator-tools.ts`, append four objects
  to the `tools` array with `name`, `description`, and `parameters` matching the
  catalog `input_schema` shapes (`type: "object"`, `properties`, `required`).
  No handler code is needed — the `export default` loop registers each and routes
  through the generic `callTool` HTTP bridge. Update the file's "Mirror
  RepoBuilder.Orchestrator.ToolCatalog" comment if it enumerates tools.

### 8. Add the `{:agent_deleted, ...}` handler to `ConsoleLive`
- In `lib/repo_builder_web/live/console_live.ex`, after the existing
  `handle_info({:agent_created, %Agent{} = agent}, socket)` clause (~line 683),
  add a `handle_info({:agent_deleted, %Agent{} = agent}, socket)` clause that:
  - Drops the worker from `:agents` (`Enum.reject(&(&1.id == agent.id))`),
    `:agent_names` (`Map.delete`), `:statuses` (`Map.delete`).
  - `stream_delete(socket, :lanes, %{id: "agent:#{agent.id}"})` to remove the
    swimlane row (the lane dom_id is `"agent:#{id}"`, matching `broadcast_lane`/
    the `agent_created` insert).
- Keep server memory flat (streams idiom, §9); the handler is idempotent for an
  already-absent worker.

### 9. Create the LiveView roster integration test
- Create `test/repo_builder_web/live/test_agent_crud_roster_test.exs` using
  `Phoenix.LiveViewTest`:
  - Mount `ConsoleLive` at `/` (`live/2` via `ConnCase`).
  - Broadcast `{:agent_created, agent}` on `console:events`
    (`Phoenix.PubSub.broadcast(RepoBuilder.PubSub, "console:events", ...)`),
    assert the roster/lane element for that agent is present
    (`has_element?(view, "#...")` against the lane/rail dom id).
  - Broadcast `{:agent_deleted, agent}`, assert the element is gone
    (`refute has_element?(...)`).
  - Reference the real dom ids added in `ConsoleLive` for the rail/lane rows.

### 10. Extend the MCP controller test
- In `test/repo_builder_web/controllers/orchestrator_mcp_controller_test.exs`,
  extend the `tools/list` test to assert `"update_agent"`, `"delete_agent"`,
  `"read_system_logs"`, `"check_adw"` are all `in names`. Optionally add one
  `tools/call` round-trip: create a worker, then `delete_agent` returns
  `isError: false` and the worker row is gone.

### 11. Run the validation commands
- Run every command in `Validation Commands` and fix any failures until all are
  green with zero regressions. Optionally use Tidewave `project_eval` to call
  `RepoBuilder.Orchestrator.Tools.call("check_adw", orch_id, %{"run_id" => ...})`
  against the live app and `execute_sql_query` to confirm a `delete_agent`
  removed the `agents` row.

## Testing Strategy
### Unit Tests
- `Tools.call/3` for each new tool: happy path returns `{:ok, map()}` with the
  documented string-keyed shape; error branches return `{:error, reason}` where
  `reason` is an atom or string (never a raw changeset/exception — the
  `changeset_reason/1` boundary + `Tools.call/3` rescue guarantee this).
- `Agents.update_worker/2`: casts `model`/`system_prompt`/`harness`; rejects an
  unregistered harness via the changeset (`{:error, %Ecto.Changeset{}}`).
- `Logs.query_system_logs/1`: limit/offset paging; `level` and `message_contains`
  filters narrow results; unknown level is ignored; ordering is newest-first.
- `Dashboard.broadcast_agent_deleted/1`: subscribers on `console:events` receive
  `{:agent_deleted, agent}`.
- LiveView: a broadcast add then delete makes the roster/lane row appear then
  disappear (streams; flat memory).
- MCP contract: `tools/list` advertises all ten tools with `inputSchema`;
  `tools/call delete_agent` is wrapped as `isError: false`.

### Edge Cases
- `update_agent` with no updatable fields (only `name`) → `{:error, "no
  updatable fields provided"}`, no DB write.
- `update_agent`/`delete_agent`/`check_agent_status` for an unknown worker →
  `{:error, :not_found}`.
- `update_agent` with `harness: "nope"` → changeset rejection (registry openness
  preserved via `validate_inclusion`).
- `delete_agent` for a worker with a **live** session → session is stopped
  (`stop_session/1`) before the row is deleted; no orphaned child, no crash; the
  GenServer termination reaps the OS child (§6). Deleting a worker with **no**
  live session → `stop_session/1` returns `{:error, :not_found}`, ignored.
- `delete_agent` idempotency in the UI: a second `{:agent_deleted, agent}` for an
  already-removed worker is a no-op.
- `check_adw` with a non-UUID `run_id` → `{:error, "invalid run_id"}` (no
  `Ecto.Query.CastError` reaching the caller); unknown UUID → `{:error,
  :not_found}`; a run with `total_cost_usd == nil` → `"cost_usd" => nil`
  (unpriced preserved, never `"0"`).
- `read_system_logs` with `limit`/`offset` absent → defaults (50/0); with a blank
  or invalid `level` → no level filter; oversized `limit` is clamped.
- Cross-orchestrator scoping: `update_agent`/`delete_agent` only resolve workers
  owned by the calling orchestrator (`get_by_name_for_orchestrator/2`), so one
  orchestrator cannot mutate/delete another's worker by name.

## Acceptance Criteria
- `ToolCatalog.tools/0` returns 10 tools; `ToolCatalog.names/0` includes
  `update_agent`, `delete_agent`, `read_system_logs`, `check_adw`.
- The MCP `tools/list` over HTTP advertises all four new tools with
  `inputSchema`; `tools/call` dispatches each through `Tools.call/3` and wraps
  `{:error, _}` as `isError: true` (never a JSON-RPC protocol error or 500).
- `update_agent` mutates a worker's `model`/`system_prompt`/`harness` and the
  change is persisted and reflected in `list_agents`/`check_agent_status`.
- `delete_agent` removes the worker row, stops any live session first, and the
  console roster/swimlane row disappears live via `{:agent_deleted, ...}`.
- `read_system_logs` returns paged, filterable system-log summaries.
- `check_adw` returns a run's status/current_step/cost/artifacts for a valid id
  and `{:error, :not_found}`/`{:error, "invalid run_id"}` otherwise.
- The pi extension `tools` array mirrors the four new definitions.
- Every new public function has an `@spec`; no struct/`Repo` access leaks outside
  a context; the full green gate passes with zero regressions.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix compile --warnings-as-errors` — Compile clean; gradual set-theoretic type
  checker + `warnings_as_errors` pass.
- `mix test test/repo_builder/orchestrator/tools_test.exs` — The four new tool
  `describe` blocks (plus existing) pass.
- `mix test test/repo_builder_web/controllers/orchestrator_mcp_controller_test.exs`
  — The extended `tools/list`/`tools/call` contract passes.
- `mix test test/repo_builder_web/live/test_agent_crud_roster_test.exs` — The
  LiveView roster add/delete integration test passes.
- `mix test --warnings-as-errors` — Full suite, zero failures.
- `mix format --check-formatted` — Code is formatted.
- `mix credo --strict` — Lint, including the "every public function has an
  `@spec`" check (`Credo.Check.Readability.Specs`).
- `mix dialyzer` — `@spec`/contract checking, no new warnings, no stale ignore
  filters.

## Notes
- **No new dependencies.** All four tools build on existing context seams
  (`Agents`, `Logs`, `Workflows`, `Session.Supervisor`, `Dashboard`) and the
  already-generic MCP controller.
- **Two bindings, one logic (§10).** The Claude binding is fully catalog-driven
  (zero controller edits); the pi binding is a hand-maintained TypeScript mirror.
  This asymmetry is by design (pi ships no MCP — memory `pi-harness-tooling`).
  Keep the `.ts` `tools` array and `ToolCatalog.tools/0` in lockstep; a future
  hardening could generate the `.ts` list from the catalog to remove the manual
  sync, but that is out of scope here.
- **No `update_agent` in the reference app.** The reference
  `orchestrator_3_stream` mutates agents implicitly via `command_agent` and has
  no explicit update tool. `update_agent` here is a deliberate superset to
  deliver true CRUD; `delete_agent`/`read_system_logs`/`check_adw` are faithful
  adaptations of the reference tools.
- **`provider` stays in `config`, not the enum column.** Workers created with an
  open provider (e.g. pi/zai) carry it in `config["provider"]` (the
  `provider` Ecto.Enum can't hold the open set). `update_agent` intentionally
  does NOT expose `provider`/`category` re-resolution in this iteration to keep
  the update surface small and predictable; changing tier/provider is done by
  deleting and re-creating, or via a future `recategorize_agent` tool.
- **Logging hygiene.** `Tools.call/3` already logs every invocation to
  `system_logs` via `log_invocation/4` and redacts arg **values**
  (`redact_args/1` logs only keys), so `read_system_logs` cannot leak prompt
  bodies passed to `update_agent`/`command_agent`.
- **Validation via Tidewave** (optional, live app): `project_eval` to exercise
  `Tools.call/3` for each new tool, `execute_sql_query` to confirm the
  `agents`/`system_logs`/`workflow_runs` state, `get_logs` to inspect any
  stacktrace.
