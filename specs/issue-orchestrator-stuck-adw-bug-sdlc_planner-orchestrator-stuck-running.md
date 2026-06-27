# Bug: Orchestrator stuck `:running` forever after a turn ends without a terminal event

## Metadata
issue_number: `orchestrator-stuck`
adw_id: `bug`
issue_json: `{"title":"Orchestrator gets stuck :running and never recovers","body":"After a worker was reconciled and the orchestrator auto-resumed, the orchestrator flipped to :running but its turn never produced output and died. The orchestrators row is now frozen at :running with no live Queue and no live turn process. The worker LivenessReaper does not fix it because it only sweeps the agents table. The orchestrator can no longer cleanly accept/auto-run turns because it reads as busy."}`

## Bug Description
The orchestrator (`orchestrators` row) can wedge at `status: :running` permanently. Once
wedged: the console shows it "running" with nothing running, and `auto_resume`/operator turns
can't cleanly start because the orchestrator already reads as busy — so it never re-engages on
returned workers again.

This is the orchestrator-level twin of the worker "phantom `:running`" bug fixed by
`RepoBuilder.Session.LivenessReaper` (spec
`issue-worker-terminal-adw-bug-sdlc_planner-orchestrator-misses-finished-workers.md`, Part B).
That reaper only sweeps the **`agents`** table, so the **`orchestrators`** table has no liveness
backstop at all.

**Expected:** when an orchestrator turn ends — cleanly, by crash, by silent session death, by
brutal supervisor shutdown, or across a BEAM restart — the `orchestrators.status` is reconciled
back to a resting state (`:idle`), so the orchestrator stays usable and can auto-resume again.

**Actual (verified live via `project_eval` + `get_logs`):** orchestrator
`bb2ca162-7400-47c8-bcfb-49c7488b02f8` (`claude`/`opus`) shows `status: :running`, `session_id:
nil`, **no live `Orchestrator.Server` turn, no live Queue, no live `Session.Registry` orchestrator
session**, and **no persisted `agent_logs` since 13:35** even though the row was written to
`:running` at 20:57 by the auto-resume that the worker reaper triggered. It is frozen `:running`
and nothing reconciles it.

## Problem Statement
1. An orchestrator turn that ends WITHOUT a terminal harness event (`%Event.Done{}` /
   `%Event.Error{}`) leaves `orchestrators.status` stuck at `:running` — `Orchestrator.Server`'s
   crash-safety `terminate/2` deliberately flushes status `nil` ("leave as-is").
2. There is no out-of-process backstop for the `orchestrators` table: the `LivenessReaper`
   reconciles only `agents`, and `OrphanReaper` only reaps OS pids — so a wedged orchestrator
   never self-heals (not on the interval, not on boot).

## Solution Statement
Two surgical changes, mirroring the worker fix:

- **In-process (primary):** make `Orchestrator.Server.terminate/2` reconcile a non-terminal exit
  to `:idle` instead of leaving status untouched. A turn that reaches `terminate/2` without
  having flushed a terminal status has, by definition, no live turn — so `:idle` is correct and
  keeps the orchestrator usable. (Cost/usage accumulation is preserved exactly as today.)
- **Out-of-process (backstop):** extend `LivenessReaper` with a second sweep pass over the
  `orchestrators` table: any orchestrator stuck `:running`/`:holding`, older than the staleness
  grace, with NO live turn (no `Orchestrator.Server` and no `"orch-<id>-…"` session in the
  session registry) is reconciled to `:idle` and an `orchestrator_updated` broadcast flips the
  console. This covers the paths `terminate/2` can't (hard `Process.exit(_, :kill)`, brutal
  supervisor shutdown, BEAM/node restart — exactly the documented gap at
  `lib/repo_builder/session/server.ex:517-519`).

The reaper pass also reconciles orchestrators wedged BEFORE this fix shipped (e.g. the live
`bb2ca162`) on its next sweep / on boot — no manual DB edit required.

## Steps to Reproduce
1. Have an orchestrator run a turn so its row flips to `:running` (`Orchestrator.Server`
   `handle_continue(:launch)`, `server.ex:194`).
2. End that turn WITHOUT a terminal event reaching `Orchestrator.Server`: kill the orchestrator's
   harness `Session.Server` with `Process.exit(pid, :kill)` (no `%Event.Done/Error{}` dispatched),
   or hard-kill the `Orchestrator.Server`, or restart the BEAM mid-turn.
3. Observe `orchestrators.status` stays `:running` forever; `Queue.whereis/1` is `nil`; no live
   `"orch-<id>-…"` session exists; the console card shows "running"; `auto_resume` can no longer
   start a clean turn.

(Reproduced live: `bb2ca162` — `:running`, no process, no logs since 13:35, written `:running`
at 20:57 by the worker reaper's auto-resume.)

## Root Cause Analysis
**Mechanism 1 — `terminate/2` leaves status as-is.** `lib/repo_builder/orchestrator/server.ex`:

- `handle_continue(:launch)` sets `:running` (`server.ex:194`), then spawns the orchestrator's
  harness `Session.Server` and returns `{:noreply}` — it does NOT monitor that session's pid; it
  only subscribes to `agent:<id>:events` and waits for a terminal frame.
- Normal completion: `handle_info(%Event.Done{})` → `flush(state, :idle|:error)` (277);
  `%Event.Error{}` → `flush(:error)` (282). These set status correctly.
- Crash safety: `terminate/2` (`server.ex:292-303`) calls `flush(state, nil)` and its own comment
  states *"status is left as-is (no terminal seen ⇒ no status change)."* So whenever the turn ends
  without a `Done`/`Error` having been received — the harness session died silently, or the
  `Orchestrator.Server` itself was stopped — the status is **never reset from `:running`**.

Because `Orchestrator.Server` doesn't monitor its harness session pid, a silent session death
produces no terminal event, so `flush(nil)` is the path taken and the row wedges `:running`.

**Mechanism 2 — no out-of-process backstop for `orchestrators`.** `LivenessReaper.sweep/0`
queries only `FROM agents WHERE status IN ('running','holding') AND updated_at < $stale` (confirmed
in `get_logs`). `OrphanReaper` only reaps OS pids via the ledger. Nothing reconciles a stuck
`orchestrators` row — so `terminate/2`-bypassing paths (hard kill, brutal shutdown, BEAM restart)
leave a permanent phantom. This is the orchestrator-side of the KNOWN GAP already documented for
workers at `lib/repo_builder/session/server.ex:517-519`.

## Relevant Files
Use these files to fix the bug:

- `lib/repo_builder/orchestrator/server.ex` — **primary fix.** `terminate/2` (292-303) must
  reconcile a non-terminal exit to `:idle` (via `flush(state, :idle)`) instead of `flush(state,
  nil)`. Keep the `flushed?: true` short-circuit (290) and the cost-accumulation behavior. Status
  writes live at 194 (`:running`), 277 (`:idle|:error`), 282/229/129 (`:error`).
- `lib/repo_builder/session/liveness_reaper.ex` — **backstop fix.** Add a second sweep pass over
  orchestrators; reuse the existing GenServer/interval/config. `sweep/0` should reconcile both
  workers (today) and orchestrators (new).
- `lib/repo_builder/orchestrator.ex` (`RepoBuilder.Orchestrators`) — the ONLY `Repo` caller for
  `orchestrators` (§8). Add an `@spec`'d stale-running query; `set_status/2` and
  `RepoBuilder.Dashboard.broadcast_orchestrator_updated/1` already exist.
- `lib/repo_builder/orchestrator/orchestrator.ex` — schema; `status` is `Ecto.Enum`
  `[:idle, :running, :error]` (confirm the value set; reconcile target is `:idle`).
- `lib/repo_builder/orchestrator/queue.ex` — turn liveness: `Queue.whereis/1`
  (`OrchestratorQueueRegistry`) and the turn pid the Queue monitors; referenced to decide the
  "no live turn" predicate.
- `lib/repo_builder/orchestrator/server.ex` (`do_start_turn/2`, 157) — the orchestrator turn's
  harness session is registered in `RepoBuilder.SessionRegistry` under
  `agent_id = "orch-<orchestrator_id>-<n>"`; the reaper's liveness check scans for that prefix.
- `lib/repo_builder/dashboard.ex` — `broadcast_orchestrator_updated/1` (flip the console header/card).
- `lib/repo_builder/application.ex` — `LivenessReaper` is already supervised after `Repo` /
  `Session.Supervisor`; no new child needed (reusing the module).
- `config/config.exs`, `config/test.exs` — the existing `:session_liveness_reaper` config
  (`sweep_on_boot`, `interval_ms`, `min_stale_ms`) governs the new pass too; no new keys required.
- `lib/repo_builder_web/components/console_components.ex` / `console_live.ex` — the orchestrator
  status indicator that re-renders off `{:orchestrator_updated, _}`; referenced, no change expected.

### New Files
- `test/repo_builder/orchestrator/test_orchestrator_terminate_reconcile_test.exs` — proves
  `Orchestrator.Server.terminate/2` reconciles a non-terminal exit to `:idle` (fails before, passes
  after).
- `test/repo_builder/session/liveness_reaper_orchestrator_test.exs` — proves the reaper reconciles
  a stale orchestrator stuck `:running` with no live turn to `:idle` (and leaves live/idle/within-grace ones alone).

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Reconcile a non-terminal orchestrator exit to `:idle` (primary, in-process)
- In `lib/repo_builder/orchestrator/server.ex` `terminate/2` (292-303), change `flush(state, nil)`
  to `flush(state, :idle)`. Update the comment to: a turn reaching `terminate/2` without a terminal
  has no live turn, so `:idle` is the correct resting status (cost/usage still flush). Keep the
  `terminate(_reason, %State{flushed?: true}), do: :ok` clause (290) — a turn that already flushed a
  terminal `:idle|:error` must NOT be overwritten. Keep the `rescue`/`catch` guard so a flush
  failure never masks the original crash reason. Preserve all `@spec`s.

### 2. Add the stale-running query to the Orchestrators context
- In `lib/repo_builder/orchestrator.ex`, add `@spec list_stuck_running(DateTime.t()) ::
  [Orchestrator.t()]` returning orchestrators with `status in [:running, :holding]` (use whatever
  subset the `status` enum actually defines — `:running` at minimum) and `updated_at <
  stale_before`. Keep `Repo` access in this module (§8).

### 3. Extend LivenessReaper with an orchestrator sweep pass
- In `lib/repo_builder/session/liveness_reaper.ex`, after the existing agents pass, add a
  `sweep_orchestrators/1` (taking `stale_before`) that:
  1. `Orchestrators.list_stuck_running(stale_before)`.
  2. Keeps only orchestrators with NO live turn — predicate `orchestrator_turn_alive?/1` is false,
     where alive means EITHER `RepoBuilder.Orchestrator.Queue.whereis(id)` holds a monitored
     in-flight turn, OR the session registry has a live process whose key starts with
     `"orch-<id>-"` (`Registry.select(RepoBuilder.SessionRegistry, …)` filtered by prefix).
  3. For each phantom, `reconcile_phantom_orchestrator/1` (fail-soft, mirroring the worker path):
     `Orchestrators.set_status(id, :idle)` then
     `RepoBuilder.Dashboard.broadcast_orchestrator_updated(updated)`; `Logger.info("LivenessReaper
     reconciled phantom :running orchestrator=#{id}")`.
  - Have `sweep/0` return the combined count (workers + orchestrators reconciled) and run BOTH
    passes on the interval and on boot. Every public function keeps an `@spec`.
- Update the module `@moduledoc` to state it now reconciles both worker sessions and orchestrator
  turns.

### 4. Test the in-process reconcile (fails before, passes after)
- Create `test/repo_builder/orchestrator/test_orchestrator_terminate_reconcile_test.exs`: build an
  `Orchestrator.Server` State for a real orchestrator row set to `:running`, invoke
  `Orchestrator.Server.terminate(:killed, state)` with `flushed?: false`, and assert the
  orchestrator row is reconciled to `:idle`. Add a guard test: a state with `flushed?: true` (a
  turn that already flushed `:error`) is NOT overwritten to `:idle`.

### 5. Test the reaper orchestrator pass (fails before, passes after)
- Create `test/repo_builder/session/liveness_reaper_orchestrator_test.exs` (`RepoBuilder.SessionCase`,
  `async: false`), driving `LivenessReaper.sweep/0`:
  - **Phantom reconciled:** an orchestrator forced to `status: :running` with an `updated_at` older
    than `min_stale_ms` and NO live turn → `sweep/0` flips it to `:idle` and emits
    `{:orchestrator_updated, %Orchestrator{status: :idle}}` (subscribe via `Dashboard.subscribe/0`
    or the orchestrator topic).
  - **Live turn untouched:** an orchestrator with a live `"orch-<id>-…"` session (or a live Queue
    turn) registered is NOT reconciled even when stale.
  - **Within grace untouched:** a `:running` orchestrator updated `now` is left alone.
  - **Idle untouched:** an `:idle` orchestrator is never touched.

### 6. Run the full validation suite
- Run every command in `Validation Commands` and resolve any failure/warning.

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- `mix test test/repo_builder/orchestrator/test_orchestrator_terminate_reconcile_test.exs` — in-process reconcile.
- `mix test test/repo_builder/session/liveness_reaper_orchestrator_test.exs` — reaper orchestrator pass.
- `mix test test/repo_builder/session/ test/repo_builder/orchestrator/` — session + orchestrator/queue suites (turn lifecycle, auto-resume, worker reaper) stay green.
- `mix test test/repo_builder_web/live/test_orchestrator_holding_pattern_test.exs test/repo_builder_web/live/test_orchestrator_adw_resume_test.exs` — LiveView orchestrator paths unaffected.
- `mix compile --warnings-as-errors` — compile clean (gradual type checker + `warnings_as_errors`).
- `mix test --warnings-as-errors` — full suite, zero failures.
- `mix format --check-formatted` — formatting clean.
- `mix credo --strict` — lint clean, including the `@spec`-on-every-public-function convention.
- `mix dialyzer` — `@spec`/contract checking with no new warnings.

## Notes
- **Clears the existing wedge automatically:** once shipped, the reaper's next interval/boot sweep
  reconciles the live `bb2ca162` phantom to `:idle` — no manual DB edit. To clear it immediately
  without waiting, evaluate `RepoBuilder.Session.LivenessReaper.sweep()` once.
- **Why `:idle`, not `:error`:** a wedged orchestrator has no in-flight work and the operator wants
  it usable again; `:idle` lets the next operator/auto-resume turn start cleanly. (Workers reconcile
  to `:error` because a worker's unfinished dispatch is a failed unit of work; an orchestrator is a
  long-lived brain, not a unit of work.)
- **Liveness predicate is load-bearing:** a long Claude orchestrator turn is legitimately `:running`
  for minutes with a live `"orch-<id>-…"` session — the registry/Queue check protects it; the
  `min_stale_ms` grace protects the launch window between `set_status(:running)` (194) and the
  session registering.
- **Belongs with the worker fix:** this is the symmetric second half of "the orchestrator loses
  track of work." Mechanism 1 (in-process) closes the common case; Mechanism 2 (reaper) closes the
  hard-kill/restart case the in-process path can't reach.
- **Optional hardening (out of scope):** `Orchestrator.Server` could `Process.monitor` its harness
  `Session.Server` so a silent session death synthesizes a terminal immediately instead of waiting
  for the idle watchdog / reaper. Larger change; not needed for this fix.
- No new dependencies, no migration, no `mix.exs` change.

## Status
- [ ] Not yet implemented. (Diagnosis verified live on orchestrator `bb2ca162`.)
