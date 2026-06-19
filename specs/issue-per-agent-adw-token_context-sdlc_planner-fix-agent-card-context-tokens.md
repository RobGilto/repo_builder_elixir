# Bug: Agent-card context-window bar/number stays empty (undercounts tokens + not backfilled)

## Metadata
issue_number: `per-agent`
adw_id: `token/context`
issue_json: `display`

## Bug Description
On the console left-rail **agent card**
(`lib/repo_builder_web/components/console_components.ex:232` `agent_card`), the
**CONTEXT WINDOW** bar (`console_components.ex:261`) and its `"{ktok}/200k"` number
(`console_components.ex:259`) stay empty / near-zero, and the per-category counters
(💬 responses / 🛠️ tools / 🪝 hooks / 🧠 thinking, lines 266-271) show `0` — even
for an agent with heavy, persisted activity. The center event stream **does** show
that agent's logs (they are backfilled), which is the tell that the data exists but
the card isn't reflecting it.

- **Expected:** the context bar fills to the agent's true context-window occupancy
  (e.g. ~96% for a long resumed Claude session) with a matching `kTok / 200k`
  number, and the counters show the real per-category event counts — both on first
  mount and after a reconnect.
- **Actual:** the bar reads ~0–1% and counters read `0`, despite dozens of
  persisted usage/tool/text events for the agent.

(The cost badge at `console_components.ex:278` is **correct** and out of scope — see
Root Cause.)

## Problem Statement
The agent card's per-agent context-token and counter values are both (1) computed
from the wrong fields when live, and (2) never seeded from the database on
mount/reconnect — so they are empty whenever the agent's work happened before the
LiveView observed it live, and even live they grossly undercount the context window.

## Solution Statement
Two surgical fixes, both behind the existing typed seams:

1. **Count the real context window (live path).** Change the per-agent context
   computation to include the cache tokens that dominate a resumed Claude prompt:
   `context_size(usage) = input_tokens + (cache_read || 0) + (cache_creation || 0)`
   (exclude `output_tokens` — it is the generated reply, not prompt occupancy). The
   `Event.Usage` struct already carries `cache_read`/`cache_creation`, so no event
   or adapter change is needed — only the consumer in `ConsoleLive`.

2. **Seed per-agent stats on mount/reconnect.** Add `@spec`'d rollup functions to
   the `Logs` context that compute, per agent, (a) the latest context-window size
   and (b) the per-category event counts, then seed `@context_tokens` and
   `@counters` in `mount` (mirroring the existing `seed_agent_costs/1`) and re-seed
   them in `backfill_events/1` so a reconnect restores them. All DB access stays
   behind `Logs` (`BUILD_PROMPT.md` §8); the counter category mapping mirrors the
   live `record_event`→`bump_counter` logic so seeded values agree with subsequent
   live increments.

## Steps to Reproduce
1. Run an agent (e.g. a Claude worker) long enough to accrue usage with cache reads
   (a resumed session), then reload the console (`/`) so the LiveView mounts after
   the work.
2. Observe the agent's card: CONTEXT WINDOW bar is ~empty, number ~`0k / 200k`,
   counters all `0` — while the center stream shows the agent's logs.
3. Verified live (agent `2134b5bb-c5a5-45d3-a9a9-5d210198ff64`): the latest `usage`
   row is `input=54, output=1646, cache_read=160059, cache_creation=32758`. The card
   shows ≈`1700` tokens (input+output) instead of the true
   `54 + 160059 + 32758 = 192871` (~96% of 200k). The agent has 47 usage / 21
   tool_call / 21 tool_result / 23 text_delta persisted rows, yet counters read `0`.

## Root Cause Analysis
- **Bug 1 — undercount (live).** `ConsoleLive`'s
  `handle_info({:agent_event, agent_id, %Event.Usage{} = event, seq_no}, …)`
  (~`console_live.ex:1534`) calls `put_context(agent_id, event.input_tokens +
  event.output_tokens)`. This omits `cache_read` + `cache_creation`, which are the
  bulk of a resumed Claude prompt. The `Event.Usage` typedstruct
  (`lib/repo_builder/harness/event.ex`) **does** carry `cache_read`/`cache_creation`
  (`enforce: false`), populated by the Claude adapter `usage_event/3`
  (`claude.ex:293-300`, from `cache_read_input_tokens` /
  `cache_creation_input_tokens`). So the data is present and simply dropped by the
  consumer. `put_context/2` (`console_live.ex:1958-1961`) just stores whatever it is
  handed.
- **Bug 2 — not backfilled.** In `mount`, only `@agent_costs` is seeded
  (`seed_agent_costs/1`, `console_live.ex:364`, via `Logs.cost_rollup!/1`).
  `@context_tokens` and `@counters` are initialized to `%{}`
  (`console_live.ex:141-142`) and are mutated **only** by live PubSub
  (`put_context/3` ~`1961`, `bump_counter/3` ~`1941`). `backfill_events/1` reseeds
  the center stream + `messages` but **not** `@context_tokens`/`@counters`. Result:
  any agent whose events predate the mount (or a reconnect) shows an empty bar and
  zero counters, even though `list_recent_global` backfills its rows into the
  stream.
- **Not a bug (cost).** `Logs.cost_rollup!/1` (`logs.ex:154`) sums `cost_usd` across
  **all** the agent's logs incl. `done` rows; for the sample agent it returns
  `$0.55`, and `seed_agent_costs/1` seeds it per-agent into `@agent_costs`, which the
  badge reads via `Map.get(@agent_costs, agent.id)`. The cost path is correct and
  must be left untouched.

## Relevant Files
Use these files to fix the bug:

- `lib/repo_builder_web/live/console_live.ex` — The consumer to fix:
  - `~1534` `Event.Usage` handler: compute context via a new nil-safe
    `context_size/1` over the usage struct (include cache tokens).
  - `~1958-1961` `put_context/2` helper (storage; unchanged, or accept the computed
    value).
  - `~1939-1956` `bump_counter/3` + `counter_key/1` — the live counter mapping
    (`:response→:responses`, `:tool→:tools`, `:thinking→:thinking`, `:hook→:hooks`)
    that the DB seeding must match.
  - `364` `seed_agent_costs/1` — the pattern to mirror for new
    `seed_context_tokens/1` + `seed_counters/1`.
  - `~141-142` mount init of `@counters`/`@context_tokens`; `mount` seed pipeline
    (`~198`); `backfill_events/1` (re-seed on reconnect).
- `lib/repo_builder/logs.ex` — Add `@spec`'d per-agent rollups:
  `context_tokens_by_agent/0..1` (latest `usage` row's context size per agent) and
  `event_counts_by_agent/0..1` (per-agent per-category counts). Mirror
  `cost_rollup!/1`'s query style; keep all `Repo`/`Ecto.Query` access here (§8).
- `lib/repo_builder/harness/event.ex` — `Event.Usage` struct (confirm
  `cache_read`/`cache_creation` fields; no change expected).
- `lib/repo_builder/harness/claude.ex` — `usage_event/3` (`~293-300`); confirms the
  cache fields are populated (no change).
- `lib/repo_builder/logs/agent_log.ex` — the `agent_logs` schema (`usage` JSONB
  embed, `event_type`, `payload`); source of the rollup queries. Confirm how the
  thinking-vs-response distinction is persisted (payload flag) so counter seeding
  matches live.
- `lib/repo_builder_web/components/console_components.ex` — `agent_card/1`
  (`232`), `context_pct/1`, `ktok/1` (rendering; read-only reference, no change).
- `BUILD_PROMPT.md` — §3 typed style, §8 DB-behind-context, §9 LiveView.
- `.claude/commands/conditional_docs.md` — check for any docs to include.

### New Files
- `test/repo_builder_web/live/test_agent_card_context_tokens_test.exs` —
  `Phoenix.LiveViewTest`: seed an agent + persisted `usage` logs (incl.
  `cache_read`/`cache_creation`) + a few tool/text rows, mount the console, and
  assert the rendered card shows the correct `kTok / 200k` number, a non-trivial
  `--ctx-bar__fill` width (≈ correct %), and non-zero counters. Fails before the
  fix, passes after.
- (Tests for the new `Logs` functions may live in the existing
  `test/repo_builder/logs_test.exs` or a new `logs_rollups_test.exs`.)

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Reproduce + confirm the contract
- Read `BUILD_PROMPT.md` §3/§8/§9 and `.claude/commands/conditional_docs.md`.
- Use Tidewave `get_source_location` on the `Event.Usage` handler, `put_context/2`,
  `bump_counter/3`, `seed_agent_costs/1`, `backfill_events/1`, and `Logs.cost_rollup!/1`.
- Reproduce with Tidewave `execute_sql_query`/`project_eval` against agent
  `2134b5bb-c5a5-45d3-a9a9-5d210198ff64`: confirm the latest usage row
  (`input=54,output=1646,cache_read=160059,cache_creation=32758`) and that
  `input+cache_read+cache_creation = 192871`.

### 2. Add the typed Logs rollups (foundation, DB behind context)
- In `lib/repo_builder/logs.ex` add:
  - `@spec context_tokens_by_agent() :: %{Ecto.UUID.t() => non_neg_integer()}` (and/or
    `/1` for a single agent) — for each agent, the **latest** `usage` row's context
    size = `input_tokens + COALESCE(cache_read,0) + COALESCE(cache_creation,0)`
    (read from the `usage` JSONB; order by `seq_no` desc). Use the SAME
    `context_size` definition as the live path (extract a shared helper if it keeps
    types clean).
  - `@spec event_counts_by_agent() :: %{Ecto.UUID.t() => %{responses: n, tools: n, hooks: n, thinking: n}}`
    — per-agent counts mapped to the four counter keys, mirroring the live
    `record_event`→`bump_counter` category derivation (responses = finalized
    non-thinking `text_delta`; thinking = thinking `text_delta`; tools = `tool_call`;
    hooks = `hook`/`status`). Read the thinking flag from `payload` exactly as the
    live handler distinguishes it, so seeded counts equal what live increments would
    have produced. Document any deliberate simplification.
- Keep both functions pure reads behind `Logs`; no LiveView touches `Repo`.

### 3. Fix the live undercount (Bug 1)
- In `console_live.ex`, add a nil-safe `@spec`'d `context_size(Event.Usage.t()) ::
  non_neg_integer()` = `input_tokens + (cache_read || 0) + (cache_creation || 0)`.
- Change the `Event.Usage` handler (~1534) to `put_context(agent_id,
  context_size(event))`. Leave `put_context/2` storage as-is. Do NOT include
  `output_tokens`.

### 4. Seed per-agent stats on mount + reconnect (Bug 2)
- Add `seed_context_tokens/1` and `seed_counters/1` to `console_live.ex` mirroring
  `seed_agent_costs/1`, sourcing from the new `Logs` rollups and keying by
  `agent.id`. Insert them into the mount seed pipeline next to `seed_agent_costs`.
- Re-seed all three (`context_tokens`, `counters`, and confirm `agent_costs`) inside
  `backfill_events/1` so a reconnect restores the card, consistent with the stream
  re-seed. Ensure seeded `@counters` use the exact `%{responses:, tools:, hooks:,
  thinking:}` shape `bump_counter/3` expects so later live increments merge cleanly.

### 5. LiveView integration test (reproduce → prove)
- Create `test/repo_builder_web/live/test_agent_card_context_tokens_test.exs`: seed
  an agent and persisted `usage` rows (incl. large `cache_read`/`cache_creation`) plus
  a couple `tool_call`/`text_delta` rows via the `Logs`/Repo test path; `live/2` the
  console; assert the card renders the correct `kTok / 200k` and a fill width matching
  the expected percentage (e.g. via `element/2` + `render/1` on the agent card), and
  non-zero counters. Confirm it fails before Steps 3-4 and passes after.

### 6. Logs unit tests
- Add tests for `context_tokens_by_agent` (latest-row context size incl. cache) and
  `event_counts_by_agent` (category mapping matches the live counters), including the
  empty-agent case (no rows ⇒ absent/0).

### 7. Validate
- Run all **Validation Commands**; fix until green. Re-check live with Tidewave
  `project_eval` that the new `Logs.context_tokens_by_agent/0` returns ~`192871` for
  the sample agent, and visually confirm the card bar fills on reload (optionally a
  Tidewave Web/Playwright screenshot of `http://localhost:4000`).

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- `mix test test/repo_builder_web/live/test_agent_card_context_tokens_test.exs` —
  card shows correct context kTok/percent + non-zero counters from backfilled logs.
- `mix test test/repo_builder/logs_test.exs` (or the new rollups test) — new Logs
  rollups correct, incl. cache tokens and category mapping.
- `mix test test/repo_builder_web/live/` — no LiveView regressions (existing
  console/agent-card tests still green).
- `mix compile --warnings-as-errors` — clean compile; set-theoretic checker +
  warnings pass.
- `mix test --warnings-as-errors` — full suite green, zero regressions.
- `mix format --check-formatted` — formatted.
- `mix credo --strict` — lint incl. every-public-fn-`@spec`.
- `mix dialyzer` — no new contract warnings, no stale ignores.
- Tidewave (live app): `project_eval` `RepoBuilder.Logs.context_tokens_by_agent()`
  includes `~192871` for `2134b5bb-c5a5-45d3-a9a9-5d210198ff64`; reload `/` and
  confirm that agent's CONTEXT WINDOW bar is ~96% full with the matching number.

## Notes
- **Why exclude `output_tokens` from context:** the context-window occupancy is the
  prompt side (input + cached prefix). `output_tokens` is the generated reply; it
  only affects the *next* turn's input, which the subsequent usage event already
  reflects. Including it would double-count and is negligible vs cache anyway.
- **`cache_read` dominates resumed sessions:** Claude `--resume` re-reads the cached
  conversation prefix, so `cache_read` (and `cache_creation` on first cache) is where
  nearly all the context lives. Counting only `input+output` made the bar effectively
  dead for exactly the long sessions where it matters most.
- **Counter parity:** seed `@counters` with the same category mapping the live
  `record_event`/`bump_counter` path uses, so a reconnect mid-run doesn't double- or
  under-count once live events resume. If the persisted thinking-vs-response split is
  awkward to derive from `payload`, document the chosen rule in the `Logs` function.
- **Cost is intentionally untouched** — verified correct ($0.55 for the sample agent,
  seeded per-agent). Do not modify `cost_rollup!`/`seed_agent_costs`.
- **No schema/migration/dependency changes** — `agent_logs.usage` already stores
  `cache_read`/`cache_creation`; this is read-path only.
