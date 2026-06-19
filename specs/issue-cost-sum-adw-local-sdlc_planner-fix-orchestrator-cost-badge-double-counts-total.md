# Bug: ORCHESTRATOR cost badge double-counts the total (agents + orchestrator ≠ total)

## Metadata
issue_number: ``
adw_id: ``
issue_json: `{"title":"Agent(s) cost + orchestrator cost should sum to the total cost","body":"On the console (/), the per-agent cost badges plus the ORCHESTRATOR panel cost badge should add up to the header total Cost pill. Today they don't: the ORCHESTRATOR badge shows the grand total (identical to the header), so the agent cards appear to be extra on top of it."}`

## Bug Description
On the orchestration console (`/`, `RepoBuilderWeb.ConsoleLive`) three cost badges are rendered by the same `RepoBuilderWeb.DashboardComponents.cost_badge/1` component:

- **Per-agent badge** (ref #0) — each `agent_card` footer: `#agent-… > div:nth-child(4) > span:nth-child(2)` → `console_components.ex:299`, fed `cost={Map.get(@agent_costs, agent.id)}`.
- **ORCHESTRATOR panel badge** (ref #1) — `#command-panel … span` → `console_components.ex:741`, fed `cost={@cost}`.
- **Header total badge** (ref #2) — `#stat-cost > span:nth-child(2)` → `console_components.ex:114`, fed `cost={@cost}`.

Expected: `Σ(per-agent costs) + (orchestrator's own cost) = header total`.

Actual: the ORCHESTRATOR panel badge is fed **`@cost` — the global grand total**, exactly the same assign as the header `#stat-cost` badge. So the orchestrator badge already equals the total, and the per-agent cards then look like they are *added on top of* the total. The intended decomposition `agents + orchestrator-own = total` never holds.

A second, related defect: even the header total `@cost` is **seeded** (on mount/reconnect) from worker agents only (`seed_cost/1` sums `Logs.cost_rollup!/1` over `socket.assigns.agents`), which **omits the orchestrator's own historical spend** (`agent_logs` rows keyed by `orchestrator_id`, not `agent_id`). So after a reconnect the header undercounts by the orchestrator's own turns until new live events arrive.

A third defect (source-of-truth divergence on worker removal): a spawned worker can be removed live (orchestrator `delete_agent` tool → `Agents.delete_agent/1` → hard `Repo.delete`, `tools.ex:576`, `agents.ex:44`). The `agent_logs.agent_id` FK is `on_delete: :delete_all` (`priv/repo/migrations/20260615230002_create_agent_logs.exs:7`), so deleting the worker **cascade-deletes its log rows** — a reconnect/reseed then recomputes a *lower* total that no longer counts the removed worker. But the live `{:agent_deleted}` handler (`console_live.ex:1806`) only drops the worker from the roster/lanes; it does **not** adjust `@agent_costs` or `@cost`. Result: after a live deletion the card vanishes while `@cost` still includes the worker's spend (and the already-rendered feed rows still "show activities"), so `Σ(visible agent badges) + orchestrator = total` breaks until the next reconnect. The live state must be reconciled with the durable cascade so the invariant holds at all times.

## Problem Statement
The console has no assign that holds the **orchestrator's own** AI spend (its own turns, distinct from the worker agents it owns). The ORCHESTRATOR panel therefore reuses the grand-total assign `@cost`, which (a) double-represents the total and (b) makes the three badges fail to satisfy `agents + orchestrator = total`. Additionally `seed_cost/1` seeds the grand total from workers only, omitting orchestrator-own history.

## Solution Statement
Introduce a dedicated `orchestrator_cost` assign (the orchestrator's **own** spend) that is seeded from `Logs.orchestrator_cost_rollup!/1` and live-accumulated from the orchestrator's own usage/done events, then feed the ORCHESTRATOR panel badge from it instead of `@cost`. Route live cost accumulation by owner: orchestrator turns (whose broadcast `agent_id` is the synthetic `"orch-<orchestrator_id>-<n>"` minted in `Orchestrator.Server`) accumulate into `orchestrator_cost`; worker turns continue into `@agent_costs`. Both still feed the grand-total `@cost`. Fix `seed_cost/1` to add the orchestrator-own seed so the header total equals `workers + orchestrator` on mount. Mirror the same routing for the live estimate so the ORCHESTRATOR panel shows the orchestrator's own `~$` estimate rather than the global sum.

Additionally, reconcile the live total on worker removal so it tracks the durable cascade (Option A — the recommended, minimal choice): when `{:agent_deleted, agent}` arrives, subtract the worker's `@agent_costs[agent.id]` (and estimate) from `@cost`/`@cost_estimate` and drop the per-agent entries. This makes live state equal what a fresh reseed would compute (the worker's logs are cascade-deleted), so the invariant holds continuously.

Net effect (authoritative costs): `Σ @agent_costs (workers) + @orchestrator_cost == @cost`, at all times — on mount, after live events, and after a worker is removed. The three badges reconcile.

> SOURCE-OF-TRUTH DECISION (DECIDED): **Option A — worker deletion erases the worker's cost from the live total, matching the existing `agent_logs.agent_id` FK `on_delete: :delete_all` cascade.** This is the agreed behavior for this bug: live state always equals what a fresh reseed would compute. The alternative (preserving removed-agent spend as durable "real money") is explicitly NOT part of this work; it is recorded in Notes only as a future, separately-scoped change.

## Steps to Reproduce
1. Start the app (`scripts/pg.sh start`, `mix phx.server`) and open `http://localhost:4000`.
2. Have at least one worker agent with priced `agent_logs` and run an orchestrator turn that produces priced usage (or seed both kinds of `agent_logs` rows directly).
3. Read the three badges: header `#stat-cost`, the ORCHESTRATOR panel badge, and the agent card badge(s).
4. Observe: the ORCHESTRATOR badge equals the header total, and `Σ(agent badges) + (orchestrator badge)` is greater than the header total (the agents are double-counted relative to the intended decomposition). On a fresh reconnect, also observe the header total omits the orchestrator's own prior turns.

## Root Cause Analysis
- **Primary:** `console_live.ex:2367` passes `cost={@cost}` (the grand total accumulator) to `command_panel`, which renders it as the ORCHESTRATOR badge (`console_components.ex:741`). There is no orchestrator-own cost assign, so the panel borrows the total. The header badge (`console_components.ex:114`) is fed the *same* `@cost`. Hence orchestrator-badge ≡ header-badge, and the decomposition `agents + orchestrator = total` is impossible by construction.
- **Live accumulation:** In the `Event.Usage` / `Event.Done` handlers (`console_live.ex:1642-1660`, `1677-1700`) every event calls `add_cost/2` (→ `@cost`, total) and `add_agent_cost/3` (→ `@agent_costs[agent_id]`). Orchestrator turns carry a **synthetic, per-turn-unique** `agent_id` of the form `"orch-<orchestrator.id>-<unique_integer>"` (minted in `Orchestrator.Server.do_start_turn/2` at `server.ex:153`, error path `server.ex:101`). Those synthetic keys land in `@agent_costs` but are **never rendered** (the roster renders only real `@agents` from `Agents.list_agents/0`, which excludes orchestrators — separate `agents` vs `orchestrators` tables, `agents.ex:16`, `agent.ex:33`, `orchestrator.ex:66`). So the orchestrator's own spend is invisible except as part of `@cost`.
- **Seeding gap:** `seed_cost/1` (`console_live.ex:507-515`) reduces `Logs.cost_rollup!/1` over `socket.assigns.agents` (workers only). `cost_rollup!/1` filters `l.agent_id == ^agent_id` (`logs.ex:163-169`); orchestrator-own rows are keyed by `orchestrator_id` (`agent_log.ex:48`, XOR-validated against `agent_id` at `agent_log.ex:92-107`; written by `Logs.persist_orchestrator_event/2`). The matching reader `Logs.orchestrator_cost_rollup!/1` (`logs.ex:175-181`) exists but is **not used by the console**, so the seeded header total omits orchestrator-own history.
- **Estimate parallel:** `put_agent_estimate/3` (`console_live.ex:2149-2162`) stores a replace-latest estimate per `agent_id` and sums all of them into `@cost_estimate`, which feeds *only* the command panel (`console_live.ex:2368`). Because each orchestrator turn has a unique synthetic `agent_id`, every turn leaves a stale per-turn estimate in the map, so `@cost_estimate` over-sums across turns and (like the cost) conflates orchestrator + workers into the panel's `~$`.
- **Worker removal (source-of-truth divergence):** the live `{:agent_deleted, agent}` handler (`console_live.ex:1806-1813`) rejects the agent from `@agents`/`@agent_names`/`@statuses` and `stream_delete`s its lane, but leaves `@agent_costs[agent.id]` and `@cost` untouched. The durable side cascade-deletes the worker's logs (`agent_id` FK `on_delete: :delete_all`), so the seed/reconnect total drops the worker while the live total does not — the live `@cost` and the visible decomposition diverge until reconnect.

## Relevant Files
Use these files to fix the bug:

- `lib/repo_builder_web/live/console_live.ex` — the LiveView holding all three cost assigns. Add `orchestrator_cost`/`orchestrator_est_cost` assigns + seeding, route live accumulation by owner, reconcile `@cost` on worker deletion, and pass the new assign(s) to `command_panel`. Key spots: initial assigns (~`console_live.ex:86-178`), mount pipeline (`console_live.ex:209-230`), `seed_cost/1` (`507-515`), `seed_agent_costs/1` (`397-401`), `Usage`/`Done` handlers (`1642-1700`), the `{:agent_deleted, agent}` handler (`1806-1813`), `add_cost`/`add_agent_cost`/`accumulate_cost`/`put_agent_estimate` (`2119-2162`), and the `command_panel` call site (`2364-2371`).
- `lib/repo_builder/agents.ex` (`delete_agent/1` `:44`), `lib/repo_builder/orchestrator/tools.ex` (`delete_agent/2` `:568-585`, the live removal path that broadcasts `{:agent_deleted, …}`), and `priv/repo/migrations/20260615230002_create_agent_logs.exs` (`agent_id` FK `on_delete: :delete_all` `:7`) — establish that worker removal is a hard delete that cascade-removes the worker's logs. Read-only context that justifies Option A (live total must drop the removed worker to match the durable cascade).
- `lib/repo_builder_web/components/console_components.ex` — renders the three badges (`header_bar` `:114`, `agent_card` `:299`, `command_panel` `:741`). No prop-name change is strictly required (still `cost`/`estimate`), but confirm the `command_panel` attrs. Read-only unless an attr rename is chosen.
- `lib/repo_builder_web/components/dashboard_components.ex` — `cost_badge/1` (`:204-220`). No change expected; it just renders whatever `cost`/`estimated` it receives. Read for context.
- `lib/repo_builder/logs.ex` — `cost_rollup!/1` (`:163`, workers) and `orchestrator_cost_rollup!/1` (`:175`, orchestrator-own). The latter is the seed source for the new assign. No change expected.
- `lib/repo_builder/orchestrator/server.ex` — defines the synthetic orchestrator `agent_id` contract `"orch-<orchestrator.id>-<n>"` (`:101`, `:153`). The owner-detection predicate keys off this prefix. No change expected; cited so the predicate stays in sync with the contract.
- `lib/repo_builder/logs/agent_log.ex` — schema showing `agent_id` XOR `orchestrator_id` ownership (`:45`, `:48`, `:92-107`). Read for context.
- `lib/repo_builder/cost_center.ex` — note `scope_spend(:orchestrator, …)` (`:375-378`) means the *whole tree* (orchestrator + its workers) in budget terms; this is intentionally distinct from the new "orchestrator-own" panel value. Do NOT reuse `scope_spend(:orchestrator,…)` for the panel — it would re-introduce the double count. Read-only.

### New Files
- `test/repo_builder_web/live/test_orchestrator_cost_sum_test.exs` — `Phoenix.LiveViewTest` integration test proving `Σ(agent badges) + (orchestrator badge) == header total`, failing before the fix and passing after.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Read context and confirm the contract
- Read `BUILD_PROMPT.md` (§3 typed style, §8 persistence/contexts, §9 LiveView dashboard) and `README.md`.
- Re-read `console_live.ex` cost paths listed in Relevant Files and `Orchestrator.Server.do_start_turn/2` to confirm the synthetic `agent_id` prefix `"orch-"` is the stable contract for orchestrator-owned live events.
- Optional runtime confirmation via Tidewave `project_eval`: call `RepoBuilder.Logs.orchestrator_cost_rollup!(orchestrator_id)` and `RepoBuilder.Logs.cost_rollup!(agent_id)` for a real orchestrator/agent to confirm the two rollups are disjoint and sum to the tree total.

### 2. Add the orchestrator-own cost assigns
- In the initial `assign(...)` block (near `console_live.ex:175-178`, beside `cost:`/`cost_estimate:`), add `orchestrator_cost: nil` and `orchestrator_est_cost: nil`. Keep the nil-vs-0 convention (nil ⇒ unpriced/no signal, renders `—`).

### 3. Seed the orchestrator-own cost
- Add `@spec`'d `seed_orchestrator_cost/1` that, when `socket.assigns.orchestrator_id` is set, assigns `orchestrator_cost: nilify_zero(Logs.orchestrator_cost_rollup!(orchestrator_id))` (reuse the existing `nilify_zero/1`). When `orchestrator_id` is nil, leave it nil.
- Call it in the connected-mount pipeline **after** `assign_orchestrator/1` (which sets `orchestrator_id`), e.g. immediately after `console_live.ex:222`.

### 4. Make the header total include orchestrator-own spend at seed time
- Update `seed_cost/1` (`console_live.ex:507-515`) so the seeded `@cost` is `nilify_acc(workers_sum + orchestrator_own)`, where `orchestrator_own` is `Logs.orchestrator_cost_rollup!(orchestrator_id)` (0 when `orchestrator_id` is nil). Use `accumulate_cost/2` to fold the orchestrator term in so the float/Decimal + nil handling stays consistent. Ensure `seed_cost/1` runs after `assign_orchestrator/1` OR reads the orchestrator id defensively (today `seed_cost/1` runs at `:218`, before `assign_orchestrator/1` at `:222`). REORDER so `seed_cost/1` runs after `assign_orchestrator/1` (place it alongside `seed_orchestrator_cost/1`), or have both read `socket.assigns.orchestrator_id` post-assignment. Verify ordering by reading the pipeline after editing.

### 5. Route live cost accumulation by owner
- Add an `@spec`'d predicate `orchestrator_owned?/1` (or `orchestrator_event?/1`) that returns `true` when `agent_id` is a binary starting with `"orch-"` (the `Orchestrator.Server` contract). Keep it private and documented with a reference to `server.ex:153`.
- Add `@spec`'d `add_orchestrator_cost/2` mirroring `add_agent_cost/3` but writing the single `:orchestrator_cost` assign via `accumulate_cost/2` (nil cost ⇒ no-op).
- In the `Event.Usage` (`console_live.ex:1642`) and `Event.Done` (`console_live.ex:1677`) handlers, keep `add_cost/2` (grand total) for all events, but **route** the owner-scoped accumulation: if `orchestrator_owned?(agent_id)` → `add_orchestrator_cost/2`, else → `add_agent_cost/3`. Introduce one private helper (e.g. `add_owned_cost/3`) to avoid duplicating the branch in both handlers, or inline the branch in both — keep it DRY and typed.

### 6. Route the live estimate by owner (panel parity)
- Add `@spec`'d `put_orchestrator_estimate/2` that stores the orchestrator's latest estimate as a single replace-latest `Decimal` in `:orchestrator_est_cost` (nil ⇒ leave prior untouched, mirroring `put_agent_estimate/3`).
- In the `Event.Usage` handler, route `event.estimated_cost_usd`: orchestrator-owned → `put_orchestrator_estimate/2`; worker → existing `put_agent_estimate/3`. This stops orchestrator turns from polluting `@agent_est_costs`/`@cost_estimate` with stale per-turn synthetic keys.
- `@cost_estimate` (worker sum) is now only meaningful for workers; it is no longer read by the command panel after step 7. Leave it assigned (harmless) OR remove it if unused elsewhere — grep first (`grep -n cost_estimate lib/repo_builder_web/live/console_live.ex`). Do not introduce an unused-variable/assign warning under `--warnings-as-errors`.

### 7. Point the ORCHESTRATOR panel at the orchestrator-own assigns
- In the `command_panel` call site (`console_live.ex:2364-2371`) change `cost={@cost}` → `cost={@orchestrator_cost}` and `estimate={@cost_estimate}` → `estimate={@orchestrator_est_cost}`.
- Leave the header (`console_live.ex:2180`, `cost={@cost}`) and each `agent_card` (`console_live.ex:2236-2237`) untouched.

### 8. Reconcile the live total when a worker is removed (Option A)
- In the `{:agent_deleted, %Agent{} = agent}` handler (`console_live.ex:1806-1813`), before/with the existing roster rejects, subtract the removed worker's contribution from the totals so live state matches the durable cascade (`agent_id` FK `on_delete: :delete_all`):
  - Let `removed = Map.get(socket.assigns.agent_costs, agent.id)` and `removed_est = Map.get(socket.assigns.agent_est_costs, agent.id)`.
  - Set `@cost` to `subtract_cost(@cost, removed)` and `@cost_estimate` accordingly (define an `@spec`'d `subtract_cost/2` mirroring `accumulate_cost/2`: nil subtrahend ⇒ no-op; Decimal/float subtrahend ⇒ `Decimal.sub`; clamp the floor so a tiny residual never renders negative — if the result is `<= 0`, set it back to `nil` to preserve the unpriced "—" convention, consistent with `nilify_acc/1`).
  - Drop the per-agent entries: `agent_costs = Map.delete(@agent_costs, agent.id)` and `agent_est_costs = Map.delete(@agent_est_costs, agent.id)` (prevents stale entries and keeps the global estimate sum honest).
- Do NOT touch `@orchestrator_cost` here (orchestrator-own spend is unaffected by worker removal).
- Rationale comment in code: cite the cascade FK and that this keeps `Σ agents + orchestrator == total` equal to what a reconnect/reseed would compute.

### 9. Keep the live-broadcast assigns in sync for orchestrator record updates
- Verify the `{:orchestrator_updated, …}` / orchestrator-related `handle_info` paths (and any `assign_orchestrator/1` re-run on working-dir/selection change) do not stomp the new `orchestrator_cost`/`orchestrator_est_cost` assigns. If `assign_orchestrator/1` is re-invoked on updates, ensure it does NOT reset these cost assigns (re-seeding from `orchestrator_cost_rollup!/1` on an explicit reseed path is fine, but a selection change must not zero live-accumulated cost). Adjust only if a regression is found.

### 10. Add the LiveView integration test (fails before, passes after)
- Create `test/repo_builder_web/live/test_orchestrator_cost_sum_test.exs` using `RepoBuilderWeb.ConnCase` + `Phoenix.LiveViewTest` (model it on `test_live_cost_estimate_test.exs` and `test_claude_cost_no_double_count_test.exs`).
- Arrange: insert an orchestrator and at least one worker agent owned by it; insert priced `agent_logs` rows — some keyed by `agent_id` (worker) and some by `orchestrator_id` (orchestrator-own) via the same path `Logs.persist_orchestrator_event/2` uses (respect the `agent_id` XOR `orchestrator_id` validation).
- Act: `live(conn, "/")`; optionally also push live `Event.Usage` for a worker (`{:agent_event, worker_id, %Event.Usage{...}}`) and for the orchestrator (`{:agent_event, "orch-<orch_id>-1", %Event.Usage{...}}`) to exercise the live-routing branch, then render.
- Assert (the core invariant):
  - Parse the three rendered badges (header `#stat-cost`, the `#command-panel` ORCHESTRATOR badge, and the `#agent-<id>` card badge) — or assert on the assigns directly via the LiveView’s state — and verify `Σ(agent_costs over workers) + orchestrator_cost == cost` as `Decimal`s.
  - Assert the ORCHESTRATOR badge text ≠ the header badge text when a worker has nonzero cost (guards against the regression where they were identical).
  - Assert the header total includes orchestrator-own spend on a fresh mount (seed path), i.e. with only seeded logs and no live events the header equals `workers + orchestrator-own`.
  - **Worker-removal reconciliation (Option A):** with two workers having nonzero cost, send `{:agent_deleted, worker}` for one, then assert (a) its card is gone, (b) `@cost` dropped by exactly that worker's `@agent_costs`, and (c) the invariant `Σ(remaining agent_costs) + orchestrator_cost == cost` still holds — proving live state equals what a reseed would compute after the cascade delete.
- Confirm the test FAILS on the pre-fix code (run it against a stash of the change, or write it first) and PASSES after.

### 11. Validate
- Run every command in `Validation Commands`. Fix any formatting/credo/dialyzer issues introduced (preserve `@spec`s on all new private functions per `BUILD_PROMPT.md` §3 and `.credo.exs`).
- Optionally capture a screenshot of `http://localhost:4000` via Tidewave Web vision mode (or Playwright MCP) showing the three badges reconciling, as visual proof.

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- `mix test test/repo_builder_web/live/test_orchestrator_cost_sum_test.exs` — the new integration test passes (and demonstrably fails before the fix).
- `mix test test/repo_builder_web/live/test_live_cost_estimate_test.exs test/repo_builder_web/live/test_claude_cost_no_double_count_test.exs` — existing cost/estimate LiveView tests still pass (no regression in the routing change).
- `mix compile --warnings-as-errors` — clean compile; gradual set-theoretic type checker and `warnings_as_errors` pass.
- `mix test --warnings-as-errors` — full ExUnit suite, zero failures.
- `mix format --check-formatted` — formatting clean.
- `mix credo --strict` — lint clean, including the every-public-function-has-`@spec` rule.
- `mix dialyzer` — no new contract warnings, no stale ignore filters.

## Notes
- No new dependencies. No migration (the `orchestrator_id` column and `orchestrator_cost_rollup!/1` already exist).
- Keep the nil-vs-0 (`—` / `$0`) convention intact via the existing `nilify_zero/1`, `nilify_acc/1`, and `accumulate_cost/2` helpers — never coerce nil to `Decimal.new(0)` in the display path.
- Owner detection relies on the `"orch-"` `agent_id` prefix minted in `Orchestrator.Server` (`server.ex:101`, `server.ex:153`). If that prefix ever changes, this predicate must change with it — cite the contract in a code comment so the coupling is explicit. (A binary-id worker `agent_id` is a UUID and never starts with `"orch-"`, so the predicate is unambiguous.)
- Deliberately do NOT use `CostCenter.scope_spend(:orchestrator, …)` for the panel: that scope is the whole tree (orchestrator + workers) and would reproduce the double-count. The panel must show orchestrator-OWN spend (`Logs.orchestrator_cost_rollup!/1` + `"orch-"`-routed live events) only.
- Identity guaranteed after the fix (authoritative costs): `Σ @agent_costs(workers) + @orchestrator_cost == @cost`, continuously — including after a worker is removed (Option A reconciliation). Estimates are display-only fallbacks (`~$`) shown when authoritative cost is nil and are routed for panel parity, but the hard invariant the test asserts is the authoritative-cost sum.
- **Source-of-truth decision: Option A is DECIDED for this bug.** Worker deletion erases the worker's spend from the live total, matching the existing `agent_logs.agent_id` FK `on_delete: :delete_all` cascade. Minimal (one handler change, no migration); live state always equals a reconnect/reseed.
- **Future, separately-scoped (NOT this bug) — Option B:** if removed-agent spend must later be preserved as durable "real money", that is a distinct change: migrate the FK to `on_delete: :nilify_all`, denormalize `orchestrator_id` onto worker log rows at write time so orphaned spend stays attributable (revisit the XOR `validate_owner/1` constraint), and add a "removed/other agents" line to the console decomposition so `Σ visible + removed-bucket + orchestrator == total` stays honest with no card to host the orphaned spend. Do not implement here.
- **Latent inconsistency (known, NOT fixed here):** `CostCenter.period_spend/1` and `scope_spend/3` are documented as reporting "real money spent" (CLEAR/hidden rows preserved), yet hard agent deletion cascade-deletes `agent_logs`, so deleting a worker reduces those period/scope totals — contradicting the "real money" intent. This would be resolved by the future Option B work; under Option A it remains known behavior. Do NOT change `period_spend`/`scope_spend` semantics in this bug.
