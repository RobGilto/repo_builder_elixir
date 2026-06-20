# Bug: No live cost while context fills — Claude orchestrator alias model is unpriced

## Metadata
issue_number: `log-7700`
adw_id: `we`
issue_json: `can`

## Bug Description
While a Claude orchestrator turn is in flight, the command panel's context bar climbs (e.g.
~97k tokens across center-stream rows log-7676 → log-7700) but the cost badge shows `—` (no
value). The token/context display updates correctly; only the cost is missing.

Expected: as the context fills during a turn, the cost badge shows a live token-derived
estimate (`~$X.XX`), matching the behavior described in the panel's tooltip ("Live estimate
from tokens — billed amount pending"), and then the authoritative billed cost on turn
completion.

Actual: the badge shows `—` for the entire in-flight turn (no estimate), and only a final
billed number can appear at `Done` — so for the whole streaming window the operator sees
growing context with zero cost signal.

## Problem Statement
The live cost estimate for a Claude orchestrator running on a model **alias**
(`opus` / `sonnet` / `haiku`) is always `nil`, because the price catalog that backs the
estimate is keyed by **canonical** model IDs (`claude-opus-4-8` / `claude-sonnet-4-6` /
`claude-haiku-4-5`). The alias never matches a catalog key, so `Pricing.derive/3` returns
`nil`, the estimate assign stays `nil`, and the cost badge renders `—` even though context
tokens (which do not depend on pricing) render fine.

## Solution Statement
Canonicalize the Claude model alias to its catalog key before pricing the live estimate, so
`opus`/`sonnet`/`haiku` resolve to `claude-opus-4-8`/`claude-sonnet-4-6`/`claude-haiku-4-5`
(mirroring what the `claude` CLI already does — "resolves the aliases to the latest of each
family"). The fix is surgical and lives in the Claude harness (which already owns
Claude-specific model semantics): resolve the alias immediately before
`Pricing.derive(ctx.model, …)` in `usage_event/3`. The CLI still receives the alias verbatim
(unchanged `--model opus`); only the **pricing lookup** is canonicalized. No change to
`Pricing`, the catalog schema, persistence, or the authoritative `Done.cost_usd` path.

## Steps to Reproduce
1. Start the app (`scripts/pg.sh start` then `mix phx.server`), open `http://localhost:4000`.
2. Ensure the orchestrator harness is `claude` with the default model alias `opus` (the
   header dropdown lists `opus`/`sonnet`/`haiku`; the registry default is `opus`).
3. Send the orchestrator a prompt large enough to stream many Usage events (context grows to
   tens of thousands of tokens).
4. Watch the command panel during the turn: the context bar fills (e.g. ~97k), but the cost
   badge shows `—` (no `~$…` estimate) for the whole streaming window.
5. Compare: a `pi` session on a priced GLM model (`glm-4.6`) shows a live `~$…` estimate,
   confirming the estimate path works only when the model key is in the catalog.

Runtime confirmation (Tidewave `project_eval`):
```elixir
# Alias misses the catalog → nil (the bug):
RepoBuilder.Harness.Pricing.derive("opus", %{input: 97_000, output: 0},
  RepoBuilder.CostCenter.price_table_for("claude"))
# => nil  (and logs "no price for model \"opus\"")

# Canonical key is priced → a float:
RepoBuilder.Harness.Pricing.derive("claude-opus-4-8", %{input: 97_000, output: 0},
  RepoBuilder.CostCenter.price_table_for("claude"))
# => 1.455...  (non-nil)
```

## Root Cause Analysis
- The Claude orchestrator's model is `orchestrator.model || orchestrator_defaults[:default_model]`,
  and the registry sets the orchestrator default to the **alias** `"opus"`
  (`config/config.exs` `harnesses["claude"].orchestrator.default_model = "opus"`; dropdown
  `models: %{"anthropic" => ["opus","sonnet","haiku"]}`). This alias flows into the session as
  `state.model` and is exposed to the harness as `ctx.model`
  (`lib/repo_builder/session/server.ex:139,222`).
- The Claude harness derives the live estimate from `ctx.model` and the catalog price table:
  `lib/repo_builder/harness/claude.ex:349-358` calls
  `Pricing.derive(Map.get(ctx, :model), …, Map.get(ctx, :price_table, %{}))`.
- The price table is built from the seeded `model_prices` catalog via
  `RepoBuilder.CostCenter.price_table_for/1` (merged in
  `session/server.ex:resolve_price_table/2`). The catalog is keyed by **canonical** IDs:
  `priv/repo/pricing_seeds.exs` seeds `claude-opus-4-8`, `claude-sonnet-4-6`,
  `claude-haiku-4-5` — there are no `opus`/`sonnet`/`haiku` rows.
- `Pricing.lookup/2` (`lib/repo_builder/harness/pricing.ex:77-86`) does an exact
  `Map.get(price_table, model)`. `"opus"` is absent → returns `nil` →
  `Pricing.derive/3` returns `nil` (and warns "no price for model …").
- A `nil` estimate means `put_owned_estimate/3` leaves `@orchestrator_est_cost` `nil`
  (`console_live.ex:1691, 2258-2263`), and with no `Done` yet `@orchestrator_cost` is also
  `nil`, so `cost_badge` hits its `true ->` branch and renders `—`
  (`dashboard_components.ex:205`). Context still renders because `context_size/1` uses only
  token counts (`console_live.ex:2154-2156`), independent of pricing.

Net: alias ≠ catalog key ⇒ nil estimate ⇒ `—` for the whole in-flight turn.

## Relevant Files
Use these files to fix the bug:

- `lib/repo_builder/harness/claude.ex` — `usage_event/3` (~335-362) builds `Event.Usage` and
  calls `Pricing.derive(ctx.model, …)`. **Primary fix site**: canonicalize the alias here
  before the lookup. Add a small alias→canonical map (Claude-specific) and a private
  `canonical_model/1`.
- `lib/repo_builder/harness/pricing.ex` — `derive/3` + `lookup/2` (exact-key match). Read-only
  reference; confirms the lookup is exact and intentionally harness-agnostic (so alias
  knowledge must NOT live here).
- `lib/repo_builder/cost_center.ex` — `price_table_for/1` (~109-118) builds the per-model table
  from the catalog (canonical keys). Read-only reference.
- `priv/repo/pricing_seeds.exs` — the canonical catalog rows
  (`claude-opus-4-8`/`claude-sonnet-4-6`/`claude-haiku-4-5`). Read-only reference; the fix maps
  aliases onto these keys (alternative considered: add alias rows here — rejected, see Notes).
- `config/config.exs` — `harnesses["claude"].orchestrator` sets the alias default/dropdown.
  Read-only reference confirming aliases are the live-path model strings.
- `lib/repo_builder/session/server.ex` — `resolve_price_table/2` (~162-176) and the ctx
  (`model`/`price_table`, ~222-229) feeding the harness. Read-only reference for the data flow.
- `lib/repo_builder_web/components/dashboard_components.ex` — `cost_badge/1` (~205) renders `—`
  when both cost and estimate are nil. Read-only reference for the visible symptom.
- `lib/repo_builder_web/live/console_live.ex` — `put_owned_estimate/3` / `put_orchestrator_estimate`
  (~1691, 2258-2275) thread `estimated_cost_usd` into `@orchestrator_est_cost`. Read-only
  reference; no change needed.
- `test/repo_builder/harness/claude_test.exs` (or the existing Claude harness test) — add a
  regression unit test asserting an alias model now yields a non-nil `estimated_cost_usd`.

### New Files
- `test/repo_builder_web/live/test_orchestrator_cost_alias_test.exs` — `Phoenix.LiveViewTest`
  integration test proving the command panel shows a `~$…` estimate (not `—`) when a Claude
  orchestrator on an alias model emits a `Usage` event with token counts.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Reproduce and pin the root cause
- Use Tidewave `project_eval` to run the two `Pricing.derive` calls in "Steps to Reproduce"
  and confirm the alias returns `nil` while the canonical key returns a float. Use `get_logs`
  to observe the "no price for model \"opus\"" warning emitted during a live turn.

### 2. Add Claude alias→canonical resolution in the harness
- In `lib/repo_builder/harness/claude.ex`, add a module attribute mapping the orchestrator
  aliases to their canonical catalog IDs, matching the seeded rows:
  `@model_aliases %{"opus" => "claude-opus-4-8", "sonnet" => "claude-sonnet-4-6", "haiku" => "claude-haiku-4-5"}`.
- Add a private `@spec canonical_model(String.t() | nil) :: String.t() | nil` that returns
  `Map.get(@model_aliases, model, model)` for binaries and passes `nil` through.
- In `usage_event/3`, replace `Map.get(ctx, :model)` in the `Pricing.derive/3` call with
  `canonical_model(Map.get(ctx, :model))`. Do NOT change the model anywhere else (the CLI must
  still receive the alias). Keep all `@spec`s; no struct/contract changes.

### 3. Regression unit test (harness)
- In the Claude harness test, add a case: build the `usage_event` path (or call the public
  normalize entry that produces a `%Event.Usage{}`) with `ctx.model = "opus"` and a Claude
  price table from `priv/repo/pricing_seeds.exs` (or a fixture with the canonical key), and
  assert `estimated_cost_usd` is a non-nil float. Add a parallel assert for `"sonnet"`.
- Add a negative guard: a truly unknown model (e.g. `"made-up"`) still yields `nil` (alias
  resolution must not mask genuinely unpriced models).

### 4. LiveView integration test (reproduces the visible bug)
- Create `test/repo_builder_web/live/test_orchestrator_cost_alias_test.exs` using
  `Phoenix.LiveViewTest`. Mount `ConsoleLive` at `/` with a Claude orchestrator whose model is
  the alias `"opus"`.
- Broadcast an orchestrator `Event.Usage` (agent_id `"orch-<id>-<n>"`) carrying
  `input_tokens`/`cache_read` that produce a non-nil `estimated_cost_usd` once the alias is
  canonicalized (mirror how existing console tests inject `{:agent_event, …}` events).
- Assert the command-panel cost badge renders a `~$` estimate (not `—`) — e.g.
  `assert render(view) =~ "~$"` / `refute element(view, "#command-panel") |> render() =~ "—"`
  for the badge region. This test must FAIL before the Step 2 fix and PASS after.

### 5. Validate
- Run every command in `Validation Commands` and ensure all are green with zero regressions.

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- `mix test test/repo_builder_web/live/test_orchestrator_cost_alias_test.exs` - The new
  LiveView test (fails before the fix, passes after).
- `mix test test/repo_builder/harness/claude_test.exs` - The Claude harness regression test
  (alias now priced; unknown model still nil).
- `mix compile --warnings-as-errors` - Compile clean; gradual type checker + warnings-as-errors pass.
- `mix test --warnings-as-errors` - Full ExUnit suite, zero failures.
- `mix format --check-formatted` - Code formatting.
- `mix credo --strict` - Lint, including the `@spec`-on-every-public-function convention.
- `mix dialyzer` - Contract checking, no new warnings.

Runtime re-check (Tidewave, after the fix): re-run the `Pricing.derive("opus", …)` repro via
`project_eval` against a price table that has been alias-resolved by the harness — or send a
real orchestrator turn and confirm the badge shows `~$…` as context grows (optionally
screenshot `http://localhost:4000` via Tidewave Web vision mode / Playwright MCP).

## Notes
- Scope: this is a **display-only** estimate bug. The authoritative billed cost still comes
  from Claude's `Done.total_cost_usd` (`claude.ex:252`), untouched. The fix only restores the
  live in-turn `~$…` estimate.
- Why the harness, not `Pricing`: `Pricing.lookup/2` is deliberately harness-agnostic
  (handles `Rate` and flat-number tables). Alias→family resolution is Claude-specific CLI
  behavior, so it belongs in the Claude harness, keeping `Pricing` pure.
- Alternative considered (rejected): seed `opus`/`sonnet`/`haiku` rows into
  `priv/repo/pricing_seeds.exs`. Rejected because it duplicates rates (drift risk when the
  canonical family rate changes) and pollutes the catalog/Cost Center UI with non-canonical
  rows. A single alias map mirrors the CLI's own resolution with no duplication.
- Keep the alias map in sync if a new family/latest model is added; the canonical targets must
  match the seeded catalog keys. Consider a follow-up to derive both the dropdown aliases and
  this map from one source if more aliases appear (out of scope for this surgical fix).
- No new dependencies, no migrations.
