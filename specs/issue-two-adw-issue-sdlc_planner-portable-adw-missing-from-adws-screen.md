# Bug: Portable (shell-out) ADW runs but never appears on the ADWs screen

## Metadata
issue_number: `two`
adw_id: `issue`
issue_json: `log-36411`

## Bug Description
An operator launched a real ADW from the orchestrator chat (`start_adw` with harness
`"adw"`) against a target repo (`worldWorkBench`). The ADW **is running** — its per-step
worker events (`harness = "adw"`, `payload.adw_id = "adw-mXtkfe3YbNXtKgi5"` /
`"adw-3Vvtcyd-1y4FhBAw"`, `payload.adw_step = "plan"|"build"`) are streaming into
`agent_logs` (evidence: `log-36411`…`log-36421`, `log-36423`…`log-36429`, and the
orchestrator's own commentary at `log-36364`, `log-36367`…`log-36368`,
`log-36370`…`log-36372`, `log-36380`…`log-36381`, `log-36383`…`log-36384`, where the
orchestrator narrates *"Phase 2 ADW c103b5cc is running"*).

**Expected:** the running ADW shows up as an ADW card on the console's **ADWs** screen
(a swimlane card with status `running` and per-step squares filling as the phases
progress).

**Actual:** the ADWs screen shows **"No AI Developer Workflows found."** even while the
ADW streams events. The run is invisible on the screen dedicated to ADWs. Separately, the
ADW's persisted events are **mis-attributed**: their `agent_logs` rows carry
`orchestrator_id = NULL` and `project_id = NULL` (verified via SQL for `log-36411`,
`log-36415`, `log-36421`, `log-36423`, `log-36430`), so they are not owned by the
launching orchestrator nor scoped to the target project.

## Problem Statement
The **portable / shell-out ADW path** (`RepoBuilder.Orchestrator.Tools.start_adw_via_adapter/4`,
taken when the resolved harness is `"adw"`) models an ADW run as an orchestrator-owned
**worker Agent** driven by the generic §6 session runtime. That runtime broadcasts a
swimlane lane of `kind: :agent`. The console's **ADWs** screen, however, renders **only**
`kind: :workflow` cards held in the `@workflow_progress` assign (seeded from
`WorkflowRun` rows and updated by `kind: :workflow` lanes). Because the portable ADW
never produces a `WorkflowRun` row and never broadcasts a `kind: :workflow` lane, it has
**no surface** on the ADWs screen. A recent change (`de59371`) also updated the sibling
worker-launch path (`command_agent/3`) to thread `orchestrator_id`/`project_id` into the
session but did **not** update `spawn_adw_session/4`, so portable-ADW events persist
unowned/unscoped.

## Solution Statement
Two surgical, additive changes — no new schema, no new deps:

1. **Make the portable ADW render on the ADWs screen (primary).** Have the session
   runtime broadcast a `kind: :workflow` lane (`id: "workflow:<agent_id>"`) — in addition
   to the existing `kind: :agent` lane — for ADW-harness sessions on each lifecycle
   transition (start → running, terminal → succeeded/failed). The console already handles
   such lanes: `ConsoleLive.update_workflow_status/2` matches `id: "workflow:" <> run_id`
   and builds/updates a card via `default_workflow_view/1` even for a run first seen live.
   Because the card's `run_id` equals the worker/agent id, `workflow_step_squares/3`
   (which matches `row.agent_key == run_id`) fills the card's squares from the ADW worker
   events that are already streaming — the card lights up with no further wiring.

2. **Restore attribution/scoping (secondary, a regression from `de59371`).** Thread
   `orchestrator_id`, the orchestrator's bound `project_id`, `agent_name`, `provider`, and
   `isolation_mode` into `spawn_adw_session/4`'s session opts, mirroring `command_agent/3`.
   This makes the ADW's persisted `agent_logs` rows carry the launching orchestrator and
   target project (so they pass the console's project-scoped feed and are correctly owned),
   matching the sibling worker path exactly.

## Steps to Reproduce
1. Register a target repo at `/projects` and bind an orchestrator to it (or run against
   the platform itself).
2. From the orchestrator chat, launch a portable ADW: `start_adw` with harness `"adw"`,
   a discovered `workflow_type` (e.g. `adw_plan_build_local_iso`), and an `input`.
3. Open the **ADWs** screen on the console at `/`.
4. **Observe:** the screen shows *"No AI Developer Workflows found."* even though the ADW
   is running (tool calls / text deltas are streaming; `check_adw` returns live events).
5. Inspect persistence:
   ```sql
   SELECT log_no, event_type, harness,
          orchestrator_id IS NOT NULL AS has_orch,
          project_id IS NOT NULL AS has_proj,
          payload->>'adw_id' AS adw_id, payload->>'adw_step' AS step
     FROM agent_logs WHERE harness = 'adw' ORDER BY log_no DESC LIMIT 10;
   ```
   **Observe:** `has_orch = f`, `has_proj = f` for every ADW row.

## Root Cause Analysis
Two independent gaps compound into the reported symptom.

**A. The ADWs screen has no surface for the portable-ADW path.**
- `RepoBuilder.Orchestrator.Tools.start_adw/2` (`lib/repo_builder/orchestrator/tools.ex:1320`)
  branches on the harness: harness `"adw"` → `start_adw_via_adapter/4`
  (`tools.ex:1363`); anything else → `start_adw_via_engine/4` (`tools.ex:1336`).
- The **engine** path creates a `WorkflowRun` (with `orchestrator_id`) whose `Runner`
  broadcasts `kind: :workflow` lanes (`id: "workflow:<run_id>"`) → the ADWs screen shows a
  card. **This path works.**
- The **adapter** path instead calls `Agents.create_worker/2` (`tools.ex:1390`) and
  `spawn_adw_session/4` (`tools.ex:1495`). The generic runtime
  (`RepoBuilder.Session.Server.lane/3`, `lib/repo_builder/session/server.ex:1041`) only
  ever broadcasts `%{id: "agent:<agent_id>", kind: :agent, …}`. It **never** emits a
  `kind: :workflow` lane.
- `ConsoleLive` renders the ADWs list purely from `@workflow_progress`
  (`lib/repo_builder_web/live/console_live.ex:3696`–`3711`), seeded from
  `Workflows.list_recent_runs/2` (`console_live.ex:746`–`752`) and mutated only by
  `kind: :workflow` lanes (`console_live.ex:2966`–`2968` → `update_workflow_status/2` at
  `console_live.ex:758`). `kind: :agent` lanes go to the flat `:lanes` stream
  (`console_live.ex:2970`–`2973`), which the ADWs screen does not render. Net: a running
  portable ADW appears nowhere on the ADWs screen, so `@workflow_progress == %{}` and the
  empty state at `console_live.ex:3713`–`3723` shows.

**B. `spawn_adw_session/4` drops orchestrator/project attribution (regression).**
- `Session.Server` reads `opts[:orchestrator_id]` and `opts[:project_id]` at init
  (`lib/repo_builder/session/server.ex:182`, `:202`) and persists every event with
  `state.project_id` / the resolved owner.
- `command_agent/3` passes both (`tools.ex:437`–`455`: `orchestrator_id: orchestrator_id`,
  `project_id: worker.project_id`, plus `agent_name`, `provider`, `isolation_mode`).
- `spawn_adw_session/4` passes **neither** (`tools.ex:1497`–`1507`) — only
  `agent_id`/`agent_db_id`/`session_id`/`harness`/`prompt`/`model`/`config`/`cwd`.
- Compounding: `Agents.create_worker/2` sets `orchestrator_id` but **not** `project_id`
  (`lib/repo_builder/agents.ex:125`–`135`), so `worker.project_id` is `nil` for adapter
  ADWs and must be resolved from the orchestrator's bound project (the helper
  `orchestrator_project_id/1` already used by `adw_target_project/2` at `tools.ex:1452`).
- Result: ADW events persist with `orchestrator_id = NULL`, `project_id = NULL` — exactly
  what the DB shows for `log-36411`…`log-36430`. Even once change **A** makes a card
  appear, without **B** the ADW's events fall outside the active project's scoped feed and
  are unowned.

`de59371` ("spec-driven … Workstream orchestration") introduced the divergence: it added
`project_id`/`isolation_mode` to `command_agent/3` but left `spawn_adw_session/4` behind.

## Relevant Files
Use these files to fix the bug:

- `lib/repo_builder/orchestrator/tools.ex` — **primary edit.** `start_adw_via_adapter/4`
  (`:1363`) and `spawn_adw_session/4` (`:1495`): thread `orchestrator_id` + resolved
  `project_id` (+ `agent_name`, `provider`, `isolation_mode`) into the session opts,
  mirroring `command_agent/3` (`:437`–`455`). `orchestrator_project_id/1` (used at `:1454`)
  resolves the bound project.
- `lib/repo_builder/session/server.ex` — **primary edit.** `maybe_broadcast_lane/2`
  (`:1023`) and `lane/3` (`:1041`): for ADW-harness sessions (`state.harness == :adw`),
  additionally broadcast a `kind: :workflow` lane (`id: "workflow:<agent_id>"`) mirroring
  the lifecycle status so the ADWs screen builds/updates a card. Harness-blind for all
  other harnesses (unchanged).
- `lib/repo_builder_web/live/console_live.ex` — **reference, likely no edit.** Confirms the
  ADWs render path: `update_workflow_status/2` (`:758`) keys on `id: "workflow:" <> run_id`
  and creates `default_workflow_view/1` (`:789`) for a live-first run; the ADWs template
  (`:3696`) renders `@workflow_progress`; `workflow_step_squares/3` (`:4096`) fills squares
  by `agent_key == run_id`.
- `lib/repo_builder/agents.ex` — `create_worker/2` (`:125`) sets `orchestrator_id` but not
  `project_id`; informs how `project_id` is resolved for the opts (from the orchestrator's
  bound project, not the worker row).
- `lib/repo_builder/dashboard.ex` — `broadcast_lane/1` (the seam `lane/3` calls); confirm
  the lane map shape a `kind: :workflow` lane must satisfy (`id`, `kind`, `label`,
  `status`, `harness`).
- `config/config.exs` — the `:harnesses` registry; confirms `"adw"` maps to the ADW
  adapter and is the runtime harness key (`@adw_harness = "adw"`, `tools.ex:66`).

Conditional docs (per `.claude/commands/conditional_docs.md`):
- `BUILD_PROMPT.md` §9 (LiveView dashboard: streams, swimlanes, `kind` lanes) — the ADWs
  screen contract.
- `BUILD_PROMPT.md` §6 (session runtime) + `ai_docs/adw-primitives.md` — the generic
  session runtime that drives the adapter ADW.
- `BUILD_PROMPT.md` §7 + `ai_docs/adw-orchestration.md` — the ADW/workflow model
  (engine vs. adapter split).
- `ai_docs/typed-elixir-standard.md` — the enforced typed standard (always-on).

### New Files
- `test/repo_builder_web/live/test_portable_adw_on_adws_screen_test.exs` — a
  `Phoenix.LiveViewTest` integration test that reproduces the bug (no ADW card before the
  fix) and proves the fix (a `kind: :workflow` lane for an ADW session renders an ADW card
  whose squares fill from streamed `harness: "adw"` events).

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Reproduce and confirm the current (broken) behavior
- Start Postgres (`scripts/pg.sh start`) and, for live inspection, `iex -S mix phx.server`.
- Via Tidewave `execute_sql_query`, run the reproduction SQL from **Steps to Reproduce**
  and confirm `has_orch = f`, `has_proj = f` on `harness = 'adw'` rows.
- Via Tidewave `project_eval`, confirm the runtime only emits agent lanes for an ADW
  session today, e.g. subscribe to `RepoBuilder.Dashboard.subscribe/0` and assert no
  `%{kind: :workflow}` lane arrives for the portable ADW. Note this baseline in the PR.

### 2. Restore attribution/scoping in the adapter launch path (`tools.ex`)
- In `start_adw_via_adapter/4`, resolve the bound project id once (reuse
  `orchestrator_project_id/1`) and the worker's provider/isolation the same way
  `command_agent/3` does; pass `orchestrator_id` down to `spawn_adw_session`.
- Change `spawn_adw_session/4`'s signature/opts to include (mirroring `command_agent/3`):
  `orchestrator_id:`, `agent_name: worker.name`, `provider: worker_provider(worker)`,
  `project_id:` (the resolved bound project id — **not** `worker.project_id`, which is nil
  for adapter workers), and `isolation_mode:` where the ADW cwd resolution already yields
  it (default `nil` ⇒ direct, back-compat). Keep every existing opt.
- Preserve all `@spec`s; update `spawn_adw_session/4`'s `@spec` to reflect the new
  `orchestrator_id` parameter. Keep `{:ok, map()} | {:error, reason()}` returns — never
  raise.

### 3. Emit a workflow-kind lane for ADW sessions (`session/server.ex`)
- Add a private predicate for the ADW harness (`adw?(state)` ⇒ `state.harness == :adw`;
  the registry key is `"adw"` → atom `:adw`). Do not hard-code elsewhere.
- In `maybe_broadcast_lane/2`, after the existing `kind: :agent` broadcast, when `adw?`,
  also broadcast a `kind: :workflow` lane via a new `workflow_lane/3` helper mirroring the
  same status mapping (`:running` on `SessionStarted`; `:succeeded`/`:failed`/`:holding`
  on the terminal clauses). Shape:
  `%{id: "workflow:#{state.agent_id}", kind: :workflow, label: <current step or session id>, status: status, harness: "adw"}`.
  Keep the function harness-blind for all non-ADW harnesses (no behavior change).
- Add/adjust `@spec`s for the new helpers; keep them total and non-raising.
- Rationale check: `ConsoleLive.update_workflow_status/2` will build a
  `default_workflow_view("<agent_id>")` card (`title: "ADW <short>"`, `status: :running`)
  and later flip it to the terminal status; `workflow_step_squares/3` already fills squares
  by `agent_key == run_id == agent_id`.

### 4. Write the LiveView integration test (fails before, passes after)
- Create `test/repo_builder_web/live/test_portable_adw_on_adws_screen_test.exs`.
- Mount `ConsoleLive` at `/` with a connected socket. Assert the empty state
  `#no-adws` is present initially (no ADW cards).
- Simulate the runtime: broadcast (via `RepoBuilder.Dashboard.broadcast_lane/1`) a
  `%{id: "workflow:<uuid>", kind: :workflow, status: :running, label: "plan", harness: "adw"}`
  lane, then push a `harness: "adw"` worker event for the same id through the same feed the
  session server uses (`Dashboard.broadcast_event/3` on `"console:events"`), carrying an
  `adw_step`.
- Assert an ADW card `#workflow-<uuid>` now renders (`has_element?/2`) and that
  `#no-adws` is gone. Prefer element/id assertions over raw-HTML/text per the LiveView test
  guidelines in `AGENTS.md`.
- Keep the test minimal and `async: true` if it shares no global state; use
  `Phoenix.LiveViewTest` `element/2`/`has_element?/2` against the ids added in the template
  (`#workflow-<id>`, `#no-adws`).
- (Optional) A focused `test/repo_builder/session/` assertion that an ADW-harness session
  broadcasts a `kind: :workflow` lane (subscribe to `Dashboard`, drive a `SessionStarted`
  through the Fake/registry seam registered under `"adw"`, assert the lane). Include only
  if it stays small; the LiveView test is the required one.

### 5. Guard against regression in the sibling path
- Add/extend a `tools`-level test (or reuse an existing `command_agent` test harness)
  asserting the ADW adapter session is started with `orchestrator_id` and a non-nil
  `project_id` in opts when the launching orchestrator is project-bound — proving parity
  with `command_agent/3`. Assert via the session receiving the opts (or a Mox expectation
  on `Session.Supervisor.start_session/1`), not by reaching into the private function.

### 6. Run the full validation suite
- Execute every command in **Validation Commands** and ensure all are green with zero
  regressions.

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- `scripts/pg.sh start` — ensure the local Postgres cluster is up (once per session).
- `mix test test/repo_builder_web/live/test_portable_adw_on_adws_screen_test.exs` — the
  new LiveView integration test: **fails before** the `session/server.ex` change (no ADW
  card renders / `#no-adws` persists) and **passes after** (an `#workflow-<id>` ADW card
  renders).
- `mix compile --warnings-as-errors` — clean compile; gradual set-theoretic checker +
  `warnings_as_errors` pass.
- `mix format --check-formatted` — formatting is canonical.
- `mix credo --strict` — lint incl. `@spec` on every public function (and the new helpers).
- `mix test --warnings-as-errors` — full ExUnit suite green (Postgres-backed cases).
- `mix dialyzer` — `@spec`/contract checking with no new warnings and no stale ignore
  filters (`list_unused_filters: true`).
- Manual/live re-check (optional, Tidewave): after the fix, launch a portable ADW and
  confirm the ADWs screen shows a running ADW card; re-run the reproduction SQL and confirm
  new `harness = 'adw'` rows now have `has_orch = t` and `has_proj = t`. Optionally capture
  a Playwright screenshot of `http://localhost:4000` (ADWs screen) as visual proof.

## Notes
- **No new dependencies, migrations, or schema changes.** Both edits are additive and
  behind existing seams; the change is harness-agnostic except for the single, contained
  `state.harness == :adw` predicate (the ADW registry key), consistent with the existing
  `@adw_harness "adw"` usage in `tools.ex`.
- **Why broadcast a workflow lane rather than create a `WorkflowRun` row.** The portable
  ADW is deliberately modeled as a worker Agent (so `check_adw` reads its canonical events
  and it streams like any worker, per the `issue-the-adw-gap` design). Minting a full
  `WorkflowRun` for it would duplicate the engine path and add persistence the adapter
  design intentionally avoids. Emitting a `kind: :workflow` lane reuses the console's
  existing "live-first run" card path (`default_workflow_view/1`) — the smallest change
  that makes the run visible on the ADWs screen. `run_id == agent_id` guarantees the
  already-streaming ADW events populate the card's step squares.
- **The two fixes are complementary, not redundant.** Change **A** (`session/server.ex`)
  makes the card *appear*; change **B** (`tools.ex`) makes its events *owned and
  project-scoped* so they show in the correct project's feed and cost/attribution rolls up
  to the launching orchestrator. Ship both.
- **Regression origin:** `de59371` updated `command_agent/3` but not `spawn_adw_session/4`;
  this plan realigns them.
- **Tidewave was used during root-causing:** `execute_sql_query` confirmed the
  NULL `orchestrator_id`/`project_id` on `harness = 'adw'` rows (`log-36411`…`log-36430`),
  and source inspection confirmed the lane-kind mismatch between the runtime
  (`kind: :agent`) and the ADWs screen (`kind: :workflow`).
