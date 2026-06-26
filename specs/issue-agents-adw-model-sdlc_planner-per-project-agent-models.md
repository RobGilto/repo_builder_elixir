# Feature: Per-Project Agent Models with a Settings-Configured Global Default

## Metadata
issue_number: `agents`
adw_id: `model`
issue_json: `are`

## Feature Description

Today the operator perceives worker agent models as a single "overall" setup shared
across every project. In reality the worker tier roster (`fast` / `main` / `heavy` /
`leader` → `{harness, provider, model}`) is stored per-orchestrator in
`orchestrators.metadata["agent_models"]`, and because there is exactly one orchestrator
per project (partial-unique `orchestrators.project_id`), the roster is *de facto*
per-project. The gap is twofold:

1. **No global default.** When a new project is registered, its orchestrator is created
   with an **empty** `metadata["agent_models"]` map. The orchestrator therefore cannot
   spawn category-based workers (`create_agent` with `category: "main"`) until the
   operator manually assigns a model to every tier — `resolve_category/2` returns
   `"no model selected for category main"`. There is no operator-editable default that
   seeds a new project.
2. **No clear per-project surface / inheritance.** The per-project roster is editable
   only through the console's agent-models modal against whatever orchestrator is
   currently bound, with no indication of what a tier inherits and no way to manage a
   project's roster from its own `/projects/:id` page. The dormant `projects.default_model_tier`
   column is cast/persisted but read nowhere.

This feature makes the tier roster a **first-class, per-project configuration that
inherits from an operator-editable global default**:

- A new **Settings → Default Models** tab lets the operator define the global default
  agent-model roster (one `{harness, provider, model}` per tier). Persisted in a new
  `RepoBuilder.Settings` context (no settings store exists today).
- When a project is registered (its orchestrator is created), the orchestrator's
  `metadata["agent_models"]` is **seeded from the global default**.
- Both the operator (console agent-models modal + a new per-project roster card on
  `/projects/:id`) and the orchestrator (`configure_tier` MCP tool) can override any
  tier for that specific project, leaving other projects untouched.
- Worker spawning **reads through** to the global default for any tier a project has not
  explicitly set, so a freshly registered (or pre-existing, un-seeded) project can spawn
  workers immediately, while explicit per-project assignments always win.

## User Story

As the operator (and as the orchestrator agent)
I want each project to have its own agent-model roster that starts from a configurable
global default but can be tuned per project
So that registering a new project gives sensible worker models out of the box, while I
retain full control to allocate which models each project's orchestrator may use when it
spawns workers — without one project's choices leaking into another.

## Problem Statement

Worker model allocation is not operator-configurable as a global default and is not
clearly scoped per project. New projects begin with an empty tier roster, so the
orchestrator cannot spawn category workers until every tier is configured by hand;
there is no "set it once in settings, inherit everywhere, override per project" path.
The `projects.default_model_tier` column is dead, and `/projects/:id` exposes no model
configuration at all.

## Solution Statement

Introduce an operator-editable **global default agent-model roster** in a new
`RepoBuilder.Settings` context (backed by a small key/value `app_settings` table, the
only `Repo` caller for it), surfaced in a new Settings tab. Seed each project's
orchestrator roster from this default at orchestrator-creation time, and add a
read-through fallback at worker-spawn resolution so unset tiers transparently inherit
the global default. Keep all per-project overrides flowing through the existing
`Orchestrators.set_agent_model/3` seam (console modal + `configure_tier` MCP tool), and
add a per-project roster card to `/projects/:id` so each project's effective roster
(showing inherited vs. overridden) is visible and editable from the project page. The
tier-view (`get_config` / console roster rows) is extended to report the effective model
and whether it is inherited from the default or set on the project.

## Relevant Files

Use these files to implement the feature:

### Existing — read and modify

- `lib/repo_builder/orchestrator/orchestrator.ex` — `RepoBuilder.Orchestrator.Orchestrator`
  schema; `metadata` JSONB holds `agent_models`. No schema change, but the seed flows
  through here.
- `lib/repo_builder/orchestrator.ex` — `RepoBuilder.Orchestrators` context. Holds
  `@agent_categories ~w(fast main heavy leader)`, `agent_categories/0`, `agent_models/1`
  (orchestrator.ex:323), `set_agent_model/3` (orchestrator.ex:391),
  `get_or_create_for_project/1` (orchestrator.ex:147), `create_for_project/1`
  (orchestrator.ex:164), `project_harness/1` (orchestrator.ex:181). **Seed the new
  orchestrator's `metadata["agent_models"]` from the global default in
  `create_for_project/1`; add an `effective_agent_models/1` helper that merges the
  per-project roster over the global default; backfill empty rosters on
  `get_or_create_for_project/1`.** Must call into the new `RepoBuilder.Settings` context.
- `lib/repo_builder/orchestrator/tools.ex` — `RepoBuilder.Orchestrator.Tools`. The
  harness-blind MCP tool logic. `resolve_category/2` (tools.ex:195) errors when a tier
  has no model — **change to fall back to the global default before erroring**.
  `get_config/1` (tools.ex:938) builds `tiers` via `tier_view/2` (tools.ex:1196) — **extend
  to report effective model + `inherited?`**. `configure_tier/1` (tools.ex:961) already
  writes the per-project roster via `Orchestrators.set_agent_model/3` (keep). `create_agent/2`
  (tools.ex:115) and `command_agent/2` (tools.ex:288) consume the resolved model.
- `lib/repo_builder/orchestrator/tool_catalog.ex` — `ToolCatalog.tools/0`. The
  `configure_tier` (tool_catalog.ex:259) and `get_config` (tool_catalog.ex:251) tool
  descriptions — **update wording to state the roster is per-project and inherits from the
  global default** so the orchestrator agent understands the scoping.
- `lib/repo_builder/projects/project.ex` — `RepoBuilder.Projects.Project` schema; the
  dormant `default_model_tier` field (project.ex:60). **Decide its disposition (see Notes);
  no new columns required for the roster (it stays on the orchestrator).**
- `lib/repo_builder/projects.ex` — `RepoBuilder.Projects` context. `create_and_profile/1`
  (projects.ex:68) is the registration entry point; orchestrator creation (and thus the
  seed) happens lazily via `Orchestrators.get_or_create_for_project/1`. No change required
  unless we choose to eagerly create the orchestrator at registration (optional).
- `lib/repo_builder_web/live/console_live.ex` — `ConsoleLive`. `settings_tab` assign
  (console_live.ex:133); `select_settings_tab` handling; agent-models modal events
  `open_agent_models` (console_live.ex:1022) and `set_agent_model` (console_live.ex:1041);
  `agent_model_rows/1` (console_live.ex:406). **Add the new settings tab plumbing and its
  events (load/edit/save the global default roster), and surface inherited-vs-set state in
  the per-project agent-models modal rows.**
- `lib/repo_builder_web/components/console_components.ex` — settings modal
  (`settings_modal/1`, console_components.ex:1251) and its tab list
  (console_components.ex:1214); agent-models modal (`agent_models_modal/1`,
  console_components.ex:2613). **Add a "Default Models" settings tab panel and an
  inheritance indicator + "reset to default" control in the per-project roster modal.**
- `lib/repo_builder_web/live/projects_live.ex` — `ProjectsLive`. The `/projects/:id` show
  view currently edits only `command_pack`. **Add a per-project agent-models roster card
  (read effective roster, save overrides) using `Orchestrators` + `Settings`.**
- `config/config.exs` — `config :repo_builder, :orchestrator` (config.exs:291) and the
  `:harnesses` registry. **Add a `config :repo_builder, :default_agent_models, %{}`
  compile-time fallback** used when the DB has no setting yet (first boot / tests).
- `config/test.exs` — add a deterministic `:default_agent_models` (and/or Settings seed)
  so category-based spawning tests are stable.
- `priv/repo/migrations/` — new migration for the `app_settings` table (binary_id PK,
  unique `key`, JSONB `value`).
- `test/support/` — factories/fixtures for `Settings`/`Orchestrators` if present
  (`test/support/fixtures/*`); follow existing fixture conventions.

### Supporting docs (read before implementing)

- `BUILD_PROMPT.md` §3 (typed style guide), §8 (Ecto schemas/contexts/JSONB/migrations,
  binary_id), §9 (LiveView streams/components), §10 (open-identity harness doctrine —
  harness/provider stay open strings validated vs the registry).
- `ai_docs/typed-elixir-standard.md` — the enforced typed standard (always row).
- `AGENTS.md` — Phoenix v1.8 + LiveView + Ecto conventions (the only `Repo` caller is the
  context; `<.input>`/`to_form/2`; streams; `<Layouts.app>`).
- `.claude/commands/conditional_docs.md` — routing: Ecto schema/migration/context →
  `BUILD_PROMPT.md` §8; LiveView dashboard → §9; harness/provider → §10.

### New Files

- `lib/repo_builder/settings/app_setting.ex` — `RepoBuilder.Settings.AppSetting` Ecto
  schema (`use RepoBuilder.Schema`): `key :string` (unique), `value :map` (JSONB),
  timestamps. Hand-written `@type t`, `@enforce_keys` via schema, `changeset/2`.
- `lib/repo_builder/settings.ex` — `RepoBuilder.Settings` context (the ONLY `Repo` caller
  for `app_settings`). Public, `@spec`'d: `default_agent_models/0` (returns the roster map,
  falling back to `config :repo_builder, :default_agent_models`), `set_default_agent_model/4`
  (category, harness, provider, model — validated against `Orchestrators.agent_categories/0`
  and `Registry.known/0`), `set_default_agent_models/1`, and a typed roster type. Returns
  `{:ok, t()} | {:error, Ecto.Changeset.t() | reason()}`.
- `priv/repo/migrations/<timestamp>_create_app_settings.exs` — creates `app_settings`
  (binary_id PK, `add :key, :string, null: false`, `add :value, :map, default: %{}`,
  `timestamps`, `create unique_index(:app_settings, [:key])`). Generate via
  `mix ecto.gen.migration create_app_settings`.
- `test/repo_builder/settings_test.exs` — context unit tests (default fallback,
  set/override, category/harness validation, JSONB string-key round-trip).
- `test/repo_builder/orchestrator/per_project_models_test.exs` — seed-on-create,
  read-through fallback, per-project override isolation between two projects, and
  `resolve_category` no longer errors when a tier inherits the default.
- `test/repo_builder_web/live/test_per_project_agent_models_test.exs` — `Phoenix.LiveViewTest`
  integration: edit the global default in the Settings tab; register/switch projects and
  confirm the per-project roster shows inherited values; override one tier on `/projects/:id`
  and assert isolation + the rendered effective roster.

## Implementation Plan

### Phase 1: Foundation

Establish operator-editable global-default persistence. Create the `app_settings` table,
the `RepoBuilder.Settings.AppSetting` schema, and the `RepoBuilder.Settings` context with
a typed roster shape matching `orchestrators.metadata["agent_models"]`
(`%{category => %{"harness" => String.t(), "provider" => String.t() | nil, "model" => String.t()}}`).
`Settings.default_agent_models/0` reads the single `"default_agent_models"` row and falls
back to `config :repo_builder, :default_agent_models` when absent. Validate categories
against `Orchestrators.agent_categories/0` and harness against `Registry.known/0`
(open-identity rules, §10). Add the compile-time fallback config and a deterministic test
config.

### Phase 2: Core Implementation

Wire the default into the per-project roster lifecycle in `RepoBuilder.Orchestrators`:

- `create_for_project/1` seeds `metadata["agent_models"]` from `Settings.default_agent_models/0`.
- Add `effective_agent_models/1` (merge per-project roster over the global default) and a
  per-category `effective_agent_model/2` returning `{model_spec, :project | :default}` so
  callers can show inheritance.
- `get_or_create_for_project/1` backfills an empty roster from the default (covers
  pre-existing projects) without clobbering any explicit per-project entries.

Then update `RepoBuilder.Orchestrator.Tools`:

- `resolve_category/2` falls back to the global default for an unset tier before returning
  the "no model selected" error (so registration → immediate spawn works).
- `tier_view/2` / `get_config/1` report the effective model + `inherited?` boolean.
- `configure_tier/1` unchanged in behavior (still writes the per-project override via
  `set_agent_model/3`) but its catalog description clarifies per-project + inheritance.

### Phase 3: Integration

Surface everything in the LiveView UI:

- **Settings → Default Models tab** in `ConsoleLive` + `console_components.ex`: a form per
  tier (harness/provider/model selects driven by `Registry` + the pi live catalog already
  used by `get_config`'s `available_models`), saving via `Settings`.
- **Per-project agent-models modal** (console): rows show effective model with an
  "inherited from default" badge and a "reset to default" action (clears the per-project
  override so it re-inherits).
- **`/projects/:id` roster card** in `ProjectsLive`: read the project's effective roster
  and edit overrides via `Orchestrators.set_agent_model/3`, scoped to that project's
  orchestrator (`get_or_create_for_project/1`).
- Tests at every layer; final green-gate run.

## Step by Step Tasks

IMPORTANT: Execute every step in order, top to bottom.

### 1. Read the routing docs and confirm patterns
- Read `BUILD_PROMPT.md` §3, §8, §9, §10; `ai_docs/typed-elixir-standard.md`; the
  `.claude/commands/conditional_docs.md` rows for Ecto/LiveView/harness.
- Re-read `lib/repo_builder/orchestrator.ex` (`agent_models/1`, `set_agent_model/3`,
  `create_for_project/1`, `get_or_create_for_project/1`, `@agent_categories`) and
  `lib/repo_builder/orchestrator/tools.ex` (`resolve_category/2`, `tier_view/2`,
  `get_config/1`, `configure_tier/1`) to lock the exact shapes and `@spec`s to mirror.

### 2. Create the `app_settings` migration
- `mix ecto.gen.migration create_app_settings`.
- Body: binary_id PK, `add :key, :string, null: false`, `add :value, :map, default: %{}`,
  `timestamps(type: :utc_datetime_usec)`, `create unique_index(:app_settings, [:key])`.
- `mix ecto.migrate`.

### 3. Add the `RepoBuilder.Settings.AppSetting` schema
- New file `lib/repo_builder/settings/app_setting.ex`, `use RepoBuilder.Schema`.
- Hand-written `@type t :: %__MODULE__{...}` (no auto `t()`), `schema "app_settings"` with
  `field :key, :string` and `field :value, :map, default: %{}`, `timestamps()`.
- `@spec changeset(t(), map()) :: Ecto.Changeset.t()`; cast `[:key, :value]`,
  `validate_required([:key])`, `unique_constraint(:key)`.

### 4. Add the `RepoBuilder.Settings` context (the only `Repo` caller for `app_settings`)
- New file `lib/repo_builder/settings.ex`. Define a typed roster:
  `@type model_spec :: %{required(String.t()) => String.t() | nil}` and
  `@type roster :: %{optional(String.t()) => model_spec()}` (string keys = JSONB rule, §8).
- `@spec default_agent_models() :: roster()` — read the `"default_agent_models"` row's
  `value`; if missing, return `Application.get_env(:repo_builder, :default_agent_models, %{})`.
- `@spec set_default_agent_model(String.t(), String.t(), String.t() | nil, String.t()) :: {:ok, roster()} | {:error, term()}`
  — validate `category in Orchestrators.agent_categories()` (else `{:error, :invalid_category}`)
  and `harness in Registry.known()` (else `{:error, :unknown_harness}`); upsert the merged
  roster atomically (insert-or-update on `key`), returning the new roster.
- `@spec set_default_agent_models(roster()) :: {:ok, roster()} | {:error, Ecto.Changeset.t()}`
  for bulk save from the settings form.
- Add `@moduledoc` noting it is the single `Repo` caller for `app_settings` (§8).

### 5. Settings context unit tests
- New file `test/repo_builder/settings_test.exs`: default fallback returns the configured
  map when no row exists; set then read round-trips with string keys; invalid category /
  unknown harness rejected; bulk save replaces the roster. `async: true`.
- `mix test test/repo_builder/settings_test.exs`.

### 6. Add compile-time + test fallback config
- `config/config.exs`: add `config :repo_builder, :default_agent_models, %{}` (empty = no
  fallback in dev/prod until the operator sets it; documented).
- `config/test.exs`: add a deterministic `:default_agent_models` covering all four
  categories with the `fake` harness (so category spawning tests are stable without
  touching the DB).

### 7. Seed + inherit in `RepoBuilder.Orchestrators`
- In `create_for_project/1`, set the new orchestrator's `metadata` to include
  `"agent_models" => RepoBuilder.Settings.default_agent_models()` (preserve any other
  metadata keys).
- Add `@spec effective_agent_models(Orchestrator.t()) :: map()` merging
  `Settings.default_agent_models()` (base) with the orchestrator's roster (override).
- Add `@spec effective_agent_model(Orchestrator.t(), String.t()) :: {map() | nil, :project | :default}`.
- In `get_or_create_for_project/1`, when an existing orchestrator's `agent_models` is
  empty, backfill from the default (without overwriting explicit entries).
- Keep `set_agent_model/3` as the per-project override seam; add `clear_agent_model/2`
  (`@spec`) to delete a category override so it re-inherits the default (for the "reset"
  control).

### 8. Orchestrator unit tests (seed, inherit, isolation)
- New file `test/repo_builder/orchestrator/per_project_models_test.exs`: creating an
  orchestrator for a project seeds the roster from the default; overriding one tier on
  project A does not change project B; `effective_agent_models/1` reflects override>default;
  `clear_agent_model/2` re-inherits. `async: true`.
- `mix test test/repo_builder/orchestrator/per_project_models_test.exs`.

### 9. Read-through fallback + effective tier view in `Tools`
- `resolve_category/2`: when the orchestrator roster entry for the category is missing or
  has a blank model, fall back to `Settings.default_agent_models()[category]` (or
  `Orchestrators.effective_agent_model/2`) before returning `"no model selected"`.
- `tier_view/2` / `get_config/1`: include `model`, `harness`, `provider`, and
  `inherited?` (true when the value came from the default, not the per-project roster).
- Confirm `create_agent` (category path) now succeeds immediately after registration by a
  tools-level test (extend an existing `tools` test or add one) asserting no
  "no model selected" error when only the default is configured.

### 10. Update the MCP tool catalog wording
- In `tool_catalog.ex`, edit the `configure_tier` and `get_config` descriptions to state
  the roster is **per-project** (scoped to the orchestrator's bound project) and that
  unset tiers **inherit the global default**. No schema/shape change.

### 11. LiveView integration test (write before the UI is wired — TDD)
- New file `test/repo_builder_web/live/test_per_project_agent_models_test.exs` using
  `Phoenix.LiveViewTest`:
  - Mount `ConsoleLive` (`live/2`), open settings, switch to the Default Models tab
    (`element/2` on the tab id), submit the form to set a tier's model, assert it persisted
    (re-render shows the value / `Settings.default_agent_models/0` reflects it).
  - With a registered project selected, open the agent-models modal and assert tiers render
    the inherited default with an "inherited" indicator (key element ids).
  - Mount `ProjectsLive` show for a project, override one tier via the roster card form, and
    assert the rendered effective roster updates and that a second project still shows the
    default (isolation). Assert via `has_element?/2` on stable ids, not raw HTML.
- Run it red first to confirm it drives the not-yet-built UI.

### 12. Add the Settings → Default Models tab
- `console_live.ex`: add `:default_models` to the settings-tab handling; add assigns for
  the default roster form (`to_form/2`) and harness/provider/model option lists (reuse the
  registry + pi-catalog source already used by `get_config`'s `available_models`); add
  `save_default_agent_model` (or a single form submit) event calling `Settings`.
- `console_components.ex`: add `:default_models` to the settings tab list
  (console_components.ex:1214) and a panel rendering one `<.input>`-driven row per tier with
  unique DOM ids; save via the new event. Keep `<Layouts.app>` wrapping intact.

### 13. Per-project roster modal: inheritance indicator + reset
- `console_components.ex` `agent_models_modal/1`: for each tier row, show the effective
  model and a badge when `inherited?`, plus a "reset to default" button.
- `console_live.ex`: `agent_model_rows/1` uses `Orchestrators.effective_agent_models/1` and
  passes `inherited?`; add a `clear_agent_model` event → `Orchestrators.clear_agent_model/2`
  then `restream`/reassign. Keep the existing `set_agent_model` event as the override path.

### 14. `/projects/:id` per-project roster card
- `projects_live.ex` show: load the project's orchestrator
  (`Orchestrators.get_or_create_for_project/1`) and its `effective_agent_models/1`; render a
  card with one form row per tier (unique ids), saving overrides via
  `Orchestrators.set_agent_model/3` and resetting via `clear_agent_model/2`. Read-only model
  data only — no `Repo`/`Ecto.Query` in the LiveView.

### 15. Dispose of the dormant `default_model_tier` field
- Per Notes: either remove `default_model_tier` from `project.ex` (schema + changeset) with
  a drop-column migration, or repurpose it as the per-project "default category for ad-hoc
  spawns". Default decision: **leave the column but stop casting it** is not allowed under
  the standard (dead field); choose removal unless a use is wired. Implement the chosen
  option and note it.

### 16. Make the LiveView integration test pass
- Run `mix test test/repo_builder_web/live/test_per_project_agent_models_test.exs` green.

### 17. Run the full Validation Commands
- Run every command in the Validation Commands section and fix all issues to zero
  failures/warnings.

## Testing Strategy

### Unit Tests
- **`RepoBuilder.Settings`**: default fallback to config when no DB row; set/override one
  category; bulk save; invalid category and unknown harness rejected with tagged errors;
  JSONB string-key round-trip (no atom keys).
- **`RepoBuilder.Orchestrators`**: `create_for_project/1` seeds the roster from the default;
  `effective_agent_models/1` merges override over default; `effective_agent_model/2` reports
  the right source (`:project` vs `:default`); `clear_agent_model/2` re-inherits;
  `get_or_create_for_project/1` backfills an empty roster but never clobbers explicit
  entries; per-project isolation (project A override doesn't affect project B).
- **`RepoBuilder.Orchestrator.Tools`**: `resolve_category/2` returns a spec via the global
  default when a tier is unset (no error); explicit per-project override wins over the
  default; `tier_view/2`/`get_config/1` include `inherited?`.

### Edge Cases
- New project with **no** global default configured (empty map) → category spawn still
  returns the clear "no model selected" error (fallback exhausted), not a crash.
- Pre-existing project created before this feature (empty roster) → backfill/read-through
  makes category spawns work without a manual edit.
- Global default changed **after** a project was seeded → seeded projects keep their seeded
  values (explicit), while projects relying on inheritance (unset tiers) pick up the new
  default. Document this distinction in the roster modal copy.
- Unknown/unregistered harness or invalid category submitted from the UI or `configure_tier`
  → rejected at the `Settings`/`Orchestrators` boundary with `{:error, _}`, surfaced as a
  flash, never a raw Postgrex/`Ecto` exception.
- Concurrent `configure_tier` for two categories on the same project → both persist (the
  existing `FOR UPDATE` merge in `set_agent_model/3` must be preserved).
- `nil` provider (e.g. claude default provider) round-trips through JSONB and the form.
- Platform orchestrator (`project_id: nil`) still works and seeds/inherits like any other.

## Acceptance Criteria
- A new `app_settings` table exists; `RepoBuilder.Settings` is the only module touching it.
- The Settings modal has a **Default Models** tab where the operator sets a
  `{harness, provider, model}` per tier (`fast`/`main`/`heavy`/`leader`); the value persists
  and is read by `Settings.default_agent_models/0`.
- Registering a new project and selecting it shows a tier roster pre-populated from the
  global default (inherited), with no manual configuration required to spawn category
  workers.
- Overriding a tier for one project (via the console modal, `/projects/:id` card, or the
  `configure_tier` MCP tool) changes only that project's roster; other projects are
  unaffected.
- `create_agent` with a `category` succeeds immediately after registration when only the
  global default is configured (no "no model selected" error); explicit per-project
  overrides take precedence over the default.
- `get_config` reports each tier's effective model with an `inherited?` flag.
- A "reset to default" action clears a per-project override so the tier re-inherits.
- The dormant `projects.default_model_tier` field is resolved (removed or wired) — no dead
  cast remains.
- The LiveView integration test passes and the full green gate is clean.

## Validation Commands

Execute every command to validate the feature works correctly with zero regressions.

- `mix ecto.migrate` — apply the new `app_settings` migration cleanly.
- `mix test test/repo_builder/settings_test.exs` — Settings context unit tests.
- `mix test test/repo_builder/orchestrator/per_project_models_test.exs` — seed/inherit/override/isolation tests.
- `mix test test/repo_builder_web/live/test_per_project_agent_models_test.exs` — LiveView integration test for the settings tab, inheritance, and per-project override.
- `mix compile --warnings-as-errors` — compile clean; gradual set-theoretic checker + `warnings_as_errors` pass.
- `mix test --warnings-as-errors` — full ExUnit suite (Postgres-backed) with zero failures.
- `mix format --check-formatted` — formatting.
- `mix credo --strict` — lint, incl. `@spec` on every public function.
- `mix dialyzer` — `@spec`/contract checking, no new warnings, no stale ignore filters.

Runtime validation via Tidewave (`http://localhost:4000/tidewave/mcp`):
- `project_eval`:
  `RepoBuilder.Settings.default_agent_models()` → confirm the configured default roster.
  `p = RepoBuilder.Projects.create_and_profile(%{"name" => "tw-demo", "root_path" => File.cwd!()}); o = RepoBuilder.Orchestrators.get_or_create_for_project(elem(p,1).id); RepoBuilder.Orchestrators.effective_agent_models(o)`
  → confirm the new project's orchestrator inherits the default roster.
- `execute_sql_query`: `SELECT key, value FROM app_settings;` → confirm the persisted
  default roster; `SELECT id, project_id, metadata->'agent_models' AS roster FROM orchestrators;`
  → confirm per-project rosters seeded/overridden as expected.
- `get_logs` after a `create_agent`/`command_agent` round-trip to confirm no
  "no model selected" errors and no unredacted secrets.

## Notes

- **No new dependency.** This uses existing Ecto/Phoenix/LiveView only.
- **Where the roster lives.** The per-project roster intentionally stays on
  `orchestrators.metadata["agent_models"]` (one orchestrator per project, partial-unique
  `project_id`) rather than moving to a new `projects` column — this reuses the existing
  `agent_models/1` / `set_agent_model/3` seam, the console modal, and the `configure_tier`
  MCP tool with minimal churn. The only genuinely new persistence is the **global default**
  in `app_settings`.
- **Inheritance model (decision).** Seed at orchestrator-creation **and** read-through at
  resolve time. Seeding makes a new project's roster concrete and visible; read-through
  covers pre-existing/empty rosters and any tier left unset, and lets unset tiers track
  later changes to the global default. This belt-and-suspenders is deliberate; document it
  in the roster modal copy so the "seeded vs inherited" behavior is not surprising.
- **`projects.default_model_tier` disposition.** It is currently dead. Recommended:
  **remove it** (schema + changeset + a `drop column` migration) to keep the standard's
  "no dead field" rule, since the four-tier roster fully covers model allocation. If a
  future "which tier do ad-hoc spawns use" knob is wanted, prefer adding it deliberately
  later rather than leaving the unused column. Confirm the choice with the operator if
  unsure; default to removal.
- **Open-identity rules (§10).** `harness`/`provider` remain open strings validated against
  `Registry.known()` — do not introduce a closed enum for them anywhere in this feature.
- **Security.** No secrets are added; model ids are non-sensitive. Keep the existing
  redaction path untouched.
- **Out of scope.** Changing the orchestrator's *own* brain model
  (`set_orchestrator_config`) and the per-template `model` defaults — those remain as-is;
  this feature is strictly about the worker tier roster and its global default.
