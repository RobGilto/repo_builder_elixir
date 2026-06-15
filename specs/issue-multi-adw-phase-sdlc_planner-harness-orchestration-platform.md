# Feature: Harness-Agnostic AI Agent Orchestration Platform (multi-phase M0→M7)

## Metadata
issue_number: `multi`
adw_id: `phase`
issue_json: `{}`

## Feature Description
Build a **harness-agnostic AI agent orchestration platform** in Elixir/Phoenix/OTP that generalizes the "deterministic orchestration of non-deterministic AI agents" (TAC/ADW) pattern. Humans, cron, and webhooks compose **deterministic** workflows ("ADWs" — e.g. `plan → build → review → fix`) whose **step order and branching are fixed**, but whose **intelligent work inside each step is delegated to an external AI agent harness** driven as a supervised OS-process child.

The platform delivers three things:
- **CRUD of agents and workflows** (durable definitions: name, harness, provider, model, config) behind `@spec`'d Ecto contexts.
- **Composable chained ADWs**: deterministic state machines whose steps delegate execution to a swappable harness adapter and persist their position so a run survives a node restart.
- **Real-time observability**: a Phoenix LiveView dashboard streaming live logs, tool calls, cost/usage, and status for every live agent and workflow, swimlane-style, with flat server memory (LiveView streams).

The defining constraint: the platform is **NOT locked to Claude Code**. It drives multiple harnesses/providers (initially the **Claude Code CLI** and the **pi CLI**) through a **swappable service layer**, and **adding a third harness is one adapter module + one config entry** — no edits to core types, schema, or runtime. This is delivered as a phased build (`BUILD_PROMPT.md` §12, milestones **M0–M7**); each milestone has concrete acceptance criteria and must pass the typed gate before the next begins.

## User Story
As a **developer/operator orchestrating AI coding agents**
I want to **define deterministic, durable workflows whose steps are executed by any pluggable AI harness, and watch every agent and workflow run live**
So that **I get reproducible, observable, crash-isolated automation that is not locked to a single vendor CLI, with full cost/usage accounting and zero orphaned OS processes.**

## Problem Statement
Orchestrating AI agents reliably is hard for reasons that are orthogonal to "calling an LLM":
- **Process supervision**: each harness is an external streaming-NDJSON CLI child that must be spawned, fed stdin, interrupted (SIGTERM→SIGKILL), monitored, and — critically — **never leaked as an orphan**, even across a hard BEAM crash.
- **Protocol heterogeneity**: Claude's `stream-json` and pi's `--mode json` emit completely different wire frames (snake_case vs camelCase, different lifecycle, provider-polymorphic usage, no uniform terminal/cost line for pi). Downstream code must not care which harness produced an event.
- **Determinism over non-determinism**: workflow step order/branching must be fixed and durable (survive restarts) while the intelligent work inside a step is non-deterministic and delegated.
- **Vendor lock-in**: hard-coding Claude Code makes a second harness a rewrite.
- **Observability at scale**: live logs/cost/status for many concurrent agents without unbounded server memory.
- **Type safety**: Elixir is only *gradually* typed; untrusted harness JSON must be validated at the boundary and the whole system kept correct under `--warnings-as-errors` + Dialyzer.

## Solution Statement
Implement the architecture in `BUILD_PROMPT.md` as plain **Phoenix + OTP + Ecto** (no Ash), built in eight milestones:
- A **canonical, closed, typed Event sum type** (`BUILD_PROMPT.md` §4.1) that every adapter normalizes into; the orchestrator, persistence, and UI speak only these harness-blind events. Harness identity is an **open `atom()`/`String.t()`** (the one deliberate looseness) so a new harness needs no core type edit.
- A **two-behaviour harness contract** (mandatory `command/1` + `normalize/2`; optional `CustomSpawn`) resolved through a **registry** that is the single source of truth and the single test seam (§4.2, §10).
- A **GenServer-per-session runtime** over **erlexec** with partial-line/multibyte buffering, idle-timeout, backpressure, and a **durable os_pid ledger + marker-verified OrphanReaper** for zero-orphan guarantees (§5, §6).
- **Ecto persistence** (binary_id PKs, JSONB, `Ecto.Enum`, embedded `Usage`, float→Decimal cost boundary) behind `@spec`'d contexts that are the only `Repo` callers (§8).
- A **deterministic workflow engine** (`WorkflowEngine.Runner` state machine) with `workflow_runs` as the source of truth, plus **Oban** for durable cron/webhook triggers and crash-resume (§7).
- A **LiveView swimlane dashboard** using streams (flat memory), `assign_async` cost/status, and reconnect backfill (§9).

Everything is built to the **typed coding standard** (`ai_docs/typed-elixir-standard.md`) and verified by the green gate (`mix compile --warnings-as-errors`, `mix test --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`). Runtime behavior is verified with **Tidewave** (`project_eval` / `execute_sql_query` / `get_logs`) and **Phoenix.LiveViewTest** for UI.

## Relevant Files
Use these files to implement the feature:

- `BUILD_PROMPT.md` — **the authoritative spec.** Read the section that matches the milestone you're implementing: §2 (stack), §3 (typed style guide), §4 (event contract + adapter behaviours + mapping tables), §5 (supervision tree), §6 (session runtime), §7 (workflow engine + durable split), §8 (persistence), §9 (LiveView dashboard), §10 (extensibility), §11 (directory layout), §12 (milestones + acceptance), §13 (testing), §15 (Done criteria).
- `ai_docs/typed-elixir-standard.md` — **the enforced coding standard** (`@spec` on every public fn; `typedstruct`/`@enforce_keys`; precise types; tagged-tuple returns; wire-type ≠ domain-type; contexts are the only `Repo` callers). Read before writing any module.
- `.claude/commands/conditional_docs.md` — documentation router; for each milestone it points at the right `BUILD_PROMPT.md` sections + `ai_docs/adw-*.md`.
- `AGENTS.md` — repo conventions (Phoenix v1.8 + LiveView guidelines, `:req` for HTTP, `mix precommit`).
- `mix.exs` — all §2 deps already pinned; `elixirc_options: [warnings_as_errors: true]`; the §3 `:dialyzer` block; `mix` aliases.
- `.credo.exs` — enables `Credo.Check.Readability.Specs` (the `@spec` gate; `@impl` exempt).
- `lib/repo_builder/application.ex` — current supervision tree (default scaffold); each runtime milestone adds children here in the §5 order.
- `config/config.exs`, `config/runtime.exs`, `config/test.exs` — harness registry (`:harnesses`), Oban config, `:session` config, `:harness_secrets`, alerting config land here.
- `lib/repo_builder/repo.ex`, `lib/repo_builder_web/{endpoint,router,telemetry}.ex`, `lib/repo_builder_web/components/core_components.ex` — existing scaffold the runtime/dashboard extend.
- `scripts/patch_deps.sh` — the load-bearing `type_check`/Elixir-1.20 patch; must run after `mix deps.clean`/in CI before compile.
- `ai_docs/adw-orchestration.md`, `ai_docs/adw-primitives.md` — background reference for the workflow/session patterns (load via `conditional_docs.md` when relevant).

### New Files
Grouped by milestone (paths from `BUILD_PROMPT.md` §11). Test files mirror each module under `test/`.

**M0 (finish CI):**
- `.github/workflows/ci.yml` — GitHub Actions: OTP 28.4 / Elixir 1.20.1, Postgres service container, cached deps/_build + **separate PLT cache keyed on OTP+Elixir+hash(mix.lock)**, runs `scripts/patch_deps.sh`, then the full green gate.

**M1 (harness contract — pure, DB-free):**
- `lib/repo_builder/harness.ex` — mandatory `@behaviour` (`command/1` + `normalize/2`, `start_opts()`/`session_ctx()` types).
- `lib/repo_builder/harness/custom_spawn.ex` — optional `@behaviour` (`start_session/1`, `send_input/2`, `interrupt/1`, `terminate/1`, all `@optional_callbacks`).
- `lib/repo_builder/harness/event.ex` — canonical closed sum type `Event.t()` (8 `typedstruct` variants, open `harness :: atom()`, `raw` escape hatch).
- `lib/repo_builder/harness/wire.ex` — TypeCheck (`@type!`) permissive **wire types** for Claude/pi frames + `conforms?/2` boundary helper (closes the §3 rule 6 / §6 step 3 gap so the pinned `type_check` dep is used).
- `lib/repo_builder/harness/redact.ex` — `scrub/1` secret masking (any nesting, string keys) + blob truncation; never raises.
- `lib/repo_builder/harness/registry.ex` — `all/0`, `known/0`, `fetch/1` reading the `:harnesses` config map (the single seam).
- `lib/repo_builder/harness/fake.ex` — FakeHarness emitting the canned canonical sequence.
- `lib/repo_builder/harness/claude.ex`, `lib/repo_builder/harness/pi.ex` — adapter `command/1` + `normalize/2` (stubbed mapping in M1, completed in M6).
- `test/support/mocks.ex` — `Mox.defmock(RepoBuilder.Harness.Mock, for: RepoBuilder.Harness)`.
- `test/support/harness_fixtures.ex`, `test/support/fixtures/claude_stream.jsonl`, `test/support/fixtures/pi_stream.jsonl` — captured frames + chunk-splitter helpers.

**M2 (session runtime + minimal LiveView):**
- `lib/repo_builder/schema.ex` — the §8 `use RepoBuilder.Schema` base macro (**pulled forward** so the os_pid_ledger schema compiles).
- `lib/repo_builder/session/server.ex` — erlexec-wrapped GenServer-per-agent (typed `%State{}`, buffer/idle/backpressure/clean-exit/idempotent terminate).
- `lib/repo_builder/session/supervisor.ex` — typed API over `SessionSupervisor` + Admission + Registry.
- `lib/repo_builder/session/admission.ex` — live-session concurrency gate (`acquire/0` → `:ok | {:error, :at_capacity}`).
- `lib/repo_builder/os_pid_ledger/os_pid.ex`, `lib/repo_builder/os_pid_ledger.ex` — minimal ledger schema + context (writes only in M2).
- `priv/repo/migrations/*_create_os_pid_ledger.exs`.
- `lib/repo_builder_web/live/agent_live.ex` — **`RepoBuilderWeb.AgentLive`** (named per §11 from the start; minimal observability LiveView, extended in M3/M7).
- `test/support/session_case.ex`.

**M3 (persistence + reaping):** `lib/repo_builder/agents/agent.ex`, `agents.ex`, `logs/usage.ex`, `logs/agent_log.ex`, `logs/system_log.ex`, `logs.ex`, `prompts/prompt.ex`, `prompts.ex`, `chats/chat.ex`, `chats.ex`, `workflows/workflow.ex`, `workflows/workflow_run.ex`, `workflows.ex`, `orphan_reaper.ex`, and migrations `*_create_{agents,agent_logs,system_logs,prompts,chat,workflows,workflow_runs}.exs`.

**M4 (workflow engine):** `lib/repo_builder/workflow_engine/runner.ex`, `lib/repo_builder/workflow_engine/step.ex`, plus the seeded `plan→build→review→fix` example ADW.

**M5 (Oban triggers/durable/resume):** `priv/repo/migrations/*_add_oban_jobs.exs`, `lib/repo_builder/workers/step_worker.ex`, `lib/repo_builder/workers/cron_trigger.ex`, `lib/repo_builder/workers/workflow_resume.ex`, `lib/repo_builder/webhooks.ex` (HMAC + timestamp), `lib/repo_builder_web/controllers/webhook_controller.ex`, raw-body plug.

**M6 (multi-harness):** `lib/repo_builder/harness/pricing.ex`, `lib/repo_builder/harness/cursor.ex` (no-op extensibility proof).

**M7 (observability):** `lib/repo_builder_web/components/dashboard_components.ex`, `lib/repo_builder_web/live/dashboard_live.ex`, `lib/repo_builder_web/live/workflow_live.ex`, `lib/repo_builder_web/live/system_logs_live.ex`, `lib/repo_builder/telemetry/alerting.ex`. (`agent_live.ex` is **modified**, not created — see M2.)

## Implementation Plan
### Phase 1: Foundation
Finish **M0** (the only residual is CI: a GitHub Actions pipeline with a PLT cache keyed on OTP+Elixir+`mix.lock`, plus the `.gitignore` PLT exclusion). Then build **M1** — the keystone harness contract — which is pure-functional and **DB-free**, so it is fully buildable and testable today with no Postgres: the canonical `Event` sum type, the two behaviours, `Registry`, `Redact`, the TypeCheck `Wire` boundary, the `Fake` adapter, and the Mox mock, all proven by property/boundary tests and Dialyzer. **Provision Postgres** before starting M3.

### Phase 2: Core Implementation
**M2** — one erlexec-wrapped `Session.Server` per live child (buffering, idle timer, backpressure, clean-exit synthesis, idempotent terminate), supervised by `SessionSupervisor` (`:temporary`, `max_children`) + `SessionRegistry` behind the `Admission` gate, in a per-session cwd workspace, writing os_pid ledger rows, streaming canonical events into the minimal `AgentLive`. **M3** — all §8 schemas/migrations/contexts (binary_id/JSONB/Enum/embedded `Usage`, float→Decimal nil-vs-0 boundary); redact-then-persist every event; marker-verified boot-time `OrphanReaper`; LiveView reconnect seeding from last-N rows. **M4** — the deterministic `WorkflowEngine.Runner` state machine under `WorkflowSupervisor`, `workflow_runs` as source of truth at every transition, the `plan→build→review→fix` example ADW with `on_success`/`on_failure` edges and per-workflow crash isolation.

### Phase 3: Integration
**M5** — Oban (queues + Cron plugin, bigint job ids); `StepWorker` (typed args, `{:cancel, _}` for never-valid, unique on `{workflow_run_id, step_name}`); a signature+timestamp-verified webhook controller → `Oban.insert`; `CronTrigger`; the `WorkflowResume` reconciler that re-enqueues queued/running runs from `current_step` on boot (survives node restart). **M6** — production-complete Claude and pi adapters; the `:harnesses` registry as single source of truth; runtime string-selection of the harness; pi cost derivation from a price table (nil when unpriced); the no-op `Cursor` adapter proving "add a harness = one module + one config entry." **M7** — the full swimlane dashboard (per-agent + per-workflow streams, flat memory, `assign_async` cost/status, thinking-pane routing, `system_logs` view, reconnect hardening), LiveDashboard metrics + cost/error alerting, and end-to-end verification of `OrphanReaper` across crash scenarios and secret redaction.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom. Each milestone ends by running the **Validation Commands**; do not advance until that milestone's acceptance criteria pass. Honor `ai_docs/typed-elixir-standard.md` throughout.

### M0 — Finish CI + Dialyzer gate
- Append the §3-mandated PLT ignores to `.gitignore` (`/priv/plts/*.plt`, `/priv/plts/*.plt.hash`); confirm with `git check-ignore`.
- Create `.github/workflows/ci.yml`: trigger on push to `main` + PR; `erlef/setup-beam@v1` pinned to OTP `28.4` / Elixir `1.20.1` (exact `mise.toml` pins — never substitute); Postgres 16 service container with `pg_isready` health gating and `postgres/postgres/repo_builder_test` matching `config/test.exs`.
- Cache `deps` + `_build` and, **separately**, `priv/plts`, both keyed on `${otp}-${elixir}-${hashFiles('**/mix.lock')}`; `mkdir -p priv/plts` before dialyzer.
- CI step order is load-bearing: `mix deps.get` → `bash scripts/patch_deps.sh` → `mix compile --warnings-as-errors` → `mix format --check-formatted` → `mix credo --strict` → `mix test --warnings-as-errors` → `mix dialyzer --format github --list-unused-filters`.
- Acceptance: the workflow is green end-to-end and the PLT cache key resolves to OTP+Elixir+`mix.lock`.

### M1 — Harness behaviours + canonical events + FakeHarness + normalizers
- **Event sum type** (`harness/event.ex`): define open `@type harness :: atom()` and the closed `@type t :: SessionStarted.t() | … | Error.t()`; for each of the 8 variants a nested `defmodule` with `use TypedStruct` / `typedstruct enforce: true`, copying field shapes **exactly** from §4.1 (defaults, `enforce: false` for optionals, `raw: map(), default: %{}`). Honor §3 rule 9 (single `| nil` convention). Document the in-flight-full-raw vs persisted-scrubbed contract.
- **Mandatory behaviour** (`harness.ex`): `start_opts()`/`session_ctx()` types; `@callback command(start_opts()) :: {exe, args, env, session_ctx()}` (**`command/1`**, per §4.2 — note the spec's `command/2` prose is a known inconsistency); `@callback normalize(raw, session_ctx()) :: {:ok, [Event.t()]} | :skip | {:error, term()}` (must never raise).
- **Optional behaviour** (`harness/custom_spawn.ex`): `start_session/1`, `send_input/2` (not `send/2`), `interrupt/1`, `terminate/1`, all declared in `@optional_callbacks` so a minimal adapter compiles under `--warnings-as-errors`.
- **Wire boundary** (`harness/wire.ex`): define permissive TypeCheck `@type!` wire types for the Claude and pi frame envelopes and a `conforms?/2` helper used optionally in `normalize/2`/runtime `handle_line` (closes the §3 rule 6 / §6 step 3 gap and exercises the pinned `type_check` dep; if you deliberately skip runtime `conforms?/2`, still provide TypeCheck-derived generators for the boundary tests).
- **Redact** (`harness/redact.ex`): `@spec scrub(Event.t()) :: Event.t()`; recursively mask credential keys (`api_key`, `authorization`, `token`, `ANTHROPIC_API_KEY`, provider keys) in maps **and** lists, string-keyed, truncate oversized blobs; total over arbitrary `term()`, never raises.
- **Registry** (`harness/registry.ex`): `all/0`, `known/0`, `fetch/1` (`to_string` coercion, `{:error, :unknown_harness}`); the only reader of `:harnesses`; document it as the single test-injection seam (override the map entry, never a `:harness_adapter` key).
- **Config**: add `config :repo_builder, :harnesses, %{"claude" => …, "pi" => …}` to `config/config.exs`; mirror a baseline in `config/test.exs`.
- **FakeHarness** (`harness/fake.ex`): `@behaviour RepoBuilder.Harness`, `@impl true` on `command/1`/`normalize/2`; expose `@spec`'d `canned_events/0 :: [Event.t()]` emitting `session_started → text_delta* → tool_call → tool_result → usage → done` (`harness: :fake`); must compile implementing only the mandatory behaviour.
- **Claude/pi adapters** (`harness/claude.ex`, `harness/pi.ex`): `command/1` argv (Claude: `-p --output-format stream-json --verbose --include-partial-messages`; pi: `--mode json`; secrets in env, never argv) and `normalize/2` per the §4.3 mapping tables (snake_case vs camelCase; nested `event.delta.text`; provider-polymorphic usage; `is_error` overrides success subtype; `String.to_existing_atom` only). Document that pi clean-exit/idle-timeout `Done`/`Error` are **synthesized by the §6 runtime**, not `normalize/2`.
- **Mox + fixtures**: `test/support/mocks.ex`; fixtures with init/text/thinking/tool/usage/result frames, a multibyte-in-payload line, a malformed line, and a zai/GLM no-`agent_end` stream; `harness_fixtures.ex` with `chunk_at/2` to split at arbitrary byte offsets.
- **Tests** (`async: true` where pure): `event_test` (all variants, `@enforce_keys` raises, open-atom proof), `registry_test`, `redact_test`, `fake_test`, `claude_normalize_test`, `pi_normalize_test` (three usage shapes), `normalizer_boundary_test` (malformed/partial/multibyte/unknown → never raises, correct `:skip`; U+2028/U+2029 not a break), `optional_callbacks_test` (minimal adapter compiles; `function_exported?/3` discriminates `CustomSpawn`).
- Run the Validation Commands (no Postgres needed for M1).

### M2 — Single live session GenServer streaming to LiveView
- **Gate on M1**: verify `Harness`, `Event`, `Registry.fetch/1`, `Redact.scrub/1`, `Fake` exist; M2 hard-depends on them.
- **Pull forward `lib/repo_builder/schema.ex`** (the §8 base macro) so the os_pid_ledger schema compiles (critic fix — do not reference an uncreated macro). Create minimal `os_pid_ledger/os_pid.ex` + `os_pid_ledger.ex` context (`insert/1`, idempotent `delete_by_marker/1`) + migration (binary_id PK, `unique_index(:marker)`, `index(:node)`).
- **Admission** (`session/admission.ex`): GenServer holding `{used, max}` from `:max_live_sessions` (default 100); `acquire/0` → `:ok | {:error, :at_capacity}`, `release/0` idempotent.
- **Supervisor API** (`session/supervisor.ex`): typed wrapper over the application-started `SessionSupervisor`; `start_session/1` acquires admission then `DynamicSupervisor.start_child` with `restart: :temporary` (release on failure); `stop_session/1` via Registry `via/1`; `whereis/1`.
- **Session.Server** (`session/server.ex`): typed `%State{}` (byte `buf`, `idle_ref`, `marker`, `saw_output?`, `saw_agent_end`, …); `init/1` traps exit, resolves adapter via `Registry.fetch/1`, resolves secrets (never logged), generates marker, provisions `priv/workspaces/<session_id>/`, calls `adapter.command/1`, `:exec.run` with `:monitor, {:group, 0}, :kill_group, {:kill_timeout, 5}, {:env, env_with_marker}, {:cd, cwd}`, inserts the ledger row **before** consuming output, arms the idle timer.
- **stdout pipeline**: `handle_info({:stdout, …})` resets idle, appends to `buf`, enforces `max_line_bytes` overflow (→ `%Error{message: "stdout overflow"}` + stop), splits on `"\n"` only (carry partial), `handle_line` does `Jason.decode/1` → `adapter.normalize/2`, `:skip`/`{:error,_}` never crash; `dispatch/2` broadcasts the **full** event on `"agent:#{id}:events"` (M2 does not persist yet).
- **Terminal handling**: `:idle_timeout` → `:exec.stop` + `%Error{reason: :idle_timeout, retryable: true}`; `{:DOWN,…}` flushes trailing `buf`, synthesizes `%Done{reason: :clean_exit}` on clean exit + prior output + no `agent_end`, else `%Error{reason: :provider_error}`; idempotent `terminate/2` (stop child, `delete_by_marker`, workspace cleanup, `Admission.release` once).
- **stdin/interrupt**: `send_stdin/2` (not `send/2`) and `interrupt/1` via casts to `:exec.send`/`:exec.stop`.
- **Wire the tree** (`application.ex`): add `{Registry, keys: :unique, name: SessionRegistry}`, `Session.Admission`, `{DynamicSupervisor, name: SessionSupervisor, max_children: N}` in §5 order (after PubSub, before Endpoint); add `:session` config; `.gitignore` `priv/workspaces/`.
- **Minimal `AgentLive`** (`live/agent_live.ex`, named `RepoBuilderWeb.AgentLive` per §11): `connected?`-guarded subscribe, `stream(:events)` with `stream_insert(at: -1, limit: -500)`, one `handle_info` clause per Event variant (exhaustive), Start/Interrupt controls; route `live "/agents/:id", AgentLive`. (No persisted backfill yet — that's M3.)
- **E2E test task (UI)**: write `test/repo_builder_web/live/agent_live_test.exs` (`Phoenix.LiveViewTest`) — mount subscribes only when connected; broadcasting each canonical variant renders a stream entry; Start/Interrupt invoke the supervisor.
- **Other tests**: `server_test` (multibyte split, partial line, idle, overflow, clean-exit synth, terminate cleanup — drive via `Fake`/Mox + `Mox.allow/3`), `admission_test`, `supervisor_test` (crash isolation: kill one of two sessions, other keeps streaming, killed one not restarted; past-cap → `{:error, :at_capacity}`).
- Run the Validation Commands. Then the **live acceptance** (real CLIs + Postgres up): stream a real `claude` and `pi` session into `AgentLive`; interrupt → `ps` shows no orphan; kill the GenServer → child reaped; hung pi → idle-timeout `%Error`. Verify with Tidewave `project_eval`/`get_logs`.

### M3 — Persistence + orphan ledger reaping
- **Provision Postgres** (prerequisite) and confirm `mix ecto.create`.
- **Schemas** (all `use RepoBuilder.Schema`, hand-written precise `@type t`, `Ecto.Enum` literal unions): `agents` (`harness :string` validated via `validate_inclusion(:harness, Registry.known())`), `agent_logs` (`event_type` enum, `payload :map` redacted raw, `embeds_one :usage`), `system_logs`, `prompts`, `chat` (note: **CRUD-only — not populated by the runtime per spec**), `workflows`, `workflow_runs` (`total_cost_usd :decimal` nullable = unpriced), promote `os_pid_ledger` to full FK shape. `logs/usage.ex` embedded value object applies the **float→Decimal** nil-vs-0.0 boundary (`Decimal.from_float/1`; `nil`→SQL NULL, `0.0`→`Decimal.new(0)`).
- **Migrations**: one per table (binary_id PKs, JSONB, enum-as-string, FKs with `on_delete`, the unique/index set from §8).
- **Contexts** (the only `Repo` callers, all `@spec`'d, tagged tuples): `Agents`, `Logs` (incl. `persist_event/2` = redact→map variant→insert→roll usage/cost; `list_recent/2`; `cost_rollup!/1`), `Prompts`, `Chats`, `Workflows` (incl. `create_run/2`, `update_run/2`, `add_run_cost/2` preserving NULL), `OsPidLedger`.
- **Wire Session.Server**: `dispatch/2` now persists the **redacted** event while broadcasting the **full** event; updates agent status/usage; ledger row written in `init`, deleted in `terminate`.
- **OrphanReaper** (`orphan_reaper.ex`, added after Repo in the tree): on boot reads `OsPidLedger.list_for_node(node())`, verifies each pid is ours via `/proc/<os_pid>/environ` containing `REPO_BUILDER_SESSION_MARKER=<marker>` (or pidfile), SIGTERM→SIGKILL **only on positive marker match**, deletes the row; deletes stale rows for dead/recycled pids without signalling. Factor marker verification into a testable helper.
- **Reconnect seeding** (`AgentLive`, **modified**): on connected mount, `Logs.list_recent/2` seeds the stream and a last-seen cursor **before** subscribing.
- **Tests**: Enum/JSONB round-trip; contexts return `{:error, changeset}` (not raw Postgrex) when constraints fire; `cost_usd` nil→NULL and `0.0`→`0`; secret-redaction (raw with an API key scrubbed in `agent_logs.payload` but present in the broadcast event); OrphanReaper kills a deliberately leaked **marked** child on boot and leaves an unmarked/recycled pid untouched (`ps`); reconnect shows persisted history.
- Run the Validation Commands; verify DB state with Tidewave `execute_sql_query`.

### M4 — Workflow / ADW engine
- **Schemas/context**: confirm `workflows`/`workflow_runs` (from M3); add `Workflows` fns for run transitions.
- **Typed Step** (`workflow_engine/step.ex`): `typedstruct` for `{name, harness, provider, model, prompt_template, on_success, on_failure, inputs, outputs}` + lifecycle helpers; states `pending → running → (succeeded | failed | cancelled)` with deterministic edges.
- **Runner** (`workflow_engine/runner.ex`): GenServer state machine under `WorkflowSupervisor` (add `{DynamicSupervisor, name: WorkflowSupervisor}` to the tree); holds typed `%WorkflowState{}`; **persists `workflow_runs` before each transition** (source of truth); each `:running` step renders its prompt from accumulated artifacts (deterministic), starts a live session (M2), subscribes to its events, captures `:done`/`:error` + final text/usage as the step output, then follows the `on_success`/`on_failure` edge.
- **Example ADW**: seed `plan → build → review → fix` with explicit edges; one step delegates to a live session.
- **Tests**: end-to-end run; a deliberately failing step follows `on_failure` and is isolated (does not crash the workflow or a second concurrent workflow); `workflow_runs` rows reflect every transition.
- Run the Validation Commands.

### M5 — Oban triggers (cron + webhook) + durable steps + resume
- **Oban**: `mix ecto.gen.migration add_oban_jobs` (`Oban.Migration.up/down`; bigint job ids — do not force binary_id); `config :repo_builder, Oban, repo: …, queues: [default: 10, sessions: 20, workflows: 10], plugins: [{Oban.Plugins.Cron, crontab: […], timezone: "Etc/UTC"}]`; add `{Oban, …}` to the tree.
- **StepWorker** (`workers/step_worker.ex`): cast typed args at the top of `perform/1`; `{:cancel, reason}` for never-valid args; `unique: [fields: [:worker, :args], keys: [:workflow_run_id, :step_name], period: :infinity, states: [:available, :scheduled, :executing]]`; chain by inserting the next job from `perform/1` (OSS, no Pro DAG).
- **Webhooks** (`webhooks.ex` + raw-body plug + `webhook_controller.ex`): capture the raw body, verify HMAC signature **and** a timestamp window (replay protection), then validate/cast the payload, then `Oban.insert` — an invalid/unsigned payload is rejected and never becomes a poison job.
- **CronTrigger** (`workers/cron_trigger.ex`) + a crontab entry; **WorkflowResume** (`workers/workflow_resume.ex`): on boot/periodically, query `workflow_runs` with `status IN (:queued, :running)` that have no live Runner and re-enqueue the next durable step keyed off `current_step`, idempotently.
- **Telemetry**: attach the Oban telemetry logger; add `[:oban, :job, :stop|:exception]` metrics.
- **Tests** (Oban testing mode): webhook + cron enqueue jobs; never-valid args → `{:cancel, _}` (no retry storm); unique-job dedup (duplicate webhook/cron does not double-enqueue); unsigned/expired webhook rejected; a triggered run **survives a node restart** (resumes from `current_step`).
- Run the Validation Commands.

### M6 — Multi-harness + provider switching
- **Registry config**: populate `:harnesses` as the single source of truth (`module`, `exe`, `default_model`, `price_table`); add `:harness_secrets` to `config/runtime.exs` (values by env-var name, never persisted).
- **Pricing** (`harness/pricing.ex`): derive pi cost `(tokens / 1e6) * price_per_mtok` from the price table; **nil when unpriced** (warn), never default to `0.0`.
- **Complete adapters**: finish Claude `command/1` flags + full §4.3 `normalize/2`; finish pi `command/1` + full §4.3 `normalize/2` + provider-polymorphic usage + cost via `Pricing`.
- **String selection**: agent/workflow step selects the harness by string; runtime + Runner resolve strictly via `Registry.fetch/1` (no hardcoded modules).
- **Extensibility proof**: add `harness/cursor.ex` (no-op `Cursor` adapter) **+ one `:harnesses` entry**, with **zero edits** to `Event`/`Agent`/runtime — a test asserts the same ADW runs under `"claude"`, `"pi"`, and that `"cursor"` resolves.
- **Tests**: the same ADW runs end-to-end under both Claude and pi by changing only the `harness` string; pi cost derived correctly (and `nil` when unpriced); the Cursor adapter compiles and resolves with no core change.
- Run the Validation Commands.

### M7 — Polish / observability
- **Logs read API**: add dashboard query fns to `Logs` (swimlane rows, per-agent/per-workflow recent events, cost rollups).
- **Typed components** (`components/dashboard_components.ex`): `attr/3`+`slot/3`-validated `log_line`, `swimlane_row`, `cost_badge`.
- **LiveViews**: extend `AgentLive`; build `workflow_live.ex`, `system_logs_live.ex`, and the top-level `dashboard_live.ex` (per-agent + per-workflow **swimlanes** via `stream_insert` with stable `dom_id` for in-place `running→done`; flat memory). Live cost/status via `assign_async`/`start_async` + `<.async_result>`; thinking-pane routing (`thinking?: true`); reconnect/backfill hardening. Wire routes.
- **Metrics/alerting**: extend `telemetry.ex` `metrics/0` (live-session count, cost rollups, error rate, Oban, Repo) + periodic measurements; `telemetry/alerting.ex` handler for cost/error thresholds; alerting config.
- **E2E test task (UI)**: `test/repo_builder_web/live/dashboard_live_test.exs` (`Phoenix.LiveViewTest`) — minimal swimlane flow proving multi-agent/multi-workflow rendering with streams; capture a Tidewave/Playwright screenshot of `http://localhost:4000` as visual proof.
- **Verification suites**: `orphan_reaper_crash_test` (kill BEAM with a marked child running → restart reaps exactly that child, never a recycled pid); `secret_redaction_e2e_test` (no secret in `agent_logs`/`system_logs`/logs while the live event keeps detail); `alerting_test`; per-view LiveViewTests.
- Run the Validation Commands and confirm all §15 "Done" criteria (1–11) hold.

## Testing Strategy
### Unit Tests
- **Normalizers (M1)**: per-row `RAW → CANONICAL` mapping for both adapters (§4.3); provider-polymorphic pi usage (Anthropic/OpenAI/pi-native); Claude `is_error` overriding the success subtype; subtype→reason enum mapping; nested `stream_event.event.delta.text`.
- **Boundary/property (M1/M2)**: malformed JSON, partial lines split across chunks, **multibyte chars split across chunks** (via `chunk_at/2`), unknown frame types, both casing styles → never raises, correct `:skip`; U+2028/U+2029 not treated as a line break.
- **Redaction (M1/M3)**: secrets masked at arbitrary nesting in maps + lists (string keys); persisted `agent_logs.payload` scrubbed while the broadcast event keeps full `raw`.
- **Session runtime (M2)**: buffer framing, idle timeout, overflow cap, clean-exit synthesis, idempotent terminate; Admission cap; **crash isolation** (kill one of two sessions; `:temporary` non-restart).
- **Persistence (M3)**: Enum + JSONB round-trip; contexts return `{:error, changeset}` (proving the index/FK exists); `cost_usd` nil→NULL and `0.0`→`0`.
- **Workflow (M4)**: end-to-end ADW; failed step follows `on_failure`, isolated from a second concurrent workflow; `workflow_runs` reflects every transition.
- **Oban/webhook (M5)**: enqueue-from-webhook/cron; `{:cancel, _}` on never-valid args; unique-job dedup; HMAC + timestamp-replay rejection; node-restart resume from `current_step`.
- **Multi-harness (M6)**: same ADW under both harnesses by string; pi cost (nil when unpriced); no-op `Cursor` resolves with zero core edits.
- **LiveView (M2/M7)**: `Phoenix.LiveViewTest` — connected-only subscribe, per-variant stream rendering, swimlane in-place replace, controls invoke the runtime.

### Edge Cases
- Single malformed/non-JSON JSONL line → `:skip`/`{:error,_}`, never crash (`Jason.decode/1`).
- Multibyte UTF-8 / JSON token split across stdout chunks → accumulate bytes, split on `0x0A` only, carry partial; flush trailing `buf` on `{:DOWN,…}`.
- pi zai/GLM stream ending on `message_end` + exit 0 with **no `agent_end`** → synthesize `%Done{reason: :clean_exit}` (else hang).
- Hung child → idle timer fires → `%Error{reason: :idle_timeout, retryable: true}`; non-clean exit (code ≠ 0) → `%Error{reason: :provider_error}`.
- `:exec.run` spawn failure → `%Error{reason: :spawn_failed}` + **release admission** (no slot leak).
- Idempotent `terminate/2` across normal/crash/interrupt; `delete_by_marker` + `Admission.release` each happen at most once.
- Admission full → `{:error, :at_capacity}`; `max_children` is an independent backstop.
- `cost_usd` nil (unpriced) vs `0.0` (priced-zero) preserved as NULL vs `0`; pi cost never defaulted to `0.0`.
- Open harness identity: a `:cursor` event/registry value representable/resolvable with zero core edits.
- Hard BEAM kill leaves a marked child → boot `OrphanReaper` kills exactly that child, never an unrelated/recycled pid (marker-verified).
- Webhook replay (old timestamp) and bad signature rejected before any job is enqueued.
- LiveView reconnect: events broadcast while disconnected are gone; mount must re-seed from persisted rows.

## Acceptance Criteria
Maps to `BUILD_PROMPT.md` §12 (per-milestone) and §15 ("Done" 1–11):
1. CRUD of agents and workflows works through `@spec`'d contexts; the web layer never touches `Repo` directly.
2. A live session GenServer drives a **real** Claude CLI and a **real** pi CLI, normalizing both to the **identical** canonical event contract; the dashboard streams both live.
3. Interrupting/crashing a session reaps its OS child with **zero orphans** (SIGTERM→SIGKILL); after a hard BEAM kill, `OrphanReaper` reaps marked orphans on boot via the durable `os_pid_ledger` (by marker, never bare pid).
4. Crash isolation: one agent or one workflow step failing affects only itself.
5. The `plan → build → review → fix` ADW runs end-to-end with deterministic edges and harness-delegated steps; a failed step follows `on_failure` and is isolated.
6. Oban durably triggers workflows via **signature-verified webhook** and **cron**, surviving a node restart (resumes from `workflow_runs.current_step`); live streaming stays in GenServers (durable/live split honored); unique-job dedup prevents double-runs.
7. The **same ADW** runs under both harnesses by changing only the `harness` string; **adding a third harness is one adapter module + one config entry** (no edits to `Event`/`Agent`/runtime — proven by the no-op `Cursor` adapter).
8. The LiveView dashboard renders swimlanes + append-only logs via **streams** (flat memory), live cost/status via `assign_async`, and resumes correctly on reconnect by seeding from persisted rows.
9. No secret (API keys/provider creds) appears in `agent_logs`, `system_logs`, or any log; the persisted `raw` is redacted while the live event keeps full detail.
10. Live-session concurrency is bounded (admission gate + `max_children`); the node does not exhaust OS processes/fds under many concurrent sessions.
11. CI is green: `mix compile --warnings-as-errors`, `mix test --warnings-as-errors`, `mix dialyzer` (no stale ignore filters). Every public function has an `@spec` (callback impls exempt); every struct is `@enforce_keys`-typed; a minimal adapter (`command/1` + `normalize/2` only) compiles clean; untrusted harness JSON is validated at the boundary before becoming a canonical event.

## Validation Commands
Execute every command from the project root (toolchain is project-scoped via `mise.toml` — prefix with `mise exec --` if `mix` is not on PATH). The full gate must pass for **every** milestone before advancing; the live/DB acceptance applies from the milestone that introduces it.

- `mix compile --warnings-as-errors` — gradual set-theoretic type checker + warnings-as-errors must pass.
- `mix format --check-formatted` — formatting.
- `mix credo --strict` — lint, including the `@spec`-on-every-public-function gate (`Credo.Check.Readability.Specs`).
- `mix dialyzer` — `@spec`/contract checking, no stale ignore filters (`list_unused_filters: true`).
- `mix test --warnings-as-errors` — full ExUnit suite (M3+ requires Postgres: the `test` alias runs `ecto.create`/`ecto.migrate`).
- Per-UI milestone (M2, M7): run the LiveView E2E explicitly, e.g. `mix test test/repo_builder_web/live/agent_live_test.exs` and `mix test test/repo_builder_web/live/dashboard_live_test.exs`.
- Live acceptance (M2/M6, real CLIs + Postgres): start `mix phx.server`; run real `claude -p --output-format stream-json --verbose` and `pi --mode json` sessions through `Session.Server`; confirm streaming in the dashboard; `ps` shows **no orphan** after interrupt/kill; a hung pi session fires the idle timeout.
- Runtime verification via **Tidewave** (`http://localhost:4000/tidewave/mcp`): `project_eval` to drive a context/OTP path in the live app, `execute_sql_query` to confirm persisted state (rows written, `cost_usd` NULL-vs-0), `get_logs` to confirm no errors and **no leaked secrets**. Optionally capture a dashboard screenshot via Tidewave vision mode (Playwright MCP fallback) as visual proof for M7.

## Notes
- **No new dependencies** are required — all §2 packages are already pinned in `mix.exs` (verified line-by-line). If a milestone genuinely needs one, add it to `deps/0`, run `mix deps.get`, and report it here.
- **Current status (2026-06-15):** M0 is essentially done (scaffold, pinned deps, `:dialyzer` block, the typed standard + Credo `@spec` gate + `conditional_docs` router, all four gate commands green). M0's only residual is the **GitHub Actions CI workflow** with a PLT cache keyed on OTP+Elixir+`mix.lock`. Everything M1–M7 is greenfield.
- **Postgres** is currently unprovisioned; it is a hard prerequisite for M3+ (and for `mix test`, which creates/migrates the test DB). M0/M1 are fully buildable and testable without it.
- **Toolchain quirk (CI-relevant):** `type_check` 0.13.7 does not compile on Elixir 1.20 until `scripts/patch_deps.sh` runs (removes the removed `Regex.re_version` reference). CI step order must be `deps.get → patch_deps.sh → compile`. (See project memory `native-dep-space-path`.)
- **Critic-resolved consistency fixes** folded into this plan: (1) the per-agent LiveView is `RepoBuilderWeb.AgentLive` at `live/agent_live.ex` from M2 (per §11), modified — not recreated — in M3/M7; (2) a TypeCheck **wire-type boundary** (`harness/wire.ex`) is added in M1 so the pinned `type_check` dep is actually used (§3 rule 6 / §6 step 3); (3) the mandatory callback is **`command/1`** everywhere (the spec's `command/2` prose is a known inconsistency); (4) `lib/repo_builder/schema.ex` is pulled forward into M2 so the os_pid_ledger schema compiles; (5) the `chat` table is CRUD-only and **not populated by the runtime** per spec — do not expect chat rows from the event pipeline.
- **Deliberate design seam:** harness identity is an open `atom()`/`String.t()` everywhere (Event `harness`, `agents.harness` validated against the registry — not a closed `Ecto.Enum`/union). This is the single intentional type looseness (§3 rule 5, §10) and is what makes "add a harness = one module + one config entry" true; everywhere else use precise unions.
- **Oban OSS only:** multi-job DAG/batches are Pro; chain steps manually by enqueuing the next job from `perform/1`. Treat Pro as an optional future upgrade, never a requirement.
- This plan was synthesized from a parallel per-milestone drafting pass grounded in `BUILD_PROMPT.md`, then run through an adversarial completeness critic against the §15 "Done" criteria (`coverage_ok: true`).
