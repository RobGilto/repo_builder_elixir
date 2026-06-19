# Bug: Costing does not populate early — make cost responsive the moment token usage drops (orchestrator + agents)

## Metadata
issue_number: `does`
adw_id: `not`
issue_json: `populate`

## Bug Description
The cost badges in the console UI stay at `—` (or `$0.00`) for most of an agent/orchestrator run and only "snap" to a real dollar amount at the very end of the run. Cost feels unresponsive: even though token-usage events are flowing the whole time (the CONTEXT WINDOW bar and token counters update live), the **cost** display does not move until the terminal `Done`/`result` event lands.

Two badges are affected (both selected by the user):
- **Agent card cost badge** — `ConsoleComponents.agent_card/1` → `DashboardComponents.cost_badge/1` (`lib/repo_builder_web/components/console_components.ex:291`, badge at `lib/repo_builder_web/components/dashboard_components.ex:200`). Driven by `@agent_costs[agent.id]` in `console_live.ex`.
- **Command-panel (orchestrator) cost badge** — `ConsoleComponents.command_panel/1` → `DashboardComponents.cost_badge/1` (`lib/repo_builder_web/components/console_components.ex:732`). Driven by `@cost`/orchestrator `total_cost_usd`.

**Expected:** As soon as token-usage events ("token logs") drop for an orchestrator or an agent, the cost badge should show a live, clearly-marked **estimate** (e.g. `~$0.04`), continuously updated, and then settle on the **authoritative billed amount** when the harness reports it at the end of the run.

**Actual:** The cost badge shows `—`/`$0.00` for the whole run and only populates once, at the end, from the terminal cost.

## Problem Statement
For the **claude** (and **cursor**) harness, per-turn `Event.Usage` events carry token counts but **no `cost_usd`** — the authoritative USD figure (`total_cost_usd`) is emitted only once, on the terminal `result`/`Done` event. The live cost accumulators in both the orchestrator and the console only move when a non-nil `cost_usd` arrives, so cost is invisible until the run ends. We need cost to become responsive the instant token usage is observed, without corrupting the final authoritative total.

## Solution Statement
Introduce a **live cost estimate** that is computed from the token counts already flowing in every `Event.Usage` event and the per-model price catalog the system already maintains (`RepoBuilder.CostCenter` / `RepoBuilder.Harness.Pricing`), then displayed as soon as tokens drop — for both the orchestrator and each agent. The estimate is kept **separate** from the authoritative billed cost and is **superseded** by it when the harness reports the real `cost_usd`. The badge renders the authoritative amount when present, otherwise the estimate with a clear `~` marker, otherwise `—`.

This deliberately preserves the existing nil-vs-priced-0 semantics and the additive authoritative accumulators (`@agent_costs`, `@cost`, `Orchestrator.total_cost_usd`) untouched — the estimate is an additional, display-only signal. The estimate reuses the already-loaded `price_table` (in the harness `ctx`) so it adds **no new DB queries on the hot path**.

## Steps to Reproduce
1. Start the app (`scripts/pg.sh start` then `mix phx.server`) and open `http://localhost:4000`.
2. Send the orchestrator a prompt that does real work, or spawn an agent that runs on the **claude** harness.
3. Watch the agent card / command panel during the run: the token counters and CONTEXT WINDOW bar update live, but the **cost badge stays at `—`/`$0.00`**.
4. Observe that the cost badge only jumps to a real value at the moment the run finishes (the terminal `result`/`Done` event).
5. Expected after the fix: the cost badge shows a live `~$…` estimate within one usage event of work starting, updating as tokens accrue, then settles on the exact billed amount at the end.

## Root Cause Analysis
The live-cost path is **additive on `cost_usd` only**, and for the claude/cursor harnesses `cost_usd` is nil for every event except the terminal one:

- `lib/repo_builder/harness/claude.ex:206-221` — each intermediate `assistant` message emits `usage_event(u, raw)` (the 2-arity form), so `cost_usd` defaults to **nil** (`claude.ex:330-341`, `cost \\ nil`). Tokens are present; cost is not.
- `lib/repo_builder/harness/claude.ex:250-272` — only the terminal `result` carries `total_cost_usd`, passed into both the final `usage_event(usage, raw, cost)` and the `Done`.
- **Agent path:** `lib/repo_builder_web/live/console_live.ex:1569-1586` handles `Event.Usage` with `add_cost(event.cost_usd)` / `add_agent_cost(agent_id, event.cost_usd)`; `accumulate_cost/2` (`console_live.ex:2062-2069`) is a **no-op when `cost_usd` is nil** (`accumulate_cost(current, nil) -> current`). So intermediate usage events contribute nothing to cost.
- **Orchestrator path:** `lib/repo_builder/orchestrator/server.ex:222-226` handles `Event.Usage` with `Orchestrators.add_cost(id, event.cost_usd)`; `RepoBuilder.Orchestrator.add_cost(id, nil)` is an explicit **no-op** (`orchestrator.ex:378-384`). Tokens are recorded live via `add_usage/3` (`orchestrator.ex:405-420`), but cost is not.

By contrast the **pi** harness already derives per-turn `cost_usd` from tokens × price table (`lib/repo_builder/harness/pi.ex:361-367` via `RepoBuilder.Harness.Pricing.derive/4`), which is exactly why pi cost feels responsive while claude does not. The infrastructure to derive cost from tokens already exists (`Pricing.derive/4`, `CostCenter.price_table_for/1`, and the session runtime already loads a per-harness `price_table` into `ctx` — `lib/repo_builder/session/server.ex:145,164-169,230`); it simply is not applied to claude/cursor intermediate usage, and there is no separate "estimate" signal to display before the authoritative cost lands.

Note (do NOT regress): the nil-vs-priced-0 distinction is load-bearing across persistence and the cost-center (`Logs.add_cost/2`, `CostCenter.derive_costs/5`). The fix must keep authoritative `cost_usd` semantics intact and treat the estimate as a strictly separate, additive-free, display-only value.

## Relevant Files
Use these files to fix the bug:

- `lib/repo_builder/harness/event.ex` — `Event.Usage` typedstruct (`event.ex:102-116`). Add an optional `estimated_cost_usd :: float()` field so the live estimate rides on the same event both the agent and orchestrator paths already consume. Keep `cost_usd` semantics unchanged.
- `lib/repo_builder/harness/pricing.ex` — `Pricing.derive/4` already converts tokens + price table → USD or nil. Reused as-is to compute the estimate; no change expected.
- `lib/repo_builder/harness/claude.ex` — populate `estimated_cost_usd` on the intermediate + terminal `usage_event/3` from `ctx` model + `ctx.price_table` (mirroring pi). The authoritative `cost_usd` stays exactly as today (nil intermediates, real total on terminal). `usage_event/3` currently ignores `ctx`; thread the price table through.
- `lib/repo_builder/harness/cursor.ex` — same harness pattern as claude (no per-turn USD); populate `estimated_cost_usd` the same way for parity. (Verify whether cursor emits usage; if not, no change.)
- `lib/repo_builder/harness/pi.ex` — pi already derives `cost_usd`; set `estimated_cost_usd` to the same derived value so the estimate field is uniformly present (display logic can treat all harnesses identically).
- `lib/repo_builder/harness/adw/event_schema.ex` — ADW usage decoding (`event_schema.ex:188,224-240`); populate `estimated_cost_usd` consistently (it already has a `usage_cost` derivation path and `price_table` in ctx).
- `lib/repo_builder/harness/fake.ex` — test harness usage frames (`fake.ex:105,167,189`); ensure the new field is set/threaded so tests can exercise the estimate deterministically.
- `lib/repo_builder/orchestrator/server.ex` — `handle_info({:harness_event, %Event.Usage{}}, …)` (`server.ex:222-226`). In addition to `add_cost`/`add_usage`, record the estimate via a new `Orchestrators.set_estimated_cost/2` (or fold into `add_usage`). The terminal `Done` (authoritative) already lands via `add_cost`.
- `lib/repo_builder/orchestrator.ex` — orchestrator schema + context. Add an `estimated_cost_usd` (Decimal, nullable) column/field and a setter; expose it in the read shape the command panel uses so the UI can show `actual || estimate`. Keep `total_cost_usd` authoritative and untouched.
- `lib/repo_builder_web/live/console_live.ex` — agent path: in `handle_info({:agent_event, _, %Event.Usage{}}, …)` (`console_live.ex:1569`), track a per-agent estimate (new `@agent_est_costs` assign, replace-latest, NOT additive into `@agent_costs`) and a global estimate; seed on mount/reconnect (alongside `seed_agent_costs/1`, `seed_context_tokens/1`). Pass `estimate` to the agent card and command panel.
- `lib/repo_builder_web/components/dashboard_components.ex` — `cost_badge/1` (`dashboard_components.ex:195-205`). Add an optional `estimated` assign; render `"$X.XX"` when `@cost` is present, else `"~$X.XX"` when `@estimated` is present, else `—`. Keep the current nil → `—` behavior.
- `lib/repo_builder_web/components/console_components.ex` — pass the estimate through `agent_card/1` (`console_components.ex:291`) and `command_panel/1` (`console_components.ex:732`) into `cost_badge/1`.
- `lib/repo_builder/cost_center.ex` — reference for the existing estimate semantics (`derive_costs/5`, `price_table_for/1`, `estimated?`); reuse `price_table_for/1` if an estimate must be computed outside the harness ctx (seed path).
- `lib/repo_builder/session/server.ex` — confirms `price_table` is already resolved per harness and placed in `ctx` (`server.ex:145,164-169,230`); no change expected, used to justify the "no extra DB on hot path" claim.
- `BUILD_PROMPT.md` — §4.1/§4.3/§6 (harness event contract + pricing), §8 (float→Decimal boundary, nil-vs-0), §9 (LiveView dashboard + reconnect rule). Authoritative for keeping the fix typed and idiomatic.

### New Files
- `test/repo_builder_web/live/test_live_cost_estimate_test.exs` — `Phoenix.LiveViewTest` integration test proving the bug: a usage event with tokens but `cost_usd: nil` makes the agent card (and orchestrator command panel) render a `~$…` estimate (fails before the fix), and a subsequent authoritative cost makes it render the exact `$…` (estimate superseded).
- `test/repo_builder/harness/claude_estimate_test.exs` — unit test that `claude.ex` populates `estimated_cost_usd` on intermediate usage events from a `ctx` price table while leaving `cost_usd` nil until the terminal event.
- `test/repo_builder/orchestrator/estimated_cost_test.exs` — context-level test that an orchestrator `Event.Usage` with nil `cost_usd` produces a live `estimated_cost_usd` while `total_cost_usd` stays 0 until the terminal `Done`.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Extend the canonical `Event.Usage` with an estimate field
- In `lib/repo_builder/harness/event.ex`, add `field :estimated_cost_usd, float(), enforce: false` to the `Usage` typedstruct, with a doc note: "Token-derived live ESTIMATE (display-only); never accumulated into authoritative cost; nil when the model is unpriced."
- Keep `cost_usd` exactly as-is (nil = unpriced, 0.0 = priced-at-zero).
- Run `mix compile --warnings-as-errors` to confirm the struct change is clean.

### 2. Derive the estimate in the harness normalizers (single source, reused by orch + agents)
- In `lib/repo_builder/harness/claude.ex`, thread `ctx` into `usage_event/3` and set `estimated_cost_usd: Pricing.derive(Map.get(ctx, :model), in, out, Map.get(ctx, :price_table, %{}))` for both the intermediate `assistant` usage (`claude.ex:206-221`) and the terminal `result` usage (`claude.ex:250-272`). Leave `cost_usd` unchanged (nil intermediate, real total terminal). Add `alias RepoBuilder.Harness.Pricing` if missing.
- In `lib/repo_builder/harness/pi.ex`, set `estimated_cost_usd:` to the same value already computed for `cost_usd` (so the field is uniformly present).
- In `lib/repo_builder/harness/cursor.ex` and `lib/repo_builder/harness/adw/event_schema.ex`, populate `estimated_cost_usd` the same way using the ctx price table. In `lib/repo_builder/harness/fake.ex`, ensure the field is threaded so tests can drive it deterministically.
- Keep every `@spec` precise; `Pricing.derive/4` already returns `float() | nil`.

### 3. Surface the orchestrator estimate
- In `lib/repo_builder/orchestrator.ex`, add a nullable `estimated_cost_usd` (Decimal) field to the `Orchestrator` schema + typedstruct + changeset cast, and a `@spec`'d `set_estimated_cost/2` (float→Decimal boundary, nil-safe, OVERWRITE-latest not additive — the estimate is a running snapshot, not a sum). Expose it in whatever read/serialization shape the command panel consumes.
- Add an Ecto migration in `priv/repo/migrations/` adding `estimated_cost_usd numeric` (nullable) to the orchestrators table; verify a clean round-trip.
- In `lib/repo_builder/orchestrator/server.ex:222-226`, after `add_usage`, call `Orchestrators.set_estimated_cost(id, event.estimated_cost_usd)`. The terminal `Done` continues to set the authoritative `total_cost_usd` via `add_cost` (no change).

### 4. Surface the per-agent + global estimate in the console
- In `lib/repo_builder_web/live/console_live.ex`, add an `@agent_est_costs` assign (`%{agent_id => Decimal | nil}`) and a global estimate, mounted empty and seeded next to `seed_agent_costs/1`/`seed_context_tokens/1` (a `Logs`-backed seed of the latest estimate per agent, OR derived from the latest usage row + `CostCenter.price_table_for/1` — choose the path that adds no per-event DB query on the live path).
- In `handle_info({:agent_event, agent_id, %Event.Usage{} = event, _}, …)` (`console_live.ex:1569`), update `@agent_est_costs[agent_id]` to `event.estimated_cost_usd` (REPLACE-latest, nil-safe; do NOT route it through `accumulate_cost/2`/`add_agent_cost/2`). Recompute the global estimate (sum of per-agent latest estimates). Leave the authoritative `add_cost`/`add_agent_cost` calls exactly as-is.
- Pass `estimate={Map.get(@agent_est_costs, agent.id)}` into the agent card (`console_live.ex:2136-2146`) and the orchestrator estimate into the command panel.

### 5. Render the estimate in the badge
- In `lib/repo_builder_web/components/dashboard_components.ex`, add `attr :estimated, :any, default: nil` to `cost_badge/1` and render: authoritative `@cost` → `"$" <> …`; else `@estimated` → `"~$" <> …` (with a `title`/muted style marking it an estimate); else `—`. Keep the `Decimal.round(…, 2)` formatting and the `@spec`.
- In `lib/repo_builder_web/components/console_components.ex`, thread the `estimate` assign through `agent_card/1` (`:291`) and `command_panel/1` (`:732`) into `cost_badge/1`.

### 6. Add the harness + context unit tests (fail before, pass after)
- Write `test/repo_builder/harness/claude_estimate_test.exs`: feed an intermediate `assistant` usage frame through `Claude.normalize/2` with a `ctx` price table; assert the resulting `Event.Usage` has `cost_usd: nil` AND a positive `estimated_cost_usd`; assert an unpriced model yields `estimated_cost_usd: nil`.
- Write `test/repo_builder/orchestrator/estimated_cost_test.exs`: drive an orchestrator usage event with nil `cost_usd` + estimate; assert `estimated_cost_usd` is set and `total_cost_usd` is still `0`; then a terminal `Done` with real cost sets `total_cost_usd`.

### 7. Add the LiveView integration test (reproduces the UI bug)
- Write `test/repo_builder_web/live/test_live_cost_estimate_test.exs` using `Phoenix.LiveViewTest`:
  - Mount the console with an agent (and/or orchestrator) present.
  - Send an `{:agent_event, agent_id, %Event.Usage{cost_usd: nil, estimated_cost_usd: …, input_tokens: …, output_tokens: …}, seq}` (mirroring the live PubSub path the LiveView already handles).
  - Assert the agent card cost badge now renders a `~$` estimate (this assertion FAILS before the fix, where it shows `—`).
  - Then send an authoritative `%Event.Usage{cost_usd: …}` (or `%Event.Done{cost_usd: …}`) and assert the badge renders the exact `$` amount with no `~` (estimate superseded).
  - Optionally repeat for the orchestrator command-panel badge.
- Optionally capture a screenshot of `http://localhost:4000` via Tidewave Web vision mode (or Playwright MCP) as visual proof a live estimate appears mid-run. Do NOT use the browser to validate CSS/styling.

### 8. Run the full validation suite
- Run every command in **Validation Commands** and resolve any failure. Use Tidewave `get_logs`/`project_eval` to reproduce/inspect if a live-path assertion is unclear.

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- `mix test test/repo_builder_web/live/test_live_cost_estimate_test.exs` — the LiveView reproduction test passes (badge shows `~$` estimate on token drop, exact `$` after authoritative cost).
- `mix test test/repo_builder/harness/claude_estimate_test.exs test/repo_builder/orchestrator/estimated_cost_test.exs` — harness + orchestrator estimate unit tests pass.
- `mix compile --warnings-as-errors` — clean compile; gradual set-theoretic type checker and `warnings_as_errors` pass.
- `mix test --warnings-as-errors` — full ExUnit suite (Postgres-backed) green, zero regressions; confirms the authoritative cost totals and nil-vs-0 semantics are unchanged.
- `mix format --check-formatted` — formatting clean.
- `mix credo --strict` — lint clean, including the "every public function has an `@spec`" gate (new `set_estimated_cost/2`, updated `cost_badge/1`, etc.).
- `mix dialyzer` — no new contract warnings, no stale ignore filters (the new `Event.Usage` field + Decimal/float boundaries type-check).

## Notes
- **No new dependency.** The fix reuses `RepoBuilder.Harness.Pricing.derive/4`, `RepoBuilder.CostCenter.price_table_for/1`, and the per-harness `price_table` already resolved into the session `ctx` (`session/server.ex`). No `mix.exs` change.
- **Why an estimate, not authoritative-early:** claude reports the authoritative `total_cost_usd` only at the terminal event, and its per-turn `input_tokens` are cumulative (context re-sent each turn), so a token-derived value is necessarily an estimate. Marking it `~` and superseding it with the billed amount keeps the UI honest and matches the existing cost-center `estimated?` concept (`cost_center.ex:342-356`).
- **Do not break nil-vs-priced-0.** `cost_usd: nil` (unpriced) must stay distinct from `0.0` (priced-at-zero) through persistence and the cost center. The estimate is a strictly separate, display-only, replace-latest signal; it is never accumulated into `@agent_costs`/`@cost`/`Orchestrator.total_cost_usd`.
- **Latent observation (out of scope, do not fix here):** claude's terminal `result` passes `total_cost_usd` into BOTH `usage_event(usage, raw, cost)` and `Done` (`claude.ex:268`), and the console accumulates `cost_usd` on both the `Event.Usage` and `Event.Done` handlers (`console_live.ex:1572`, `:1610`) — a possible double-count of the final amount for claude. This is independent of the responsiveness bug; flag it for a separate ticket and ensure the estimate work does not depend on or worsen it.
- **Tidewave during implementation:** use `project_eval` to run a usage event through `Claude.normalize/2` with a sample price table to confirm `estimated_cost_usd` is derived; use `get_logs` to watch the live `{:agent_event, …, %Event.Usage{}}` flow when validating the LiveView badge.
