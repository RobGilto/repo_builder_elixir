# Feature: Human-readable log number (`log-<n>`) per persisted log

## Metadata
issue_number: `just`
adw_id: `need`
issue_json: `a`

## Feature Description

Every persisted `agent_logs` row today has a **random UUID** primary key (`binary_id`,
v4) and a microsecond `inserted_at`. The UUID is unique but **not** chronological, and
neither field is a friendly identifier an operator can read aloud or quote in a bug
report ("look at log 12,431"). The in-memory `seq` the console already tracks is a
**per-socket counter** that resets on every reconnect — it labels stream rows for the
current connection only and is not a durable identity.

This feature assigns each persisted log a **durable, human-readable sequential number** —
rendered `log-1`, `log-12`, `log-435444545` — that is **best-effort chronological**
(monotonic in insert/commit order via a Postgres `BIGSERIAL` sequence). The number is a
property of the persisted row, surfaced **only in the event-detail drilldown panel** (the
slide-out opened by clicking a stream square). It deliberately does **not** appear in the
center event stream, the chat column, or the agent roster — the stream stays visually
clean; the number is there when you drill in.

## User Story

As an **operator inspecting the console event stream**
I want **each log to carry a short, human-readable, roughly-chronological number visible
when I open its detail panel**
So that **I can unambiguously reference, compare, and order individual logs (e.g. in a bug
report or while pairing) without copying a 36-char UUID or relying on a per-connection
counter that resets on reconnect.**

## Problem Statement

`agent_logs` rows are keyed by a random v4 UUID, so the id is unique but carries **no
chronological signal** — you cannot tell from two ids which was written first, and the id
is too long to quote. Chronology lives only in `inserted_at` (microsecond), which is not a
clean integer and can tie under burst writes. The console's `seq` assign *looks* like a
log number but is an in-memory, per-socket value (`record_event/3` increments it,
`backfill_events/1` resets it to a 1-based index on every mount), so the "number" a user
sees changes between connections and is not stored anywhere. There is currently **no
stable, readable, ordered identifier** for an individual log, and the detail drilldown
panel (`event_detail_panel/1`) shows type/category/agent/time but nothing that names *which
log* this is.

## Solution Statement

Add a DB-assigned **`seq_no BIGSERIAL`** column to `agent_logs`:

1. **Migration** — add `seq_no` as a `bigint` backed by an owned sequence, deterministically
   backfilling existing rows in `(inserted_at, id)` order so historical logs get
   chronological numbers, then attaching the sequence as the column `DEFAULT` and a unique
   index. New inserts auto-assign the next value (best-effort chronological = insert/commit
   order). Fully reversible.
2. **Schema** — add a `seq_no` field with `read_after_writes: true` so every `Repo.insert`
   returns the DB-assigned value in the struct. It is **never cast** (DB-managed, never user
   input), so `changeset/2` is unchanged.
3. **Surface it in the drilldown** — the two paths that fill the console `event_buffer`
   both carry the number onto their row map under a new `:log_no` key:
   - **Backfill** (`log_to_row/4`) reads `log.seq_no` directly (rows map 1:1 to DB rows).
   - **Live** path: the global console broadcast is **tagged** with the persisted row's
     `seq_no`. `Session.Server.dispatch/2` captures the inserted `AgentLog` from the
     (already-returning) `Logs.persist_event/2` / `persist_orchestrator_event/2` and passes
     its `seq_no` into `Dashboard.broadcast_event/3`; the 8 `{:agent_event, …}` console
     handlers thread it into `record_event/4`. Events that aren't persisted (partial
     `text_delta` token shards) carry `nil` → rendered "—".
4. **Render** — `event_detail_panel/1` gains a `log` cell showing `log-<n>` (via a
   `log_label/1` helper; `nil → "—"`). No other UI surface changes.

This reuses the existing persistence return values, the existing `event_buffer`/drilldown
seam, and the typed `AgentLog` schema; it is additive and touches no read query's results
shape (rollup/cost queries don't select `seq_no`).

## Relevant Files

Use these files to implement the feature:

- `BUILD_PROMPT.md` — authoritative spec; §3 typed style (`@spec` on every public fn,
  precise types, `{:ok, t()} | {:error, reason()}`), §4/§4.1 harness event + redaction
  contract, §8 contexts-only-touch-`Repo` + binary_id/JSONB persistence conventions, §9
  LiveView/streams/reconnect-backfill rule, §13 testing. **Read first.**
- `AGENTS.md` — Phoenix v1.8 + LiveView conventions (stable DOM ids, no `String.to_atom/1`
  on input, `to_form`/`<.input>`), and the binary_id/migration conventions.
- `.claude/commands/conditional_docs.md` — routing map; matched rows for this task: the
  **(always)** typed-standard row (`ai_docs/typed-elixir-standard.md`) and the **Ecto /
  migration / schema-change** row (a new migration adds a column + sequence + index, and a
  schema field) — read both before editing.
- `ai_docs/typed-elixir-standard.md` — enforced typed standard (`@spec` everywhere, precise
  types, no stray `any()`); the new `seq_no` field must be reflected in `AgentLog.t()`.
- `priv/repo/migrations/` — existing migrations show the binary_id + JSONB conventions and
  the timestamp style. **Add the new `*_add_seq_no_to_agent_logs.exs` migration here**
  (use a timestamp prefix later than the latest existing migration).
- `lib/repo_builder/logs/agent_log.ex` — the `AgentLog` Ecto schema (`use RepoBuilder.Schema`
  → binary_id PK, `utc_datetime_usec` timestamps). **Add the `seq_no` field
  (`read_after_writes: true`) and extend `@type t`.** `changeset/2` stays unchanged (field
  not cast).
- `lib/repo_builder/logs.ex` — the sole `Repo` caller for `agent_logs`. `persist_event/2`
  and `persist_orchestrator_event/2` already return `{:ok, AgentLog.t()}`; with the new
  field the returned struct carries `seq_no`. `list_recent_global/2`/`list_recent/2` already
  return full structs (no change). **Add a `@doc`/`@spec`'d `log_label/1` formatter here**
  (pure, no `Repo`) so both the live and backfill paths and tests share one definition.
- `lib/repo_builder/session/server.ex` — `dispatch/2` persists then broadcasts. **Capture
  the inserted log from `persist_quietly/2` + `persist_orchestrator_quietly/2` (change their
  return from `:ok` to `AgentLog.t() | nil`) and pass `seq_no` into
  `Dashboard.broadcast_event/3`.** Partial-delta / non-persisted events ⇒ `nil`.
- `lib/repo_builder/orchestrator/server.ex` — `~:94`: this server also calls
  `Dashboard.broadcast_event(agent_id, event)` then `Logs.persist_orchestrator_event/2`.
  **Reorder to persist first, then broadcast with the resulting `seq_no`** (parity with the
  session path) so orchestrator turns also show a number live.
- `lib/repo_builder/dashboard.ex` — `broadcast_event/2` (`~:75`) and the `{:agent_event,
  agent_id, event}` message. **Add an optional `seq_no` (3rd arg, default `nil`) and extend
  the broadcast tuple to `{:agent_event, agent_id, event, seq_no}`.** Update the `@spec` and
  `@doc`. This topic (`console:events`) has exactly one subscriber (ConsoleLive); the
  per-agent `agent:<id>:events` topic is untouched.
- `lib/repo_builder_web/live/console_live.ex` — the 8 `handle_info({:agent_event, agent_id,
  %Event.X{} = event}, socket)` clauses (`~:1261`–`~:1408`), `record_event/3` (`~:1485`),
  `log_to_row/4` (`~:2134`), and `backfill_events/1` (`~:432`). **Match the new 4-tuple,
  thread `seq_no` into `record_event/4` and onto the row map's `:log_no`; add `log_no:
  log.seq_no` in `log_to_row/4`.** The existing in-memory `seq` (stream `id`/`line`) is
  unchanged — `:log_no` is a new, separate field.
- `lib/repo_builder_web/components/dashboard_components.ex` — `event_detail_panel/1`
  (`~:157`). **Add a `log` cell rendering `log-<n>` (via `log_label/1`); add an
  `event_square` `title` note is NOT required.** No stream/roster change.
- `test/repo_builder/logs_orchestrator_test.exs` and/or `test/repo_builder/` log tests —
  existing context tests. **Add `seq_no` monotonicity + `log_label/1` coverage.**

### New Files

- `priv/repo/migrations/<timestamp>_add_seq_no_to_agent_logs.exs` — adds the `seq_no`
  `bigint` column, deterministic chronological backfill, owned sequence as `DEFAULT`,
  `NOT NULL`, and a unique index; fully reversible `up`/`down` (raw `execute/2` for the
  sequence + backfill, `create unique_index` for the index).
- `test/repo_builder_web/live/test_log_number_test.exs` — `Phoenix.LiveViewTest`
  integration test: seed persisted logs, mount `/`, open a stream square via the
  `open_event` event, and assert the detail panel renders `log-<seq_no>` (matching
  `Logs`-loaded value) while the **center stream row does not** show the number. Also drive
  the **live** path: `Dashboard.broadcast_event(agent_id, event, n)` and assert the opened
  detail shows `log-<n>`.

## Implementation Plan

### Phase 1: Foundation
Add the durable identity at the data layer: a reversible migration giving `agent_logs` a
`seq_no BIGSERIAL` (chronological backfill + sequence default + unique index), and the
matching `AgentLog` schema field (`read_after_writes: true`, added to `@type t`, not cast).
Add the shared `Logs.log_label/1` formatter. This phase is independently shippable — the
number exists and is returned by every insert/read — before any UI wiring.

### Phase 2: Core Implementation
Surface the number in the drilldown. Tag the global console broadcast with the persisted
`seq_no` (`Dashboard.broadcast_event/3` + `Session.Server`/`Orchestrator.Server` capturing
the inserted log), thread it through the 8 `:agent_event` console handlers into
`record_event/4`'s row `:log_no`, and add `log_no: log.seq_no` to the backfill `log_to_row/4`.
Render `log-<n>` in `event_detail_panel/1`.

### Phase 3: Integration
Prove the number is durable, chronological, and visible on both the live and reconnect
paths, with zero regression to the stream/chat/roster, the cost rollup, and the redaction
contract — via context unit tests, the new LiveView integration test, and the full green
gate.

## Step by Step Tasks

IMPORTANT: Execute every step in order, top to bottom.

### 1. Read the authoritative docs
- Read `BUILD_PROMPT.md` §3 (typed style), §4/§4.1 (event + redaction), §8 (persistence /
  contexts-only-`Repo` / binary_id), §9 (LiveView reconnect-backfill), §13 (testing).
- Read `ai_docs/typed-elixir-standard.md` and the `.claude/commands/conditional_docs.md`
  Ecto/migration row.
- Skim the persistence + broadcast + drilldown path: `lib/repo_builder/logs.ex`,
  `lib/repo_builder/logs/agent_log.ex`, `lib/repo_builder/session/server.ex` `dispatch/2`,
  `lib/repo_builder/dashboard.ex` `broadcast_event/2`, and in `console_live.ex` the
  `{:agent_event, …}` handlers, `record_event/3`, `log_to_row/4`, `backfill_events/1`, and
  `event_detail_panel/1` in `dashboard_components.ex`.

### 2. Write the migration (chronological backfill + sequence + unique index)
- Create `priv/repo/migrations/<timestamp>_add_seq_no_to_agent_logs.exs` (timestamp later
  than the newest existing migration). Use explicit `up/0` + `down/0`.
- `up`:
  - `alter table(:agent_logs) do add :seq_no, :bigint end`
  - Deterministic backfill (raw SQL):
    `execute("""
     WITH ordered AS (
       SELECT id, row_number() OVER (ORDER BY inserted_at ASC, id ASC) AS rn
       FROM agent_logs
     )
     UPDATE agent_logs a SET seq_no = o.rn FROM ordered o WHERE a.id = o.id
     """)`
  - Create an owned sequence and wire it as the column default, starting after the max:
    `execute("CREATE SEQUENCE agent_logs_seq_no_seq OWNED BY agent_logs.seq_no")`
    `execute("SELECT setval('agent_logs_seq_no_seq', COALESCE((SELECT MAX(seq_no) FROM agent_logs), 0) + 1, false)")`
    `execute("ALTER TABLE agent_logs ALTER COLUMN seq_no SET DEFAULT nextval('agent_logs_seq_no_seq')")`
    `execute("ALTER TABLE agent_logs ALTER COLUMN seq_no SET NOT NULL")`
  - `create unique_index(:agent_logs, [:seq_no])`
- `down`:
  - `drop unique_index(:agent_logs, [:seq_no])`
  - `alter table(:agent_logs) do remove :seq_no end` (the `OWNED BY` sequence drops with the
    column). If the adapter requires it, also `execute("DROP SEQUENCE IF EXISTS agent_logs_seq_no_seq")`.
- Run `mix ecto.migrate` and then `mix ecto.rollback` once to confirm the round-trip, then
  `mix ecto.migrate` again. (Or use Tidewave `execute_sql_query` to confirm `seq_no` is
  populated and unique.)

### 3. Add the `seq_no` field to the `AgentLog` schema
- In `lib/repo_builder/logs/agent_log.ex`, add `field :seq_no, :integer, read_after_writes: true`
  to the `schema "agent_logs"` block (place it before `timestamps()`).
- Add `seq_no: integer() | nil` to `@type t`.
- Do **not** add `:seq_no` to the `cast/3` field list in `changeset/2` (DB-managed; never
  user input). No other changeset change.

### 4. Add the shared `log_label/1` formatter to the `Logs` context
- In `lib/repo_builder/logs.ex` add a pure helper:
  `@spec log_label(integer() | nil) :: String.t()`
  `def log_label(n) when is_integer(n), do: "log-#{n}"`
  `def log_label(_), do: "—"`
- (No `Repo` access — it is a formatter co-located with the log context for reuse by the web
  layer and tests.)

### 5. Context unit tests for the durable number (red → green as Phase 1 lands)
- Add tests (in the most fitting existing log context test file, e.g.
  `test/repo_builder/logs_orchestrator_test.exs`, or a focused new describe block):
  - `persist_event/2` returns a log whose `seq_no` is a positive integer.
  - Two successive `persist_event/2` (or struct `Repo.insert!`) calls produce **strictly
    increasing** `seq_no` (monotonic / best-effort chronological).
  - `Logs.log_label/1`: `1 → "log-1"`, `435444545 → "log-435444545"`, `nil → "—"`.
  - Regression: `list_recent_global/2` rows each carry a non-nil `seq_no`.

### 6. Tag the global broadcast with `seq_no`
- In `lib/repo_builder/dashboard.ex`, change `broadcast_event/2` → `broadcast_event/3` with
  `seq_no \\ nil`; broadcast `{:agent_event, agent_id, event, seq_no}`. Update `@spec`
  (`@spec broadcast_event(String.t(), Event.t(), integer() | nil) :: :ok`) and the `@doc`
  (note subscribers now receive a 4-tuple; the per-agent topic is unchanged).

### 7. Capture the inserted log in the session + orchestrator runtime
- `lib/repo_builder/session/server.ex`:
  - Change `persist_quietly/2` and `persist_orchestrator_quietly/2` to return
    `AgentLog.t() | nil` (the inserted struct on `{:ok, log}`, else `nil`); keep the
    rescue/catch returning `nil`. Update their `@spec`s and alias `AgentLog` if needed.
  - In `dispatch/2`, capture the persisted log (worker or orchestrator branch, whichever
    ran) into a local `seq_no = log && log.seq_no`, and call
    `RepoBuilder.Dashboard.broadcast_event(agent_id, event, seq_no)`. Non-persisted events
    (`persist?/1 == false`, i.e. partial text deltas) keep `seq_no = nil`.
- `lib/repo_builder/orchestrator/server.ex` (`~:94`): reorder to persist **before**
  broadcasting, capture the `{:ok, log}` `seq_no`, and pass it to
  `Dashboard.broadcast_event/3`.

### 8. Thread `seq_no` through the console handlers onto the row
- In `lib/repo_builder_web/live/console_live.ex`, update the 8 `handle_info({:agent_event,
  agent_id, %Event.X{} = event}, socket)` clauses (`~:1261`–`~:1408`) to match the new
  4-tuple `{:agent_event, agent_id, %Event.X{} = event, seq_no}` and pass `seq_no` to a new
  `record_event/4` arity (or add a `log_no:` key to the per-call `attrs` map).
  - Recommended: `record_event(socket, agent_id, attrs, seq_no \\ nil)`, adding
    `log_no: seq_no` to the `row` map alongside `id`/`line`.
  - The partial-`text_delta` clause (`~:1275`) — which only updates the streaming buffer,
    not a finalized stream row — passes `nil`/ignores `seq_no` (unchanged behavior).
- In `log_to_row/4` (`~:2142` row map) add `log_no: log.seq_no`.
- Confirm `backfill_events/1` needs no change (it calls `log_to_row/4`, which now carries the
  field).

### 9. Render `log-<n>` in the drilldown detail panel
- In `lib/repo_builder_web/components/dashboard_components.ex` `event_detail_panel/1`
  (`~:171` grid), add a cell:
  `<div><span style="color: var(--cns-text-2)">log</span> {RepoBuilder.Logs.log_label(@event[:log_no])}</div>`
  (use `@event[:log_no]` access so a row built before this field — none after this change —
  degrades to "—" rather than crashing).
- Do **not** add the number to `event_square/1`, the center stream row, the chat bubble, or
  the roster (the feature is drilldown-only).

### 10. Write the LiveView integration test
- Create `test/repo_builder_web/live/test_log_number_test.exs`
  (`use RepoBuilderWeb.ConnCase, async: false`; `import Phoenix.LiveViewTest`).
- **Backfill path:** insert ≥2 `agent_logs` rows (struct `Repo.insert!` or
  `Logs.persist_event/2` with a created agent + session), `live(conn, "/")`. The backfill
  assigns stream-row ids `1..N` in chronological order (`backfill_events/1`); open the most
  recent via `render_click(view, "open_event", %{"id" => N})` and assert the detail panel
  (`#event-detail-panel`) renders `"log-#{log.seq_no}"` where `log` is the matching DB row
  (read via `Logs.list_recent_global/2` or `Repo`).
- Assert the **center stream** does **not** contain that `log-<n>` text (only the panel does).
- **Live path:** subscribed view — call `RepoBuilder.Dashboard.broadcast_event(agent_id,
  event, 4242)` with a constructed canonical `Event` (e.g. `%Event.ToolCall{}` /
  `%Event.Done{}`), then open the just-appended row and assert the panel shows `"log-4242"`.
- Optionally capture a Playwright/Tidewave-vision screenshot of `http://localhost:4000` with
  a row's detail panel open showing the number, as visual proof.

### 11. Run the full Validation Commands
- Run every command in **Validation Commands**; fix every failure until the full green gate
  passes with zero regressions. Optionally use Tidewave `project_eval`
  (`RepoBuilder.Logs.list_recent_global(2) |> Enum.map(& &1.seq_no)`) and
  `execute_sql_query` (`SELECT seq_no FROM agent_logs ORDER BY inserted_at LIMIT 5`) to
  confirm monotonic, populated values against the live app.

## Testing Strategy

### Unit Tests
- `persist_event/2` / `persist_orchestrator_event/2` return a struct with a positive integer
  `seq_no`; successive inserts are strictly increasing (monotonic, best-effort chronological).
- `Logs.log_label/1`: integer → `"log-<n>"`, `nil` → `"—"`, large value
  (`435444545`) formats without separators.
- `list_recent_global/2` / `list_recent/2` rows all carry a non-nil `seq_no` (reconnect
  backfill has the number).
- Regression: `CostCenter.rollup/1`, `Logs.cost_rollup!/1`, `hide_all_logs/0`,
  `release_hidden_logs/0`, and the redaction contract (`Redact.scrub`) are unaffected (no
  `seq_no` in their selects/results).

### Edge Cases
- **Non-persisted live event** (partial `text_delta` token shard): broadcast carries
  `seq_no = nil`; opening such a (transient) row shows `log` → "—", no crash.
- **Backfill row predates the migration**: every historical row was backfilled, so it has a
  number; ordering by `(inserted_at, id)` makes the backfill deterministic and chronological.
- **Burst / tied `inserted_at`**: `seq_no` is still strictly unique and monotonic (sequence
  assignment), giving a deterministic order where `inserted_at` ties — the number is the
  tie-breaker the UUID never was.
- **Reconnect**: the number is durable, so the same log shows the same `log-<n>` before and
  after a reconnect (unlike the per-socket `seq`), satisfying §9.
- **Migration rollback**: `down` removes the column, index, and owned sequence cleanly
  (round-trip verified).
- **Orchestrator vs worker rows**: both persist to `agent_logs`, so both get a `seq_no` and
  both show the number live (orchestrator path reordered to persist-before-broadcast).

## Acceptance Criteria

- Every persisted `agent_logs` row has a unique, NOT-NULL, integer `seq_no` assigned by a
  DB sequence; existing rows were backfilled in `(inserted_at, id)` (chronological) order.
- New inserts auto-assign a monotonically increasing `seq_no` (best-effort chronological);
  `persist_event/2` returns it on the struct (`read_after_writes`).
- The event-detail drilldown panel renders the number as `log-<n>` (e.g. `log-1`,
  `log-435444545`); a row with no persisted number shows `—`.
- The number is **not** shown in the center event stream, chat column, or agent roster.
- The number is identical for the same log across reconnects (durable, not the per-socket
  `seq`).
- Both the **live** broadcast path and the **reconnect-backfill** path populate the number
  in the drilldown.
- All `agent_logs` DB access stays in `RepoBuilder.Logs` (§8); LiveViews/components/OTP
  processes never touch `Repo`/`Ecto.Query` for it.
- The redaction contract, cost rollup, and CLEAR/show-hidden behavior are unchanged.
- The full green gate passes with zero regressions.

## Validation Commands

Execute every command to validate the feature works correctly with zero regressions.

- `scripts/pg.sh start` — ensure the local Postgres cluster is running (once per session).
- `mix ecto.migrate` — apply the new migration (backfill + sequence + unique index).
- `mix ecto.rollback --step 1 && mix ecto.migrate` — confirm the migration round-trips
  cleanly (down removes column/index/sequence; up re-applies).
- `mix test test/repo_builder_web/live/test_log_number_test.exs` — the new CRUD/drilldown
  LiveView integration test (live + backfill paths).
- `mix test test/repo_builder/logs_orchestrator_test.exs` — context tests incl. `seq_no`
  monotonicity + `log_label/1`.
- `mix compile --warnings-as-errors` — gradual set-theoretic types + `warnings_as_errors`.
- `mix test --warnings-as-errors` — full suite, zero failures (drives Postgres-backed cases).
- `mix format --check-formatted` — formatting.
- `mix credo --strict` — lint, including `@spec`-on-every-public-function.
- `mix dialyzer` — `@spec`/contract checking, no new warnings, no stale ignore filters.
- (Optional, via Tidewave) `execute_sql_query`:
  `SELECT seq_no, inserted_at FROM agent_logs ORDER BY inserted_at ASC LIMIT 5;` — confirm
  populated, increasing values; and `project_eval`:
  `RepoBuilder.Logs.list_recent_global(2) |> Enum.map(& &1.seq_no)`.

## Notes

- **No new dependency.** Pure migration + schema field + existing-seam wiring + tests.
- **Why `BIGSERIAL`, not a sortable UUID (v7) or the per-socket `seq`:** the requirement is a
  *human-readable* integer (`log-12`), not a 36-char id, and the existing console `seq` is an
  in-memory per-connection counter that resets on reconnect. A DB sequence is the simplest
  durable, monotonic, readable identifier; "best effort chronological" maps exactly to
  insert/commit order. The random v4 PK is intentionally left as the stable join key.
- **Broadcast tuple shape change:** `{:agent_event, …}` gains a 4th element (`seq_no`). The
  `console:events` topic has a single subscriber (ConsoleLive), and the per-agent
  `agent:<id>:events` topic is untouched, so the blast radius is contained to the 8 console
  handlers + the two runtime emitters. A lower-touch fallback (backfill-only, with live rows
  showing `—` until reconnect) is possible if the 4-tuple change is undesirable — but it
  yields an inconsistent drilldown, so the tagged-broadcast approach is preferred.
- **`read_after_writes`:** required so the DB-default-assigned `seq_no` is returned in the
  inserted struct (the live path needs it at broadcast time). It adds `seq_no` to the
  `RETURNING` list Ecto already emits for the binary_id PK — negligible cost.
- **Large-table migration:** the backfill is a single `UPDATE … FROM (row_number())` pass;
  on a very large `agent_logs` it is O(n) but one-shot. If the table is huge in production,
  consider running the migration in a maintenance window (noted for the operator).
- **Future considerations:** show `log-<n>` in a copy-to-clipboard affordance; let the
  orchestrator `read_*` tools filter/reference logs by `seq_no`; add a `seq_no` range filter
  to the console search; expose the number in exported/downloaded log bundles.
```
