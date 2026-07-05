# Bug: Transient provider `rate_limit` turn failures consume the drive-loop stall/replan budget and prematurely escalate the task ledger

## Metadata
issue_number: `rate-limit-stall`
adw_id: `transientstall`
issue_json: `n/a` (freeform bug report — orchestrator turns that die on provider rate limits are counted as no-progress attempts, exhausting the replan budget and stranding the task)

## Bug Description
When an orchestrator turn's harness session fails with a **transient provider
error** (Anthropic `rate_limit` / overloaded), the turn ends with a not-ok
terminal. `RepoBuilder.Orchestrator.Server` flushes the turn `:error` and calls
`Ledgers.auto_record_progress/4`, which writes a Progress entry with
`made_progress: false` ("auto-recorded: turn ended error (no explicit progress
report)"). `RepoBuilder.Orchestrator.Driver.maybe_apply_stall/2` then treats that
entry identically to genuine stagnation and calls `Ledgers.bump_stall/1`. Two or
three rate-limited turns in a row — which is exactly what a rate limit produces,
since immediate retries hit the same limit — walk the ledger straight up the
failure ladder (`max_stall: 2` → replan, `escalate_after_stall: 3` → escalate) and
strand the goal awaiting operator input.

**Observed incident (evidence trail):** task ledger
`3655aaf1-d4c9-4e0e-88c0-d1f87a03967f` (2026-07-05, orchestrator `6b5d8aaa…`).
Replacement worker `cancel-impl-2` was spawned at 14:27 UTC; the orchestrator's
next two turns (progress entries at 14:27:46 and 14:29:06, turn agents
`orch-…-op-392834` / `orch-…-op-244483`) both auto-recorded "turn ended error (no
explicit progress report)". The matching `agent_logs` rows show synthetic
assistant messages with `"error": "rate_limit"` and `"model": "<synthetic>"` —
pure provider throttling, ~80 s apart. At 14:31:02 the Driver escalated: "No
progress after 3 attempts (replan exhausted) — awaiting operator input." The
in-flight implementation task was stranded.

**Expected:** a transient, self-resolving provider condition backs off and
retries (the Driver's own tick + `min_drive_interval_ms` cooldown already provide
a ≥120 s natural backoff) without consuming the stagnation budget, which exists
to catch *strategic* stagnation (same failing step pushed repeatedly), not infra
weather.

**Actual:** rate-limited turns are indistinguishable from stagnation in the
Progress ledger, so the escalation ladder fires after ~3 minutes of throttling.

## Problem Statement
The stall verdict in `Driver.maybe_apply_stall/2` has only two inputs
(`made_progress`, `looping`) and the auto-record backstop
(`Ledgers.auto_record_progress/4`) collapses every failed turn to
`made_progress: false`. There is no representation of "this turn failed for a
transient infrastructure reason" anywhere between the harness event stream (which
DOES know — `Event.Status{kind: :rate_limit}` exists) and the ledger, so the
drive loop cannot distinguish throttling from stagnation.

## Solution Statement
Thread the transient-error signal from the harness event stream to the stall
verdict, and make the Driver treat it as **neutral** (neither bump nor reset —
the next tick simply retries, giving a built-in ≥`min_drive_interval_ms`
backoff). Four small, typed changes along the existing seams:

1. **Harness detection (`RepoBuilder.Harness.Claude.normalize/2`):** the adapter
   already emits `Event.Status{kind: :rate_limit}` for `%{"type" => "rate_limit"}`
   frames, but the incident's synthetic assistant frames
   (`%{"type" => "assistant", "error" => "rate_limit", …}`) fall through to the
   plain assistant clause and the signal is lost. Extend the assistant clause to
   ALSO emit a `Status{kind: :rate_limit}` event when `raw["error"]` is a
   transient marker (`"rate_limit"`, `"overloaded"`).
2. **Turn-scoped flag (`Orchestrator.Server`):** add a
   `transient_error?: boolean` field to the Server's `State` (default `false`),
   set it in a new `handle_info({:harness_event, %Event.Status{kind: :rate_limit}}, state)`
   clause (currently swallowed by the catch-all at `server.ex:333`), and pass
   outcome `:transient` (instead of `:error`) to `auto_record_progress/2` from the
   not-ok `Done` / `Error` / turn-deadline paths when the flag is set.
3. **Ledger representation:** add a `transient` boolean column (default `false`)
   to `progress_entries` + the `ProgressEntry` schema/changeset. Widen
   `Ledgers.auto_record_progress/4`'s outcome type to `:ok | :error | :transient`;
   a `:transient` outcome writes `transient: true` with summary
   `"auto-recorded: turn ended error (transient provider rate limit — not counted toward stall)"`.
4. **Neutral stall verdict (`Driver.maybe_apply_stall/2`):** when the newest
   Progress entry has `transient: true`, mark it acted (so it is never
   double-processed) but call **neither** `bump_stall/1` **nor** `reset_stall/1`.
   The ladder position is unchanged; the Driver's normal `act_on/3` still enqueues
   the next drive turn, so the goal keeps moving once the limit clears.

No new dependencies; one small migration; `:direct` behavior of genuine error
turns (real failures still bump stall) is unchanged.

## Steps to Reproduce
1. Confirm the historical trail (Tidewave `execute_sql_query` or `psql`):
   `select inserted_at, summary from progress_entries where task_ledger_id = '3655aaf1-d4c9-4e0e-88c0-d1f87a03967f' order by inserted_at;`
   shows two "turn ended error" auto-records followed by the 14:31:02 escalation;
   `select payload->>'error' from agent_logs where inserted_at between '2026-07-05 14:27:40' and '2026-07-05 14:29:10' and payload::text like '%rate_limit%';`
   shows the synthetic `rate_limit` assistant frames.
2. Deterministic reproduction (this becomes the regression test): with an active
   ledger at `stall_count: 2`, insert a Progress entry equivalent to the
   auto-record (`made_progress: false, on_track: false`) for a rate-limited turn,
   then run `Driver.tick/0` — **before the fix** the ledger escalates
   (`status: :escalated`); **after the fix**, when the entry carries
   `transient: true`, the ledger stays `:active` at `stall_count: 2` and a drive
   turn is enqueued instead.
3. Harness-level reproduction: feed
   `%{"type" => "assistant", "error" => "rate_limit", "message" => %{"content" => [], "model" => "<synthetic>"}}`
   to `RepoBuilder.Harness.Claude.normalize/2` — before the fix no
   `Event.Status{kind: :rate_limit}` is emitted.

## Root Cause Analysis
Three-layer signal loss:

- **Adapter layer:** `claude.ex:270` only recognizes the standalone
  `%{"type" => "rate_limit"}` frame. The CLI's *synthetic assistant* error frames
  (`"error": "rate_limit"`, `"model": "<synthetic>"` — the shape actually logged
  in the incident) match the generic assistant clause at `claude.ex:230`, so the
  rate-limit fact never becomes a typed event on the orchestrator turn.
- **Turn layer:** `Orchestrator.Server` collapses every not-ok terminal to the
  binary `:error` outcome (`server.ex:306,312,324`); `Event.Status` frames are
  discarded by the catch-all (`server.ex:333`). `Ledgers.auto_record_progress/4`
  (`ledgers.ex:97-122`) then has only `:ok | :error` to persist.
- **Drive-loop layer:** `Driver.maybe_apply_stall/2` (`driver.ex:144-164`)
  reduces the verdict to `made_progress and not looping`; anything else bumps
  `stall_count`. With defaults `max_stall: 2` / `escalate_after_stall: 3`
  (`driver.ex:45-46`), three consecutive rate-limited auto-records escalate — by
  design for stagnation, wrongly for throttling.

The stall ladder was built for the Magentic-One stagnation rule ("don't push the
same failing step"); transient provider failures were simply never modeled.

## Relevant Files
Use these files to fix the bug:

- `lib/repo_builder/harness/claude.ex` — assistant normalize clause (line 230) and
  the existing `rate_limit` clause (line 270); the synthetic-assistant-error shape
  gains `Status{kind: :rate_limit}` emission here.
- `lib/repo_builder/harness/event.ex` — reference only: `Event.Status.kind`
  already enumerates `:rate_limit` (line 138); no event-contract change needed.
- `lib/repo_builder/orchestrator/server.ex` — `State` typedstruct gains
  `transient_error?`; new `handle_info` clause for `%Event.Status{kind: :rate_limit}`;
  the three `auto_record_progress(state, :error)` call sites (lines 306, 312, 324)
  become transient-aware; private `auto_record_progress/2` spec widens.
- `lib/repo_builder/orchestrator/ledgers.ex` — `auto_record_progress/4` (line 97)
  outcome type widens to `:ok | :error | :transient` and writes the new flag +
  distinct summary.
- `lib/repo_builder/orchestrator/progress_entry.ex` — schema gains
  `field :transient, :boolean, default: false` + changeset cast.
- `lib/repo_builder/orchestrator/driver.ex` — `maybe_apply_stall/2` (line 144)
  gains the neutral branch for `transient: true` entries.
- `test/repo_builder/orchestrator/driver_test.exs` — existing Driver ladder tests;
  the neutral-verdict regression tests land beside them.
- `test/repo_builder/orchestrator/ledgers_test.exs` — existing auto-record tests;
  extend for the `:transient` outcome.
- `test/repo_builder/harness/claude_normalize_test.exs` — existing normalize
  contract tests; extend for the synthetic assistant `rate_limit` shape.
- `test/repo_builder/orchestrator/server_test.exs` — Server turn-flush tests;
  extend for the Status-flag → `:transient` outcome path.
- `priv/repo/migrations/` — new migration for the `transient` column.
- `ai_docs/typed-elixir-standard.md` — typed standard for all touched `@spec`s.

### New Files
- `priv/repo/migrations/<timestamp>_add_transient_to_progress_entries.exs` —
  `alter table(:progress_entries) do add :transient, :boolean, default: false, null: false end`.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Migration + schema: represent transience on Progress entries
- Generate `priv/repo/migrations/<timestamp>_add_transient_to_progress_entries.exs`
  adding `:transient, :boolean, default: false, null: false` to `progress_entries`.
- In `lib/repo_builder/orchestrator/progress_entry.ex`, add
  `field :transient, :boolean, default: false` (beside `made_progress`, line 38)
  and include `:transient` in the changeset `cast` list. Update the `@type t`
  if the module enumerates fields.
- Run `mix ecto.migrate`.

### 2. Ledgers: `:transient` outcome on the auto-record backstop
- In `lib/repo_builder/orchestrator/ledgers.ex`, widen
  `@spec auto_record_progress(Ecto.UUID.t(), String.t() | nil, :ok | :error | :transient, DateTime.t()) :: :ok`.
- For `:transient`, insert the entry with `made_progress: false, on_track: false,
  transient: true` and summary
  `"auto-recorded: turn ended error (transient provider rate limit — not counted toward stall)"`.
  `:ok`/`:error` behavior is byte-identical to today (`transient` defaults false).

### 3. Harness: recognize the synthetic assistant `rate_limit` frame
- In `lib/repo_builder/harness/claude.ex`, in the assistant clause (line 230),
  when `Map.get(raw, "error") in ["rate_limit", "overloaded"]`, prepend
  `%Event.Status{harness: :claude, kind: :rate_limit, detail: raw, raw: raw}` to
  the returned event list (keep the existing block/usage extraction unchanged).
  Do not touch the standalone `%{"type" => "rate_limit"}` clause.

### 4. Orchestrator Server: turn-scoped transient flag
- Add `field :transient_error?, boolean(), default: false` to the Server `State`.
- Add, ABOVE the harness-event catch-all (`server.ex:333`):
  `def handle_info({:harness_event, %Event.Status{kind: :rate_limit}}, %State{} = state), do: {:noreply, %State{state | transient_error?: true}}`.
- Change the three failure call sites (`Done` with `ok: false` at line 306, `Error`
  at line 312, `:turn_deadline` at line 324) to pass
  `if(state.transient_error?, do: :transient, else: :error)`. The `Done ok: true`
  path stays `:ok` (a turn that recovered from a throttle and finished is real
  progress handling as before). Widen the private `auto_record_progress/2` spec to
  `:ok | :error | :transient`.

### 5. Driver: neutral stall verdict for transient entries
- In `lib/repo_builder/orchestrator/driver.ex` `maybe_apply_stall/2`, add a branch
  before the bump/reset decision: when `latest.transient` is `true`, record the
  entry as acted (`put_in(state.acted[id], latest.id)`) **without** calling
  `bump_stall/1` or `reset_stall/1`. Document in the moduledoc failure-ladder list:
  transient provider failures are ladder-neutral; the tick cadence
  (`min_drive_interval_ms`) is the backoff.

### 6. Tests
- `test/repo_builder/harness/claude_normalize_test.exs`: feeding
  `%{"type" => "assistant", "error" => "rate_limit", "message" => %{"content" => [], "model" => "<synthetic>"}}`
  yields a `%Event.Status{kind: :rate_limit}` among the events (fails before
  step 3, passes after).
- `test/repo_builder/orchestrator/ledgers_test.exs`: `auto_record_progress/4` with
  `:transient` writes `transient: true` and the distinct summary; `:error` still
  writes `transient: false`.
- `test/repo_builder/orchestrator/server_test.exs`: a turn that receives a
  `Status{kind: :rate_limit}` event and then a not-ok `Done` auto-records a
  `transient: true` entry; without the Status event it records `transient: false`.
- `test/repo_builder/orchestrator/driver_test.exs` (the core regression, mirrors
  the incident): active ledger at `stall_count: 2`; insert a `transient: true`
  no-progress entry; `Driver.tick/0` leaves `stall_count == 2`, the ledger
  `:active` (NOT `:escalated`), and enqueues a drive turn. Companion case: the
  same entry with `transient: false` escalates (pins that genuine errors still
  climb the ladder).

### 7. Run the `Validation Commands`
- Execute every command in `Validation Commands`; all must pass.

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- `mix ecto.migrate` — the new `progress_entries.transient` column applies cleanly.
- `mix test test/repo_builder/harness/claude_normalize_test.exs` — synthetic
  assistant `rate_limit` frame normalization.
- `mix test test/repo_builder/orchestrator/ledgers_test.exs` — `:transient`
  auto-record contract.
- `mix test test/repo_builder/orchestrator/server_test.exs` — turn-scoped flag →
  outcome threading.
- `mix test test/repo_builder/orchestrator/driver_test.exs` — the incident
  regression: transient entries are ladder-neutral; real errors still escalate.
- `mix compile --warnings-as-errors` - Compile clean; the gradual set-theoretic type checker and `warnings_as_errors` must pass.
- `mix test --warnings-as-errors` - Run the full ExUnit suite (spawns Postgres-backed cases) with zero failures.
- `mix format --check-formatted` - Ensure code is formatted.
- `mix credo --strict` - Lint, including the "every public function has an `@spec`" convention.
- `mix dialyzer` - `@spec`/contract checking with no new warnings and no stale ignore filters.

## Notes
- **No new retry machinery.** The Driver's existing tick +
  `min_drive_interval_ms` cooldown (≥120 s by default, `driver.ex:43-44`) IS the
  backoff once transient failures stop consuming the ladder — deliberately minimal.
- **Only the brain-recorded path is untouched:** when the brain explicitly calls
  `record_progress`, its verdict wins as today; the `transient` flag is written
  only by the auto-record backstop, keeping the change surgical.
- The `pi` harness adapter (`lib/repo_builder/harness/pi.ex`) may have its own
  provider-throttle shape; extending it can follow the same
  `Status{kind: :rate_limit}` seam later — out of scope here (the incident and the
  emitting adapter are both Claude).
- Budget-exhaustion (`Budget.Guard`) is a different, already-handled gate
  (`drivable_now?/2`); this fix does not let a hard-down provider spin forever —
  a persistent outage makes no progress AND no transient marker once the CLI stops
  emitting rate-limit frames (e.g. auth errors still record `:error` and climb the
  ladder normally).
- No LiveView/UI surface changes — the escalation banner behavior is unchanged;
  no LiveView integration test required.
