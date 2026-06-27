# Feature: Deterministic worker-fleet gate — stop the orchestrator LLM from polling live workers

## Metadata
adw_id: `plan`

## Description

The autonomous drive loop (`RepoBuilder.Orchestrator.Driver`) and the holding
pattern (`RepoBuilder.Orchestrator.Queue`) re-engage the orchestrator's **expensive
LLM turn** to find out things that are already knowable from cheap, deterministic
runtime state: *is my worker still alive? is it making progress? is it done? is it
stuck?* This work replaces that LLM-based "checking" with a deterministic
**worker-fleet gate** computed from the `agents` table, the `SessionRegistry`, and
the existing `heartbeat_at` column — so the orchestrator is only woken on a real,
actionable state transition, never to passively confirm "worker still running."

### Evidence (why this is worth doing)

A live investigation of the **DroneCommander** project (`agent_logs`,
`project_id = 7936bac1-3729-4073-a9ca-3c341b3776fe`) found:

- Total project consumption ≈ **108.4M tokens**; the orchestrator
  (`orch:DroneCommander`, `claude-opus-4-8`) was **97%** (105.5M).
- A **single 51-minute session** (`a06a3744…`, today 08:22–09:13) was **88% of the
  entire project's tokens**: 433 turns, **84.9M `cache_read` + 10.9M
  `cache_creation`**. The token type is the tell — it is almost entirely
  `cache_read`, i.e. the cost of **re-sending the ~196K-token orchestrator context
  over and over** to perform passive polling, not new work.
- The assistant text from that session is explicit: *"The generation run is in
  flight (7 sequential image API calls, several minutes)… I'll end the turn — I'm
  re-engaged automatically."* The drive loop kept waking the Opus orchestrator ≈once
  a minute **while a worker was legitimately busy for minutes** on a long external
  operation. Every wake re-read the full cached context and produced no decision.

## Problem Statement

`Driver.do_tick/1` selects orchestrators to drive via `Orchestrators.list_drivable/0`
(an `:active` ledger + status `:idle`/`:error`) gated only by `within_budget?/1` and
`queue_free?/1`. **None of those gates know whether the orchestrator has live workers
in flight.** The moment an orchestrator dispatches a worker and ends its turn it
becomes `:idle` with a non-busy queue — so the Driver re-engages it on the very next
tick (default `drive_interval_ms: 30_000`) even though a dispatched worker is alive
and working. Each re-engagement is a full Opus turn re-reading a large cached context.

The event-driven holding pattern (`Queue.maybe_auto_resume/2`) **already** re-engages
the orchestrator exactly once when a worker reaches a terminal state, and the Queue
**already** `Process.monitor`s dispatched worker pids (self-healing Phase 2) and the
`LivenessReaper` already reconciles phantoms. So the drive-loop polling of an
orchestrator that has healthy live workers is **pure redundant spend**: the
actionable wake-up will arrive event-driven regardless.

Previous specs (`issue-worker-terminal-…`, the Phase 1/2 liveness work) correctly
made worker *death/phantom* detection deterministic, but they still funnel every
reconciliation into an LLM turn and never taught the **drive loop** to stand down
while workers are healthy. The cost is therefore unbounded by anything except the
budget guard — which is exactly what got exhausted.

## Solution Statement

Introduce a deterministic, LLM-free **worker-fleet classifier** and make it a
first-class gate in the drive loop, so the autonomous loop becomes a rare *backstop*
while the event-driven holding pattern stays primary:

1. **`RepoBuilder.Orchestrator.WorkerFleet`** (new) — a pure-ish module that
   classifies an orchestrator's dispatched workers into one deterministic
   `fleet_state` from cheap signals already on hand:
   - `:active` — ≥1 non-archived worker in `:running`/`:holding` whose
     `SessionRegistry` process is alive **and** whose `heartbeat_at` is within a
     progress grace (it is genuinely working or legitimately blocked/holding).
   - `:quiescent` — workers exist but none are progressing (no live process, or all
     heartbeats stale) — a legitimate, *occasional* drive-nudge target.
   - `:empty` — no live workers — normal drive territory.
   All inputs are a single indexed query plus `Registry.lookup` — **zero tokens**.

2. **Driver gate** — `do_tick/1` skips any orchestrator whose fleet is `:active`. The
   holding pattern re-engages it event-driven when a worker terminates; the drive
   loop no longer polls it. This is the change that removes the 88%-of-spend pattern.

3. **Per-orchestrator drive cooldown** — a deterministic `min_drive_interval_ms`
   floor tracked in `Driver` state (`last_drive: %{orchestrator_id => mono_ms}`) so
   even an `:empty`/`:quiescent` fleet cannot be polled faster than the floor,
   bounding worst-case spend regardless of fleet-classification edge cases.

4. **Re-tune the cadence** — the drive loop is now a backstop, not the engine: raise
   the default `drive_interval_ms` and add the new floor/grace config keys, all
   overridable. No behavioural change in tests (`:infinity` interval preserved).

This shifts "checking on workers" from billed Opus turns to indexed SQL + a process
registry lookup, and caps the remaining drive spend deterministically.

## Relevant Files

Use these files to do the work:

- `lib/repo_builder/orchestrator/driver.ex` — the autonomous loop. `do_tick/1`
  (filter at lines ~96–107) gains the fleet gate and cooldown; `state()` gains
  `last_drive`. The primary edit site.
- `lib/repo_builder/orchestrator.ex` — config accessors (`auto_resume?/0`,
  `max_queue_depth/0`, `list_drivable/0`). Add typed accessors for the new config
  keys here so the Driver reads them through one seam (matching `interval_ms/0` etc.
  which currently live in `driver.ex` — keep new *Driver-only* knobs local, but route
  shared ones through the context).
- `lib/repo_builder/agents.ex` — already has `list_for_orchestrator/1`,
  `list_stale_live_running/1`, `touch_heartbeat/1`. Add a **cheap fleet query**
  (`live_workers_for/1` or `count_live_workers/1`) returning just the
  `{id, status, heartbeat_at}` of non-archived `:running`/`:holding` workers for an
  orchestrator — the only new DB access, behind this context (§8: no `Repo` outside
  contexts).
- `lib/repo_builder/agents/agent.ex` — confirm `heartbeat_at` and `status`/`archived`
  field types for the precise `@type` on the new query result; no schema change.
- `lib/repo_builder/session/supervisor.ex` — `whereis/1` (line ~113) is the
  authoritative liveness probe (`SessionRegistry` lookup). `WorkerFleet` calls it.
- `lib/repo_builder/orchestrator/queue.ex` — no functional change required; it
  already monitors worker pids and drives the event-driven resume. Referenced so the
  plan does not duplicate the wake-up path. (Optionally: expose a read-only
  `live_worker_ids/1`-style helper later, but the DB+registry path is sufficient and
  avoids a cross-process call in the hot tick.)
- `lib/repo_builder/session/liveness_reaper.ex` — the existing deterministic
  phantom/quiescence sweep. Documents the precedence the new grace must respect
  (`quiescence_ms` 90s soft < `min_stale_ms` 120s reaper); the fleet grace reuses the
  same ordering so the two layers agree.
- `config/config.exs` — `:repo_builder, :orchestrator` block (lines ~327–340). Raise
  `drive_interval_ms`; add `min_drive_interval_ms` and `worker_progress_grace_ms`.
  `:session` block (lines ~353–368) `quiescence_ms` is the reference for the grace.
- `config/test.exs` — keeps `drive_interval_ms: :infinity` (driver driven explicitly);
  set the new keys to deterministic test values; default fleet-gate ON.
- `BUILD_PROMPT.md` §5/§6 (supervision, session runtime) and
  `ai_docs/adw-orchestration.md` — architecture references for the drive loop and the
  durable/live split (read during implementation).
- `.claude/commands/conditional_docs.md` routes: the workflow/ADW engine row
  (`BUILD_PROMPT.md` §7; `ai_docs/adw-orchestration.md`) and the typed-standard
  **always** row (`ai_docs/typed-elixir-standard.md`).

### New Files

- `lib/repo_builder/orchestrator/worker_fleet.ex` — the deterministic fleet
  classifier. Public API:
  `@spec classify(Ecto.UUID.t()) :: :active | :quiescent | :empty` and
  `@spec drivable?(Ecto.UUID.t()) :: boolean()` (true when `:empty`/`:quiescent`).
  No `Repo`/`Ecto.Query` directly — it calls `Agents.live_workers_for/1` and
  `Session.Supervisor.whereis/1`. Typed result structs via `typedstruct`/`@type`.
- `test/repo_builder/orchestrator/worker_fleet_test.exs` — unit tests for the
  classifier across `:active`/`:quiescent`/`:empty` with live vs. dead processes and
  fresh vs. stale heartbeats (use `start_supervised!` for any session stub;
  `Process.monitor` not `Process.sleep`).
- `test/repo_builder/orchestrator/driver_fleet_gate_test.exs` — drives `Driver.tick/0`
  explicitly and asserts an orchestrator with an `:active` fleet is **not** driven,
  while `:empty`/`:quiescent` ones are, and that the `min_drive_interval_ms` cooldown
  suppresses a too-soon second tick. (A `Phoenix.LiveViewTest` UI test is **not**
  needed — this is runtime/engine logic with no UI surface.)

## Step by Step Tasks

IMPORTANT: Execute every step in order, top to bottom.

### 1. Add the cheap fleet query to the `Agents` context

- Add `@spec live_workers_for(Ecto.UUID.t()) :: [%{id: Ecto.UUID.t(), status:
  Agent.status(), heartbeat_at: DateTime.t() | nil}]` to `lib/repo_builder/agents.ex`.
- Query non-archived workers for the orchestrator with `status in [:running,
  :holding]`, selecting only `id`, `status`, `heartbeat_at` (a narrow `select` map,
  not full rows — keep it cheap). Reuse the `agents_orchestrator_id_index` /
  `agents_active_index`.
- Keep all `Repo`/`Ecto.Query` use inside the context (§8). Precise `@type` on the
  result — no `map()`.

### 2. Create `RepoBuilder.Orchestrator.WorkerFleet`

- New module `lib/repo_builder/orchestrator/worker_fleet.ex` with `@moduledoc`
  explaining it is the deterministic, LLM-free replacement for drive-loop polling.
- `classify/1`: load `Agents.live_workers_for(id)`; if empty → `:empty`. Otherwise,
  a worker is **progressing** when `Session.Supervisor.whereis(worker.id)` is a live
  pid **and** (`status == :holding` OR `heartbeat_at` within
  `worker_progress_grace_ms` of now). If any worker is progressing → `:active`; else
  `:quiescent`.
- `drivable?/1`: `classify/1 in [:empty, :quiescent]`.
- `@spec` on every public function; tagged/atom-union returns, never raising;
  fail-soft (a registry/DB hiccup classifies conservatively as `:active` so the loop
  errs toward *not* spending — i.e. a transient error never triggers a poll storm).
- Pull `worker_progress_grace_ms` from config with a sensible default
  (`>= quiescence_ms`, e.g. 90_000) via a private typed accessor.

### 3. Gate the drive loop on the fleet + cooldown

- In `lib/repo_builder/orchestrator/driver.ex`:
  - Extend `@type state` to `%{acted: …, last_drive: %{optional(Ecto.UUID.t()) =>
    integer()}}`; initialize `last_drive: %{}` in `init/1` and `reset`.
  - In `do_tick/1`, extend the `Enum.filter/2` to also require
    `WorkerFleet.drivable?(&1.id)` **and** `cooldown_elapsed?(&1.id, state)`.
  - On a successful drive/replan/escalate in `act_on/3` (or in `drive_one/2`), stamp
    `last_drive[id]` with `System.monotonic_time(:millisecond)`. Thread the updated
    `state` back (the reduce already carries `st`).
  - Add private typed accessors `min_drive_interval_ms/0` (config, default e.g.
    120_000) and `cooldown_elapsed?/2`. Use monotonic time (not wall clock) for the
    cooldown.
  - Keep `escalate` reachable regardless of cooldown? No — escalation only happens
    after stalls, which already require prior driven turns; the cooldown applies
    uniformly. Document this.
- Raise the `@default_interval_ms` to match the new backstop role (e.g. 120_000) and
  keep `interval_ms/0` reading config first.

### 4. Wire config

- `config/config.exs` `:repo_builder, :orchestrator`: change `drive_interval_ms:
  30_000` → a backstop cadence (e.g. `120_000`); add `min_drive_interval_ms:
  120_000` and `worker_progress_grace_ms: 90_000`. Update the surrounding comment to
  describe the fleet gate + cooldown and that the holding pattern is now primary.
- `config/test.exs`: keep `drive_interval_ms: :infinity`; add
  `min_drive_interval_ms: 0` (so explicit `tick/0` calls in unrelated tests aren't
  throttled) and `worker_progress_grace_ms` matching the existing test ordering. The
  new fleet-gate tests set their own values per scope.

### 5. Tests — `WorkerFleet`

- `test/repo_builder/orchestrator/worker_fleet_test.exs`: create an orchestrator +
  worker rows (existing factories/`SessionCase` helpers); assert `:empty` (no
  workers), `:active` (live registered pid + fresh heartbeat, and separately a
  `:holding` worker), and `:quiescent` (row `:running` but no live process / stale
  heartbeat). Register a fake live process under `SessionRegistry` via
  `start_supervised!`; assert liveness via `Process.monitor` DOWN, never
  `Process.sleep`/`Process.alive?`.

### 6. Tests — Driver fleet gate + cooldown

- `test/repo_builder/orchestrator/driver_fleet_gate_test.exs`: with a pluggable
  starter/Queue stub (mirror the existing driver test setup), assert:
  - an orchestrator with an `:active` fleet is **not** counted/driven by `tick/0`;
  - an `:empty`/`:quiescent` fleet **is** driven;
  - a second `tick/0` within `min_drive_interval_ms` does not re-drive the same
    orchestrator (cooldown), and after the floor elapses it does;
  - a `WorkerFleet` classification error falls back to *not* driving (conservative).
- Confirm existing `Driver` and `Queue` tests still pass unchanged (the holding
  pattern path is untouched).

### 7. Update docs

- Add a short note to `ai_docs/adw-orchestration.md` (or the relevant section)
  describing the deterministic fleet gate: drive loop is a backstop, holding pattern
  is primary, worker liveness/progress is answered programmatically, never by an LLM
  turn. Keep it factual and brief.

### 8. Run the validation commands

- Run every command in **Validation Commands** and fix any regressions until all green.

## Acceptance Criteria

- The `Driver` does **not** enqueue a drive turn for an orchestrator that has ≥1 live,
  progressing/holding worker (`WorkerFleet.classify/1 == :active`), proven by
  `driver_fleet_gate_test.exs`.
- `WorkerFleet.classify/1` returns the correct `:active`/`:quiescent`/`:empty` for the
  live-process × heartbeat-freshness matrix, with no tokens consumed (no harness/LLM
  call anywhere in its path), proven by `worker_fleet_test.exs`.
- A per-orchestrator `min_drive_interval_ms` cooldown demonstrably suppresses a
  too-soon second drive.
- The event-driven holding pattern (`Queue.maybe_auto_resume/2`) and the
  `LivenessReaper` are unchanged and their tests still pass — re-engagement on a real
  worker terminal still happens exactly once.
- All DB access for the new query is inside `RepoBuilder.Agents` (no `Repo`/`Ecto.Query`
  in `WorkerFleet`, `Driver`, or LiveViews).
- Every new public function has an `@spec`; new domain data is typed
  (`typedstruct`/`@type`, precise unions, no `any()`/bare `map()`); returns are
  tagged/atom-union, never raising.
- The five-command green gate passes with zero regressions.

## Validation Commands

Execute every command to validate the work with zero regressions.

- `mix compile --warnings-as-errors` - Compile clean; gradual checker + warnings-as-errors pass.
- `mix test --warnings-as-errors` - Full ExUnit suite, zero failures.
- `mix format --check-formatted` - Formatting.
- `mix credo --strict` - Lint incl. the `@spec` convention.
- `mix dialyzer` - Contract checking, no new warnings.

## Notes

- **Scope discipline.** This plan deliberately does *not* try to make the orchestrator
  deterministically *evaluate worker output* (did the artifact land, is the code
  correct) — that is goal-specific and rightly an LLM judgment. It only takes over the
  cheap, generic *liveness/progress* checks that were being done with billed turns.
- **Orthogonal, recommended follow-ups (out of scope here, mention to operator):**
  (a) run the orchestrator's autonomous *drive* turns on a cheaper model (e.g. Sonnet)
  via the per-project agent-model roster — the `cache_read` cost is dominated by Opus;
  (b) consider `drive_on_boot: false` so a restart doesn't immediately re-engage idle
  goals. Both are config/roster changes, not code, and compound the savings from this
  structural fix.
- **Why fleet state lives in DB+registry, not the Queue's `workers` map.** The Queue's
  monitored-workers map is in-memory and lost on a Queue/BEAM restart (by design — the
  reaper is its backstop). The Driver tick must be correct after a restart too, so the
  fleet classifier reads the durable `agents` rows + the live `SessionRegistry`, which
  together survive a Queue restart and never wedge.
- **Conservative failure mode is "don't spend."** If the classifier cannot determine
  state (DB/registry error), it returns `:active` so the drive loop stands down — the
  worst case is a missed backstop nudge (the event-driven path and the next tick
  recover), never a poll storm.
