# Chore: Rename `seq_no` → `log_no` end-to-end and document log troubleshooting

## Metadata
issue_number: `the`
adw_id: `logs`
issue_json: `in`

## Chore Description

Every persisted `agent_logs` row carries a durable, human-readable sequential
identifier rendered in the console drilldown as `log-<n>` (e.g. `log-12`,
`log-435444545`). Today that identifier has **two different names** depending on
which layer you read:

- **Backend** (DB column, Ecto schema field, context docs, `Dashboard.broadcast_event/3`
  local var, the two runtime emitters' locals): it is called **`seq_no`**.
- **Web/UI** (the console `event_buffer` row map and the drilldown detail panel): it is
  already called **`log_no`** (`record_event/4` sets `log_no: seq_no`; `log_to_row/4`
  sets `log_no: log.seq_no`; `event_detail_panel/1` reads `@event[:log_no]`).

This split naming is confusing — an operator or development agent sees `log-12` /
`log_no` in the UI but must know to grep for `seq_no` to find where it lives in the
data layer. This chore makes the friendly name **`log_no` consistent everywhere**
(DB column + sequence + unique index, schema field, `@type t`, context docstrings,
broadcast/runtime locals, tests) so the identifier reads the same from the database
through to the screen.

It also adds **troubleshooting documentation** so a development agent (or operator)
can quickly find and reference these logs by their `log-<n>` number — where the logs
live (`agent_logs`, the `RepoBuilder.Logs` context), how to look one up by its number
(SQL / `project_eval` via Tidewave), and how the number maps onto the console
drilldown.

This is a **pure rename + docs** chore: no behavior change, no new identifier
semantics, no new dependency. The column is `BIGSERIAL`-backed and already populated;
we rename the existing column (and its owned sequence + unique index) in a new,
fully reversible migration rather than editing the already-applied
`20260618120000_add_seq_no_to_agent_logs.exs`.

## Relevant Files

Use these files to resolve the chore:

- `BUILD_PROMPT.md` — authoritative spec. §3 typed style (`@spec` on every public fn,
  precise types), §8 persistence (contexts-only-touch-`Repo`, binary_id/JSONB,
  `agent_logs` table), §9 LiveView reconnect-backfill, §13 testing. **Read first.** Used
  here both as the rename's correctness reference and as the doc to optionally extend with
  a one-line note that the readable per-log identifier is `log_no` (`log-<n>`).
- `AGENTS.md` — Phoenix v1.8 + LiveView conventions and the binary_id/migration
  conventions. **Primary home for the new "Troubleshooting via logs" doc section** (an
  agent-facing how-to for finding a log by its `log-<n>` number).
- `.claude/commands/conditional_docs.md` — routing map. Matched rows for this chore: the
  **(always)** typed-standard row (`ai_docs/typed-elixir-standard.md`) and the **Ecto /
  migration / schema-change** row (`BUILD_PROMPT.md` §8) — a migration renames a
  column + sequence + index and the schema field changes. **Read both before editing.**
- `ai_docs/typed-elixir-standard.md` — enforced typed standard (`@spec` everywhere,
  precise types, no stray `any()`). The renamed `log_no` field must stay reflected in
  `AgentLog.t()` and every `@spec` that mentions the old name must be updated.
- `priv/repo/migrations/20260618120000_add_seq_no_to_agent_logs.exs` — the **already
  applied** migration that introduced `seq_no` (column, owned sequence
  `agent_logs_seq_no_seq`, unique index). **Do NOT edit it.** It is the reference for
  exactly which DB objects the new rename migration must rename.
- `priv/repo/migrations/20260619200000_add_estimated_cost_to_orchestrators.exs` — the
  newest existing migration; the new rename migration's timestamp must sort **after** it.
- `lib/repo_builder/logs/agent_log.ex` — the `AgentLog` Ecto schema. `field :seq_no,
  :integer, read_after_writes: true` (line ~66) and `seq_no: integer() | nil` in
  `@type t` (line ~37) must become `log_no`.
- `lib/repo_builder/logs.ex` — sole `Repo` caller for `agent_logs`. The `log_label/1`
  `@doc` references the durable `seq_no` (line ~89); update the prose to `log_no`. The
  formatter body is unchanged (it takes a plain integer). No query selects the column by
  name, so query bodies are unaffected.
- `lib/repo_builder/dashboard.ex` — `broadcast_event/3` (line ~79) takes a `seq_no`
  third arg and broadcasts `{:agent_event, agent_id, event, seq_no}`; rename the
  parameter and `@doc`/`@spec` prose to `log_no`. The **tuple position is unchanged**
  (still a 4-tuple); only the local name + docs change.
- `lib/repo_builder/orchestrator/server.ex` — lines ~99–111: local `seq_no`, the
  `log.seq_no` read, and the `Dashboard.broadcast_event/3` call + comment. Rename local
  to `log_no` and read `log.log_no`.
- `lib/repo_builder/session/server.ex` — lines ~455–483, ~555: local `seq_no`,
  `log && log.seq_no`, comments. Rename local to `log_no` and read `log.log_no`.
- `lib/repo_builder_web/live/console_live.ex` — the 8 `handle_info({:agent_event,
  agent_id, %Event.X{} = event, seq_no}, ...)` clauses (lines ~1453–1645), the
  `record_event/4` param + comment (lines ~1771–1779), and `log_to_row/4`'s `log_no:
  log.seq_no` (line ~2554). Rename the matched/threaded local from `seq_no` to `log_no`;
  the **row-map key is already `log_no`** so the map key does not change — only the source
  (`log.seq_no` → `log.log_no`) and the local var names do.
- `lib/repo_builder_web/components/dashboard_components.ex` — `event_detail_panel/1`
  already reads `@event[:log_no]`. **No change needed** (verify only).
- Tests that reference `seq_no` (rename the field/var references; assertions on the
  `log-<n>` label are unchanged):
  - `test/repo_builder/logs_orchestrator_test.exs`
  - `test/repo_builder/dashboard_test.exs`
  - `test/repo_builder/session/broadcast_feed_test.exs`
  - `test/repo_builder/orchestrator/server_test.exs`
  - `test/repo_builder_web/live/test_log_number_test.exs`
  - `test/repo_builder_web/live/test_orchestrator_agent_test.exs`
  - `test/repo_builder_web/live/test_orchestration_console_test.exs`
  - `test/repo_builder_web/live/test_agent_card_stream_filter_test.exs`
  - `test/repo_builder_web/live/test_orchestrator_harness_provider_test.exs`

### New Files

- `priv/repo/migrations/20260619210000_rename_seq_no_to_log_no_on_agent_logs.exs` — a
  fully reversible migration that renames the column `agent_logs.seq_no` → `log_no`, the
  owned sequence `agent_logs_seq_no_seq` → `agent_logs_log_no_seq`, and the unique index
  `agent_logs_seq_no_index` → `agent_logs_log_no_index`. (Timestamp must sort after
  `20260619200000`.)

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Read the authoritative docs and confirm scope
- Read `BUILD_PROMPT.md` §3, §8, §9, §13; `ai_docs/typed-elixir-standard.md`; and the
  `.claude/commands/conditional_docs.md` typed-standard + Ecto/migration rows.
- Re-grep to confirm the full rename surface before touching anything:
  `grep -rn "seq_no" lib/ priv/ test/`. Expect exactly the files listed in
  **Relevant Files**. Note the existing DB object names by reading
  `priv/repo/migrations/20260618120000_add_seq_no_to_agent_logs.exs` (column `seq_no`,
  sequence `agent_logs_seq_no_seq`, unique index created via
  `create unique_index(:agent_logs, [:seq_no])` → default name `agent_logs_seq_no_index`).
- Confirm `dashboard_components.ex` already uses `:log_no` (no change there) and that the
  web row-map key is already `:log_no` (so only var names + the `log.seq_no` source change
  on the web side).

### 2. Write the reversible rename migration (DB layer)
- Create `priv/repo/migrations/20260619210000_rename_seq_no_to_log_no_on_agent_logs.exs`
  with explicit `up/0` + `down/0` (do not use a reversible `change/0` for raw renames).
- `up`:
  - `rename table(:agent_logs), :seq_no, to: :log_no`
  - `execute("ALTER SEQUENCE agent_logs_seq_no_seq RENAME TO agent_logs_log_no_seq")`
  - `execute("ALTER INDEX agent_logs_seq_no_index RENAME TO agent_logs_log_no_index")`
  - (Renaming the column does not change the `OWNED BY` link or the `DEFAULT
    nextval(...)`; Postgres tracks the sequence by OID, so the default keeps working. The
    `ALTER SEQUENCE/INDEX RENAME` calls are cosmetic-but-correct so DB object names match
    the new column name.)
- `down` (exact inverse, reverse order):
  - `execute("ALTER INDEX agent_logs_log_no_index RENAME TO agent_logs_seq_no_index")`
  - `execute("ALTER SEQUENCE agent_logs_log_no_seq RENAME TO agent_logs_seq_no_seq")`
  - `rename table(:agent_logs), :log_no, to: :seq_no`
- Add a short `@moduledoc`/comment explaining this is a pure rename of the durable
  `log-<n>` identifier (no data change), per the typed/migration conventions.

### 3. Rename the schema field (`AgentLog`)
- In `lib/repo_builder/logs/agent_log.ex`:
  - `field :seq_no, :integer, read_after_writes: true` → `field :log_no, :integer,
    read_after_writes: true` (keep `read_after_writes: true` and field position).
  - In `@type t`, `seq_no: integer() | nil` → `log_no: integer() | nil`.
  - `changeset/2` is unchanged (the field is DB-managed and never cast).

### 4. Update the `Logs` context docs (no query change)
- In `lib/repo_builder/logs.ex`, update the `log_label/1` `@doc` prose: "durable `seq_no`"
  → "durable `log_no`". The function head/body and `@spec` are unchanged (it takes a plain
  `integer() | nil`). Confirm no `select`/`order_by` references the column by atom name
  (it does not), so query bodies need no edit.

### 5. Rename the broadcast parameter + docs (`Dashboard`)
- In `lib/repo_builder/dashboard.ex`, rename the `broadcast_event/3` third parameter
  `seq_no` → `log_no` and update the `@doc`/`@spec` prose accordingly. Keep the broadcast
  tuple a 4-tuple — the **shape is unchanged**, only the variable name and docs change:
  `{:agent_event, agent_id, event, log_no}`.

### 6. Rename the runtime emitters' locals (session + orchestrator)
- `lib/repo_builder/orchestrator/server.ex` (lines ~99–111): rename local `seq_no` →
  `log_no`, read `log.log_no` (was `log.seq_no`), update the inline comment, and pass
  `log_no` to `Dashboard.broadcast_event/3`.
- `lib/repo_builder/session/server.ex` (lines ~455–483, and the ~555 comment): rename
  local `seq_no` → `log_no`, change `log && log.seq_no` → `log && log.log_no`, update the
  comments, and pass `log_no` to `RepoBuilder.Dashboard.broadcast_event/3`.

### 7. Rename the console handler locals + backfill source (`console_live.ex`)
- Update the 8 `handle_info({:agent_event, agent_id, %Event.X{} = event, seq_no}, ...)`
  clauses (lines ~1453–1645): match `log_no` instead of `seq_no` and thread `log_no` into
  `record_event/4`. The partial-`text_delta` clause that ignores the 4th element keeps
  using `_log_no`.
- `record_event/4` (lines ~1771–1779): rename the 4th param `seq_no` → `log_no` and the
  comment. The **row-map key stays `log_no:`** — its value is now the renamed local.
- `log_to_row/4` (line ~2554): `log_no: log.seq_no` → `log_no: log.log_no` (key already
  correct; only the struct field source changes).
- Verify `dashboard_components.ex` `event_detail_panel/1` still reads `@event[:log_no]`
  (no edit).

### 8. Rename test references
- In each test file listed under **Relevant Files**, replace `seq_no` references:
  - struct/schema field access (`log.seq_no` → `log.log_no`),
  - any `Repo.insert!`/factory attrs that set the field by name,
  - broadcast-tuple destructuring / `Dashboard.broadcast_event(agent_id, event, n)` (no
    arity change; only update any local var named `seq_no`),
  - any assertion that referenced the column/field name.
- Do **not** change assertions on the rendered `"log-<n>"` label or `Logs.log_label/1`
  results — the user-visible identifier text is unchanged.

### 9. Add the troubleshooting documentation
- In `AGENTS.md`, add a short **"Troubleshooting: finding a log by its number"** section
  (agent-facing) covering:
  - Every persisted canonical event is one `agent_logs` row with a durable, readable
    `log_no` rendered in the console drilldown as `log-<n>`.
  - All `agent_logs` access goes through `RepoBuilder.Logs` (§8) — never `Repo` directly
    from a LiveView/OTP process.
  - How to find one by its number at runtime via Tidewave:
    - `execute_sql_query`: `SELECT log_no, agent_id, orchestrator_id, event_type,
      inserted_at FROM agent_logs WHERE log_no = <n>;`
    - `project_eval`: `RepoBuilder.Logs.list_recent_global(50) |> Enum.map(&{&1.log_no,
      &1.event_type})` and `RepoBuilder.Logs.log_label(<n>)`.
  - Where it surfaces in the UI: the event-detail drilldown panel (open by clicking a
    stream square); it is deliberately **not** shown in the center stream, chat, or roster.
- Add a one-line cross-reference in `BUILD_PROMPT.md` §8 (the `agent_logs` description)
  noting the readable per-row identifier is `log_no` (`log-<n>`), surfaced in the
  drilldown — so the spec and the code agree on the name.

### 10. Apply the migration and verify the round-trip
- `scripts/pg.sh start` (once per session).
- `mix ecto.migrate` — apply the rename.
- `mix ecto.rollback --step 1 && mix ecto.migrate` — confirm the rename round-trips
  cleanly (down restores `seq_no`/old sequence/old index; up re-applies).
- (Optional, via Tidewave) confirm the column/sequence/default still works:
  `SELECT log_no, inserted_at FROM agent_logs ORDER BY inserted_at ASC LIMIT 5;` and a
  fresh insert path still auto-assigns an increasing `log_no`.

### 11. Run the full Validation Commands
- Run every command in **Validation Commands**; fix every failure until the full green
  gate passes with zero regressions. Re-run `grep -rn "seq_no" lib/ priv/ test/` and
  confirm **zero** remaining matches (the old name is fully gone outside the historical
  `20260618120000_*` migration, which is intentionally left as-is).

## Validation Commands
Execute every command to validate the chore is complete with zero regressions.

- `scripts/pg.sh start` - Ensure the local Postgres cluster is running (once per session).
- `mix ecto.migrate` - Apply the rename migration.
- `mix ecto.rollback --step 1 && mix ecto.migrate` - Confirm the migration round-trips cleanly.
- `grep -rn "seq_no" lib/ priv/repo/migrations/20260619210000_rename_seq_no_to_log_no_on_agent_logs.exs test/ ; echo "remaining (expect only intentional historical refs):" ; grep -rn "seq_no" lib/ test/ | grep -v "20260618120000"` - Confirm no stray `seq_no` left in `lib/`/`test/`.
- `mix compile --warnings-as-errors` - Compile clean; the gradual set-theoretic type checker and `warnings_as_errors` must pass.
- `mix test --warnings-as-errors` - Run the full ExUnit suite with zero failures.
- `mix format --check-formatted` - Ensure code is formatted.
- `mix credo --strict` - Lint, including the "every public function has an `@spec`" convention.
- `mix dialyzer` - `@spec`/contract checking with no new warnings.

## Notes

- **Why a new migration instead of editing the original.** The `20260618120000_*`
  migration that added `seq_no` is already applied (and committed). Editing applied
  migrations is unsafe; the idiomatic Ecto move is a new, reversible rename migration.
- **Sequence/index rename is cosmetic but worth doing.** Renaming only the column would
  leave `agent_logs_seq_no_seq` / `agent_logs_seq_no_index` named after the old column —
  confusing for exactly the troubleshooting audience this chore serves. The
  `ALTER SEQUENCE/INDEX RENAME` keeps DB object names aligned with `log_no`. The
  `OWNED BY` relationship and the column `DEFAULT nextval(...)` are tracked by OID, so the
  default keeps auto-assigning values across the rename.
- **Friendly name choice.** `log_no` is chosen (over alternatives like `log_number`)
  because the web layer **already** uses `log_no` for this value — picking it makes the
  identifier consistent end-to-end with the **smallest** surface change (the web row-map
  key does not move).
- **No behavior change.** The `log-<n>` rendered label, drilldown-only visibility,
  monotonic/chronological semantics, `read_after_writes` live-path return, redaction, and
  cost rollup are all unchanged. This is a rename + docs chore only.
- **No new dependency.**
- **`read_after_writes: true` is preserved** on the renamed field so the DB-assigned value
  is still returned in the inserted struct for the live broadcast path.
