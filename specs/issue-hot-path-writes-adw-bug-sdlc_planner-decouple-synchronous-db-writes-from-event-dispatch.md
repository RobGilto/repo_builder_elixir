# Bug: synchronous DB writes on the event hot path (Session dispatch persists inline; Orchestrator turn does ~6 DB round-trips per Usage event) — fix in-process, keep ONE server

## Metadata
issue_number: `hot-path-writes`
adw_id: `bug`
issue_json: `{"title":"Event hot path blocks on synchronous DB writes (per-session persistence inline; per-Usage orchestrator write storm)","body":"Two in-process throughput defects on the canonical-event hot path. (1) Session.Server.dispatch/2 persists each event (Logs.persist_event + a status update) SYNCHRONOUSLY before broadcasting, so a slow agent_logs insert head-of-line-blocks that session's NEXT event (handle_info is serial). (2) Orchestrator.Server does THREE separate get+update DB round-trips (add_cost, add_usage, set_estimated_cost) on EVERY Usage event during token streaming — ~6 round-trips/event on the same orchestrator row, on the same process that also dispatches in-process tool calls. Decision: keep ONE BEAM node (no separate logging service). Fix by moving persistence off the dispatch path via a supervised async writer, and by coalescing the orchestrator's per-Usage writes into one flush while preserving live cost telemetry."}`

## Bug Description
Both defects are **throughput / latency** bugs on the canonical-event hot path. Neither corrupts data today; both put **synchronous Ecto round-trips on a per-event critical path that also carries live UI streaming and orchestrator coordination**, so under real token-streaming load (and any DB latency spike) the live event stream stalls and the orchestrator row is hammered.

- **Expected:** an agent's canonical events fan out to the live UI and the orchestrator **without waiting on `agent_logs`/`orchestrators` writes**; persistence happens off the hot path and never head-of-line-blocks the next event; an orchestrator turn persists its cost/usage with **one** write per turn, not one-per-token-delta.
- **Actual:** `Session.Server.dispatch/2` **blocks on the `agent_logs` insert** (plus a status update) before it broadcasts, and because `handle_info` is serial, a slow insert delays *every subsequent event* for that session. Separately, `Orchestrator.Server` issues **three independent `get`+`update` pairs per `Usage` event** (`add_cost`, `add_usage`, `set_estimated_cost`) — ~6 DB round-trips per streamed usage frame — on the same process that synchronously dispatches in-process tool calls.

**Architecture decision recorded here (do NOT relitigate during implementation): we keep ONE server.** The reference pattern in `disler/pi-agent-observability` runs a *separate* observability process (Bun + SQLite + SSE) only because its agent and UI live in different runtimes and must talk over HTTP. On the BEAM that coupling is already solved — `Phoenix.PubSub` is the in-memory transport, Phoenix LiveView is the live channel, Postgres is the store, and `RepoBuilder.Harness.Event` is the canonical envelope. The fix is therefore **purely in-process decoupling on the single node** — a supervised async writer plus write-coalescing — NOT a new service, node, or datastore.

## Problem Statement

### Part A — Session persistence is inline on the dispatch hot path
`RepoBuilder.Session.Server.dispatch/2` (`lib/repo_builder/session/server.ex:450-489`) does, **in order, synchronously, in the session GenServer**:

```elixir
log =
  if state.agent_db_id do
    update_status_quietly(event, state)        # Agents.set_status → Repo.update   (DB write)
    if persist?(event), do: persist_quietly(event, state)   # Logs.persist_event → Repo.insert (DB write, returns seq_no)
  end
log = if state.orchestrator_db_id && persist?(event), do: persist_orchestrator_quietly(event, state), else: log
seq_no = log && log.seq_no
_ = Phoenix.PubSub.broadcast(@pubsub, "agent:#{agent_id}:events", {:harness_event, event})  # ← only AFTER the writes
if state.broadcast_feed? do
  _ = RepoBuilder.Dashboard.broadcast_event(agent_id, event, seq_no)   # global feed needs seq_no
  _ = maybe_broadcast_lane(event, state)
end
_ = maybe_emit_worker_terminal(event, state)
```

Because `Session.Server` processes frames one at a time (`handle_info(:data, …)` → `process_line` → `dispatch`), **the `agent_logs` insert sits on the critical path of the next event.** A slow/contended insert delays the per-agent broadcast (which the focused agent view *and* `Orchestrator.Server` subscribe to) and every following token. This is the platform's main fan-out hub — one per live session — so the stall is per-session head-of-line blocking.

The one genuine coupling that keeps persistence on this path: the **global feed broadcast carries the durable `seq_no`** (`Dashboard.broadcast_event(agent_id, event, seq_no)`), and `seq_no` comes from the insert (`AgentLog.seq_no`, `read_after_writes: true`, `lib/repo_builder/logs/agent_log.ex:63-66`). So persistence cannot simply be "fire-and-forget" without losing the `log-<n>` drilldown number on the live feed.

### Part B — Orchestrator turn does ~6 DB round-trips per Usage event
`RepoBuilder.Orchestrator.Server` handles each streamed `Event.Usage` with **three separate context calls, each its own `Repo.get` + `Repo.update`** (`lib/repo_builder/orchestrator/server.ex:222-227`):

```elixir
def handle_info({:harness_event, %Event.Usage{} = event}, %State{} = state) do
  _ = Orchestrators.add_cost(state.orchestrator_id, event.cost_usd)               # get + update   (lib/repo_builder/orchestrator.ex:386-405)
  _ = Orchestrators.add_usage(state.orchestrator_id, event.input_tokens, event.output_tokens)  # get + update (:441-456)
  _ = Orchestrators.set_estimated_cost(state.orchestrator_id, event.estimated_cost_usd)         # get + update (:423-431)
  {:noreply, state}
end
```

During a streaming turn a harness emits many `Usage` frames; each costs **~6 DB round-trips on the same `orchestrators` row**, in the process that also dispatches in-process tool calls (`:217-220`). Two of the three updates are **replace-latest, not additive** (`set_estimated_cost` overwrites; `add_usage` overwrites `context_tokens`), so only the final value matters — every intermediate write is wasted. Only the **accumulating** fields (`total_cost_usd`, lifetime `input_tokens`/`output_tokens`) must sum across frames, and a sum is trivially held in GenServer state and flushed once.

The one invariant that MUST be preserved: `Orchestrators.add_cost/2` also emits the shared cost telemetry (`:telemetry.execute([:repo_builder, :cost, :recorded], …)`, `lib/repo_builder/orchestrator.ex:396-400`) that **`RepoBuilder.Budget.Guard` consumes for live cap enforcement**. Coalescing the DB *write* must NOT coalesce the per-event *telemetry* — budget enforcement has to see each increment live.

## Solution Statement
Two surgical, independent in-process changes on the single node. No new service, node, datastore, or dependency.

### Part A — move persistence (and the seq_no-bearing global-feed broadcast) off `dispatch/2`
Introduce a supervised `RepoBuilder.Logs.Writer` that owns the DB side-effects and the **seq_no-carrying** global-feed broadcast, freeing `Session.Server.dispatch/2` to fan out immediately.

- `dispatch/2` keeps doing, **synchronously and first**, the latency-critical work that needs no DB: the **unconditional per-agent broadcast** (`"agent:#{agent_id}:events"`) and the lifecycle-only `maybe_broadcast_lane`/`maybe_emit_worker_terminal` (terminal-only, rare). The orchestrator and focused agent view — the timing-sensitive subscribers — are served instantly.
- `dispatch/2` then `cast`s the event + persist context to the per-row `Logs.Writer` partition. The Writer: runs `update_status_quietly`-equivalent status update, runs `Logs.persist_event/2` (or `persist_orchestrator_event/2`), obtains the durable `seq_no`, and **then** does the global-feed broadcast `Dashboard.broadcast_event(agent_id, event, seq_no)`. The global "firehose" feed thus lands a few hundred microseconds later but still carries the correct `log-<n>` — while the per-agent stream is never delayed by the DB.
- **Ordering** is preserved by routing every event for a given durable row (`agent_db_id` or `orchestrator_db_id`) to the **same** writer partition (a `PartitionSupervisor` of `Logs.Writer`, partition = `:erlang.phash2(row_id)`), and casting in dispatch order from the single `Session.Server`. Same row → same writer → FIFO. Different agents persist in parallel.
- **Failure isolation** is unchanged in spirit: the Writer keeps the existing `rescue`/`catch` → degrade-to-`nil` behavior (`persist_quietly`/`persist_orchestrator_quietly` already do this). A DB blip drops that row's `seq_no` to `nil` (feed shows "—") and never crashes the session — exactly today's contract, just off the hot path.
- **Backpressure:** the Writer is a plain GenServer with a bounded-by-convention mailbox; if persistence falls behind, casts queue in the Writer, not in `Session.Server`. (A hard cap / shed-load policy is out of scope; note it in code.)

This deletes the `Logs.persist_event` / `update_status_quietly` calls from `dispatch/2` and the `seq_no`-dependent global-feed broadcast, replacing them with one `Logs.Writer.record/…` cast. The canonical `Event` contract, the redaction boundary, the `seq_no` semantics, and the reconnect/backfill path are all unchanged.

### Part B — coalesce the orchestrator's per-Usage writes into one flush
Make `Orchestrator.Server` accumulate cost/usage in its own `State` and write the `orchestrators` row **once per turn** (on `Done`/`Error`/terminate), while still firing the live cost telemetry per `Usage`.

- On each `Event.Usage`: update **in-memory** state — `acc_cost = Decimal.add(acc_cost, cost_usd)`, `in_tokens += input_tokens`, `out_tokens += output_tokens`, `last_context = input + output`, `last_estimate = estimated_cost_usd` — and **fire the cost telemetry** for that increment so `Budget.Guard` enforces live (extract the `:telemetry.execute` so it runs without a DB write, e.g. a new `Orchestrators.emit_cost_telemetry/2` or `add_cost` split into "record + emit" vs "emit only").
- On `Event.Done` / `Event.Error` / `terminate/2`: **flush once** — a single `update_record` writing the accumulated `total_cost_usd` (current + acc), cumulative `input_tokens`/`output_tokens`, latest `context_tokens`, latest `estimated_cost_usd`, plus the final status — replacing the three separate get+update pairs. This is **one** DB round-trip for the whole turn instead of ~6 per Usage frame.
- The **live UI is unaffected**: `ConsoleLive` renders orchestrator cost/usage from the `{:agent_event, …}` event stream, not from the row, so during the turn the display is still live. Only the *persisted* row lags within a turn (accepted tradeoff — see Notes; a debounced periodic flush is the documented escape hatch if mid-turn reconnect accuracy ever matters).
- **Crash safety:** flush in `terminate/2` (best-effort, guarded) so a turn that dies before `Done` still persists its accumulated cost — matching today's incremental-write durability.

We deliberately do **not** change the `Event` contract, the telemetry topic, `Budget.Guard`, or the additive-vs-replace-latest semantics of `add_cost`/`add_usage`/`set_estimated_cost` (the flush reuses them or `update_record` directly).

## Steps to Reproduce
1. Start the app (`scripts/pg.sh start`, then `mix phx.server`) and open `http://localhost:4000`.
2. **Part A:** run a worker whose harness emits a dense token stream (a real claude/pi worker, or the `fake` harness with a long canned sequence). Artificially slow `agent_logs` inserts (e.g. add a `Process.sleep` in `Logs.persist_event/2` locally, or load the DB) and observe the **per-agent live stream and the focused agent view stutter in lock-step with insert latency** — the next token does not appear until the prior insert returns.
3. **Part B:** start an orchestrator turn and let it stream usage frames. Via Tidewave `get_logs` / DB query, observe **multiple `UPDATE orchestrators …` statements per turn** (three per Usage frame). Count round-trips with `execute_sql_query` against `pg_stat_statements` (or Ecto telemetry) before/after.

Deterministic reproduction (no live harness):
- **Part A:** feed N events through a `Session.Server` whose `Logs.persist_event` is stubbed to block; assert the per-agent topic receives event K+1 **before** event K's insert completes (fails today — per-agent broadcast is gated behind the insert; passes after the writer split).
- **Part B:** drive M `Event.Usage` frames into `Orchestrator.Server` and assert exactly **one** `orchestrators` UPDATE occurs across the turn (on `Done`), while the cost telemetry handler observed M increments (fails today with 3·M updates; passes after coalescing).

## Root Cause Analysis
- **Part A:** `dispatch/2` was written as a single synchronous hub that *persists then broadcasts* so the global feed could carry the insert's `seq_no` (`server.ex:455-485`). Correct for correctness, wrong for latency: the per-agent broadcast and every following event inherit the insert's latency because the GenServer is serial. The seq_no requirement is real but only binds the **global feed** broadcast — not the per-agent stream — so moving just persistence + the global-feed broadcast to an async per-row writer removes the head-of-line blocking while keeping `log-<n>`.
- **Part B:** `add_cost`/`add_usage`/`set_estimated_cost` were each written as standalone, self-contained `get`+`update` context functions (`orchestrator.ex:386-456`) and wired one-per-call into the `Usage` handler (`orchestrator/server.ex:222-226`). Convenient, but on a per-token event it multiplies into a write storm against one row, two-thirds of it replace-latest writes that only the last value needs. The cost telemetry is entangled inside `add_cost`, which is why naive coalescing would silently break live budget enforcement — the fix must split "emit telemetry" (per event) from "persist total" (once).

## Relevant Files
Use these files to fix the bug:

- `lib/repo_builder/session/server.ex` — **Part A primary.** `dispatch/2` (`:450-489`) currently calls `update_status_quietly` (`:596-612`), `persist_quietly` (`:558-575`), `persist_orchestrator_quietly` (`:577-594`) synchronously and then broadcasts. Replace the persistence + seq_no-bearing global-feed broadcast with a `Logs.Writer` cast; keep the unconditional per-agent broadcast (`:478`) and `maybe_broadcast_lane`/`maybe_emit_worker_terminal` synchronous. The three `*_quietly` helpers move (or delegate) into the Writer.
- `lib/repo_builder/logs.ex` — **Part A, no behavioral change.** `persist_event/2` (`:34`) and `persist_orchestrator_event/2` (`:69`) are reused verbatim by the Writer; keep redaction and the `seq_no` return.
- `lib/repo_builder/logs/agent_log.ex` — **reference.** `seq_no` is `read_after_writes: true` (`:63-66`) — the durable monotonic number the Writer reads post-insert and forwards on the global feed.
- `lib/repo_builder/dashboard.ex` — **Part A, no change (verify).** `broadcast_event/3` (global feed, carries `seq_no`) is now called from the Writer; `broadcast_lane`/`broadcast_worker_terminal` stay called from `Session.Server`.
- `lib/repo_builder/orchestrator/server.ex` — **Part B primary.** `Event.Usage` handler (`:222-227`) → accumulate in `State` + emit telemetry only; `Event.Done` (`:229-233`) / `Event.Error` (`:235-238`) → single flush; add a guarded `terminate/2` flush. Extend `State` with `acc_cost`/`in_tokens`/`out_tokens`/`last_context`/`last_estimate`.
- `lib/repo_builder/orchestrator.ex` — **Part B.** Split the telemetry emission out of `add_cost/2` (`:386-405`) so it can fire per-event without a write (e.g. `emit_cost_recorded/2`); add a single coalesced writer (`flush_turn/2` or reuse `update_record/2`, `:529`) that writes accumulated cost/usage/estimate/status in one `Repo.update`. Keep `add_cost`/`add_usage`/`set_estimated_cost` intact for other callers.
- `lib/repo_builder/application.ex` — **Part A.** Add the `Logs.Writer` (as a `PartitionSupervisor` of writers) to the supervision tree **after** `Repo` and `Phoenix.PubSub`, before/around the session runtime block (`:18-65`).
- `lib/repo_builder/budget/guard.ex` — **Part B, no change (verify).** Confirm it subscribes to `[:repo_builder, :cost, :recorded]` and still receives one telemetry event per `Usage` after the write is coalesced.
- `BUILD_PROMPT.md` — §4 (canonical harness event contract), §5 (session runtime / supervision), §8 (persistence, redaction, float→Decimal, nil-vs-0), §9 (LiveView dashboard + reconnect seq_no rule), §13 (telemetry/budget). Authoritative for keeping the fix typed and idiomatic.

### New Files
- `lib/repo_builder/logs/writer.ex` — `RepoBuilder.Logs.Writer`: a `GenServer` (started under a `PartitionSupervisor`) that receives `{:record, event, persist_ctx}` casts, runs the status update + `Logs.persist_event/2`/`persist_orchestrator_event/2` (reusing the existing `rescue`/`catch` → `nil` degradation), and — when `broadcast_feed?` — does the global-feed broadcast with the resulting `seq_no`. Per-row FIFO via partition routing on the durable row id. `@spec` on every public function.
- `test/repo_builder/logs/writer_test.exs` — unit test: a stubbed/slow `persist_event` does not delay the per-agent broadcast; events for one row persist in FIFO order; a persist failure degrades to a `nil` seq_no on the global feed without crashing; the global feed still carries the durable `seq_no` on success.
- `test/repo_builder/session/server_async_persist_test.exs` — integration: drive events through a `Session.Server` and assert the `"agent:<id>:events"` broadcast for event K+1 is observable before event K's (artificially blocked) insert returns; assert the global `console:events` broadcast still arrives with a non-nil `seq_no` once the insert completes.
- `test/repo_builder/orchestrator/cost_coalesce_test.exs` — Part B: feed M `Event.Usage` frames then a `Done` into `Orchestrator.Server`; assert exactly one `orchestrators` UPDATE across the turn (e.g. via an Ecto telemetry counter or `Repo` call count), the final `total_cost_usd` equals the summed increments, `context_tokens`/`estimated_cost_usd` equal the **last** frame's values, and the `[:repo_builder, :cost, :recorded]` telemetry fired M times (budget parity). Add a crash case asserting `terminate/2` flushes accumulated cost.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Confirm both hot-path costs (no code change)
- Read `session/server.ex:450-489,558-612` and `orchestrator/server.ex:217-238` + `orchestrator.ex:386-456` to confirm: persistence precedes the per-agent broadcast in `dispatch/2`, and the `Usage` handler issues three get+update pairs.
- Optionally Tidewave `execute_sql_query` against `pg_stat_statements` (or attach an Ecto `[:repo_builder, :repo, :query]` telemetry counter via `project_eval`) to count `orchestrators` UPDATEs across one real orchestrator turn.

### 2. Part A — add `RepoBuilder.Logs.Writer` and supervise it
- Create `lib/repo_builder/logs/writer.ex` with the `record/2` (or `record/3`) cast API and the GenServer that owns status-update + persist + seq_no-bearing global-feed broadcast, reusing `Logs.persist_event/2`/`persist_orchestrator_event/2` and the existing degrade-to-`nil` `rescue`/`catch`.
- Add a `PartitionSupervisor` of `Logs.Writer` to `application.ex` after `Repo`/`PubSub`. Route by the durable row id so per-row ordering holds.
- Run `mix compile --warnings-as-errors`.

### 3. Part A — rewire `dispatch/2` to fan out first, persist async
- In `session/server.ex`, keep the unconditional per-agent broadcast and the lifecycle `maybe_broadcast_lane`/`maybe_emit_worker_terminal` synchronous. Replace the inline `update_status_quietly`/`persist_quietly`/`persist_orchestrator_quietly` + the `seq_no` global-feed broadcast with a single `Logs.Writer.record(...)` cast carrying `{event, persist_ctx, agent_id, broadcast_feed?}`. Move the three `*_quietly` helpers into (or have them delegate from) the Writer.
- Preserve `saw_output?`/`saw_terminal?` state updates and the `persist?/1` gate (TextDelta partials still never persist).
- Run `mix compile --warnings-as-errors`.

### 4. Part A — tests
- Add `test/repo_builder/logs/writer_test.exs` and `test/repo_builder/session/server_async_persist_test.exs` per **New Files**. Mirror existing session-runtime test setup (`SessionCase`/the patterns in `test/repo_builder/session/server_test.exs`).

### 5. Part B — split cost telemetry from the write in `orchestrator.ex`
- Extract the `:telemetry.execute([:repo_builder, :cost, :recorded], …)` emission from `add_cost/2` into a reusable `emit_cost_recorded/2` so it can fire per-event without a row write. Keep `add_cost/2`'s existing behavior intact for other callers.
- Add a single `flush_turn/2` (or use `update_record/2`) that writes accumulated `total_cost_usd` (current + acc), cumulative `input_tokens`/`output_tokens`, latest `context_tokens`, latest `estimated_cost_usd`, and final status in **one** `Repo.update`.
- Run `mix compile --warnings-as-errors`.

### 6. Part B — coalesce in `Orchestrator.Server`
- Extend `State` with `acc_cost` (Decimal, default `0`), `in_tokens`/`out_tokens` (default 0), `last_context`, `last_estimate`.
- `Event.Usage` handler: accumulate into state **and** call `emit_cost_recorded/2` for the increment (so `Budget.Guard` sees it live). No DB write here.
- `Event.Done`/`Event.Error`: `flush_turn/2` once (writing accumulated totals + final status), then `{:stop, :normal, state}`.
- Add a guarded `terminate/2` that best-effort flushes accumulated cost if the turn dies before a terminal event.
- Run `mix compile --warnings-as-errors`.

### 7. Part B — tests
- Add `test/repo_builder/orchestrator/cost_coalesce_test.exs` per **New Files**: assert single-write coalescing, correct accumulated/replace-latest values, per-event telemetry parity for `Budget.Guard`, and the `terminate/2` crash-flush.

### 8. Run the full validation suite
- Run every command in **Validation Commands**; confirm green with zero regressions. Pay attention to existing session-runtime and orchestrator-cost tests (the live UI, reconnect seq_no, nil-vs-0 cost, and budget enforcement must be unchanged).

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- `mix test test/repo_builder/logs/writer_test.exs` — async writer persists FIFO per row, degrades to nil seq_no on failure, never blocks the caller.
- `mix test test/repo_builder/session/server_async_persist_test.exs` — the per-agent stream is not head-of-line-blocked by a slow insert; the global feed still carries the durable seq_no.
- `mix test test/repo_builder/orchestrator/cost_coalesce_test.exs` — one orchestrators write per turn; correct accumulated/replace-latest values; per-event cost telemetry preserved; terminate flush.
- `mix test test/repo_builder/session/server_test.exs test/repo_builder/orchestrator/estimated_cost_test.exs` — existing session-runtime + orchestrator-cost suites green (no regression to the live path).
- `mix compile --warnings-as-errors` — clean compile; gradual set-theoretic type checker + `warnings_as_errors` pass.
- `mix test --warnings-as-errors` — full ExUnit suite (Postgres-backed) green, zero regressions; confirms live UI, reconnect seq_no, nil-vs-0, and budget enforcement unchanged.
- `mix format --check-formatted` — formatting clean.
- `mix credo --strict` — lint clean, including the `@spec`-on-every-public-function gate (new `Logs.Writer` + helpers).
- `mix dialyzer` — no new contract warnings, no stale ignore filters.

## Notes
- **ONE server — settled.** No separate logging/observability process, node, or datastore is introduced or implied. Both fixes live on the existing BEAM node: a supervised GenServer (`Logs.Writer`) and in-process write-coalescing. The `disler/pi-agent-observability` separate-server topology is explicitly **not** adopted — its HTTP/SSE/SQLite split exists to bridge runtimes the BEAM already unifies via PubSub + LiveView + Postgres.
- **The two parts are independent** and can land/ship/revert separately. Part A (writer) is the larger structural change; Part B (coalesce) is contained to two files. Implement and validate in order but they share no code.
- **seq_no contract preserved.** The live feed's `log-<n>` drilldown number still comes from the durable `AgentLog.seq_no`; it is simply broadcast from the Writer after the insert instead of inline. The per-agent stream (orchestrator + focused view) never needed seq_no and is now strictly faster.
- **Per-row ordering, cross-row parallelism.** Routing every event for one `agent_db_id`/`orchestrator_db_id` to a single writer partition guarantees FIFO persistence per row (no out-of-order `seq_no`) while letting different agents persist concurrently. Do NOT use a single global writer (re-creates a hot-path bottleneck) nor a per-event Task (loses ordering).
- **Budget enforcement parity (Part B) is a hard requirement.** `Budget.Guard` enforces live caps off the per-event `[:repo_builder, :cost, :recorded]` telemetry. Coalescing must keep that telemetry firing **per `Usage`** — only the `orchestrators` *row write* is deferred. A test asserts M telemetry events for M usage frames.
- **Accepted tradeoff (Part B):** within an in-flight turn the persisted `orchestrators` row lags (flushed on terminal), while the *live UI* stays current off the event stream. A mid-turn LiveView reconnect would read the last-flushed row. If per-turn reconnect accuracy ever matters, add a debounced periodic flush (e.g. every ~2s of streaming) — documented escape hatch, out of scope here.
- **Crash durability (Part B):** the `terminate/2` flush keeps today's "cost-so-far survives a crashed turn" guarantee even though writes are coalesced. Keep it best-effort (guarded) so a flush failure never masks the original crash reason.
- **No new dependency.** Pure OTP (`GenServer`, `PartitionSupervisor`) + existing Ecto/PubSub/telemetry.
- **Tidewave during implementation:** `project_eval` to drive `Session.Server`/`Orchestrator.Server` and inspect timing; attach an Ecto query-count telemetry handler to prove the round-trip reduction; `get_logs` to watch the `{:agent_event, …}` / `{:harness_event, …}` flow and confirm no errors; `execute_sql_query` to confirm one `orchestrators` write per turn and intact `agent_logs` seq_no ordering.
</content>
</invoke>
