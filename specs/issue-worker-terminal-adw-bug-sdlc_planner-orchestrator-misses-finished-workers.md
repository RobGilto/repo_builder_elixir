# Bug: Orchestrator loses track of finished/dead workers

The orchestrator never re-engages on a worker it dispatched. This has **two distinct
root causes**, folded into one spec because they are the two halves of the same symptom
("a worker the orchestrator dispatched never gets followed up on"):

- **Part A — dropped terminal signal (IMPLEMENTED in this change).** The worker DID reach
  a terminal event, but the re-engage broadcast was dropped because the owning
  `orchestrator_id` couldn't be re-read from the agent row at terminal time.
- **Part B — phantom `:running` worker (TO IMPLEMENT).** The worker produced NO terminal
  at all and has NO live process, yet its row is frozen at `status: :running` forever. The
  orchestrator is purely event-driven and runs no liveness/stuck poll, so nothing ever
  notices and it never re-engages.

## Metadata
issue_number: `worker-terminal`
adw_id: `bug`
issue_json: `{"title":"Workers finish (or die) but the orchestrator does not pick up that the agents finished","body":"While building the game DroneCommander, dispatched workers either finish their turn or die, but the orchestrator never re-engages — it acts as if the workers are still running. The console shows workers stuck on 'running' that are not actually running. Happens for SOME workers, not all."}`

## Bug Description
When the orchestrator dispatches a worker agent, the worker runs in its own
`RepoBuilder.Session.Server` process. When that worker finishes, the session signals the
owning orchestrator's `Queue` over PubSub (`orchestrator:<id>:workers`) so the queue can
**auto-resume** the orchestrator (the "holding pattern" / `auto_resume_on_worker_return`,
`config/config.exs:306`, default `true`). The orchestrator does **not** run any loop that
polls workers for idle/stuck/liveness — re-engagement is entirely event-driven off that one
broadcast.

Two failures break that single signal:

- **Part A:** the broadcast is emitted only if a live `Agents.get_agent/1` read at terminal
  time still returns an `orchestrator_id`. When the row is gone / unbound (wind-down,
  handover, force-retire reaps, operator deletion, double-terminal race) the broadcast is
  silently dropped.
- **Part B:** if the worker's `Session.Server` dies WITHOUT ever dispatching a terminal —
  a hard `Process.exit(pid, :kill)`, a brutal supervisor shutdown, or a **BEAM/node
  restart** — then `terminate/2`'s synthesized-terminal backstop (`server.ex:507-530`) never
  runs. The optimistic `:running` write from `command_agent` is never undone, so the row
  wedges at `:running` forever, no broadcast is ever sent, and the orchestrator never
  re-engages. The console "still running" card is a faithful render of that frozen column.

**Expected:** every time a worker finishes OR dies, the owning orchestrator is notified and
(if idle) auto-resumes — and the console card reflects the worker's true state.

**Actual (live evidence, verified via `project_eval`):** worker `researcher`
(`c0d0f7e4-3565-4e50-bf57-fc59fbb13e46`, orchestrator `bb2ca162-…`) shows `status: :running`,
**last updated 431 minutes ago**, with **no live `SessionRegistry` process** (and zero live
sessions overall) — a textbook Part B phantom.

## Problem Statement
1. (Part A) Worker→orchestrator re-engagement is coupled to the *current* existence/shape of
   the `agents` row even though the owning orchestrator is already known at spawn.
2. (Part B) There is no safety net for a worker that dies without emitting a terminal: no
   periodic liveness sweep and no PID monitoring, so a `:running` row with no process is never
   reconciled and never re-engages the orchestrator.

## Solution Statement
- **Part A (done):** capture the owning `orchestrator_id` (and worker `name`) into the
  `Session.Server` state at spawn and emit the worker-terminal broadcast from that captured
  state, demoting the DB read to a best-effort fallback for the `name` only.
- **Part B (to do):** add a periodic **liveness reaper** GenServer (sibling to
  `OrphanReaper`) that, on boot and on an interval, finds non-archived agents stuck
  `:running`/`:holding` whose session process is NOT alive and that are older than a staleness
  grace, then for each: reconciles status to `:error`, broadcasts `agent_updated` (so the
  console card flips), and — when the agent carries an `orchestrator_id` — fires
  `broadcast_worker_terminal/2` so the orchestrator Queue re-engages via its existing
  force-retire path. This closes the gap the runtime already documents at `server.ex:517-519`
  ("a boot/periodic sweep, sibling to OrphanReaper, would be needed to close it").

## Steps to Reproduce
**Part A:** dispatch a worker; delete/unbind its `agents` row before it terminates (queue
wind-down/handover/force-retire reap, or operator delete); the worker reaches `%Event.Done{}`;
`maybe_emit_worker_terminal/2`'s `Agents.get_agent/1` returns nil (or no `orchestrator_id`);
no broadcast → the Queue never auto-resumes.

**Part B:** dispatch a worker so its row flips to `:running`; kill the BEAM (or hard-kill the
worker `Session.Server` with `Process.exit(pid, :kill)`) before it emits a terminal; restart
the app. The worker row stays `:running` forever; the console shows it "running"; the
orchestrator never re-engages. (Reproduced live: `researcher`, 431 min stale, no process.)

## Root Cause Analysis
**Part A** — `RepoBuilder.Session.Server.maybe_emit_worker_terminal/2` gated the broadcast on a
terminal-time `Agents.get_agent(agent_id)` read, even though `command_agent/2` already passes
`orchestrator_id` into the spawn opts (`tools.ex:340`). `build_state/3` never captured it, so
re-engagement depended on the agent row still existing with an intact `orchestrator_id`.

**Part B** — re-engagement is *only* ever triggered by the worker-terminal broadcast, which is
*only* ever emitted from within the worker's own `Session.Server` (`dispatch/2`, including the
`terminate/2` synthesized-terminal backstop). Nothing outside that process observes worker
liveness:

- `terminate/2 → reconcile_status_quietly/2` (`server.ex:507-530`) covers graceful/crash
  exits, but its own comment flags the gap: a hard kill / brutal shutdown **bypasses
  `terminate/2` entirely**, so the status is never reconciled and no broadcast fires.
- The `Queue` subscribes to the PubSub topic but does **not** `Process.monitor` the worker
  PIDs it dispatches — so a silent worker death is invisible to it.
- `OrphanReaper` runs **only at boot** and only reaps stray OS pids via the ledger; it does
  not sweep stuck `agents.status`, and it never runs while the node is up.

Net: a worker that dies without a terminal leaves a frozen `:running` row and a permanently
stalled orchestrator. There is no periodic or monitor-based detection to recover it.

## Relevant Files
Use these files to fix the bug:

### Part A (implemented)
- `lib/repo_builder/session/server.ex` — added `orchestrator_id`/`agent_name` to `State`,
  captured in `build_state/3`; `maybe_emit_worker_terminal/2` now broadcasts via
  `resolve_worker_owner/1` (spawn-captured first, DB fallback for `name` only).
- `lib/repo_builder/orchestrator/tools.ex` — `command_agent/2` opts now include
  `agent_name: worker.name`.
- `test/repo_builder/session/test_worker_terminal_without_agent_row_test.exs` — Part A
  regression (broadcast still fires when the row can't supply `orchestrator_id`).

### Part B (to implement)
- `lib/repo_builder/session/server.ex` — the documented gap lives at `server.ex:507-530`
  (graceful backstop) and the KNOWN GAP comment at `server.ex:517-519`; the session via-tuple
  uses `RepoBuilder.SessionRegistry` keyed by `agent_id` (`server.ex:144`) — the reaper's
  liveness check.
- `lib/repo_builder/orphan_reaper.ex` — the structural template for the new reaper
  (boot `{:continue, …}`, config-gated `*_on_boot?`, started after `Repo`).
- `lib/repo_builder/application.ex` — supervision tree (`children`, ~line 84) where the new
  reaper is added, AFTER `RepoBuilder.Session.Supervisor`/the `SessionRegistry` so liveness
  lookups are valid.
- `lib/repo_builder/agents.ex` — the ONLY `Repo` caller for agents (§8); add the
  `:running`/`:holding` + stale + non-archived query; `set_status/2` already exists.
- `lib/repo_builder/agents/agent.ex` — `status` is a closed `Ecto.Enum`
  (`[:idle, :running, :error, :holding]`); the reaper reconciles to `:error`.
- `lib/repo_builder/dashboard.ex` — `broadcast_worker_terminal/2` (re-engage the Queue, payload
  contract) and `broadcast_agent_updated/1` (flip the console card).
- `lib/repo_builder/orchestrator/queue.ex` — the consumer; an `ok?: false` worker-terminal with
  no handover routes the force-retire / normal-resume branch — confirm no change needed.
- `config/config.exs`, `config/test.exs` — add the reaper's `sweep_on_boot` / `interval_ms` /
  `min_stale_ms` config (boot + interval disabled in test, like `:orphan_reaper`).
- `lib/repo_builder_web/components/console_components.ex` (`agent_card/1`, ~line 271-292) — the
  card whose status span is the visible symptom; no change, referenced to confirm it re-renders
  off `{:agent_updated, agent}` (`console_live.ex:2711`).

### New Files
- `lib/repo_builder/session/liveness_reaper.ex` — the periodic + boot liveness sweep GenServer.
- `test/repo_builder/session/liveness_reaper_test.exs` — Part B unit tests (driven via an
  explicit `sweep/0`, mirroring how `OrphanReaper` tests drive `reap_node/1`).

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### Part A — captured-state worker terminal (DONE; keep green as the Part B regression baseline)
1. ✅ Added `orchestrator_id` + `agent_name` fields to `Session.Server.State`, captured in
   `build_state/3`.
2. ✅ Rewrote `maybe_emit_worker_terminal/2` to broadcast via `resolve_worker_owner/1`
   (spawn-captured first; DB read is a best-effort `name` fallback that never gates the
   broadcast). Kept the catch-all no-op clause + defensive `rescue`/`catch`.
3. ✅ `command_agent/2` passes `agent_name: worker.name`.
4. ✅ Added `test/repo_builder/session/test_worker_terminal_without_agent_row_test.exs`.

### Part B — periodic liveness reaper

#### 5. Add the stale-running query to the Agents context
- In `lib/repo_builder/agents.ex`, add `@spec`'d `list_stuck_running(DateTime.t()) :: [Agent.t()]`
  returning non-archived agents with `status in [:running, :holding]` and
  `updated_at < stale_before`. Keep the `Repo` access in this context module (§8). Order is
  irrelevant; keep it a single query.

#### 6. Create the liveness reaper GenServer
- Create `lib/repo_builder/session/liveness_reaper.ex` (`RepoBuilder.Session.LivenessReaper`),
  structured like `OrphanReaper`:
  - `use GenServer`; `start_link/1` with `name: __MODULE__`.
  - `init/1`: schedule a periodic `:sweep` via `Process.send_after/3` only when enabled, and
    run a boot sweep via `{:continue, :sweep}` only when `sweep_on_boot?/0` — both gated by
    `Application.get_env(:repo_builder, :session_liveness_reaper, [])` (`sweep_on_boot`,
    `interval_ms` default `60_000`, `min_stale_ms` default `120_000`). In test both default
    off, like `:orphan_reaper`.
  - `handle_continue(:sweep, _)` and `handle_info(:sweep, _)` both call `sweep/0` and (for the
    interval case) reschedule.
  - Public `@spec sweep() :: non_neg_integer()` (returns count reconciled) so tests drive it
    deterministically:
    1. Compute `stale_before = DateTime.add(DateTime.utc_now(), -min_stale_ms, :millisecond)`.
    2. `Agents.list_stuck_running(stale_before)`.
    3. Keep only agents whose session process is NOT alive:
       `Registry.lookup(RepoBuilder.SessionRegistry, agent.id) == []` (a live registered worker
       is mid-turn and must be left alone — this is what prevents reaping a healthy worker).
    4. For each phantom, call a private `reconcile_phantom/1` and count it.
  - `@spec reconcile_phantom(Agent.t()) :: :ok` — fail-soft (`rescue`/`catch` → `:ok`, mirroring
    OrphanReaper/`delete_ledger_quietly`), doing:
    1. `Agents.set_status(agent.id, :error)`.
    2. `RepoBuilder.Dashboard.broadcast_agent_updated(updated)` so the console card flips
       `running → error`.
    3. When `is_binary(agent.orchestrator_id)`,
       `RepoBuilder.Dashboard.broadcast_worker_terminal(agent.orchestrator_id, %{worker_id: agent.id, name: agent.name, ok?: false, holding?: false, holding_reason: nil, context_tokens: 0, final_text: nil})`
       so the orchestrator Queue re-engages exactly as on a normal failed return.
    4. `Logger.info("LivenessReaper reconciled phantom :running agent=#{agent.id}")`.
- Every public function carries an `@spec` (credo gate); keep it idiomatic and non-raising.

#### 7. Supervise the reaper
- Add `RepoBuilder.Session.LivenessReaper` to the `application.ex` `children`, AFTER
  `RepoBuilder.Session.Supervisor` (so the `SessionRegistry` exists when it looks up liveness)
  and after `Repo`. Add a short comment mirroring the `OrphanReaper` entry.

#### 8. Configure the reaper
- `config/config.exs`: add `config :repo_builder, :session_liveness_reaper, sweep_on_boot: true, interval_ms: 60_000, min_stale_ms: 120_000` with a comment explaining the staleness grace
  (avoid reaping a worker in the sub-second window between the optimistic `:running` write and
  the process registering).
- `config/test.exs`: add `config :repo_builder, :session_liveness_reaper, sweep_on_boot: false, interval_ms: :infinity` (or a guard so the interval never fires) so tests drive `sweep/0` explicitly and the periodic timer never races the sandbox.

#### 9. Part B tests (fail before, pass after)
- Create `test/repo_builder/session/liveness_reaper_test.exs` (`RepoBuilder.SessionCase`,
  `async: false`), driving `LivenessReaper.sweep/0` directly:
  - **Phantom reconciled + re-engages:** create a worker bound to an orchestrator, force its row
    to `status: :running` with an `updated_at` older than `min_stale_ms` (e.g.
    `Ecto.Changeset.change(updated_at: ...)` + `Repo.update!`), start NO session, subscribe via
    `Dashboard.subscribe_orchestrator_workers/1` and `Dashboard.subscribe/0`. Assert `sweep/0`
    returns `1`, the row becomes `:error`, and `{:worker_terminal, %{worker_id: ^id, ok?: false}}`
    + `{:agent_updated, %Agent{status: :error}}` are received.
  - **Live worker untouched:** a worker WITH a live `Session.Server` (start one via the Mock
    adapter that stays running, or register a dummy under `SessionRegistry`) and a stale
    `updated_at` is NOT reaped (still `:running`, `sweep/0` skips it).
  - **Within grace untouched:** a `:running` worker updated `now` (younger than `min_stale_ms`)
    is NOT reaped (guards the optimistic-write race).
  - **Idle/terminal untouched:** an `:idle` agent is never touched.
  - **No orchestrator_id:** a stale `:running` agent with `orchestrator_id: nil` is still
    reconciled to `:error` (and emits `agent_updated`) but fires no worker-terminal — assert no
    `{:worker_terminal, …}` arrives.

### 10. Run the full validation suite
- Run every command in `Validation Commands` and resolve any failure/warning.

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- `mix test test/repo_builder/session/test_worker_terminal_without_agent_row_test.exs` — Part A
  regression.
- `mix test test/repo_builder/session/liveness_reaper_test.exs` — Part B reaper (phantom →
  `:error` + re-engage; live/fresh/idle untouched).
- `mix test test/repo_builder/session/ test/repo_builder/orchestrator/` — session-runtime +
  queue/auto-resume suites stay green.
- `mix test test/repo_builder_web/live/test_orchestrator_holding_pattern_test.exs test/repo_builder_web/live/test_agent_handover_test.exs test/repo_builder_web/live/test_orchestrator_adw_resume_test.exs` — LiveView re-engagement paths unaffected.
- `mix compile --warnings-as-errors` — compile clean; gradual type checker + `warnings_as_errors`.
- `mix test --warnings-as-errors` — full ExUnit suite, zero failures.
- `mix format --check-formatted` — formatting clean.
- `mix credo --strict` — lint clean, including the `@spec`-on-every-public-function convention.
- `mix dialyzer` — `@spec`/contract checking with no new warnings.

## Notes
- **One-time cleanup of existing phantoms:** the boot sweep reconciles phantoms that survived a
  prior restart (e.g. the live `researcher` row). To clear it immediately without a restart,
  evaluate `RepoBuilder.Session.LivenessReaper.sweep()` once after deploy.
- **Why a sweep and not only PID monitoring:** the `Queue` could additionally `Process.monitor`
  each dispatched worker for *instant* detection, but a monitor cannot recover phantoms created
  *before* it existed (a node restart — exactly the live case). The periodic + boot sweep covers
  both, is the smaller change, and is what the runtime comment at `server.ex:517-519` already
  prescribes. Queue PID-monitoring is a reasonable *additional* enhancement but is out of scope
  for this minimal fix.
- **Contract unchanged:** Part B reuses the existing `broadcast_worker_terminal/2` payload and
  the Queue's existing failed-return handling — no consumer changes. `ok?: false` with no
  handover signal routes the same recovery the Queue already runs when a worker returns failed.
- **Staleness grace is load-bearing:** `min_stale_ms` (default 120s, ≥ 2× the interval) prevents
  reaping a worker in the brief window between `command_agent`'s optimistic `:running` write and
  the `Session.Server` registering in `SessionRegistry`.
- No new dependencies, no migration, no `mix.exs` change.
