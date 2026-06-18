# Feature: Spend by period (daily / weekly / monthly) broken down by harness and provider

## Metadata
issue_number: `cost`
adw_id: `periods`
issue_json: `{}` (interactive `/feature` invocation — see Feature Description for the verbatim request)

## Feature Description
Add a **time-windowed spend summary** to the **Settings → Cost Center** tab so the
operator can see how much they are spending **today, this week, and this month
(since the 1st)**, broken down **by harness** (e.g. `claude` vs `pi`) and **by provider**
(e.g. `anthropic`, `zai`, `minimax`). The operator pays separate bills to Claude
(Anthropic), zai (GLM), and MiniMax, and wants a clear per-period, per-vendor view of
consumption.

Critically, this summary is computed **regardless of log visibility** — unlike the
existing per-`(harness, provider, model)` Cost Center rollup (which hides cleared logs by
default), the period spend MUST include hidden/cleared logs, because it is an accounting
view of real money spent, not a view of the current console buffer. Pressing CLEAR (which
hides logs and zeroes the live console cost badges) must NOT change these numbers.

Verbatim request: "a daily weekly monthly (first of month) cost regardless of visibility,
but broken down by harness and again by provider … currently I pay for claude and zai and
minimax and I want to know how much I am using … in the settings."

## User Story
As an **operator paying multiple AI vendors (Claude/Anthropic, zai/GLM, MiniMax)**
I want **a settings panel showing my spend for today, this week, and this month, broken
down by harness and by provider, counting all logs regardless of whether they've been
cleared from the console**
So that **I can track and attribute my real per-vendor costs over time without exporting
data or doing math by hand.**

## Problem Statement
The platform records cost per `agent_logs` row (`usage.cost_usd`, plus a time-stable
`harness`/`provider`/`model` snapshot and `inserted_at`), and the Cost Center tab already
shows an all-time per-`(harness, provider, model)` rollup. But there is **no time-bounded
view** (today / this week / this month) and **no vendor-level (provider) total across
models**, and the existing rollup **excludes hidden logs by default** — so it cannot
answer "how much did I spend on zai this month?" once logs have been cleared. The operator
has no in-app way to track real per-vendor spend over standard accounting periods.

## Solution Statement
Extend the `RepoBuilder.CostCenter` context with a **period spend** aggregation that sums
`agent_logs.usage.cost_usd` (and tokens) over three time windows — **today**, **this
week**, **this month (since the 1st)** — each grouped two ways: **by harness** and **by
provider**. The windows are computed in the operator's **display timezone** (reusing the
existing `RepoBuilder.Timezones` + `Orchestrators.timezone/1`), then converted to UTC for
the `inserted_at >=` filter (rows store UTC). The aggregation **always includes hidden
rows** (no `hidden` filter) — this is the deliberate difference from `CostCenter.rollup/1`.

Render it in the **Cost Center settings tab**, above the existing all-time rollup, as a
compact set of period sections, each with a harness sub-table and a provider sub-table
(cost + token totals; preserve the nil-vs-0 and estimated-cost conventions already used by
`Rollup`/`derive_costs`). Pure read; no schema change (all needed columns exist:
`harness`, `provider`, `usage` JSONB, `inserted_at`, and the row is already there
regardless of `hidden`).

## Relevant Files
Use these files to implement the feature:

- `lib/repo_builder/cost_center.ex` — PRIMARY. Holds `rollup/1` (the analog to copy:
  grouped `agent_logs` SUM over `usage->>'cost_usd'` / tokens, `derive_costs/5` for
  estimated cost, `filter_hidden/2`, `clamp_limit/1`). Add `period_spend/1` (or
  `spend_summary/1`) that groups by a single dimension (`:harness` | `:provider`) within a
  `inserted_at >= ^since` window and does **not** filter hidden.
- `lib/repo_builder/cost_center/rollup.ex` — the existing per-dimension result struct;
  reference for conventions. A new `SpendSummary`/`SpendRow` struct will live alongside it.
- `lib/repo_builder/logs/agent_log.ex` + `lib/repo_builder/logs/usage.ex` — the source
  schema/embed: `harness`, `provider`, `model`, `usage` (`cost_usd`/`input_tokens`/
  `output_tokens` …), `inserted_at`, `hidden`. Confirms columns the query needs.
- `lib/repo_builder/timezones.ex` — `to_local/2`, `default/0`, `valid?/1`; used to compute
  the period boundaries in the operator's tz (then back to UTC). Confirm a `to_utc`/shift
  path or add a small helper for boundary math.
- `lib/repo_builder/orchestrators.ex` — `timezone/1` (reads the orchestrator's display tz
  from metadata); the LiveView already threads `@timezone` from here.
- `lib/repo_builder_web/live/console_live.ex` — `load_cost_center/1` (seeds
  `cost_rollups`/`price_rows`); add the period-spend assign here and a refresh on the
  timezone change + cost-center tab open. The LiveView already has `@timezone`.
- `lib/repo_builder_web/components/console_components.ex` — the Cost Center tab
  (`settings_tab == :cost_center`, ~line 1265, `cost_rollup_table`); add a
  `spend_summary_table` (or period sections) component above the existing rollup table.
- `BUILD_PROMPT.md` — §3 typed style (new `@spec`s + a `typedstruct` result), §8
  (DB access only via the `CostCenter` context — the LiveView/components never touch
  `Repo`), §9 (LiveView/settings conventions).
- `.claude/commands/conditional_docs.md` — check for any cost/observability doc to include.

### New Files
- `lib/repo_builder/cost_center/spend_summary.ex` — a `typedstruct` result for the period
  view: the three periods, each with `by_harness` and `by_provider` lists of spend rows
  (dimension key, actual cost, estimated cost/flag, input/output tokens, event count),
  plus the resolved period boundaries (for display/tests). Pure data, no `Repo`.
- `test/repo_builder/cost_center_period_test.exs` — unit tests for `period_spend/1`:
  window boundaries (tz-aware), hidden rows INCLUDED, grouping by harness vs provider,
  nil-vs-0/estimated handling, empty periods.
- `test/repo_builder_web/live/test_cost_center_spend_test.exs` — `Phoenix.LiveViewTest`:
  seed priced logs across harnesses/providers (incl. a hidden one), open Settings → Cost
  Center, assert the period sections render the right per-harness and per-provider totals
  and that the hidden row IS counted (vs the all-time rollup which excludes it).

## Implementation Plan
### Phase 1: Foundation
- Add tz-aware period-boundary math: from "now" + operator tz, compute UTC start instants
  for **today**, **start of ISO week (Monday)**, and **start of month (1st)**. Put the
  helper in `Timezones` (or a small private in `CostCenter`), reusing `to_local/2`.
- Define the `SpendSummary`/`SpendRow` structs.

### Phase 2: Core Implementation
- Add `CostCenter.period_spend/1` taking `:timezone` (and optional `:now` for tests).
  Internally run, for each window and each dimension (`:harness`, `:provider`), a grouped
  `agent_logs` SUM of `usage->>'cost_usd'` + tokens with `where inserted_at >= ^since`,
  `where not is_nil(usage)`, and **no hidden filter** (regardless of visibility). Map rows
  through the existing `derive_costs/5` convention (actual vs estimated, nil-vs-0).
- Return a `SpendSummary` with the three periods × {by_harness, by_provider}.

### Phase 3: Integration
- `load_cost_center/1`: also assign `period_spend = CostCenter.period_spend(timezone: @timezone)`.
- Refresh it when the operator changes timezone (`set_timezone`) while the Cost Center tab
  is open, and when the tab is opened.
- Add the `spend_summary_table` component and render it at the top of the Cost Center tab.
- Tests + validation.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Read context and confirm conventions
- Read `BUILD_PROMPT.md` §3/§8/§9, `.claude/commands/conditional_docs.md`, and re-read
  `cost_center.ex` (`rollup/1`, `derive_costs/5`, `filter_hidden/2`) and `timezones.ex`.
- Confirm the tz database is available for boundary shifts (the existing `to_local/2`
  works, so it is); confirm `agent_logs` carries `provider`/`harness`/`inserted_at`/`hidden`.

### 2. Define the result structs
- Create `lib/repo_builder/cost_center/spend_summary.ex` with `typedstruct` for
  `SpendSummary` (periods: today/week/month, each `%{since: DateTime.t(), by_harness:
  [SpendRow.t()], by_provider: [SpendRow.t()]}`) and a `SpendRow` (`key`, `actual_cost_usd`,
  `estimated?`, `estimated_cost_usd`, `input_tokens`, `output_tokens`, `event_count`).
  `@enforce_keys`/`@spec`s per §3.

### 3. Add tz-aware period boundaries
- Add a helper to compute the UTC `since` instants for today / start-of-ISO-week (Mon) /
  start-of-month, given a timezone and a reference `now`. Pure, unit-testable. Pick and
  DOCUMENT the week convention (ISO-8601, Monday start) and DST handling.

### 4. Implement `CostCenter.period_spend/1`
- `@spec period_spend(keyword()) :: SpendSummary.t()`. For each window × dimension, run a
  grouped sum query (mirror `rollup/1`'s SUM/COALESCE fragments) WITHOUT `filter_hidden`
  (include hidden) and WITH `where: l.inserted_at >= ^since`. Group by the chosen
  dimension only (`l.harness` or `l.provider`), normalizing nil provider/harness to a
  stable label ("unknown"/""). Map via the existing actual-vs-estimated derivation.
- Keep ALL DB access in the context (no `Repo` in web layer, §8).

### 5. Unit tests for the context (write alongside step 4)
- `test/repo_builder/cost_center_period_test.exs`: insert priced logs at controlled
  `inserted_at` across harnesses/providers, including a `hidden: true` row and an
  out-of-window row; pass a fixed `:now` + tz; assert each period's by-harness and
  by-provider totals, that hidden rows ARE counted, and that out-of-window rows are not.
  Cover empty periods and nil-vs-0/estimated.

### 6. LiveView integration test (early UI contract)
- `test/repo_builder_web/live/test_cost_center_spend_test.exs`: seed logs (incl. hidden),
  open Settings → Cost Center, assert the period sections show correct per-harness and
  per-provider amounts and that the hidden row is reflected in period spend but NOT in the
  visibility-filtered all-time rollup.

### 7. Wire the context into the LiveView
- In `load_cost_center/1`, assign `period_spend` via `CostCenter.period_spend(timezone:
  socket.assigns.timezone)`. Re-run on `set_timezone` (when the cost-center tab is active)
  and on tab open. Add the `period_spend` socket assign + default.

### 8. Render the spend summary in the Cost Center tab
- Add a `spend_summary_table/1` (or period-section) component in `console_components.ex`
  and render it above `cost_rollup_table` under `settings_tab == :cost_center`. Show, per
  period, a harness breakdown and a provider breakdown with cost (actual; estimated marked)
  and token totals. Reuse the `cost_badge`/formatting conventions; keep it harness-blind.
- Label it clearly as "all activity (includes cleared logs)" to distinguish from the
  visibility-filtered rollup.

### 9. Manual verification (Tidewave)
- Use `execute_sql_query` to compute expected per-period/per-provider sums directly and
  `project_eval` to compare with `CostCenter.period_spend/1`. Optionally screenshot the
  Cost Center tab at `http://localhost:4000`.

### 10. Run the Validation Commands
- Run all commands below; fix any failure; confirm zero regressions.

## Testing Strategy
### Unit Tests
- `period_spend/1`: boundary correctness in a non-UTC tz (e.g. a row just before/after
  local midnight lands in the right day); week starts Monday; month starts on the 1st.
- Hidden rows are INCLUDED (the defining requirement) — contrast with `rollup/1` excluding
  them.
- Grouping by harness vs provider; nil/unknown provider bucketing; estimated vs actual
  (nil-vs-0 preserved); empty periods → zeros, not crashes.

### Edge Cases
- Operator in a timezone where "today" differs from UTC day (row near midnight).
- Month/week boundary rows (1st of month at 00:00 local; Sunday/Monday transition).
- Unpriced harness (pi) rows → estimated cost via catalog; unpriced + no catalog → nil.
- No logs at all; logs only outside all windows; a provider used in one period but not another.
- A row whose `provider` is nil/empty (older rows pre-snapshot) → "unknown" bucket, not dropped.
- DST transition week (document chosen behavior; ensure no crash).

## Acceptance Criteria
- Settings → Cost Center shows three period sections — Today, This week, This month —
  each with a by-harness breakdown and a by-provider breakdown (cost + tokens).
- Numbers are computed in the operator's display timezone and update when the timezone
  setting changes.
- Period spend **includes hidden/cleared logs**; pressing CLEAR does not change these
  numbers (verified against the all-time rollup, which still excludes hidden by default).
- nil-vs-0 and estimated-cost conventions match the existing rollup (no fabricated costs).
- All DB access is inside `CostCenter`; the LiveView/components touch no `Repo`/`Ecto.Query`.
- New LiveView + context tests pass; `--warnings-as-errors`, Credo `--strict`, Dialyzer all clean.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix test test/repo_builder/cost_center_period_test.exs` — period aggregation correctness
  (tz windows, hidden-included, grouping, nil-vs-0/estimated).
- `mix test test/repo_builder_web/live/test_cost_center_spend_test.exs` — the Cost Center
  tab renders the period breakdowns and counts hidden logs.
- `mix test test/repo_builder/cost_center_test.exs` — existing Cost Center tests stay green.
- `mix compile --warnings-as-errors`
- `mix test --warnings-as-errors`
- `mix format --check-formatted`
- `mix credo --strict`
- `mix dialyzer`

## Notes
- No new dependencies expected (timezone shifting already works via `Timezones.to_local/2`;
  if a `to_utc` helper is missing, add a tiny private one — do NOT add a tz library). No
  schema/migration: `agent_logs` already has `harness`, `provider`, `usage`, `inserted_at`,
  `hidden`.
- This is intentionally the inverse of the visibility-aware console cost badges: period
  spend is an accounting view (all rows), the badges/all-time-rollup are a console view
  (visible rows). Keep that distinction explicit in the UI copy to avoid confusion.
- Performance: three windows × two dimensions = 6 grouped scans on open; fine at current
  volumes. If `agent_logs` grows large, a partial index on `(inserted_at)` and/or
  `(harness, inserted_at)` / `(provider, inserted_at)` is a cheap future optimization
  (note only; not in scope).
- Future considerations (out of scope): a custom date range, CSV export, a "previous
  period" comparison, and per-model drilldown within a provider.
```
