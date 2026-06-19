# Bug: Claude harness double-counts the final billed cost (terminal `result` stamps `total_cost_usd` on BOTH the Usage and the Done)

## Metadata
issue_number: `claude-cost`
adw_id: `bug`
issue_json: `{"title":"Claude cost double-counted at end of run","body":"For the claude harness, the terminal result frame emits the same total_cost_usd on both the Event.Usage and the Event.Done. The console and orchestrator both accumulate cost_usd on the Usage handler AND the Done handler (additive), and persistence writes cost on both rows, so cost_rollup! sums it twice — claude runs end up showing/persisting ~2x the real billed amount. pi does not have this bug because it stamps cost on the Usage only and leaves Done.cost_usd nil."}`

## Bug Description
For the **claude** harness, the authoritative billed amount (`total_cost_usd`) is counted **twice** at the end of every run. The cost badges (agent card, command panel) and the persisted cost rollups (agent + orchestrator + cost report) settle on **~2× the real cost** for claude workers/orchestrators.

- **Expected:** at the end of a claude run, the live cost badge and the persisted `cost_rollup!`/`total_cost_usd` equal the harness-reported `total_cost_usd` exactly once.
- **Actual:** they equal `2 × total_cost_usd` — the same terminal amount is added on both the `Event.Usage` and the `Event.Done` handlers, and persisted on both the terminal `usage` row and the `done` row.

This is the latent issue flagged (out of scope) in `specs/issue-does-adw-not-sdlc_planner-live-cost-estimate-on-token-drop.md` → Notes → "Latent observation". The live-estimate work did **not** touch it (the estimate is replace-latest and never accumulated), so it can be fixed independently and surgically here.

## Problem Statement
`RepoBuilder.Harness.Claude.normalize/2`, on the terminal `result` frame, emits **two** canonical events that each carry the same authoritative `total_cost_usd`:

```elixir
# lib/repo_builder/harness/claude.ex:250-271
cost = Map.get(raw, "total_cost_usd")
done = %Event.Done{harness: :claude, ..., cost_usd: cost, ...}
{:ok, [usage_event(usage, raw, ctx, cost), done]}   # <-- Usage.cost_usd = cost  AND  Done.cost_usd = cost
```

Every downstream cost consumer is **additive** and runs on **both** the `Usage` and the `Done` handler, so the same amount is summed twice:

- **Live agent (console):** `console_live.ex:1576-1594` (`Event.Usage` → `add_cost`/`add_agent_cost`) **and** `console_live.ex:1611-1619` (`Event.Done` → `add_cost`/`add_agent_cost`). `accumulate_cost/2` is `Decimal.add`.
- **Live orchestrator:** `orchestrator/server.ex:222-226` (`Event.Usage` → `Orchestrators.add_cost`) **and** `orchestrator/server.ex:229-231` (`Event.Done` → `Orchestrators.add_cost`).
- **Persistence / reconnect seed:** `logs.ex:384-396` `usage_params/1` writes `cost_usd` for **both** the terminal `Event.Usage` row **and** the `Event.Done` row; `logs.ex:162-169` `cost_rollup!/1` (and `:175-181` `orchestrator_cost_rollup!/1`) then sum **every** priced row (`logs.ex:349-350`), so the reconnect seed (`console_live.ex` `seed_cost`/`seed_agent_costs`) and the cost report re-derive the doubled figure.

The invariant the rest of the system already relies on: **a harness stamps the authoritative `cost_usd` on exactly ONE terminal event.** pi obeys it — it stamps cost on the terminal `Usage` and leaves `Done.cost_usd` nil (`pi.ex:291-305`, `agent_end` builds `%Event.Done{...}` with no `cost_usd`). Claude **violates** it by stamping the same total on both.

## Solution Statement
Make claude obey the single-carrier invariant: keep `Event.Done` as the **sole** authoritative cost carrier for claude (its terminal `cost_usd` is the run total, already consumed by the console/orchestrator/persistence as the authoritative bill) and stop stamping that same total on the terminal `Event.Usage`. Concretely, drop the `cost` argument from the terminal `usage_event/4` call so the terminal `Usage` carries `cost_usd: nil` — exactly like every intermediate claude `Usage` — while still carrying its token-derived `estimated_cost_usd` (the live-estimate display signal is unchanged).

This is a **one-line** change in `lib/repo_builder/harness/claude.ex` and fixes the double-count in all four consumers at once (live agent, live orchestrator, persistence rollup, reconnect seed), because each of them only ever counts cost from whichever single event carries it:

- Terminal `Usage` now has `cost_usd: nil` → `add_cost(nil)`/`add_agent_cost(_, nil)` are no-ops; `usage_params(%Event.Usage{cost_usd: nil})` persists a NULL cost that `cost_rollup!` skips.
- `Done` keeps `cost_usd: total` → counted exactly once, live and persisted.

We deliberately do **not** change the canonical `Event` contract, the console/orchestrator handlers, or `logs.ex` — `Done.cost_usd` stays the authoritative claude carrier, so no other `Done.cost_usd` consumer (workflow cost, orchestrator cost report) is affected. We do **not** touch pi/fake/cursor (pi already correct; cursor emits no cost; fake is test-only). We keep `cost_usd: nil` distinct from `0.0` (no priced-0 regression).

## Steps to Reproduce
1. Start the app (`scripts/pg.sh start`, then `mix phx.server`) and open `http://localhost:4000`.
2. Run a real claude worker (or orchestrator) to completion so a `result` frame with `total_cost_usd` lands.
3. Observe the agent-card / command-panel cost badge settle on roughly **double** the `total_cost_usd` the claude CLI actually reported; the same doubled figure persists and re-appears after a LiveView reconnect (it is re-seeded from `cost_rollup!`).

Deterministic reproduction (no live harness):
- Feed a claude terminal `result` frame through `Claude.normalize/2` and assert the returned `Event.Usage` and `Event.Done` **both** currently carry the same non-nil `cost_usd` (the defect), then broadcast both events into `ConsoleLive` via `Dashboard.broadcast_event/2,3` and assert the cost badge shows `2 × total` (fails before the fix, single `total` after).
- Tidewave: `project_eval` to run `RepoBuilder.Harness.Claude.normalize(result_frame, ctx)` and inspect both events' `cost_usd`; `execute_sql_query` to confirm a finished claude agent has cost on **both** its `usage` and `done` `agent_logs` rows.

## Root Cause Analysis
`Claude.normalize(%{"type" => "result", "subtype" => "success"} = raw, ctx)` (`lib/repo_builder/harness/claude.ex:250-271`) reads `cost = Map.get(raw, "total_cost_usd")` once and threads it into **both** emitted events: `usage_event(usage, raw, ctx, cost)` (terminal `Usage.cost_usd = cost`) and `%Event.Done{... cost_usd: cost ...}`. Because the platform's cost accumulation is additive and is wired on **both** the `Usage` and `Done` handlers (console + orchestrator) and persisted for both rows (`logs.ex` `usage_params/1`, summed by `cost_rollup!/1`), the single authoritative total is counted twice for claude.

pi avoids this by stamping the per-run cost on the `Usage` only and leaving `Done.cost_usd` nil, so its additive accumulation sums to the correct single total. The fix aligns claude with the same single-carrier invariant (choosing `Done` as the carrier, since `Done.cost_usd` is the established authoritative-total field).

Note: this is the responsiveness bug's documented latent observation; the `estimated_cost_usd` field added there is replace-latest and never accumulated, so it neither caused nor is affected by this double-count.

## Relevant Files
Use these files to fix the bug:

- `lib/repo_builder/harness/claude.ex` — **primary fix.** Terminal `result` normalizer (`:250-271`) stamps `total_cost_usd` on both the terminal `Usage` (`usage_event(usage, raw, ctx, cost)` at `:268`) and the `Done` (`:263`). Drop the `cost` arg from the terminal `usage_event/4` call so the terminal `Usage` carries `cost_usd: nil` (estimate preserved). `usage_event/4` (`~:330-348`) already defaults `cost \\ nil`, so no signature change is needed.
- `lib/repo_builder/harness/pi.ex` — **reference, no change.** `agent_end` (`:291-305`) is the correct single-carrier pattern: cost on `Usage`, `Done.cost_usd` nil. Confirms the invariant.
- `lib/repo_builder_web/live/console_live.ex` — **no change (verify).** `Event.Usage` handler (`:1576-1594`) and `Event.Done` handler (`:1611-1619`) both call `add_cost`/`add_agent_cost`; correct once claude stamps cost on a single event. `accumulate_cost/2` and the `seed_cost`/`seed_agent_costs` reconnect path read whichever rows carry cost.
- `lib/repo_builder/orchestrator/server.ex` — **no change (verify).** `Event.Usage` (`:222-226`) and `Event.Done` (`:229-231`) both `Orchestrators.add_cost`; correct once the single-carrier invariant holds.
- `lib/repo_builder/logs.ex` — **no change (verify).** `usage_params/1` (`:384-398`) persists `cost_usd` from a `Usage` (`:390`) and from a `Done` with float cost (`:394-396`); `cost_rollup!/1` (`:162-169`) / `orchestrator_cost_rollup!/1` (`:175-181`) sum priced rows via `add_cost/2` (`:349-350`). With the fix, the terminal `Usage` row persists NULL cost (skipped) and the `Done` row persists the single total.
- `lib/repo_builder/harness/event.ex` — **no change (verify).** `Event.Usage` (`:102-116`) and `Event.Done` cost fields are unchanged; `cost_usd: nil` vs `0.0` distinction preserved.
- `BUILD_PROMPT.md` — §4 (canonical harness event contract), §8 (persistence, float→Decimal boundary, nil-vs-0), §9 (LiveView dashboard + reconnect rule). Authoritative for keeping the fix typed and idiomatic.

### New Files
- `test/repo_builder/harness/claude_cost_single_carrier_test.exs` — unit test on `Claude.normalize/2`: a terminal `result` frame yields a `Usage` with `cost_usd: nil` (and a non-nil `estimated_cost_usd`) and a `Done` with `cost_usd == total_cost_usd`; encodes the single-carrier invariant so a future regression is caught at the contract level.
- `test/repo_builder_web/live/test_claude_cost_no_double_count_test.exs` — `Phoenix.LiveViewTest` integration test: drive a claude terminal `result` frame through `Claude.normalize/2`, broadcast the resulting events into `ConsoleLive` (via `Dashboard.broadcast_event/2,3`), and assert the agent-card (and command-panel) cost badge shows the single `total` — not `2 × total`. Fails before the fix, passes after.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Confirm the double-count at the contract + persistence level (no code change)
- Read `lib/repo_builder/harness/claude.ex:250-271`, `console_live.ex:1576-1619`, `orchestrator/server.ex:222-233`, and `logs.ex:162-169,349-350,384-398` to confirm cost is accumulated/persisted on both the terminal `Usage` and the `Done`.
- Optionally use Tidewave `project_eval` to run `Claude.normalize/2` on a sample `result` frame and observe both events carrying the same `cost_usd`; `execute_sql_query` to confirm a finished claude agent has a priced `usage` row AND a priced `done` row for the same total.

### 2. Apply the surgical fix in `claude.ex`
- In the terminal `result` normalizer, change the emit from `{:ok, [usage_event(usage, raw, ctx, cost), done]}` to `{:ok, [usage_event(usage, raw, ctx), done]}` so the terminal `Event.Usage` carries `cost_usd: nil` (its `estimated_cost_usd` is still derived from `ctx`); the `%Event.Done{cost_usd: cost}` remains the single authoritative cost carrier.
- Keep `usage_event/4`'s `@spec`, the `cost \\ nil` default, and the `estimated_cost_usd` derivation exactly as-is. Add a brief comment on the changed line documenting the single-carrier invariant ("cost lives on Done only — see issue-claude-cost; double-counted otherwise").
- Run `mix compile --warnings-as-errors`.

### 3. Add the harness contract unit test
- Create `test/repo_builder/harness/claude_cost_single_carrier_test.exs`: build a claude `result` frame with a known `total_cost_usd` and a `usage` map (priced model in `ctx.price_table`); assert `Claude.normalize/2` returns a `Event.Usage{cost_usd: nil}` with a positive `estimated_cost_usd`, and a `Event.Done{cost_usd: total}`.
- Add a second assertion that the intermediate `assistant` usage also has `cost_usd: nil` (unchanged), to lock the "cost on Done only" invariant.

### 4. Add the LiveView regression test (fails before, passes after)
- Create `test/repo_builder_web/live/test_claude_cost_no_double_count_test.exs` (`use RepoBuilderWeb.ConnCase, async: false`):
  - Mount `~p"/"`, create a `harness: "claude"` agent and announce it via `send(view.pid, {:agent_created, agent})`.
  - Normalize a claude terminal `result` frame (with `total_cost_usd` = e.g. `0.10` and a usage map) via `Claude.normalize/2`, then broadcast each resulting event into the LiveView with `Dashboard.broadcast_event(agent.id, event)` in order (terminal `Usage`, then `Done`).
  - Assert the agent-card cost badge renders `$0.10` and **not** `$0.20` (i.e. counted once). Use `wait_until/1` polling on `render(element(view, "#agent-#{agent.id}"))` mirroring `test/repo_builder_web/live/test_activity_orb_test.exs`.
  - This assertion fails before Step 2 (badge shows `$0.20`) and passes after.
- Optionally capture a screenshot of `http://localhost:4000` via Tidewave Web vision mode as visual proof; do NOT use the browser to validate CSS/styling.

### 5. Add a persistence/rollup regression assertion (orchestrator + agent)
- In an existing or new context-level test (e.g. extend `test/repo_builder/logs_test.exs` or add to the claude test), persist a terminal `Event.Usage{cost_usd: nil}` and `Event.Done{cost_usd: total}` for one agent (mirroring the fixed claude output) and assert `Logs.cost_rollup!(agent_id)` equals `total` (once). If a pre-fix snapshot is useful, also assert that persisting cost on both rows would double — but keep the committed test asserting the corrected single-count behavior.

### 6. Run the full validation suite
- Run every command in **Validation Commands** and confirm all are green with zero regressions (the authoritative cost totals, nil-vs-0 semantics, and the live `estimated_cost_usd` display are all unchanged except for the corrected single count).

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- `mix test test/repo_builder/harness/claude_cost_single_carrier_test.exs` — claude emits the authoritative cost on `Done` only; terminal `Usage.cost_usd` is nil (estimate preserved).
- `mix test test/repo_builder_web/live/test_claude_cost_no_double_count_test.exs` — the cost badge counts a claude terminal cost exactly once (fails before the fix with `$0.20`, passes after with `$0.10`).
- `mix compile --warnings-as-errors` — clean compile; the gradual set-theoretic type checker and `warnings_as_errors` pass.
- `mix test --warnings-as-errors` — full ExUnit suite (Postgres-backed) green, zero regressions; confirms nil-vs-0 semantics and the live estimate are unchanged.
- `mix format --check-formatted` — formatting clean.
- `mix credo --strict` — lint clean, including the `@spec`-on-every-public-function gate.
- `mix dialyzer` — no new contract warnings, no stale ignore filters.

## Notes
- **No new dependency.** One-line behavioral change in `claude.ex` plus tests.
- **Why fix at the harness, not the consumers:** the double-count manifests in four places (live agent, live orchestrator, persistence rollup, reconnect seed). Fixing the single source — claude stamping cost on one terminal event instead of two — corrects all four with the minimal change and without altering the canonical `Event` contract or the `add_cost`/`cost_rollup!` plumbing that pi and every other harness already rely on.
- **Why `Done` is the kept carrier (not the terminal `Usage`):** `Done.cost_usd` is the established authoritative-total field consumed by the console, orchestrator, and any workflow/cost-report path; leaving it intact avoids touching those consumers. The terminal `Usage` cost was the redundant copy.
- **Preserve nil-vs-priced-0:** the terminal `Usage` now carries `cost_usd: nil` (unpriced/no-authoritative-here), never `0.0`; the `Done` carries the real total. The cost-center `derive_costs`/`estimated?` semantics are untouched.
- **Historic data is already doubled (out of scope):** claude `agent_logs` rows written before this fix carry cost on both the `usage` and `done` rows, so historic `cost_rollup!`/`total_cost_usd` for past claude runs remain doubled. A backfill/data migration to null the redundant historic `usage`-row cost is **not** included here (forward-only fix); flag it for a separate data-cleanup ticket if historic accuracy is required.
- **Possible sibling case (separate ticket, verify, do NOT fix here):** the ADW harness (`lib/repo_builder/harness/adw/event_schema.ex`) decodes `cost_usd` on its `done` frame (`:188`) and also derives cost on its `usage` frames (`:224-246`); if an ADW emits the same authoritative total on both, it would double-count the same way. Confirm against the ADW emitter contract (`adws/adw_emit.py`) and file separately if real — it is independent of this claude fix.
- **Tidewave during implementation:** `project_eval` to run `Claude.normalize/2` and inspect both events' `cost_usd`; `get_logs` to watch the live `{:agent_event, …}` flow; `execute_sql_query` to confirm the per-row cost persistence before/after.
```
