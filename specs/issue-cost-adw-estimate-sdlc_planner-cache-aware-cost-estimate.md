# Bug: Cost estimate ignores cache tokens, so the cost badge stays flat while displayed tokens grow

## Metadata
issue_number: `cost`
adw_id: `estimate:`
issue_json: `Pricing.derive`

## Bug Description
On the Console dashboard (`/`), each agent card shows a **CONTEXT WINDOW** token count and a **cost badge**. In a long or resumed Claude session the token count keeps climbing while the cost badge (a live `~$` estimate) stays nearly flat — the two visibly contradict each other.

**Symptom:** tokens increasing, cost (estimate) not increasing.

**Expected:** the live cost estimate should rise as the billable token footprint of the session rises — including the cached-prompt tokens (`cache_read`, `cache_creation`) that dominate a resumed Claude prompt.

**Actual:** the estimate is computed from `input_tokens + output_tokens` only. The displayed token count is computed from `input_tokens + cache_read + cache_creation`. Because `cache_read` (the bulk of a resumed Claude prompt) is excluded from the estimate, the estimate barely moves while the token count balloons.

This is a display/accounting bug only — Claude's *authoritative* billed cost (`cost_usd`, carried on the terminal `Done` event) is unaffected. The defect is in the **token-derived estimate** path used while a run is in flight and in the Cost Center estimate fallback for unpriced rows.

## Problem Statement
`RepoBuilder.Harness.Pricing.derive/4` prices only `(input_tokens + output_tokens)` against a single collapsed combined per-model rate. Cached-prompt tokens — `cache_read` (billed by Anthropic at ~0.1× the input rate) and `cache_creation` (billed at ~1.25× the input rate) — are real billable tokens but contribute **zero** to the estimate. They are simultaneously the tokens that drive the displayed CONTEXT WINDOW count (`context_size/1` in `console_live.ex`), producing the contradiction the operator sees.

## Solution Statement
Make the estimate **cache-aware** (the user-approved "option 1"):

1. Replace the single collapsed combined rate with the **separate input/output per-Mtok rates already stored** in the `model_prices` catalog (`input_price_per_mtok`, `output_price_per_mtok`).
2. Bill cache tokens relative to the **input** rate: `cache_read` at `0.1×`, `cache_creation` at `1.25×` (Anthropic's published cache pricing multipliers), expressed as named module attributes.
3. Thread `cache_read`/`cache_creation` from every harness `Usage` build site into `Pricing.derive`, and from the Cost Center aggregations into its estimate fallback, so the live badge **and** the Cost Center rollup/period/scope estimates are consistent.

Backward compatibility: the config-based flat `price_table` maps (`%{model => number}`, e.g. pi's `glm-4.6 => 0.6`) keep working — a bare number is treated as both the input and output rate, so cache multipliers still apply against it.

## Steps to Reproduce
1. Start the app (`scripts/pg.sh start` then `mix phx.server`) and open `http://localhost:4000`.
2. Run a Claude-harness agent through a multi-turn / resumed conversation so the prompt is served largely from cache (large `cache_read_input_tokens`, small `input_tokens`).
3. Watch an agent card: the CONTEXT WINDOW token count climbs turn over turn, but the cost badge `~$…` estimate stays essentially constant.
4. Programmatic reproduction (Tidewave `project_eval`), demonstrating the estimate ignores cache:
   ```elixir
   alias RepoBuilder.Harness.Pricing
   # 10k uncached in + 1k out, but 1_000_000 cache_read tokens (a resumed prompt).
   # Today this returns only the in+out cost; cache_read contributes nothing.
   Pricing.derive("claude-opus-4-8", 10_000, 1_000, %{"claude-opus-4-8" => 75.0})
   # => ~0.000825  (cache_read's 1,000,000 tokens add $0.00 — the bug)
   ```

## Root Cause Analysis
Two computations consume the same `Event.Usage` but use different token sets:

- **Displayed tokens** — `lib/repo_builder_web/live/console_live.ex:2098` `context_size/1`:
  `nz(input_tokens) + nz(cache_read) + nz(cache_creation)` — *includes* cache (comment notes "cache_read dominates a resumed Claude prompt").
- **Estimate** — `lib/repo_builder/harness/claude.ex:347` → `RepoBuilder.Harness.Pricing.derive/4` → `lib/repo_builder/harness/pricing.ex:29`:
  `(input_tokens + output_tokens) / 1_000_000 * price` — *excludes* cache entirely.

In a resumed Claude session each turn's new `input_tokens`/`output_tokens` are small while `cache_read` grows, so the estimate is flat while the displayed token count grows. The single combined rate (`CostCenter.price_table_for/1` → `combined_rate/1`, `lib/repo_builder/cost_center.ex:110`) also discards the input/output split needed to price cache correctly. The estimate is a REPLACE-latest snapshot per run (`console_live.ex:2145` `put_agent_estimate/3`), so it shows the latest run's cache-blind estimate — compounding the appearance of "frozen" cost.

## Relevant Files
Use these files to fix the bug:

- `lib/repo_builder/harness/pricing.ex` — **core fix.** `derive/4` must become cache-aware: accept cache tokens, price input/output at their own rates, and add cache contributions via the multipliers. Define the new `Rate` value and the cache multiplier attributes here.
- `lib/repo_builder/harness/claude.ex` — `usage_event/3` (line ~347) builds `estimated_cost_usd` via `Pricing.derive`; must pass `cache_read`/`cache_creation`.
- `lib/repo_builder/harness/pi.ex` — `parse_usage/3` (line ~353) builds both `cost_usd` and `estimated_cost_usd` via `Pricing.derive`; must pass cache tokens.
- `lib/repo_builder/harness/adw/event_schema.ex` — `parse_usage/2` (line ~225) and `usage_cost/4` (line ~240) call `Pricing.derive`; must pass cache tokens.
- `lib/repo_builder/cost_center.ex` — `price_table_for/1` (line ~110) must emit `%{model => Pricing.Rate.t()}` (separate input/output rates) instead of `combined_rate/1`; `derive_costs/5` (line ~411) must pass cache token sums; the three aggregation queries (`rollup/1` base line ~162, `window_rows/1` line ~237, `scope_window_rows/3` line ~349) must also `SUM` `cache_read`/`cache_creation` from the `usage` JSONB so the fallback estimate is cache-aware and consistent with the live badge. Remove the now-unused `combined_rate/1`.
- `lib/repo_builder/harness/event.ex` — `Event.Usage` already carries `cache_read`/`cache_creation` (lines ~108–116); reference only, no change expected.
- `lib/repo_builder/harness.ex` — `ctx()` type's `:price_table` (line ~37) stays `map()`; confirm the looser value type (`Rate.t() | number()`) does not require a signature change.
- `lib/repo_builder_web/components/dashboard_components.ex` — `cost_badge/1` (line ~206) renders the estimate; reference only (no change — it already displays whatever estimate it is given).
- `lib/repo_builder_web/live/console_live.ex` — `context_size/1` (line ~2098), `put_agent_estimate/3` (line ~2145), and the `Event.Usage` handler (line ~1642); reference only — the fix flows through the event's `estimated_cost_usd`.
- `priv/repo/pricing_seeds.exs` — confirms catalog rows already store both `input_price_per_mtok` and `output_price_per_mtok`; reference only.
- `BUILD_PROMPT.md` — §3 typed style, §4 harness event contract, §8 persistence/Cost Center; authoritative spec to keep the fix idiomatic.

### New Files
- `test/repo_builder_web/live/test_cost_badge_cache_estimate_test.exs` — `Phoenix.LiveViewTest` integration test: drive a Claude `Event.Usage` with a large `cache_read` through `ConsoleLive` and assert the rendered cost badge estimate reflects the cache contribution (fails before the fix, passes after).

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Read the spec and confirm the contract
- Read `BUILD_PROMPT.md` §3 (typed style), §4 (harness event contract), §8 (Cost Center) and `README.md` to keep the fix idiomatic and typed.
- Confirm via Tidewave `project_eval` the current (buggy) behavior using the reproduction snippet above so there is a before/after baseline.

### 2. Make `Pricing` cache-aware (core change)
- In `lib/repo_builder/harness/pricing.ex`:
  - Define a typed value for a per-model rate, e.g. `RepoBuilder.Harness.Pricing.Rate` via `TypedStruct` with `input :: float()` and `output :: float()` (USD per Mtok), both `@enforce`d.
  - Add named multipliers: `@cache_read_multiplier 0.1` and `@cache_creation_multiplier 1.25` (document them as Anthropic's cache_read/cache_creation pricing relative to the input rate).
  - Widen `@type price_table` to `%{optional(String.t()) => Rate.t() | number()}` (legacy flat number still supported).
  - Replace `derive/4` with a cache-aware signature that takes the cache tokens. Prefer a single token map to keep call sites readable and typed, e.g.:
    `@spec derive(String.t() | nil, tokens(), price_table()) :: float() | nil`
    where `@type tokens :: %{required(:input) => non_neg_integer(), required(:output) => non_neg_integer(), optional(:cache_read) => non_neg_integer() | nil, optional(:cache_creation) => non_neg_integer() | nil}`.
  - `lookup/2` returns the matched `Rate.t() | number()`; normalize a bare `number()` to `%Rate{input: n, output: n}` so cache multipliers apply uniformly.
  - Compute:
    `cost = (input*rate.input + output*rate.output + nz(cache_read)*rate.input*@cache_read_multiplier + nz(cache_creation)*rate.input*@cache_creation_multiplier) / 1_000_000`
    (cache tokens are nil-safe; preserve the **unpriced ⇒ nil, never 0.0** invariant and the existing `Logger.warning` on an unknown priced model).
- Keep all `@spec`s precise; this must compile under `--warnings-as-errors`, the set-theoretic type checker, and Dialyzer.

### 3. Thread cache tokens through the harness Usage builders
- `lib/repo_builder/harness/claude.ex` `usage_event/3`: pass the parsed `cache_read`/`cache_creation` into `Pricing.derive` alongside `input`/`output` (the Usage already captures them via `opt_non_neg`).
- `lib/repo_builder/harness/pi.ex` `parse_usage/3`: compute the cache token values once and pass them into the single `Pricing.derive` call that feeds both `cost_usd` and `estimated_cost_usd`.
- `lib/repo_builder/harness/adw/event_schema.ex` `parse_usage/2` and `usage_cost/4`: pass `cache_read`/`cache_creation` into `Pricing.derive`.

### 4. Make the Cost Center estimate cache-aware and consistent
- `lib/repo_builder/cost_center.ex`:
  - Rewrite `price_table_for/1` to build `%{model => %Pricing.Rate{input: ..., output: ...}}`. When only one rate column is present, fall back (input↔output) so both fields are populated; omit rows with neither rate. Remove the now-unused `combined_rate/1`.
  - Add `COALESCE(SUM((?->>'cache_read')::bigint), 0)` and `COALESCE(SUM((?->>'cache_creation')::bigint), 0)` to the `select` of `rollup/1`'s base query, `window_rows/1`, and `scope_window_rows/3`.
  - Update `to_rollup/1`, `derive_spend_row/1`, and `derive_costs/5` to pass the cache token sums into `Pricing.derive` (via the token map). Keep the **non-NULL actual SUM ⇒ no estimate** rule (`derive_costs/5` first clause) unchanged — cache only affects the `nil`-actual estimate branch.
  - Verify `Rollup`/`SpendRow` structs still satisfy their `@spec`s (cache is folded into the estimate, not new fields — unless surfacing cache token counts is desired; keep minimal and do **not** add fields).

### 5. Unit tests for `Pricing.derive`
- Extend `test/repo_builder/harness/pricing_test.exs`:
  - Update existing calls to the new signature (token map).
  - New: a `Rate`-valued table prices input/output separately.
  - New: `cache_read` is billed at `0.1×` input rate and `cache_creation` at `1.25×` input rate (assert exact arithmetic).
  - New: a bare-number table still works and applies cache multipliers against that number.
  - New: nil/absent cache tokens are safe; unpriced/unknown model still returns `nil` (never `0.0`).

### 6. Harness normalize regression tests
- `test/repo_builder/harness/claude_estimate_test.exs` (and/or `claude_normalize_test.exs`): assert the `Event.Usage.estimated_cost_usd` for a payload with a large `cache_read` exceeds the input+output-only estimate (proves cache is now priced).
- `test/repo_builder/harness/pi_normalize_test.exs` and `adw_normalize_test.exs`: assert cache tokens contribute to the derived cost where a price table is supplied; unpriced still yields `nil`.

### 7. Cost Center rollup test
- `test/repo_builder/cost_center_test.exs`: insert `agent_logs` rows with NULL `cost_usd` but non-zero `cache_read`, plus a catalog price; assert the rollup's `estimated_cost_usd` reflects the cache contribution (and stays `estimated?: true`). Confirm `price_table_for/1` returns `Rate` values.

### 8. LiveView integration test (UI proof)
- Create `test/repo_builder_web/live/test_cost_badge_cache_estimate_test.exs` (mirror the setup of an existing `test/repo_builder_web/live/*` test that drives `{:agent_event, agent_id, %Event.Usage{}, log_no}` into `ConsoleLive`):
  - Build a Claude `Event.Usage` (via `Claude.normalize/2` with a price table, or directly) carrying small `input_tokens`/`output_tokens` and a large `cache_read`, yielding a non-nil `estimated_cost_usd`.
  - Render `ConsoleLive`, send the usage event for a known agent, and assert the agent card's cost badge renders the cache-aware `~$` estimate (and that it is strictly greater than the input+output-only figure).
- Optionally capture a screenshot of `http://localhost:4000` via Tidewave Web vision mode (or Playwright MCP) as visual proof.

### 9. Run the full validation suite
- Run every command in **Validation Commands** and fix any failures until all are green with zero regressions.

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- Reproduce (before fix) via Tidewave `project_eval`: `RepoBuilder.Harness.Pricing.derive(...)` shows cache tokens adding `$0.00`; after the fix the same inputs return a strictly larger, cache-inclusive figure.
- `mix test test/repo_builder/harness/pricing_test.exs` — unit coverage of the cache-aware math.
- `mix test test/repo_builder/harness/claude_estimate_test.exs test/repo_builder/harness/claude_normalize_test.exs test/repo_builder/harness/pi_normalize_test.exs test/repo_builder/harness/adw_normalize_test.exs` — harness estimate regression.
- `mix test test/repo_builder/cost_center_test.exs test/repo_builder/cost_center_period_test.exs` — Cost Center rollup/period estimate consistency.
- `mix test test/repo_builder_web/live/test_cost_badge_cache_estimate_test.exs` — LiveView UI proof (fails before fix, passes after).
- `mix compile --warnings-as-errors` — clean compile; set-theoretic type checker + `warnings_as_errors` pass.
- `mix test --warnings-as-errors` — full suite, zero failures.
- `mix format --check-formatted` — formatting.
- `mix credo --strict` — lint, including the `@spec`-on-every-public-function rule.
- `mix dialyzer` — contract checking, no new warnings, no stale ignore filters.

## Notes
- No new dependencies required.
- **Cache pricing multipliers** (`0.1×` read, `1.25×` creation relative to the input rate) match Anthropic's published prompt-caching pricing and are encoded as named module attributes so they are auditable and adjustable in one place. They apply uniformly to the legacy flat `price_table` numbers as well.
- **Invariants preserved:** unpriced model ⇒ `estimated_cost_usd: nil` (never `0.0`); a non-NULL actual cost SUM still suppresses any estimate in the Cost Center (priced-at-zero stays distinct from unpriced); the live estimate remains a display-only, REPLACE-latest snapshot never accumulated into authoritative `cost`.
- **Scope guard:** Claude's authoritative billed `cost_usd` (terminal `Done` event) is untouched — this fix changes only the token-derived *estimate* path. The signature change to `Pricing.derive` is internal; all four callers (claude, pi, adw, `CostCenter.derive_costs`) are updated in this plan.
