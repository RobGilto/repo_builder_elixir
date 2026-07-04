# Architecture map — the subsystems README doesn't cover in depth

Audit F7 (docs/audit-2026-07.md): the README documents the core platform (harness
contract, session runtime, zero-orphan ledger, workflow engine, plugins, agentic-layer
adaptor) but five sizeable subsystems grew past their one-line mentions. This map is the
orientation document for those five. Line references intentionally omitted — navigate by
module name.

## 1. Orchestrator (`lib/repo_builder/orchestrator*`)

The delegation-only meta-agent that drives the whole console. One durable
`Orchestrator` row per console (harness/provider/model selection, system prompt,
reasoning effort, working dir, timezone), one live server per active console.

- `Orchestrator.Server` — the GenServer running orchestrator turns against its
  configured harness; holding-pattern aware (re-engaged by terminal workflow runs).
- `Orchestrator.Tools` — the façade dispatching every LLM-callable tool; the
  implementations live in `orchestrator/tools/<domain>.ex` (agent_ops, adw,
  workstream_ops, ledger, focus, quality_gate, self_config, cost, agent_templates,
  log_lookup, shared). The LLM-facing manifest is rendered by `ToolCatalog` and is
  byte-pinned by `test/repo_builder/orchestrator/tool_manifest_snapshot_test.exs`.
- `Orchestrator.Queue` — per-orchestrator command queue with cancel; snapshot feeds the
  console's queue strip.
- `Orchestrator.Driver` — the autonomous drive-loop (self-healing orchestration):
  stall detection → replan → escalate, with a `Breaker` stopping runaway loops.
- `Ledgers` / `Progress` — the Task/Progress ledger giving the operator (and the
  orchestrator itself) a durable view of delegated work.
- `ContextWindow` — model-window catalog + estimation for the header context meter.
- `SystemPrompt` / `Templates` / `Expertise` — prompt assembly, saved agent templates,
  and the reflections/expertise store orchestrators write themselves.

## 2. Workstreams (`orchestrator/workstreams.ex` + `workstreams/*`)

The orchestrator's top-level unit of work AND its external memory
(spec-driven phased orchestration). A workstream decomposes into right-sized phases;
each phase runs a `spec → implement → test → review` machine with a
`review → fix → review` branch. `record_stage/3` drives promotion; stalls count toward
`:blocked`. `list_workstreams/1` is the compact rehydration index the orchestrator
reads after `compact_self` — the durable rows, not the chat transcript, are the memory.
Return routing is workstream-tagged so a worker's report lands on the right phase.
Console: the Workstreams panel + ADWS swimlane render these rows live.

## 3. Cost Center (`cost_center.ex` + `cost_center/*`)

The operator's window onto AI spend by `(harness, provider, model)`, split into:

- **Actuals** — rolled up from `agent_logs`' embedded `Usage` value objects (provider/
  model snapshotted at write time). Period spend is timezone-relative.
- **Rates** — the seeded, editable `model_prices` catalog (console Cost Center tab),
  feeding cache-aware cost estimates.
- **Attribution** — `agent_logs.project_id` scopes spend per target repo;
  `project_spend/1` + period strips back the per-project report. Clear/restore is
  soft (history kept).

Cost rolls emit `[:repo_builder, :cost, :recorded]` telemetry — the hot input to the
Budget Guard below.

## 4. Budget Guard (`budget.ex`, `budget/guard.ex`, `budget/scope.ex`, `budget/cap.ex`)

Live budget circuit breaker modeled on `Session.Admission`. Durable `Cap` rows
(scope: global / orchestrator / workflow / project / session-day) are reconciled from
`CostCenter.scope_spend/3` at init and periodically (slow path); each cost-telemetry
event accumulates per cap in-process (hot path — no DB round-trip). `Guard.check/1`
is the single authoritative "is spend allowed in scope X right now?" — consulted by
the workflow Runner before every harness step and by session admission. A tripped cap
fails the step down its `on_failure` edge; the kill switch stops everything. Console:
Settings → Budget tab (caps CRUD, live state, kill switch).

## 5. Forge (`forge.ex` + `forge/*`)

Meta-artifact generation: *generating a plugin is itself a deterministic ADW*. An
operator requests a `kind` (command / agent / skill / workflow) with a
natural-language spec; `Forge.Workflow` renders the matching generator prompt, drives
a real harness session in an isolated scratch workspace, validates + packages the
artifact, and hands the package to the existing `Plugins` install → activate
lifecycle. `Forge` owns the durable `forge_artifacts` request/lifecycle record. The
Forge has its own driver seam (`generate_runner`) — it does not go through
`WorkflowEngine.Catalog`.

## Quality gates (cross-cutting)

The `:quality_gate` plugin contribution kind (see `ai_docs/quality-gate-plugins.md`)
defines a per-stack five-stage gate (format · lint · type · test · mutation) run at a
workstream phase's `:test` stage via the orchestrator's `run_quality_gate` tool.
Stack definitions ship in `plugin_library/quality-gates-<stack>/`
(elixir/python/typescript/go/rust/ruby). This platform's own gate is the five-command
sequence in the README.

## Test-suite conventions (audit F8, resolved as intentional)

Two naming styles coexist by design:

- `test/**/<name>_test.exs` — hand-written core suites (contexts, runtime, engine).
- `test/repo_builder_web/live/test_<feature>_test.exs` — ADW-generated feature
  integration tests; the `test_` prefix is mandated by the planning template
  (`.claude/commands/plan.md`) so generated work is distinguishable at a glance.

The opt-in `:live_acceptance` tag (excluded by default in `test_helper.exs`) drives
the REAL agent CLIs: `mix test --only live_acceptance`.
