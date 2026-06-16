# Feature: Functional Orchestrator — Programmatic Claude⇄pi Harness Adapter + Provider/Model Selection + Dual-Harness Observability

## Metadata
issue_number: `d`
adw_id: `b7f4c2a9`
issue_json: `{"title":"Make the orchestrator functional: programmatic Claude⇄pi harness adapter with provider/model selection and observability on both","body":"We need the orchestrator to be functional. It will use an adapter pattern where we swap the Claude programmatic harness for the pi programmatic harness. Research how Claude's programmatic --dangerously-skip-permissions works and how to use pi programmatically. We need observability on both, reflected in the observability system. On top of harness selection, we need a provider set for the orchestrator (for Claude it would be Opus by default), but for pi it depends which provider and model are available."}`

## Feature Description

Today the orchestrator brain runs end-to-end **only on the keyless `fake` harness** (its tool calls are dispatched in-process by `RepoBuilder.Orchestrator.Server`). The wiring for real harnesses exists — `RepoBuilder.Harness.Orchestrating.orchestrator_spawn/2` is implemented for both Claude and pi, the per-orchestrator MCP endpoint is served, and the pi extension ships under `priv/orchestrator/pi_extension/` — but three things make the orchestrator **non-functional against the real `claude` and `pi` CLIs**:

1. **Permissions are never bypassed programmatically.** Claude in headless mode (`claude -p --output-format stream-json …`) blocks on a permission prompt the first time the model invokes an MCP tool. Because the session runtime only frames stdout and never answers an interactive prompt, the orchestrator produces no further output and is reaped by the idle timer as `%Error{reason: :idle_timeout}`. The fix is the programmatic `--dangerously-skip-permissions` flag (equivalent to `--permission-mode bypassPermissions`), plus `--strict-mcp-config` so only our scoped MCP server loads. pi is the mirror image: it has **no permission popups by design** (its autonomy is the default), so it needs *no* skip flag — only a `--approve` to trust project-local resources in non-interactive mode and `--provider`/`--model` selection. Encoding this asymmetry behind the two-callback adapter seam is exactly the harness-adapter pattern the platform is built on.

2. **There is no provider concept for the orchestrator.** The `orchestrators` row carries `harness` + `model` but no `provider`. The operator must be able to choose a **harness, a provider, and a model**, with sensible per-harness defaults: **Claude → provider `anthropic`, model `opus` (latest Opus) by default**; **pi → provider + model chosen by the operator** from the set pi supports (anthropic, openai, google, zai, groq, openrouter, …), because "it depends which provider and model are available."

3. **Orchestrator turns are not persisted, so observability is live-only.** Orchestrator sessions are started **without an `agent_db_id`**, so `RepoBuilder.Session.Server.dispatch/2` broadcasts their canonical events (per-agent topic + global `console:events` feed + swimlane lanes) but **never persists** them to `agent_logs`. The console shows orchestrator activity live, but a reconnect/backfill (`Logs.list_recent_global/1`) and the seeded cost rollup do **not** include orchestrator turns, and the orchestrator's history is not reconstructable from the DB. The feature must make orchestrator events "reflect in the observability system" **identically for both harnesses**: persisted, backfilled on reconnect, and rolled into cost.

This feature closes all three gaps so the operator can flip the orchestrator between a real Claude (Opus) brain and a real pi brain (any available provider/model) from the console header, run unattended turns that actually invoke the orchestrator tools, and watch both harnesses stream into the same observability surface.

## User Story

As an **operator driving the orchestration console**
I want to **switch the orchestrator's brain between a real Claude (Opus) harness and a real pi harness with a chosen provider/model, and have each run unattended while streaming into the observability system**
So that **I can use the best available model/provider for meta-orchestration, prove the platform is genuinely harness-agnostic at the orchestrator layer, and audit every orchestrator turn after the fact — not just watch it live.**

## Problem Statement

The orchestrator only works against the keyless `fake` harness. Against real CLIs it (a) hangs on Claude's first tool-permission prompt because nothing answers it, (b) cannot express a provider (only harness + model), so it can't default Claude to Opus or target one of pi's many providers, and (c) does not persist its turns, so the observability system reflects orchestrator activity only while the LiveView stays connected. The platform's central claim — harness-agnostic orchestration with full observability — is therefore unproven at the orchestrator layer.

## Solution Statement

Extend the existing two-callback adapter seam and the orchestrator runtime, with **zero edits to the canonical `Event` types** (`BUILD_PROMPT.md` §10):

1. **Programmatic autonomy, per harness.** Add a config-declared autonomy posture to each harness registry entry and consume it in `command/1`/`orchestrator_spawn/2`: Claude appends `--dangerously-skip-permissions` (and `--strict-mcp-config` for the orchestrator MCP binding); pi appends `--approve` and sets `PI_SKIP_VERSION_CHECK=1`. The flag set is built in the adapter, never hardcoded in the runtime, so adding a third harness still means one module + one config entry.

2. **Open provider identity end-to-end.** Add a `provider :string` column to `orchestrators` (open identity validated loosely, like `harness` — *not* a closed `Ecto.Enum`, because pi supports 30+ providers). Thread `provider` through `Harness.start_opts`, `Session.Server`, and into each adapter's `command/1` (pi → `--provider`; Claude → implicit `anthropic`, model alias `opus`). Carry per-harness **orchestrator defaults** (`default_provider`/`default_model`) in the registry config so switching to Claude sets Opus automatically.

3. **Dual-harness observability parity.** Persist orchestrator canonical events to `agent_logs` keyed by `orchestrator_id` (nullable FK; `agent_id` made nullable), so reconnect-backfill, cost rollups, and the DB-of-record all include orchestrator turns identically to workers. Surface harness/provider/model/status/cost selection + display in the console header.

## Relevant Files

Use these files to implement the feature:

- `BUILD_PROMPT.md` — authoritative spec. §4.2 (mandatory/optional harness behaviours), §4.3 (Claude & pi wire mappings), §6 (session runtime, secrets, idle timeout), §8 (persistence, `agent_logs`, float→Decimal), §10 (extensibility = one module + one config entry), §13 (Mox/registry test seam). The open-`atom()`/`String.t()` harness identity rule (§3 rule 5) is the precedent for an open `provider`.
- `ai_docs/typed-elixir-standard.md` — the enforced typed standard (`@spec` on every public fn, `typedstruct`/`@enforce_keys`, wire≠domain, tagged tuples). Read before touching any public function/struct/schema (the conditional_docs **(always)** row).
- `.claude/commands/conditional_docs.md` — routing map; matched rows: harness adapters/event contract (§4/§10), session runtime/erlexec (§6), Ecto/JSONB/cost boundary (§8), LiveView dashboard/streams (§9), secrets/redaction (§4.1/§6), tests/Mox/Fake (§13).
- `config/config.exs` — the harness registry (`:harnesses`) and `:orchestrator` defaults. **Add** per-harness `orchestrator: %{default_provider, default_model, …}` and autonomy flags here.
- `config/runtime.exs` — `:harness_secrets` (per-harness env creds) and `ORCHESTRATOR_MCP_BASE_URL`. No new secrets, but pi `--provider` may need additional provider keys documented here.
- `lib/repo_builder/harness.ex` — the mandatory `@behaviour`; `start_opts` type. **Add** `optional(:provider)` to `start_opts`.
- `lib/repo_builder/harness/orchestrating.ex` — the optional `orchestrator_spawn/2` behaviour + `tool_ctx`. Claude's MCP-skip flags attach here.
- `lib/repo_builder/harness/claude.ex` — Claude adapter. `command/1` adds `--dangerously-skip-permissions` (config-driven) + `--model opus` resolution; `orchestrator_spawn/2` adds `--strict-mcp-config`.
- `lib/repo_builder/harness/pi.ex` — pi adapter. `command/1` adds `--provider` + `--approve` (config-driven) + hygiene env; provider threaded from `start_opts`.
- `lib/repo_builder/harness/registry.ex` — single source of truth/test seam. **Add** `orchestrator_defaults/1` (provider/model per harness) and an autonomy accessor.
- `lib/repo_builder/orchestrator/orchestrator.ex` — the `orchestrators` schema. **Add** `provider :string` field + `@type` + changeset validation.
- `lib/repo_builder/orchestrators.ex` — the context (only `Repo` caller). **Add** `set_provider/2`, `set_model/2`, per-harness default application on `get_or_create_default`/`set_harness`, and `apply_harness_defaults/2`.
- `lib/repo_builder/orchestrator/server.ex` — runs one orchestrator turn. Thread `provider` + the orchestrator-default model into the `Session.Supervisor.start_session/1` opts; pass an `orchestrator_db_id` for persistence.
- `lib/repo_builder/orchestrator/system_prompt.ex` — already injects harness/tools; extend the prompt to mention the active provider/model (minor).
- `lib/repo_builder/session/server.ex` — the erlexec runtime. Thread `provider` into `start_opts`; add an `orchestrator_db_id` to `State`; persist events for orchestrator sessions (parallel to the worker `agent_db_id` gate) without touching the worker path.
- `lib/repo_builder/logs.ex` + `lib/repo_builder/logs/agent_log.ex` — persistence context + schema. **Add** nullable `orchestrator_id`, make `agent_id` nullable, add `persist_orchestrator_event/2` + `orchestrator_cost_rollup!/1`; keep `list_recent_global/1` working (now includes orchestrator rows).
- `lib/repo_builder_web/live/console_live.ex` — the console. Header `set_harness` exists; **add** `set_provider`/`set_model` handlers and pass provider/model options to the header.
- `lib/repo_builder_web/components/console_components.ex` — `header_bar/1` (harness toggle). **Add** provider + model selectors.
- `test/repo_builder/harness/claude_normalize_test.exs`, `test/repo_builder/harness/pi_normalize_test.exs` — sibling adapter tests; mirror their structure for new `command/1`/`orchestrator_spawn/2` argv assertions.
- `test/repo_builder/orchestrator/server_test.exs`, `test/repo_builder/orchestrator/tools_test.exs` — orchestrator runtime/tool tests; extend for provider threading + persistence.
- `test/repo_builder_web/live/test_orchestrator_agent_test.exs` — the orchestrator LiveView integration test (keyless Fake); template for the new header-selector + observability test.
- `priv/repo/migrations/20260616000001_create_orchestrators.exs`, `20260616000002_add_orchestrator_fields_to_agents.exs`, `20260615230002_create_agent_logs.exs` — existing migrations to mirror for the two new migrations (binary_id, JSONB, FK conventions).

### New Files

- `priv/repo/migrations/<ts>_add_provider_to_orchestrators.exs` — adds `provider :string` (nullable) to `orchestrators`.
- `priv/repo/migrations/<ts>_add_orchestrator_id_to_agent_logs.exs` — adds nullable `orchestrator_id` FK to `agent_logs` (`references(:orchestrators, type: :binary_id, on_delete: :delete_all)`), makes `agent_id` nullable, adds an index on `orchestrator_id`.
- `test/repo_builder/harness/orchestrator_autonomy_test.exs` — unit tests asserting the exact argv/env each adapter emits for orchestrator + worker sessions (Claude `--dangerously-skip-permissions`/`--strict-mcp-config`/`--model opus`; pi `--provider`/`--approve`/`PI_SKIP_VERSION_CHECK`), driven purely off `command/1`/`orchestrator_spawn/2` — **no real CLI**.
- `test/repo_builder/orchestrators_provider_test.exs` — context tests for `set_provider/2`, `set_model/2`, and per-harness default application (switch to `claude` ⇒ provider `anthropic`, model `opus`; switch to `pi` ⇒ operator-chosen, no forced model).
- `test/repo_builder/logs_orchestrator_test.exs` — persistence tests: an orchestrator event round-trips to `agent_logs` under `orchestrator_id`, appears in `list_recent_global/1`, and rolls into `orchestrator_cost_rollup!/1` (nil-vs-0.0 preserved as NULL-vs-0).
- `test/repo_builder_web/live/test_orchestrator_harness_provider_test.exs` — `Phoenix.LiveViewTest` integration: mount `/`, switch harness via the header, set provider + model, assert the orchestrator row updates and the header reflects the selection; run one keyless Fake orchestrator turn and assert its events both broadcast on `console:events` **and** persist (observability parity).

## Implementation Plan

### Phase 1: Foundation (open provider identity + per-harness defaults, no behavior change yet)

Add the `provider` column and thread it through the type system end-to-end, plus the registry orchestrator-defaults accessor. Nothing changes the spawned argv yet — this phase only makes `provider` a first-class, typed, persisted concept so later phases can consume it. Keep the worker spawn path byte-for-byte unchanged (provider defaults to `nil` for workers, which adapters ignore).

### Phase 2: Core Implementation (programmatic autonomy + provider-aware spawning)

Teach each adapter its autonomy mechanism and provider wiring behind the seam:
- **Claude** `command/1`: append `--dangerously-skip-permissions` when the session is autonomous (orchestrator, or registry `autonomous: true`); resolve the orchestrator default model to the `opus` alias. `orchestrator_spawn/2`: additionally append `--strict-mcp-config` (only the generated `.mcp.json` server loads).
- **pi** `command/1`: append `--provider <name>` when `start_opts.provider` is set; append `--approve` when autonomous; inject `PI_SKIP_VERSION_CHECK=1` (and keep secrets in env). No skip-permissions flag — pi has none by design.
- Registry + `Orchestrators` apply per-harness orchestrator defaults so switching to Claude sets Opus, and switching to pi leaves provider/model to the operator.

### Phase 3: Integration (observability parity + console selection UI)

- Persist orchestrator canonical events to `agent_logs` via `orchestrator_id`, so reconnect-backfill and cost rollups include orchestrator turns for **both** harnesses.
- Add provider + model selectors to the console header next to the existing harness toggle; wire `set_provider`/`set_model`; reflect the live selection.
- Prove the whole flow with a keyless Fake LiveView integration test plus adapter-argv unit tests (no real CLI required for CI).

## Step by Step Tasks

IMPORTANT: Execute every step in order, top to bottom.

### Task 1 — Read the standard and confirm the contract

- Read `ai_docs/typed-elixir-standard.md` and `BUILD_PROMPT.md` §4.2/§4.3/§6/§8/§10/§13 (and the matched `conditional_docs.md` rows). Confirm the open-identity precedent (§3 rule 5) before adding `provider` as an open `String.t()`.
- Confirm via the existing code that the worker spawn path must remain unchanged: `Session.Server.maybe_orchestrator_spawn/4` only diverges when `orchestrator_ctx != nil`, and `dispatch/2` persistence is gated on `agent_db_id`. The new provider/persistence plumbing must preserve both gates.

### Task 2 — Migration: `provider` on `orchestrators`

- `mix ecto.gen.migration add_provider_to_orchestrators`. Body: `alter table(:orchestrators) do add :provider, :string end`. Nullable (existing rows + pi may legitimately have no explicit provider). No CHECK; membership is validated at the changeset boundary like `harness`.
- Mirror the conventions in `20260616000001_create_orchestrators.exs`.

### Task 3 — Schema + context: open provider identity

- `lib/repo_builder/orchestrator/orchestrator.ex`: add `field :provider, :string`; add `provider: String.t() | nil` to `@type t`; cast `:provider`; add a soft validation `validate_length(:provider, min: 1)` when present (open identity — do **not** make it a closed `Ecto.Enum`). Keep `@spec changeset/2`.
- `lib/repo_builder/orchestrators.ex`:
  - Add `@spec set_provider(Ecto.UUID.t(), String.t() | nil) :: {:ok, Orchestrator.t()} | {:error, :not_found}` and `set_model/2` (delegating to `update_fields/2`).
  - Add `@spec apply_harness_defaults(Orchestrator.t() | map(), String.t()) :: map()` that merges per-harness orchestrator defaults (provider/model) from the registry for a harness.
  - Update `get_or_create_default/1` to seed `provider`/`model` from the harness's orchestrator defaults (Claude ⇒ `anthropic`/`opus`).
  - Update `set_harness/2` to also apply that harness's orchestrator defaults to `provider`/`model` on switch (so flipping to Claude yields Opus, flipping to pi clears the Claude-only model). Keep every public function `@spec`'d and returning tagged tuples.

### Task 4 — Registry: per-harness orchestrator defaults + autonomy posture

- `config/config.exs`: extend the orchestrating harness entries:
  - `"claude"` ⇒ add `orchestrator: %{default_provider: "anthropic", default_model: "opus"}` and `autonomous: true` (programmatic permission skip for unattended runs on this sandboxed orchestration server — document the risk inline).
  - `"pi"` ⇒ add `orchestrator: %{default_provider: nil, default_model: nil, providers: ["anthropic", "openai", "google", "zai", "groq", "openrouter"]}` and `autonomous: true` (pi's autonomy is `--approve`, not a skip flag).
  - `"fake"` (dev) ⇒ no autonomy/provider changes (keyless in-process path).
- `lib/repo_builder/harness/registry.ex`: add `@spec orchestrator_defaults(harness()) :: %{optional(atom()) => term()}` (reads the `:orchestrator` sub-map; `%{}` when absent) and `@spec autonomous?(harness()) :: boolean()`. These are the only readers of the new config keys.

### Task 5 — `start_opts` + Session.Server: thread `provider` and an orchestrator persistence id

- `lib/repo_builder/harness.ex`: add `optional(:provider) => String.t() | nil` to the `start_opts` type. (Type-only; no runtime change.)
- `lib/repo_builder/session/server.ex`:
  - Add `field :provider, String.t(), enforce: false` and `field :orchestrator_db_id, Ecto.UUID.t(), enforce: false` to `State`.
  - In `build_state/3`, set `provider: opts[:provider]` and `orchestrator_db_id: opts[:orchestrator_db_id]`.
  - In `handle_continue(:spawn, …)`, include `provider: state.provider` in the `start_opts` map passed to `adapter.command/1`.
  - In `dispatch/2`, add a parallel persistence branch: when `state.orchestrator_db_id` is set, call a new `persist_orchestrator_quietly/2` (→ `Logs.persist_orchestrator_event/2`) — **mirror** the existing `agent_db_id` branch and keep both mutually independent so the worker path is untouched.
  - Leave `maybe_orchestrator_spawn/4`, idle-timer, ledger, and admission logic unchanged.

### Task 6 — Claude adapter: programmatic permission skip + Opus + strict MCP

- `lib/repo_builder/harness/claude.ex`:
  - `command/1`: append `--dangerously-skip-permissions` when the session is autonomous — detect via `opts.config[:orchestrator] == true` **or** a passed `opts.config[:autonomous]`/registry flag (resolve through `start_opts.config`; do not read global config from the adapter). Keep `--model` handling; when the model is the `opus` alias or a full Opus id, pass it through verbatim (Claude resolves `opus` to latest Opus).
  - `orchestrator_spawn/2`: append `--strict-mcp-config` after `--mcp-config <path>` so only the generated server loads, and append `--dangerously-skip-permissions` here too (orchestrator MCP tool calls must never prompt). Keep writing `.mcp.json` and `--resume` exactly as today; secrets stay in env.
  - Add/keep `@spec` on any new private helper (e.g. `permission_args/1`).

### Task 7 — pi adapter: provider arg + `--approve` + hygiene env

- `lib/repo_builder/harness/pi.ex`:
  - `command/1`: when `opts[:provider]` is a non-empty string, insert `--provider <name>` into the base args (before the prompt, alongside `--model`); when autonomous (`opts.config[:orchestrator]`/`autonomous`), append `--approve`. Thread `PI_SKIP_VERSION_CHECK=1` into the env via `env/1` (keep existing secret mapping; never log).
  - `orchestrator_spawn/2`: unchanged except it inherits the provider/`--approve` already added by `command/1` (the runtime appends orchestrator args/env after the base command, so no duplication). Confirm `--session <id>` resume still applies.
  - Keep `@spec` on new helpers; pi cost stays `nil` in the stream (derived downstream, unchanged).

### Task 8 — Orchestrator.Server: pass provider, orchestrator model default, and the persistence id

- `lib/repo_builder/orchestrator/server.ex`:
  - In `handle_continue(:launch, …)`, add to the `Session.Supervisor.start_session/1` opts: `provider: orchestrator.provider`, `orchestrator_db_id: orchestrator.id`, and resolve `model:` to `orchestrator.model || Registry.orchestrator_defaults(orchestrator.harness)[:default_model]` (so a Claude orchestrator with no explicit model still runs Opus).
  - Keep `config: %{orchestrator: true}` (drives the autonomy detection in the adapters) and the existing token/`tool_ctx` flow.
  - No change to the in-process Fake tool-dispatch branch.

### Task 9 — Migration + Logs context: orchestrator-scoped persistence

- `mix ecto.gen.migration add_orchestrator_id_to_agent_logs`. Body: `alter table(:agent_logs)`: `add :orchestrator_id, references(:orchestrators, type: :binary_id, on_delete: :delete_all)`; `modify :agent_id, :binary_id, null: true` (was `null: false`); then `create index(:agent_logs, [:orchestrator_id])`. App guarantees exactly one of `agent_id`/`orchestrator_id` is set.
- `lib/repo_builder/logs/agent_log.ex`: add `field :orchestrator_id, :binary_id`; add `orchestrator_id: Ecto.UUID.t() | nil` to `@type t`; allow it in the changeset; relax the `agent_id` requirement so an orchestrator log validates without `agent_id`.
- `lib/repo_builder/logs.ex`: add `@spec persist_orchestrator_event(Event.t(), %{required(:orchestrator_id) => Ecto.UUID.t(), required(:session_id) => String.t()}) :: {:ok, AgentLog.t()} | {:error, Ecto.Changeset.t()}` mirroring `persist_event/2` (same redaction via the existing scrub path, same float→Decimal usage embed). Add `@spec orchestrator_cost_rollup!(Ecto.UUID.t()) :: Decimal.t()`. Confirm `list_recent_global/1` still returns the most-recent rows across both owners (it orders by time/id, owner-agnostic) so console reconnect-backfill shows orchestrator turns.

### Task 10 — Console header: provider + model selectors

- `lib/repo_builder_web/components/console_components.ex` — `header_bar/1`: add a provider `<select>` and a model `<select>`/free-text input next to the existing harness toggle, with `attr/3`-typed inputs (`orchestrator_provider`, `orchestrator_model`, `provider_options`, `model_options`). Give each control a stable DOM id (`#orchestrator-harness`, `#orchestrator-provider`, `#orchestrator-model`) for tests. Keep the world-class styling consistent with the existing pills/chips.
- `lib/repo_builder_web/live/console_live.ex`:
  - In `assign_orchestrator/1`, also assign `orchestrator_provider`, `orchestrator_model`, and per-harness `provider_options`/`model_options` (from `Registry.orchestrator_defaults/1`).
  - Add `handle_event("set_provider", %{"provider" => p}, socket)` and `handle_event("set_model", %{"model" => m}, socket)` calling `Orchestrators.set_provider/2`/`set_model/2`, updating the assigns, and flashing on error (mirror the existing `set_harness` handler).
  - Update `set_harness` to also refresh provider/model assigns from the harness's applied defaults (so the UI shows Opus after switching to Claude).
  - Pass the new assigns into `<.header_bar …>`.

### Task 11 — System prompt: surface the active provider/model (minor)

- `lib/repo_builder/orchestrator/system_prompt.ex`: include the orchestrator's active `provider`/`model` in the prompt text (e.g. "Your own harness is `claude` (provider `anthropic`, model `opus`).") so the brain is self-aware of its execution context. Keep `@spec build/1`.

### Task 12 — Adapter argv/env unit tests (no CLI)

- Create `test/repo_builder/harness/orchestrator_autonomy_test.exs`:
  - Claude worker `command/1` with `config: %{orchestrator: true}` ⇒ argv contains `--dangerously-skip-permissions`; with `model: "opus"` ⇒ argv contains `--model opus`; non-autonomous worker (no orchestrator/autonomous flag) ⇒ no skip flag (safety).
  - Claude `orchestrator_spawn/2` ⇒ argv contains `--strict-mcp-config` and `--mcp-config <path>` and writes `.mcp.json`; token only in headers, never in argv.
  - pi `command/1` with `provider: "openai"`, `config: %{orchestrator: true}` ⇒ argv contains `--provider openai` and `--approve`; env contains `PI_SKIP_VERSION_CHECK`; no `--dangerously-skip-permissions` anywhere.
- These assert the **exact** programmatic-permission behavior the feature is about, hermetically.

### Task 13 — Context + persistence tests

- Create `test/repo_builder/orchestrators_provider_test.exs`: `set_provider/2`/`set_model/2` round-trip; `get_or_create_default("claude")` ⇒ provider `anthropic`, model `opus`; `set_harness(id, "pi")` ⇒ Claude-only model cleared, provider taken from pi defaults; unknown harness rejected by the changeset.
- Create `test/repo_builder/logs_orchestrator_test.exs`: `persist_orchestrator_event/2` round-trips Enum + JSONB under `orchestrator_id` with `agent_id` NULL; the row appears in `list_recent_global/1`; `orchestrator_cost_rollup!/1` sums priced usage and preserves nil-vs-0.0 (NULL-vs-0); secret-bearing `raw` is redacted in the persisted payload (reuse the existing redaction assertion pattern).
- Extend `test/repo_builder/orchestrator/server_test.exs` to assert the launch opts now include `provider` and `orchestrator_db_id` and that a Fake orchestrator turn persists at least one `agent_logs` row for the orchestrator.

### Task 14 — LiveView integration test (UI + observability parity, keyless)

- Create `test/repo_builder_web/live/test_orchestrator_harness_provider_test.exs` using `Phoenix.LiveViewTest`:
  - Mount `/`; assert the header shows the default orchestrator harness and (after default seeding) provider/model.
  - `render_click`/`render_change` the harness selector to `claude` (test registry override may keep it keyless via the Mock seam) and assert the provider/model selectors reflect `anthropic`/`opus`; switch provider/model via `set_provider`/`set_model` and assert the orchestrator row updated (read back through `Orchestrators.fetch/1`).
  - Run one keyless Fake orchestrator turn (no agent selected, submit `#command-form`), then assert: (a) the orchestrator's `TextDelta` broadcasts on `console:events` (`Dashboard.subscribe_events/0`, as the existing orchestrator test does), and (b) at least one `agent_logs` row exists for the orchestrator id (observability persistence parity) via `Logs.list_recent_global/1` or `Repo`-free context read.
  - Reference element IDs (`#orchestrator-harness`, `#orchestrator-provider`, `#orchestrator-model`, `#command-form`) per the AGENTS.md LiveView-test guidance; assert via `has_element?/2`, never raw HTML.
- Optionally capture a Playwright screenshot of `http://localhost:4000` showing the header selectors as visual proof.

### Task 15 — Tidewave runtime validation (live app)

- With the app running (`scripts/pg.sh start` then `iex -S mix phx.server`), use Tidewave MCP:
  - `get_source_location`/`get_docs` to confirm `:exec`/erlexec and adapter modules resolve.
  - `project_eval`: `RepoBuilder.Harness.Claude.command(%{prompt: "hi", model: "opus", cwd: ".", sink: self(), config: %{orchestrator: true}, secrets: %{}})` and assert the argv contains `--dangerously-skip-permissions` and `--model opus`; the analogous `RepoBuilder.Harness.Pi.command/1` with `provider: "openai"` contains `--provider openai`/`--approve`.
  - `project_eval`: `RepoBuilder.Orchestrators.get_or_create_default("claude")` ⇒ provider `anthropic`, model `opus`.
  - `execute_sql_query`: after a Fake orchestrator turn, `SELECT count(*) FROM agent_logs WHERE orchestrator_id IS NOT NULL` returns > 0 (observability persistence).
  - `get_logs` to inspect any stacktrace if a step fails.

### Task 16 — Run the Validation Commands

- Run every command in **Validation Commands** below and fix any failure before considering the feature complete. Resolve Dialyzer/Credo findings introduced by the new public functions and the `provider`/`orchestrator_id` types; ensure no stale `.dialyzer_ignore.exs` filters.

## Testing Strategy

### Unit Tests

- **Adapter argv/env (hermetic):** Claude `command/1`/`orchestrator_spawn/2` emit `--dangerously-skip-permissions`, `--strict-mcp-config`, and the Opus model only when autonomous; pi `command/1` emits `--provider`/`--approve`/`PI_SKIP_VERSION_CHECK` and never a skip-permissions flag. Token never in argv.
- **Registry:** `orchestrator_defaults/1` returns the right per-harness map; `autonomous?/1` reflects config; unknown harness ⇒ `%{}`/`false`.
- **Context:** `Orchestrators.set_provider/2`/`set_model/2`/default application; changeset rejects unknown harness; `provider` accepted as an open string.
- **Persistence:** `Logs.persist_orchestrator_event/2` round-trips Enum + JSONB under `orchestrator_id`; redaction holds; `orchestrator_cost_rollup!/1` preserves NULL-vs-0; `agent_logs.agent_id` nullable works.
- **Runtime threading:** `Session.Server` puts `provider` into `start_opts` and persists when `orchestrator_db_id` is set; worker path (no orchestrator) is byte-for-byte unchanged.

### Edge Cases

- **Claude tool-permission deadlock avoided:** without the skip flag a headless Claude orchestrator would idle-timeout; the test proves the flag is present for orchestrator/autonomous sessions and absent for plain workers (no accidental global bypass).
- **pi has no skip flag:** asserting the *absence* of `--dangerously-skip-permissions` for pi is as important as asserting its presence for Claude — they must not be conflated.
- **Provider unset for pi:** `--provider` is omitted when `provider` is `nil`/empty (pi falls back to its own login/default); no empty `--provider ""` ever emitted.
- **Switching harness resets stale model:** flipping Claude→pi must not leave a Claude-only model (`opus`) on the pi orchestrator; flipping pi→Claude must restore Opus.
- **Cost nil-vs-0.0:** an unpriced pi orchestrator turn stores `NULL`, not `0`, in the rolled-up cost; a priced-at-zero turn stores `0`.
- **Reconnect backfill:** orchestrator turns appear in `list_recent_global/1` after a LiveView remount (no `agent_id`), interleaved correctly with worker rows.
- **Secret redaction:** an `ANTHROPIC_API_KEY` in a `raw` frame is scrubbed in the persisted orchestrator `agent_logs.payload` but present in the live broadcast.
- **Unknown/looser provider strings:** an arbitrary pi provider (e.g. `groq`) is accepted (open identity) and threaded to `--provider groq`.

## Acceptance Criteria

- The orchestrator can be switched between `claude` and `pi` from the console header, and an operator can independently set its **provider** and **model**; switching to `claude` defaults to provider `anthropic`, model `opus`.
- A Claude orchestrator turn spawns `claude … --dangerously-skip-permissions --strict-mcp-config --model opus --mcp-config <.mcp.json> …` (verified by `command/1`/`orchestrator_spawn/2` argv tests), so it runs unattended and can invoke its MCP tools without an interactive prompt.
- A pi orchestrator turn spawns `pi --mode json --provider <name> [--model <id>] --approve -e <ext> --append-system-prompt … [--session <id>] <prompt>` with `PI_SKIP_VERSION_CHECK=1` in env and **no** skip-permissions flag.
- Adding the provider/autonomy capability required **zero edits** to the canonical `Event` types and **no** closed-enum changes; harness/provider remain open identities (§10 preserved).
- Orchestrator canonical events for **both** harnesses are persisted to `agent_logs` (keyed by `orchestrator_id`), appear in `list_recent_global/1` reconnect-backfill, and roll into `orchestrator_cost_rollup!/1` (nil-vs-0.0 preserved) — observability parity with workers.
- No secret appears in any persisted orchestrator `agent_logs.payload` while the live broadcast keeps full `raw`.
- The worker spawn/persistence path is unchanged (existing tests still pass).
- All five green-gate commands pass with zero failures and no new Dialyzer/Credo findings or stale ignore filters.

## Validation Commands

Execute every command to validate the feature works correctly with zero regressions. (Ensure `scripts/pg.sh start` has run this session.)

- `mix test test/repo_builder/harness/orchestrator_autonomy_test.exs` — adapter argv/env (Claude skip + Opus + strict MCP; pi provider + approve, no skip).
- `mix test test/repo_builder/orchestrators_provider_test.exs` — provider/model context + per-harness defaults.
- `mix test test/repo_builder/logs_orchestrator_test.exs` — orchestrator-scoped persistence + cost rollup + redaction.
- `mix test test/repo_builder/orchestrator/server_test.exs` — provider/orchestrator_db_id threading + persisted turn.
- `mix test test/repo_builder_web/live/test_orchestrator_harness_provider_test.exs` — LiveView header selectors + observability parity.
- `mix test test/repo_builder_web/live/test_orchestrator_agent_test.exs` — existing orchestrator flow still green (no regression).
- `mix compile --warnings-as-errors` — clean compile; gradual set-theoretic checker + `warnings_as_errors` pass.
- `mix test --warnings-as-errors` — full ExUnit suite, zero failures.
- `mix format --check-formatted` — formatted.
- `mix credo --strict` — lint, including the `@spec`-on-every-public-function convention for all new public functions.
- `mix dialyzer` — `@spec`/contract checking with no new warnings and no stale ignore filters.

## Notes

- **No new dependencies.** Everything builds on the existing erlexec runtime, the harness registry seam, and Ecto. `mix.exs` `deps/0` is untouched.
- **Permission posture is deliberate and documented.** `--dangerously-skip-permissions` is the *programmatic* equivalent of `--permission-mode bypassPermissions` (confirmed in the Claude CLI reference). It is gated behind a per-harness `autonomous` config flag + the orchestrator session marker, so it only applies on this sandboxed orchestration server and can be disabled in config. pi's "autonomy" is structurally different — it has **no** permission popups by design (per the pi `coding-agent` README "No permission popups"); the only programmatic gate is project trust, handled with `--approve`. Capturing this asymmetry behind the two-callback adapter seam is the harness-adapter pattern the feature is meant to demonstrate.
- **Why `provider` is an open `String.t()` (not `Ecto.Enum`).** pi supports 30+ providers (anthropic, openai, google, vertex, bedrock, zai, groq, cerebras, openrouter, mistral, xai, …). A closed enum would make adding a provider a core schema edit and would reject valid pi providers — exactly the anti-pattern §10/§3-rule-5 forbid for `harness`. Validation is a soft non-empty check at the changeset boundary; the registry's per-harness `providers` list drives the UI dropdown without constraining the column.
- **Observability persistence choice.** Persisting orchestrator events under a nullable `orchestrator_id` on `agent_logs` (rather than a "shadow agent" row) is required because `agents.provider` is a closed `Ecto.Enum[:anthropic,:openai,:local]` that cannot represent pi's open provider set — a shadow agent literally could not hold a `zai`/`groq` orchestrator. The `agent_logs` route keeps the DB the single source of truth (§8) and gives true reconnect/backfill/cost parity for both harnesses.
- **Live acceptance remains the one manual step** (per the README) — running the real `claude` (Opus) and real `pi` CLIs is environment-dependent. All CI-facing tests use the keyless Fake/Mock through the registry seam and hermetic adapter-argv assertions, so the green gate needs no external CLI.
- **Future considerations:** dynamic pi model discovery via `pi --list-models` to populate the model dropdown live; a `--max-budget-usd`/`--max-turns` safety bound for autonomous Claude orchestrator turns; and persisting the orchestrator as a first-class "lane" in the swimlane view.
