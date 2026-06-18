# Feature: Cost Center settings tab

## Metadata
issue_number: `Center`
adw_id: `settings`
issue_json: `tab`

## Feature Description

Add a **Cost Center** tab to the console Settings modal that lets an operator both
**observe** and **manage** AI spend, organized by `(harness, provider, model)`.

The tab has two stacked sections:

1. **Recent spend rollup (observability).** A table of actual cost and token usage
   aggregated by `(harness, provider, model)`, ordered by most-recent activity
   (the "recent harness/provider/model" the user asked for). Each row shows
   summed `cost_usd`, input/output tokens, event count, and last-used time. Rows
   whose actual cost is unknown (`nil` — unpriced harnesses like `pi`) show an
   **estimated** cost derived from the price catalog, clearly labelled as an
   estimate rather than a billed amount.

2. **Price catalog (management).** A small editable table of per-model rates
   (`input_price_per_mtok`, `output_price_per_mtok`) keyed by
   `(harness, provider, model)`. This catalog is **stored in Postgres and seeded
   from a checked-in file** so it never starts from scratch, and it becomes the
   source of truth the `pi` (and any other unpriced) harness consults to derive
   `cost_usd`, with the existing `config/config.exs` `price_table` as a fallback.

### Architecture decision (answers the user's open question)

> *"shall I be using a postgres db, seeded by a file (so I don't start from scratch)?"*

**Two distinct data concerns, two distinct stores — this is the crux of the design:**

- **Cost ACTUALS** (what was already spent) are **already in Postgres** and need
  **no new table**: every cost-bearing canonical `Usage`/`Done` event is persisted
  as an `agent_logs` row with an embedded `Usage` value object
  (`cost_usd`, tokens). We aggregate those existing rows. The only gap is that
  `agent_logs` records `harness` but **not** `provider`/`model`, so we add two
  nullable snapshot columns (`provider`, `model`) captured at write time. This
  gives time-correct attribution (a `GROUP BY` instead of a fragile join to the
  owner's *current* identity, which mutates via `set_model`/`set_provider`).

- **Price RATES** (the catalog, the "don't start from scratch" part) **are** the
  right thing to put in a **Postgres table seeded from a file**. Rates are
  reference data the operator wants pre-populated and then editable; a seeded
  `model_prices` table delivers exactly that. The seed is idempotent (upsert by
  unique key) so re-running `mix ecto.setup` / the seed never duplicates or
  clobbers operator edits beyond the seeded keys.

So: **actuals = aggregate existing `agent_logs` (no new table); rates = a new
Postgres `model_prices` table seeded from `priv/repo/pricing_seeds.exs`.**

## User Story

As an **operator running multi-harness AI orchestrations**
I want to **see recent cost broken down by harness/provider/model and edit the
per-model price rates from a Cost Center settings tab**
So that **I can understand and control spend across providers, and so unpriced
harnesses (e.g. `pi`) report meaningful cost without me editing config and
redeploying.**

## Problem Statement

Cost is surfaced today only as flat scalars — a header "Cost" pill, per-agent
card footers, and the orchestrator's lifetime `total_cost_usd`
(`report_cost` tool). There is **no breakdown by harness/provider/model** and **no
way to see which provider/model is driving spend**. Worse:

- `pi` and other harnesses that do **not** report USD leave `cost_usd` as `nil`
  unless the exact model is present in the hard-coded `config/config.exs`
  `price_table`. Adding a price means editing config and restarting — not
  operator-manageable.
- The orchestrator's `total_cost_usd`/token counters are **flat lifetime sums**
  with no per-model segmentation; switching provider/model mid-life loses
  attribution entirely.
- `agent_logs` (the correct per-event grain for time-segmented cost) stores
  `harness` but neither `provider` nor `model`, so even aggregating existing rows
  can't attribute to a model without an unreliable join to the owner's *current*
  identity.

## Solution Statement

1. **Snapshot `provider` + `model` onto `agent_logs`** at persist time (two
   nullable columns) so cost can be grouped by `(harness, provider, model)` with a
   correct, time-stable `GROUP BY`. Backfill existing rows best-effort from the
   owner FK.
2. **Add a seeded `model_prices` Postgres table** + a `RepoBuilder.CostCenter`
   context that (a) manages the catalog (list/upsert/delete), (b) seeds it
   idempotently from `priv/repo/pricing_seeds.exs`, and (c) produces the rollup
   aggregation by dimension.
3. **Make `model_prices` the price source for derivation**: build the per-harness
   `price_table` from the DB catalog (config `price_table` as fallback) where the
   session runtime currently reads it, so operator edits affect future `pi` cost
   without a redeploy.
4. **Add the `:cost_center` Settings tab** rendering the rollup table and the
   editable catalog, following the existing `settings_tab` / `select_settings_tab`
   pattern exactly.

## Relevant Files

Use these files to implement the feature:

- `BUILD_PROMPT.md` — authoritative spec; §3 typed style guide, §4.1 `cost_usd`
  nil-vs-0.0 + float→Decimal boundary, §8 persistence/contexts-only-touch-`Repo`,
  §9 LiveView/streams/reconnect, §13 testing. **Read before starting.**
- `AGENTS.md` — Phoenix v1.8 + LiveView guidelines (`<Layouts.app>`, `to_form`,
  streams, `<.input>`, no daisyUI, no `String.to_atom/1` on input).
- `.claude/commands/conditional_docs.md` — routing map; matched rows for this
  task: the **(always)** typed standard row (`ai_docs/typed-elixir-standard.md`),
  the Ecto/JSONB/Decimal row (`BUILD_PROMPT.md` §8), and the LiveView row
  (`BUILD_PROMPT.md` §9).
- `ai_docs/typed-elixir-standard.md` — enforced typed standard (rule 6 wire≠domain,
  rule 10 float→Decimal). **Always applies (public fns, structs, schema).**
- `config/config.exs` — `:harnesses` registry with per-harness `price_table`
  (`pi => %{"glm-4.6" => 0.6, "glm-4.5-air" => 0.2}`, others `%{}`). The seed
  derives initial catalog rows from here; the catalog becomes the override layer.
- `lib/repo_builder/harness/pricing.ex` — `Pricing.derive/4` (combined
  per-Mtok rate over `input+output`; `nil` when unpriced). **Unchanged signature**;
  the catalog feeds the `price_table` it receives.
- `lib/repo_builder/harness/pi.ex:73,295` — builds `ctx.price_table` and calls
  `Pricing.derive/4`. No change here; the table is supplied upstream.
- `lib/repo_builder/session/server.ex:138` — `price_table: Map.get(config, :price_table, %{})`.
  **The single integration point** to merge the DB catalog over config defaults.
- `lib/repo_builder/logs/usage.ex` — embedded `Usage` value object (the
  float→Decimal boundary); reused as-is by the rollup.
- `lib/repo_builder/logs/agent_log.ex` — `agent_logs` schema; **add `provider`
  + `model` columns + changeset casts**.
- `lib/repo_builder/logs.ex` — `persist_event/2` + `persist_orchestrator_event/2`;
  **capture `provider`/`model` from `attrs` into the row params**. Also the
  existing home of `cost_rollup!/1` — the new dimensional rollup lives in the new
  `CostCenter` context (its grain spans owners), not here.
- `lib/repo_builder/session/server.ex:394-470` & `lib/repo_builder/orchestrator/server.ex:97`
  — persist callers; **thread `provider`/`model`** into the `attrs` map from
  session/orchestrator state.
- `lib/repo_builder/orchestrator/orchestrator.ex` — `orchestrators` schema
  (`harness`/`provider`/`model` available for the orchestrator snapshot + backfill join).
- `lib/repo_builder/agents/agent.ex` — `agents` schema (`harness`/`provider`/`model`
  available for the worker snapshot + backfill join).
- `lib/repo_builder/schema.ex` — `use RepoBuilder.Schema` macro (binary_id + utc
  timestamps) for the new `ModelPrice` schema.
- `lib/repo_builder_web/live/console_live.ex` — `:settings_tab` assign
  (`:101`), `select_settings_tab` handler (`:824`), `settings_tab/1` guard
  (`:2068-2073`), `<.settings_modal .../>` render (`:1898-1914`). **Add the new
  tab, its data assigns, and catalog-edit event handlers.**
- `lib/repo_builder_web/components/console_components.ex` — `settings_modal/1`
  (`:818-1175`), `settings_tab` attr `values:` (`:789-791`), tab rail
  (`:839-843`), `settings_tab_button/1` (`:1182`), `settings_field/1` (`:1201`).
  **Add the `:cost_center` tab button, panel, and render components.**
- `lib/repo_builder_web/components/dashboard_components.ex:194-200` — `cost_badge/1`
  (renders `"—"` for `nil`, `"$X.XX"` otherwise); reuse for cost cells.
- `priv/repo/seeds.exs` — calls the idempotent catalog seed so `mix ecto.setup`
  populates `model_prices`.
- `test/support/session_case.ex`, `test/support/data_case.ex`,
  `test/support/conn_case.ex` — test cases for context + LiveView tests.
- `test/repo_builder/orchestrator/cost_report_test.exs` — existing cost test
  patterns to mirror.

### New Files

- `priv/repo/migrations/<ts>_add_provider_model_to_agent_logs.exs` — add nullable
  `provider`/`model` columns to `agent_logs` (+ best-effort backfill from the owner
  FK), and an index on `(harness, provider, model)` to keep the rollup `GROUP BY`
  fast.
- `priv/repo/migrations/<ts>_create_model_prices.exs` — `model_prices` table
  (binary_id, `harness`, `provider` default `""`, `model`, `input_price_per_mtok`
  `:decimal`, `output_price_per_mtok` `:decimal`, `source` enum, timestamps) with a
  unique index on `(harness, provider, model)`.
- `lib/repo_builder/cost_center/model_price.ex` — `RepoBuilder.CostCenter.ModelPrice`
  Ecto schema (`use RepoBuilder.Schema`, `@type t`, `@enforce_keys` via schema,
  `changeset/2`).
- `lib/repo_builder/cost_center/rollup.ex` — `RepoBuilder.CostCenter.Rollup`
  `typedstruct` value object for one aggregated `(harness, provider, model)` row
  (actual + estimated cost, tokens, count, `last_used_at`). Pure data, no `Repo`.
- `lib/repo_builder/cost_center.ex` — `RepoBuilder.CostCenter` context: the **only**
  `Repo` caller for `model_prices` + the dimensional rollup query. Public:
  `list_prices/0`, `get_price/3`, `upsert_price/1`, `delete_price/1`,
  `price_table_for/1`, `seed_prices/0`, `rollup/1`.
- `priv/repo/pricing_seeds.exs` — checked-in initial catalog data (derived from
  config `price_table`s + well-known model rates); invoked by `CostCenter.seed_prices/0`.
- `test/repo_builder/cost_center_test.exs` — context unit tests (seed idempotency,
  upsert/delete, `price_table_for/1`, rollup grouping + estimate logic, nil-vs-0
  cost handling).
- `test/repo_builder_web/live/test_cost_center_tab_test.exs` — `Phoenix.LiveViewTest`
  integration test: open settings, switch to Cost Center, assert the rollup table
  and catalog render, drive a price upsert, assert the row updates.

## Implementation Plan

### Phase 1: Foundation

Establish the data model so cost can be attributed by dimension and rates can be
stored/seeded.

- Migration + schema change to **snapshot `provider`/`model` on `agent_logs`**,
  with a best-effort backfill of existing rows from the owner FK
  (`agents`/`orchestrators`) and a supporting index.
- Thread `provider`/`model` through `Logs.persist_event/2` /
  `persist_orchestrator_event/2` and their two callers.
- Migration + `ModelPrice` schema for the seeded **`model_prices`** catalog.

### Phase 2: Core Implementation

Build the `RepoBuilder.CostCenter` context (catalog CRUD, seeding, price-table
construction, dimensional rollup) and its typed `Rollup` value object, plus the
seed file and `seeds.exs` wiring. All `Repo` access stays in this context (§8).

### Phase 3: Integration

- Wire the catalog into cost **derivation**: build the session runtime's
  `price_table` from `CostCenter.price_table_for/1` merged over the config default
  (one line at `session/server.ex:138`), so operator edits affect future cost.
- Add the **`:cost_center` Settings tab**: tab button, panel rendering the rollup
  + editable catalog, console_live assigns/handlers, mirroring the existing
  settings-tab mechanism. LiveView integration test + green gate.

## Step by Step Tasks

IMPORTANT: Execute every step in order, top to bottom.

### 1. Read the authoritative docs

- Read `BUILD_PROMPT.md` §3 (typed style), §4.1 (`cost_usd` nil-vs-0.0,
  float→Decimal), §8 (persistence, contexts-only-`Repo`), §9 (LiveView/streams),
  §13 (testing).
- Read `ai_docs/typed-elixir-standard.md` (rules 6 + 10).
- Confirm conventions in `AGENTS.md` (no `String.to_atom/1` on input; `to_form/2`
  + `<.input>`; `<Layouts.app>`; streams for collections).

### 2. Migration: snapshot provider/model on `agent_logs`

- Generate with `mix ecto.gen.migration add_provider_model_to_agent_logs`.
- `alter table(:agent_logs)`: `add :provider, :string` (nullable),
  `add :model, :string` (nullable).
- Add `create index(:agent_logs, [:harness, :provider, :model])`.
- **Best-effort backfill** existing rows in the migration's `up` via raw SQL
  `UPDATE ... FROM agents/orchestrators` (two statements, one per owner FK),
  setting `provider`/`model` from the current owner identity. Wrap so it is a
  no-op when tables are empty. Keep `down` dropping the index + columns.

### 3. Update `AgentLog` schema + changeset

- Add `field :provider, :string` and `field :model, :string` to
  `lib/repo_builder/logs/agent_log.ex`.
- Extend `@type t` with `provider: String.t() | nil`, `model: String.t() | nil`.
- Add `:provider, :model` to the `cast/3` field list in `changeset/2` (they are
  optional — no `validate_required`).

### 4. Capture provider/model in `Logs.persist_event/2` + `persist_orchestrator_event/2`

- In `lib/repo_builder/logs.ex`, add `provider: attrs[:provider]` and
  `model: attrs[:model]` to the `params` map in both functions.
- Widen the `persist_orchestrator_event/2` `@spec` attrs map to include
  `optional(:provider) => String.t() | nil, optional(:model) => String.t() | nil`
  (and likewise document `persist_event/2`'s `map()` attrs accept them).
- Keep behavior tolerant: missing keys → `nil` columns (no crash, degrades to
  "unknown" in the rollup).

### 5. Thread provider/model from the persist callers

- `lib/repo_builder/session/server.ex` (`:452`, `:463`): add `provider:`/`model:`
  to the `attrs` maps from the session `%State{}` (it carries the worker `model`;
  source `provider` from the agent row/config available in state — verify the
  field; if provider isn't in state, load it once at init and store it, or pass
  `nil` and rely on backfill/join — prefer threading the real value).
- `lib/repo_builder/orchestrator/server.ex` (`:97`): add `provider:`/`model:` from
  the orchestrator struct already in scope (`orch.provider`, `orch.model`).
- Run `mix compile --warnings-as-errors` to confirm the gradual type checker is
  happy with the widened attrs.

### 6. Migration: `model_prices` catalog table

- `mix ecto.gen.migration create_model_prices`.
- `create table(:model_prices, primary_key: false)` with binary_id PK + utc
  timestamps (match `RepoBuilder.Schema` conventions used elsewhere).
- Columns: `harness :string null: false`, `provider :string null: false,
  default: ""` (empty = harness-default/unspecified; keeps the unique index +
  upsert clean since SQL NULLs are distinct), `model :string null: false`,
  `input_price_per_mtok :decimal`, `output_price_per_mtok :decimal`,
  `source :string null: false, default: "seed"` (`"seed" | "manual"`).
- `create unique_index(:model_prices, [:harness, :provider, :model])`.

### 7. `ModelPrice` schema

- Create `lib/repo_builder/cost_center/model_price.ex`:
  `defmodule RepoBuilder.CostCenter.ModelPrice` `use RepoBuilder.Schema`.
- `@type source :: :seed | :manual`; `@type t` listing every field with concrete
  types (`Decimal.t() | nil` for the prices).
- `field :source, Ecto.Enum, values: [:seed, :manual], default: :seed`.
- `@spec changeset(t(), map()) :: Ecto.Changeset.t()`: cast all fields,
  `validate_required([:harness, :model])`, `validate_number/2` on the two prices
  (≥ 0), `validate_inclusion(:harness, Registry.known())`,
  `unique_constraint([:harness, :provider, :model], name: ...)`. Normalize a `nil`
  provider to `""` in the changeset so the unique key is stable.

### 8. `Rollup` value object

- Create `lib/repo_builder/cost_center/rollup.ex` with `use TypedStruct`,
  `typedstruct enforce: true`: fields `harness :: String.t()`,
  `provider :: String.t()`, `model :: String.t() | nil`,
  `actual_cost_usd :: Decimal.t()` (sum of priced rows; `0` if none),
  `estimated? :: boolean()` (true when some rows were unpriced and an estimate was
  computed), `estimated_cost_usd :: Decimal.t() | nil`,
  `input_tokens :: non_neg_integer()`, `output_tokens :: non_neg_integer()`,
  `event_count :: non_neg_integer()`, `last_used_at :: DateTime.t()`.
- No `Repo` access here — pure data.

### 9. `CostCenter` context — catalog CRUD + seeding

- Create `lib/repo_builder/cost_center.ex` (`@moduledoc` noting it is the sole
  `Repo` caller for `model_prices` + the dimensional rollup, per §8).
- `@spec list_prices() :: [ModelPrice.t()]` — all rows, ordered
  `harness, provider, model`.
- `@spec get_price(String.t(), String.t(), String.t()) :: ModelPrice.t() | nil`.
- `@spec upsert_price(map()) :: {:ok, ModelPrice.t()} | {:error, Ecto.Changeset.t()}`
  — `Repo.insert` with `on_conflict: {:replace, [...]}, conflict_target:
  [:harness, :provider, :model]`; manual edits set `source: :manual`.
- `@spec delete_price(Ecto.UUID.t()) :: {:ok, ModelPrice.t()} | {:error, term()}`.
- `@spec price_table_for(String.t()) :: %{optional(String.t()) => number()}` —
  build the combined per-Mtok `%{model => rate}` map for a harness from the
  catalog, for the `Pricing.derive/4` shape. (Derive uses a single combined rate
  over `input+output`; map a catalog row to a representative combined rate —
  e.g. prefer `output_price_per_mtok`, else `input_price_per_mtok`. Document the
  choice in the `@doc`.)
- `@spec seed_prices() :: {:ok, non_neg_integer()}` — idempotent upsert of every
  row from `priv/repo/pricing_seeds.exs` (only writes `source: :seed` keys; never
  clobbers a `:manual` row — guard the upsert's `on_conflict` so manual edits win).

### 10. Dimensional rollup query

- `@spec rollup(keyword()) :: [Rollup.t()]` in `CostCenter` with opts
  `:limit` (default e.g. 50, clamped) and `:include_hidden?` (default `false`,
  reuse the `hidden` semantics).
- Query `agent_logs` where `usage` is present (has tokens or cost), `GROUP BY
  harness, provider, model`, selecting: `sum(cost_usd)` (only non-null →
  `actual_cost_usd`), `sum(input_tokens)`, `sum(output_tokens)`, `count(*)`,
  `max(inserted_at) AS last_used_at`. Order by `last_used_at DESC` ("recent").
  Use `fragment`/`coalesce` as needed; keep all query code in this context.
- For each grouped row, compute `estimated_cost_usd` via `price_table_for/1` over
  the summed tokens **only when** `actual_cost_usd` is zero/absent and a catalog
  price exists; set `estimated? = true` in that case. Preserve the nil-vs-0
  distinction (no price ⇒ `estimated_cost_usd: nil`, `estimated?: false`).
- Map each grouped result into a `%Rollup{}`.

### 11. Seed file + `seeds.exs` wiring

- Create `priv/repo/pricing_seeds.exs` returning a list of price maps (harness,
  provider, model, input/output rate). Seed from config `price_table`s
  (`pi` GLM models) plus a few well-known anchors (e.g. claude models) so the
  catalog is useful immediately. Keep it data-only.
- In `priv/repo/seeds.exs`, call `RepoBuilder.CostCenter.seed_prices()` so
  `mix ecto.setup`/`mix ecto.reset` populate `model_prices` idempotently.

### 12. Integrate the catalog into derivation

- In `lib/repo_builder/session/server.ex:138`, replace
  `price_table: Map.get(config, :price_table, %{})` with a merge:
  config defaults first, DB catalog (`CostCenter.price_table_for(harness)`)
  overriding. Resolve the harness string available at that point. Keep it a pure
  read; on any error fall back to the config table (never crash a session start).
- Add/adjust a `Pricing`-path test confirming a catalog entry produces a derived
  `cost_usd` where config alone would have left it `nil`.

### 13. Add the `:cost_center` settings tab — components

- `lib/repo_builder_web/components/console_components.ex`:
  - Add `:cost_center` to the `settings_tab` attr `values:` list (`~:789-791`).
  - Add `<.settings_tab_button tab={:cost_center} active={@settings_tab}
    label="Cost Center" />` to the tab rail (`~:843`).
  - Add a `<div :if={@settings_tab == :cost_center}>` panel after the About panel.
  - Add new `attr`s to `settings_modal/1` for `:cost_rollups` (list of `Rollup`),
    `:price_rows` (list of `ModelPrice`), and `:price_form` (a `to_form/2` form).
  - Write a `cost_rollup_table/1` component (reuse `cost_badge/1` for cost cells;
    label estimated cost distinctly, e.g. a `~"est."` suffix/badge) and a
    `price_catalog_table/1` component with an inline `<.form id="price-form"
    for={@price_form} phx-submit="upsert_price">` using `<.input>` for each field
    and a per-row delete button (`phx-click="delete_price"
    phx-value-id={...}`). Give every interactive element a stable DOM id.

### 14. Wire console_live assigns + handlers

- `lib/repo_builder_web/live/console_live.ex`:
  - Extend `@spec settings_tab/1` union and add
    `defp settings_tab("cost_center"), do: :cost_center` (`~:2068-2073`).
  - On mount (and when the Cost Center tab is selected), assign `:cost_rollups`,
    `:price_rows`, and `:price_form` from `CostCenter`. To avoid loading on every
    mount, load lazily in the `select_settings_tab` handler when `tab ==
    "cost_center"` (or `assign_async` for the rollup — note in the test that the
    async result resolves).
  - Add `handle_event("upsert_price", %{"model_price" => params}, socket)` →
    `CostCenter.upsert_price/1`, then re-assign `:price_rows`/`:cost_rollups` and
    reset `:price_form`; on error re-assign the form with the changeset.
  - Add `handle_event("delete_price", %{"id" => id}, socket)` →
    `CostCenter.delete_price/1`, then re-assign.
  - Pass the new assigns into `<.settings_modal .../>` (`~:1898-1914`).
  - Keep all DB access via `CostCenter` (no `Repo`/`Ecto.Query` in the LiveView).

### 15. LiveView integration test

- Create `test/repo_builder_web/live/test_cost_center_tab_test.exs`
  (`use RepoBuilderWeb.ConnCase`, import `Phoenix.LiveViewTest`).
- Seed a couple of `model_prices` and a couple of cost-bearing `agent_logs` rows
  (with `harness`/`provider`/`model`/`usage`) via the contexts/fixtures.
- `live(conn, "/")`, open settings, `render_click` the
  `select_settings_tab` button for `cost_center`, assert the rollup table
  (`has_element?(view, "#cost-rollup-table")`) and at least one grouped row
  render with the expected harness/model, and that an unpriced row shows the
  estimated-cost marker.
- Drive `render_submit` on `#price-form` to upsert a price; assert the catalog
  table reflects it (`has_element?/2` on the new row). Drive `delete_price` and
  assert removal.
- Optionally capture a Playwright/Tidewave-vision screenshot of
  `http://localhost:4000` with the Cost Center tab open as visual proof.

### 16. Context unit tests

- Create `test/repo_builder/cost_center_test.exs` (`use RepoBuilder.DataCase`):
  - `seed_prices/0` is idempotent (run twice → same count, no dup) and does not
    clobber a `:manual` row.
  - `upsert_price/1` inserts then updates on conflict; `:manual` source set on edit.
  - `delete_price/1` happy + missing-id paths.
  - `price_table_for/1` returns the expected `%{model => rate}` shape.
  - `rollup/1` groups by `(harness, provider, model)`, sums cost only for priced
    rows, computes an estimate for unpriced rows that have a catalog price, leaves
    `estimated_cost_usd: nil` when no price exists (nil-vs-0 preserved), orders by
    `last_used_at DESC`, and honors `:include_hidden?`.

### 17. Run the validation commands

- Run every command in **Validation Commands** and fix any failure until the full
  green gate passes with zero regressions.

## Testing Strategy

### Unit Tests
- `CostCenter` context: seed idempotency + manual-preserving upsert; CRUD;
  `price_table_for/1` shape; `rollup/1` grouping, ordering, actual-vs-estimated
  cost, nil-vs-0 preservation, `:include_hidden?`.
- `ModelPrice.changeset/2`: required fields, non-negative price validation,
  harness inclusion, unique constraint, nil-provider→`""` normalization.
- `Logs.persist_event/2` + `persist_orchestrator_event/2`: provider/model are
  written to the new columns; absence degrades to `nil` (no crash).
- Pricing integration: a catalog entry yields a derived `cost_usd` where config
  alone left it `nil`; config remains the fallback.

### Edge Cases
- Unpriced harness (`pi`) with **no** catalog entry → rollup `actual_cost_usd: 0`,
  `estimated_cost_usd: nil`, `estimated?: false` (never fabricate a billed cost).
- Priced-at-zero (`Decimal` 0) vs unpriced (`nil`) stay distinct in the rollup.
- `agent_logs` rows with `nil` provider/model (pre-backfill / unknown) group into
  a clearly-labelled "unknown" dimension rather than crashing the `GROUP BY`.
- Upsert conflict on `(harness, provider, model)` updates in place (no duplicate);
  re-running the seed never duplicates and never overwrites a `:manual` row.
- Orchestrator whose model/provider changed mid-life: historical cost stays
  attributed to the model snapshotted at write time, not the current identity.
- Empty database / fresh install: tab renders an empty-state, not an error;
  `seed_prices/0` populates the catalog so it is never blank.
- LiveView reconnect: switching to the Cost Center tab re-derives from the DB
  (no reliance on lost socket state).

## Acceptance Criteria

- A **Cost Center** tab appears in the Settings modal and is selectable via the
  existing `select_settings_tab` mechanism.
- The tab shows a rollup table grouped by `(harness, provider, model)` ordered by
  most-recent activity, with summed cost (actual, with estimate fallback labelled
  as such) and tokens per row.
- The tab shows an editable price catalog; upserting and deleting a price persists
  to `model_prices` and the UI reflects the change without a full reload.
- `model_prices` is a Postgres table **seeded from `priv/repo/pricing_seeds.exs`**
  via `mix ecto.setup`/`seed_prices/0`; the seed is idempotent and preserves
  `:manual` edits.
- A `pi` model added to the catalog produces a non-`nil` derived `cost_usd` on the
  next session, with config `price_table` still working as fallback.
- `agent_logs` carries `provider`/`model` snapshots; the rollup never relies on the
  owner's mutable current identity for historical rows.
- All DB access for the feature lives in `RepoBuilder.CostCenter` /
  `RepoBuilder.Logs`; LiveViews/servers never touch `Repo` directly.
- The full green gate passes with zero regressions.

## Validation Commands

Execute every command to validate the feature works correctly with zero regressions.

- `scripts/pg.sh start` — ensure the local Postgres cluster is running (once per session).
- `mix ecto.migrate` — apply the two new migrations cleanly (and confirm `down`/`redo` round-trips: `mix ecto.rollback -n 2 && mix ecto.migrate`).
- `mix run priv/repo/seeds.exs` — confirm `seed_prices/0` populates `model_prices` idempotently (run twice; row count is stable).
- `mix test test/repo_builder/cost_center_test.exs` — context unit tests.
- `mix test test/repo_builder_web/live/test_cost_center_tab_test.exs` — LiveView integration test.
- `mix compile --warnings-as-errors` — gradual set-theoretic types + `warnings_as_errors` pass.
- `mix test --warnings-as-errors` — full suite, zero failures.
- `mix format --check-formatted` — formatting.
- `mix credo --strict` — lint, including `@spec`-on-every-public-function.
- `mix dialyzer` — `@spec`/contract checking, no new warnings, no stale ignore filters.
- (Optional, via Tidewave) `execute_sql_query` `SELECT harness, provider, model, count(*) FROM agent_logs GROUP BY 1,2,3;` to verify snapshot columns populate; `project_eval` `RepoBuilder.CostCenter.rollup([])` against the live app to inspect the rollup shape; capture a Playwright screenshot of `http://localhost:4000` with the Cost Center tab open.

## Notes

- **No new dependency required.** Everything uses existing libs (Ecto, Decimal,
  typedstruct, Phoenix LiveView). If any is added, pin per `BUILD_PROMPT.md` §2,
  run `mix deps.get`, and update this section.
- **Naming:** the new context is `RepoBuilder.CostCenter` (catalog + rollup) to
  avoid confusion with the existing `RepoBuilder.Harness.Pricing` (the pure
  `derive/4` function). They compose: `CostCenter.price_table_for/1` feeds the
  table that `Pricing.derive/4` consumes.
- **`Pricing.derive/4` rate model is combined per-Mtok over `input+output`.** The
  catalog stores separate input/output rates for future accuracy, but
  `price_table_for/1` collapses to the combined shape the current derivation
  expects. A future enhancement is a split-rate `derive_split/5` consuming both
  rates directly — out of scope here; noted for later.
- **Time-correctness:** snapshotting `provider`/`model` on `agent_logs` is the key
  decision that makes per-dimension attribution correct across mid-life
  provider/model switches. The migration backfill is best-effort (current owner
  identity) — historical rows predating this feature may be approximate; rows
  written after it are exact.
- **Future considerations:** per-workflow/per-day cost trends; CSV export; a
  `currency` column; budget thresholds per dimension wired to the existing
  `:alerting` `cost_threshold_usd`; surfacing the rollup on the dashboard
  swimlane, not just settings.
