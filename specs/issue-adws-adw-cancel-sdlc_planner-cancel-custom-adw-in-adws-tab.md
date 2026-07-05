# Feature: Cancel anything that runs and shows in the ADWS tab

## Metadata
issue_number: `adws`
adw_id: `cancel`
issue_json: `n/a` (freeform feature request — `in the ADWS tab the ability to cancel ANYTHING that runs and shows there, both kinds of long-running work, behind ONE unified Cancel affordance`)

## Feature Description
Add a single, identical **`✕ Cancel`** affordance to **both** kinds of long-running work
that render inside the ADWS view of the operator console (`view_mode == :adws`,
`RepoBuilderWeb.ConsoleLive` ~lines 2002–2105), so the operator can stop either kind
in one tap with one confirmation modal:

1. **Custom ADWs (workstreams).** The four-column Spec → Implement → Test → Review Kanban
   swimlane (built from `orchestrator_workstreams` rows by
   `BrainComponents.workstreams_swimlane/1`, `brain_components.ex:145`). Cancel flips
   the durable `Workstream.status` from `:running`/`:blocked` ⇒ `:abandoned` via the
   existing `RepoBuilder.Orchestrator.Workstreams.close_workstream/3` seam (already
   valid for `:abandoned`, `workstreams.ex:349`).

2. **Standard / orchestrator-launched ADWs (workflow runs).** The `<.adw_card>`s rendered
   in `#workflow-runs` (built from `workflow_runs` rows by
   `DashboardComponents.adw_card/1`, `dashboard_components.ex:77`). Cancel does **more
   than a DB flip** — it tears down the live `WorkflowEngine.Runner` GenServer that
   owns the in-flight step + its live harness session, AND cancels the equivalent
   durable Oban `StepWorker` job when the run has not yet started live. Cancellation
   is **idempotent at the DB level** and bounded to cancel-eligible states
   (workstream `:running`/`:blocked`; run `:queued`/`:running`).

Both affordances open an always-mounted confirmation modal that names the entity,
binds a wire-type payload (`%{"id" => ref}`), and calls a `@impl`-true `handle_event/3`
in the existing console LiveView. Each `handle_event` is the typed boundary between
the modal's wire type and the engine's domain atom (`:abandoned` for workstreams;
`:cancelled` for runs) — no `String.to_atom/1` on operator input. The WireType →
DomainType bridge at this boundary (typed standard §3, rule 6) is the single seam
where unsafe literals would otherwise leak; both handlers pass a **compile-time
literal atom** (`:abandoned` / `:cancelled`), never a parsed one.

The endpoint of both cancel paths is **the same** cross-console broadcast on
`Dashboard`'s topics — `broadcast_workstreams/2` for the workstream path, and
`broadcast_workflow(run.id, {:workflow_update, run})` (the identical 2-tuple the live
Runner already emits from `broadcast_lane/2`) for the run path — so any open console
tab re-renders the affected card immediately, and `:abandoned` / `:cancelled`
workstreams + runs remain in the DB (with a tinted status chip) for auditability.
Nothing is hard-deleted.

The non-trivial Phase 2 work is the **ADW-run teardown seam**: today
`RepoBuilder.WorkflowEngine.start_workflow/2`
(`lib/repo_builder/workflow_engine.ex:29`) starts the Runner via
`DynamicSupervisor.start_child(WorkflowSupervisor, {Runner, ...})` and returns
`{:ok, run.id, pid}` **without registering the pid by run id**. There is no Registry
keyed by run id (contrast `RepoBuilder.SessionRegistry`, which the session runtime
already uses, `application.ex:43`). This plan adds a `RepoBuilder.WorkflowRunRegistry`
(`:unique`) under the supervision tree, registers the Runner in `init/1` via
`Registry.register/3`, and defines a typed `RepoBuilder.WorkflowEngine.cancel_run/1`
that:

- looks up the pid via `Registry.lookup(WorkflowRunRegistry, run_id)`; falls back to a
  `DynamicSupervisor.which_children/1` scan of `RepoBuilder.WorkflowSupervisor` only
  if the Registry lookup misses (defensive; a `:queued`-only run has no live Runner at
  all and skips straight to the durable path);
- if a live session is in flight (`state.session_agent_id`), interrupts that session
  via `RepoBuilder.Session.Supervisor.stop_session/1` (`supervisor.ex:104`, delegates
  to `DynamicSupervisor.terminate_child(SessionSupervisor, pid)`; the session
  GenServer's `terminate/2` already does SIGTERM→SIGKILL of the OS child and deletes
  the ledger row) so **no agent keeps burning budget** — but the authoritative teardown
  lives in the Runner's own `terminate/2` (it traps exits), so a cancel that races the
  Runner's normal exit still cleans up exactly once;
- sets the run's `status` to `:cancelled` via `Workflows.update_run/2`, marks the
  in-flight step `:cancelled` via the existing `WorkflowEngine.record_step_state/3`
  seam that both the live Runner and durable `StepWorker` already share (§7
  source-of-truth contract), and cancels any pending/available `StepWorker` job for
  that run (idempotent `Oban.cancel_all_jobs/1` scoped by the `workflow_run_id` job
  arg);
- `DynamicSupervisor.terminate_child(RepoBuilder.WorkflowSupervisor, pid)` on the
  Runner pid (the trapped-exit Runner runs its `terminate/2` teardown, then exits; it
  is `:temporary`, so it is not restarted);
- broadcasts `{:workflow_update, run}` on the per-run topic
  (`Dashboard.broadcast_workflow/2`, `dashboard.ex:304`) so every open console
  re-renders the `<.adw_card>` as cancelled.

A worktree-isolated run's branch is **not** auto-cleaned on cancel (the merge step is
deliberately bypassed; the branch stays until the operator runs `merge` or removes it
manually); this is a deliberate UX decision documented in §Notes.

## User Story
As a **platform operator** watching a long-running ADW in the ADWS tab,
I want to **stop either kind of in-flight work (a custom workstream or a standard
ADW run) with a single `✕ Cancel` button that opens a confirmation modal**, then have
the modal action actually **stop the live process and update the card to
`:abandoned`/`:cancelled`** within one broadcast round-trip on every open console,
So that **I can pull the plug on a runaway ADW without waiting for it to finish,
without writing a chat instruction, and without leaving the operator UI** — and the
audit trail stays in the DB.

## Problem Statement
The ADWS view (`view_mode: :adws`, `RepoBuilderWeb.ConsoleLive` ~lines 2002–2105) shows
two kinds of long-running work, but cancel today is **either missing or out of reach**:

1. **Standard / orchestrator-launched ADWs** — `workflow_runs` rows, rendered as
   `<.adw_card>`s inside `#workflow-runs`. Their lifecycle
   (`RepoBuilder.Workflows.WorkflowRun.status`,
   `lib/repo_builder/workflows/workflow_run.ex:12` + `@statuses` line 36) **already
   includes `:cancelled`** and the per-step enum (`Step.status`,
   `lib/repo_builder/workflow_engine/step.ex:12`) **already includes `:cancelled`** —
   the schema accepts it, no migration needed. But there is **no operator UI** to set
   either. Behind the scenes, a `:running` workflow is a live
   `RepoBuilder.WorkflowEngine.Runner` GenServer (`runner.ex:19`, `restart: :temporary`,
   `Process.flag(:trap_exit, true)` at `runner.ex:60`) started under
   `RepoBuilder.WorkflowSupervisor` via `DynamicSupervisor.start_child/2` in
   `start_workflow/2` (`lib/repo_builder/workflow_engine.ex:41`). Each `:running` step
   holds a live agent session via `Session.Supervisor.start_session(...)`
   (`runner.ex:141`), with `session_agent_id` in the Runner's `State`
   (`runner.ex:45`). **The Runner is NOT registered anywhere by run_id** —
   `start_workflow/2` returns `{:ok, run.id, pid}` to its caller but no
   Registry/`via_tuple` lets a cancel handler look it up later. **Cancelling a
   `:running` run therefore means: (a) find the Runner pid, (b) stop its live session,
   (c) terminate the Runner, (d) persist `:cancelled` on both the run and the in-flight
   step, (e) cancel any pending `StepWorker` job for that run, (f) broadcast so consoles
   re-render.** None of that exists today. A `:queued` run instead may live only as an
   Oban `StepWorker` job keyed on `{workflow_run_id, step_name}`
   (`step_worker.ex:9`, `unique: [...]`); cancel also has to reach that job (otherwise
   the next Oban tick resumes the run and we lied).

2. **Custom ADWs that are workstreams** — `orchestrator_workstreams` rows rendered as
   the four-column Kanban by `BrainComponents.workstreams_swimlane/1`
   (`brain_components.ex:145`). The DB schema supports `status: :abandoned`,
   `Workstreams.close_workstream/3` (`workstreams.ex:349`) accepts it, and
   `WorkstreamOps.close_workstream/2` already exposes the same call to the brain — but
   **no UI button exists**. The phase card itself offers per-stage quick-action chips
   (`record_stage`) that drive `:passed | :failed | :blocked` **stage** transitions,
   NOT workstream abandonment. Operators must currently instruct the brain over chat to
   abandon a workstream, which costs turns, isn't reversible in one click, and isn't
   visible in the tab the operator is staring at.

The Kanban card's per-phase quick-actions and the `<.adw_card>`'s status header are
otherwise visually and behaviorally identical (chip + status + duration); the
**absence of one Cancel affordance on both** is the operator-facing gap.

## Solution Statement
Three-phase delivery. Phase 1 is the low-risk workstream DB-flip cancel. Phase 2 is
the substantive new half — the ADW-run teardown seam. Phase 3 unifies the UI and runs
integration tests for BOTH paths.

### Phase 1 — Workstream cancel (DB flip only)
1. **Per-workstream "Cancel" affordance on the swimlane card.** Add a `✕ Cancel
   workstream` chip on each phase card in `BrainComponents.workstreams_swimlane/1`,
   rendered only when `workstream.status in [:running, :blocked]` (terminal statuses
   would render a no-op — better not to render the button at all so the UI is honest).
   The button's `phx-click` is `"open_cancel_workstream"`, carrying
   `phx-value-id={ws.id}` and `phx-value-title={ws.title}`, so the modal can render the
   right workstream and call the existing context with the right ref.
2. **Always-mounted confirmation modal.** Add a
   `<div id="cancel-workstream-modal" ...>` that mirrors the `agent_models_modal/1`
   pattern: always in the DOM, hidden with `style="display:none"`, shown client-side
   via `JS.show(...)` only after the operator clicks Cancel. The modal renders the
   workstream title and two buttons — `Back` (hide) and `Cancel workstream` (calls
   `"cancel_workstream"`).
3. **`cancel_workstream` handler in `ConsoleLive`.** Calls the existing
   `RepoBuilder.Orchestrator.Workstreams.close_workstream/3` with `:abandoned`,
   broadcasts `Dashboard.broadcast_workstreams(orchestrator_id, records)`, and emits
   `put_flash(:info, "Cancelled '<title>'")`. `{:error, _}` ⇒ `put_flash(:error, …)` +
   close the modal.
4. **`:abandoned` chip CSS** plus a `data-workstream-status={to_string(ws.status)}`
   CSS rule to belt-and-suspenders hide the Cancel button on a cross-console race.

### Phase 2 — ADW-run cancel (tear down a LIVE process)
5. **`RepoBuilder.WorkflowRunRegistry`** — a new
   `{Registry, keys: :unique, name: RepoBuilder.WorkflowRunRegistry}` entry added to
   the supervision tree (`application.ex`) immediately after
   `RepoBuilder.WorkflowSupervisor`. This is the single missing lookup seam — without
   it, no cancel handler can find a Runner pid by run id.
6. **Runner registration** — modify `WorkflowEngine.Runner.init/1` to
   `Registry.register(RepoBuilder.WorkflowRunRegistry, run.id, nil)` immediately after
   `Process.flag(:trap_exit, true)`. (Register **inside `init/1`**, not via a
   `start_link` name — the run struct isn't in scope at `start_link/1`, and registering
   in `init` keeps `start_workflow/2` untouched; see justification in Notes.)
7. **`RepoBuilder.WorkflowEngine.cancel_run/1`** — a new typed context function that
   does the lookup → interrupt session → terminate Runner → persist `:cancelled` →
   cancel queued Oban job → broadcast path. Returns `{:ok, run} | {:error, reason}` so
   the UI flash is typed.
8. **`open_cancel_run_modal` + `cancel_run` handlers in `ConsoleLive`.** Mirror the
   workstream modal flow but routed to `WorkflowEngine.cancel_run/1`. The new
   confirmation modal lives at `<div id="cancel-run-modal" ...>`.
9. **`<.adw_card>` `✕ Cancel` affordance** in the `@status in [:queued, :running]`
   branch (the cancel-eligible set), with a stable `id={"cancel-run-#{@id}"}` for
   testing.

### Phase 3 — Unified UI affordance + cross-console broadcast + tests
10. **Shared modal CSS** (one `cns-cmd-overlay`/`cns-cmd-panel` rule covers both
    modals; no per-card duplication) and the `cns-chip--abandoned` / `cns-card--cancelled`
    palette rules.
11. **LiveView integration tests** driving BOTH paths — :running cancel, :blocked
    cancel, already-`:abandoned` no-op, queued Oban cancel, mid-step live-run cancel
    with session teardown, worktree branch left intact — plus a `WorkflowEngine.cancel_run/1`
    unit/integration test that starts a fake run, cancels it, and asserts `:cancelled` +
    session stopped + registry entry gone.

All edits stay inside the existing console LiveView + `BrainComponents` +
`DashboardComponents` + `WorkflowEngine.Runner` + `WorkflowEngine` + `Workflows` +
`Dashboard` + `Application` (sup tree) seams. No schema migration, no new deprecated
field, no new dependency.

## Relevant Files
Use these files to implement the feature:

- `lib/repo_builder_web/components/console/brain_components.ex` — `workstreams_swimlane/1`
  (line 145) is the Kanban board (rendered in the ADWS view). The Cancel chip
  (`phx-click="open_cancel_workstream"`) is added inside the existing per-phase
  `<div id="phase-card-#{phase.id}" …>` block, beside the title-row `cns-chip`,
  conditionally rendered when the **workstream** status (not the phase status) is in
  `[:running, :blocked]`. The always-mounted `<div id="cancel-workstream-modal" …>`
  lives right after this component, following the `agent_models_modal/1` precedent. All
  other Kanban behaviour (4 columns, per-phase record-stage buttons, ui_ux badge) is
  unchanged. The modal accepts workstream modal state as `%{open?, id, title}` driven by
  the `open_cancel_workstream` LiveView event.
- `lib/repo_builder_web/components/dashboard_components.ex` — `adw_card/1` (line 77) is
  the ADW-run card. The Cancel chip (`phx-click="open_cancel_run_modal"`) goes in the
  top-right header beside the `<span :if={@duration} class="cns-duration">` (line 93),
  conditionally rendered only when `@status in [:queued, :running]` (terminal statuses
  omit the button so the affordance disappears after the run is fully
  cancelled/succeeded/failed). The chip carries `phx-value-id={@id}` and
  `phx-value-title={@title}` for modal binding, with a stable `id={"cancel-run-#{@id}"}`.
- `lib/repo_builder_web/components/console/shared_components.ex` — add the show/hide JS
  helper pairs (next to the existing `show_agent_models/1` / `hide_agent_models/1`) for
  BOTH modals: `show_cancel_workstream/1` / `hide_cancel_workstream/1` AND
  `show_cancel_run/1` / `hide_cancel_run/1`. Each returns `Phoenix.LiveView.JS.t()`:
  `JS.show(js, to: "#<id>", display: "flex")` / `JS.hide(js, …)`. The existing
  `cns-cmd-overlay`/`cns-cmd-panel` CSS rules cover both.
- `lib/repo_builder_web/components/console_components.ex` (or the dashboard component
  namespace the console imports) — add `defdelegate`s so the console's HEEx can call
  `<.cancel_workstream_modal>` and `<.cancel_run_modal>` alongside the existing
  `workstreams_swimlane/1` / `adw_card/1` delegations.
- `lib/repo_builder_web/live/console_live.ex` — four new `handle_event` clauses, in the
  same workstream/quick-action block as `record_stage`:
  - `"open_cancel_workstream", %{…}` — assigns the modal's `%{open?, id, title}` state
    and shows the modal client-side.
  - `"cancel_workstream", %{"id" => ref}` — calls `Workstreams.close_workstream/3` with
    the literal `:abandoned`, broadcasts `Dashboard.broadcast_workstreams/2`, snaps flash.
  - `"open_cancel_run_modal", %{…}` — assigns `run_modal: %{open?, id, title}` state and
    shows `#cancel-run-modal`.
  - `"cancel_run", %{"id" => run_id}` — calls `WorkflowEngine.cancel_run/1`; the
    function already broadcasts `{:workflow_update, run}` on the per-run topic that the
    console's existing `handle_info` consumes, so the handler only snaps flash + closes
    the modal.
  Two new assigns (`workstream_modal: %{open?: false, …}`, `run_modal: %{open?: false, …}`)
  join the mount's default assigns.
- `lib/repo_builder/workflow_engine/runner.ex` — `init/1` (line 59) adds one line:
  `Registry.register(RepoBuilder.WorkflowRunRegistry, run.id, nil)` after the
  `Process.flag(:trap_exit, true)` and after `run` is bound. Add a `terminate/2`
  callback (the process already traps exits) that stops the live session
  (`Session.Supervisor.stop_session(state.session_agent_id)` when set) so a Runner
  killed by `DynamicSupervisor.terminate_child/2` tears its session down orderly.
  Everything else in the Runner is unchanged; `finalize/2` still owns the normal
  terminal path.
- `lib/repo_builder/workflow_engine.ex` — two changes:
  - `start_workflow/2` (line 30) is **unchanged** for registration (the Runner
    self-registers in `init/1`); no name option needed.
  - **NEW** `cancel_run/1` (see Implementation Plan §Phase 2) is the typed public
    function the LiveView handler calls. It does NOT raise; returns
    `{:ok, run} | {:error, reason}`.
  - `enqueue_workflow/2` is unchanged — durable queues still survive a node restart.
- `lib/repo_builder/workflows/workflow_run.ex` — **reference only.** Confirms that
  `status: :cancelled` is in `@type status` (line 12) and `@statuses` (line 36) and
  that `changeset/2` (line 68) casts `:status`; no migration needed.
- `lib/repo_builder/workflow_engine/step.ex` — **reference only.** Confirms
  `step.status` includes `:cancelled` (`step.ex:12`); the `record_step_state` seam on
  the same row works.
- `lib/repo_builder/workflows.ex` — **reference only for the seam.** `update_run/2`
  (line 120), `get_run/1` (line 89), and `put_step_state/3` (line 272) already exist;
  `cancel_run/1` calls `record_step_state/3` (which wraps `put_step_state/3`) for the
  in-flight step. No schema edits.
- `lib/repo_builder/workflow_engine.ex` `record_step_state/3` (line 130) — the SHARED
  transition seam that persists per-step state AND broadcasts per-step progress; the
  cancel path reuses it to mark the in-flight step `:cancelled`.
- `lib/repo_builder/orchestrator/workstreams.ex` — **existing only, no edits.**
  `close_workstream/3` (line 349) + `list_records/1` (line 414) reused unchanged.
- `lib/repo_builder/dashboard.ex` — already publishes `broadcast_workstreams/2`
  (line 185) and `broadcast_workflow/2` (line 304). The `cancel_run/1` function calls
  `broadcast_workflow(run.id, {:workflow_update, run})` — the identical 2-tuple the
  live Runner emits from `broadcast_lane/2` (`runner.ex:312`), which the console's
  `handle_info` already consumes. No edits here.
- `lib/repo_builder/session/supervisor.ex` — `stop_session/1` (line 104) is the
  existing typed seam a cancel-call uses to gracefully terminate the live session; the
  session's `terminate/2` does SIGTERM→SIGKILL of the OS child + ledger row delete +
  workspace cleanup. No edits; `cancel_run/1` and the Runner's `terminate/2` call it by
  agent id.
- `lib/repo_builder/application.ex` — adds **one new supervisor child**:
  `{Registry, keys: :unique, name: RepoBuilder.WorkflowRunRegistry}` inserted
  immediately after the `WorkflowSupervisor` (line 57), mirroring the existing
  `SessionRegistry` (line 43) that fronts the session runtime. It starts before any
  Runner is spawned (Runners are only started on demand by `start_workflow/2`).
- `lib/repo_builder/projects/worktree.ex` — a cancelled run's worktree branch is
  **deliberately** NOT auto-merged or removed; the operator can run `merge` later or
  remove the branch manually. Reference only. See §Notes.
- `lib/repo_builder/workers/step_worker.ex` — **reference only.** Confirms the
  durable-step model: a `:queued` run may be an Oban job keyed on `{workflow_run_id,
  step_name}` (line 9, `unique: [...]`). The cancel path reaches that job via
  `Oban.cancel_all_jobs/1` scoped by the `workflow_run_id` arg (see Phase 2 step 4e).
- `assets/css/app.css` — adds ONE chip rule `cns-chip--abandoned` (mirror the
  `cns-chip--blocked` palette) and confirms `cns-card--cancelled` renders a distinct
  left-border tint next to `cns-card--succeeded`. The `cns-cmd-overlay`/`cns-cmd-panel`
  rules already exist (used by `agent_models_modal`); both modals reuse them.
- `ai_docs/typed-elixir-standard.md` — `@spec`/`@typedoc`/enforce_keys requirements are
  enforced on every new function listed in `Step by Step Tasks`.

### New Files
- `test/repo_builder_web/live/test_cancel_custom_adw_in_adws_tab_test.exs` —
  `Phoenix.LiveViewTest` integration test that drives BOTH cancel flows end-to-end:
  (a) workstream cancel from `:running`, (b) workstream cancel from `:blocked`,
  (c) no-op for terminal workstream, (d) workstream cross-console broadcast,
  (e) ADW-run cancel from `:running` with live session teardown, (f) ADW-run cancel
  from `:queued` with Oban job cancellation, (g) no-op for terminal run, (h) ADW-run
  cross-console broadcast, (i) idempotent re-cancel of an already-`:cancelled` run,
  (j) worktree branch left intact after cancel.
- `test/repo_builder/workflow_engine/cancel_run_test.exs` —
  `RepoBuilder.DataCase` unit/integration test for `WorkflowEngine.cancel_run/1` in
  isolation: start a fake-harness run through `start_workflow/2`, assert the Runner is
  registered under `WorkflowRunRegistry`, call `cancel_run/1`, assert `{:ok, run}` with
  `run.status == :cancelled`, the in-flight step marked `:cancelled`, the Registry entry
  gone (Runner terminated), and the live session stopped.

## Implementation Plan

### Phase 1: Foundation — workstream DB-flip cancel
Set up the lower-risk, additive path first: modal show/hide helpers, the always-mounted
confirmation modal, the swimlane affordance + handler, and the `:abandoned` chip. Every
step in Phase 1 mirrors a precedent already in the codebase (the `agent_models_modal`
pattern, the `record_stage` handler, the `broadcast_workstreams` PubSub seam).

### Phase 2: Core Implementation — ADW-run process teardown seam (NEW substantive half)
This is the new code that earns the cancel button on the `<.adw_card>`. Order matters:

1. **Add `WorkflowRunRegistry` to the supervision tree** (`application.ex`, immediately
   after `RepoBuilder.WorkflowSupervisor`). One new supervisor child, no race — Runners
   are only spawned on demand, well after boot.
2. **Register the Runner in `init/1`** — `Registry.register(WorkflowRunRegistry,
   run.id, nil)` after `Process.flag(:trap_exit, true)`. Keeps `start_workflow/2`
   untouched and guarantees the entry exists before the first `handle_continue`.
3. **Add `WorkflowEngine.Runner.terminate/2`** — stop the live session on the way out so
   a `terminate_child/2`-killed Runner doesn't orphan its agent OS process.
4. **Add `WorkflowEngine.cancel_run/1`** — the typed context function (body in
   `Step by Step Tasks` §B). Public, `@spec`'d, `{:ok, run} | {:error, reason}`. It:
   - a. `Workflows.get_run(run_id)` — `nil` ⇒ `{:error, :not_found}`.
   - b. If `run.status` already terminal (`:succeeded | :failed | :cancelled`) ⇒
     return `{:ok, run}` unchanged (idempotent no-op — do not re-terminate).
   - c. Look up the Runner pid: `Registry.lookup(WorkflowRunRegistry, run_id)`; on a
     miss, `which_children/1`-scan `WorkflowSupervisor` as a fallback. `nil` pid is fine
     (a purely `:queued` run has no live Runner).
   - d. If a Runner pid exists, `DynamicSupervisor.terminate_child(WorkflowSupervisor,
     pid)` — the trapped-exit Runner's `terminate/2` stops the live session. Defensively
     also call `Session.Supervisor.stop_session(step_agent_id)` for the in-flight step
     (idempotent; covers a race where the Runner already exited).
   - e. `Oban.cancel_all_jobs/1` for any StepWorker job whose args carry this
     `workflow_run_id` (covers the `:queued`/durable path).
   - f. Persist: `Workflows.update_run(run, %{status: :cancelled})` and, if
     `run.current_step` is set, `WorkflowEngine.record_step_state(run, run.current_step,
     %{status: "cancelled", finished_at: now_iso()})`.
   - g. `Dashboard.broadcast_workflow(run.id, {:workflow_update, run})`.
   - h. Return `{:ok, run}`.
5. **Add show/hide helpers + `<.cancel_run_modal>`** mirroring the Phase 1 workstream
   modal.
6. **Add the `<.adw_card>` Cancel chip + the `open_cancel_run_modal` / `cancel_run`
   `handle_event` clauses** in `ConsoleLive`, beside the workstream cancel handlers.

### Phase 3: Integration — unified UI + cross-console broadcast + integration tests
After both cancel paths work in isolation, paint the `cns-chip--abandoned` /
`cns-card--cancelled` CSS, verify the console's existing `handle_info({:workflow_update,
run})` already re-renders the card, then drive the two new test files and the
regression guards in the Validation Commands below.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### A. Phase 1 — workstream cancel (DB flip)

#### A.1. Add show / hide JS helpers for the cancel-workstream modal
- In `lib/repo_builder_web/components/console/shared_components.ex`, immediately after
  `hide_agent_models/1`, add:
  ```elixir
  @spec show_cancel_workstream(JS.t()) :: JS.t()
  def show_cancel_workstream(js \\ %JS{}),
    do: JS.show(js, to: "#cancel-workstream-modal", display: "flex")

  @spec hide_cancel_workstream(JS.t()) :: JS.t()
  def hide_cancel_workstream(js \\ %JS{}),
    do: JS.hide(js, to: "#cancel-workstream-modal")
  ```
  Shape matches `show_agent_models/1` / `hide_agent_models/1` so the calling convention
  (`phx-click={hide_cancel_workstream()}`, `phx-window-keydown={hide_cancel_workstream()}
  phx-key="Escape"`) is identical and the modal plugs into the same CSS overlay styles.
- Extend the existing `import RepoBuilderWeb.Console.SharedComponents, only: [...]` in
  `brain_components.ex` to add the two new helpers.

#### A.2. Render the always-mounted cancellation modal (workstream)
- In `lib/repo_builder_web/components/console/brain_components.ex`, immediately after the
  close of `workstreams_swimlane/1`, add `cancel_workstream_modal/1`:
  ```elixir
  attr :id, :string, required: true, doc: "workstream id (passed through to the handler)"
  attr :title, :string, required: true, doc: "workstream title (modal label)"

  @spec cancel_workstream_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def cancel_workstream_modal(assigns) do
    ~H"""
    <div
      id="cancel-workstream-modal"
      class="cns-cmd-overlay"
      style="display:none"
      phx-window-keydown={hide_cancel_workstream()}
      phx-key="Escape"
    >
      <div class="cns-cmd-panel" style="max-width: 36rem">
        <div class="mb-3 text-xs font-semibold" style="color: var(--cns-cyan)">
          CANCEL WORKSTREAM
        </div>
        <div class="mb-3 text-sm" style="color: var(--cns-text)">
          Cancel <strong>{@title}</strong>? The brain will stop advancing the workstream;
          the row stays visible (marked
          <span class="cns-chip cns-chip--abandoned">ABANDONED</span>) so you can audit it.
        </div>
        <div class="flex items-center justify-end gap-2">
          <button type="button" id="cancel-workstream-back"
            phx-click={hide_cancel_workstream()} class="cns-chip">Back</button>
          <button type="button" id="cancel-workstream-confirm"
            phx-click="cancel_workstream" phx-value-id={@id}
            class="cns-chip" style="background: #b23b3b; color: #fff"
            title="Mark this workstream :abandoned">Cancel workstream</button>
        </div>
      </div>
    </div>
    """
  end
  ```
- Add `defdelegate cancel_workstream_modal(assigns), to: BrainComponents` beside the
  existing `workstreams_swimlane/1` delegation.

#### A.3. Render the modal at the bottom of the ADWS view
- In `lib/repo_builder_web/live/console_live.ex`, find the `<.workstreams_swimlane ... />`
  call inside the `view_mode == :adws` branch (line 2096). Add the modal right after it
  (still inside the same `#swimlanes` parent, so it stays mounted whether or not the
  swimlane is shown):
  ```heex
  <.cancel_workstream_modal
    :if={@workstream_modal.open?}
    id={@workstream_modal.id}
    title={@workstream_modal.title}
  />
  ```
- Add a default assign `workstream_modal: %{open?: false, id: nil, title: ""}` to the
  mount assigns.

#### A.4. Add the `open_cancel_workstream` handler
- In `ConsoleLive`, in the same `handle_event` block as `record_stage`, add:
  ```elixir
  @impl true
  def handle_event("open_cancel_workstream", %{"id" => id, "title" => title}, socket) do
    {:noreply,
     socket
     |> assign(:workstream_modal, %{open?: true, id: id, title: title})
     |> push_event("js-exec", %{to: "#cancel-workstream-modal", attr: "data-show"})}
  end
  ```
  (Follow whichever open-modal convention `agent_models_modal` uses — either a
  `push_event`/colocated-hook show, or rendering the modal `:if` open and letting a
  mounted `JS.show` fire. Match the existing precedent; do not invent a new one.)

#### A.5. Render the per-phase Cancel chip on the swimlane
- In `BrainComponents.workstreams_swimlane/1`, add `data-workstream-status={to_string(ws.status)}`
  on the wrapping phase-card div. Right after the title/row chips, render a
  Cancel-workstream chip when the **workstream** is still running or blocked:
  ```heex
  <button
    :if={ws.status in [:running, :blocked]}
    type="button"
    id={"cancel-workstream-#{ws.id}"}
    phx-click="open_cancel_workstream"
    phx-value-id={ws.id}
    phx-value-title={ws.title}
    class="cns-chip"
    style="background: #6b3a3a; color: #fff"
    title="Cancel this workstream (mark abandoned)"
  >
    ✕ Cancel workstream
  </button>
  ```
- The `:if` is the single source of truth for "cancel-able": a `:running`/`:blocked`
  workstream renders the button; `:abandoned`/`:done` short-circuit and the chip
  disappears.

#### A.6. Add the `cancel_workstream` event handler
- In `ConsoleLive` (same `handle_event` block as `record_stage`):
  ```elixir
  @impl true
  def handle_event("cancel_workstream", %{"id" => ref}, socket) do
    orchestrator_id = socket.assigns.orchestrator_id

    socket =
      case Workstreams.close_workstream(orchestrator_id, ref, :abandoned) do
        {:ok, workstream} ->
          records = Workstreams.list_records(orchestrator_id)
          :ok = Dashboard.broadcast_workstreams(orchestrator_id, records)

          socket
          |> assign(:workstream_modal, %{open?: false, id: nil, title: ""})
          |> put_flash(:info, "Cancelled '#{workstream.title}'")

        {:error, reason} ->
          socket
          |> assign(:workstream_modal, %{open?: false, id: nil, title: ""})
          |> put_flash(:error, "Could not cancel workstream: #{inspect(reason)}")
      end

    {:noreply, socket}
  end
  ```
  Note the domain atom `:abandoned` is a **compile-time literal**, never parsed from the
  wire payload (typed standard §3, rule 6). `%{"id" => ref}` is the WireType; `:abandoned`
  is the DomainType; this handler is the boundary.

### B. Phase 2 — ADW-run cancel (tear down a LIVE process)

#### B.1. Add the run registry to the supervision tree
- In `lib/repo_builder/application.ex`, immediately after the `WorkflowSupervisor` child
  (line 57), add:
  ```elixir
  {Registry, keys: :unique, name: RepoBuilder.WorkflowRunRegistry},
  ```
  This mirrors the existing `RepoBuilder.SessionRegistry` (line 43).

#### B.2. Register the Runner and add teardown
- In `lib/repo_builder/workflow_engine/runner.ex` `init/1`, after
  `Process.flag(:trap_exit, true)` and after `run` is bound:
  ```elixir
  {:ok, _} = Registry.register(RepoBuilder.WorkflowRunRegistry, run.id, nil)
  ```
- Add a `terminate/2` (the process already traps exits, so this runs on a
  `terminate_child/2` kill):
  ```elixir
  @impl true
  def terminate(_reason, %State{session_agent_id: agent_id}) when is_binary(agent_id) do
    _ = Session.Supervisor.stop_session(agent_id)
    :ok
  end

  def terminate(_reason, _state), do: :ok
  ```
  This guarantees no agent keeps burning budget once the Runner is torn down.

#### B.3. Add `WorkflowEngine.cancel_run/1`
- In `lib/repo_builder/workflow_engine.ex`, add the typed public function. It must NOT
  raise; every branch returns `{:ok, run} | {:error, reason}`:
  ```elixir
  @doc """
  Cancel an in-flight or queued ADW run. Idempotent: a run already in a terminal state
  is returned unchanged. Tears down the live Runner (whose `terminate/2` stops the live
  session so no agent keeps spending budget), cancels any durable Oban `StepWorker` job
  for the run, persists `:cancelled` on the run + the in-flight step, then broadcasts so
  every open console re-renders the card.
  """
  @spec cancel_run(Ecto.UUID.t()) :: {:ok, WorkflowRun.t()} | {:error, reason()}
  def cancel_run(run_id) when is_binary(run_id) do
    case Workflows.get_run(run_id) do
      nil ->
        {:error, :not_found}

      %WorkflowRun{status: status} = run when status in [:succeeded, :failed, :cancelled] ->
        {:ok, run}

      %WorkflowRun{} = run ->
        _ = terminate_runner(run_id)
        _ = cancel_queued_jobs(run_id)

        {:ok, cancelled} = Workflows.update_run(run, %{status: :cancelled})

        cancelled =
          if is_binary(run.current_step) do
            record_step_state(cancelled, run.current_step, %{
              status: "cancelled",
              finished_at: now_iso()
            })
          else
            cancelled
          end

        Dashboard.broadcast_workflow(cancelled.id, {:workflow_update, cancelled})
        {:ok, cancelled}
    end
  end

  @spec terminate_runner(Ecto.UUID.t()) :: :ok
  defp terminate_runner(run_id) do
    case Registry.lookup(RepoBuilder.WorkflowRunRegistry, run_id) do
      [{pid, _} | _] -> DynamicSupervisor.terminate_child(@sup, pid)
      [] -> :ok
    end

    :ok
  end

  @spec cancel_queued_jobs(Ecto.UUID.t()) :: :ok
  defp cancel_queued_jobs(run_id) do
    import Ecto.Query

    query =
      from(j in Oban.Job,
        where: j.worker == "RepoBuilder.Workers.StepWorker",
        where: fragment("?->>'workflow_run_id' = ?", j.args, ^run_id)
      )

    _ = Oban.cancel_all_jobs(query)
    :ok
  end
  ```
  `reason()` is the module's existing `@type reason :: atom() | Ecto.Changeset.t()`.
  `@sup` is the existing `RepoBuilder.WorkflowSupervisor` alias. Add
  `alias RepoBuilder.Dashboard` (already aliased) and confirm `Registry`/`Oban` are in
  scope.

#### B.4. Add show/hide helpers + `<.cancel_run_modal>`
- In `shared_components.ex`, add `show_cancel_run/1` / `hide_cancel_run/1` targeting
  `#cancel-run-modal` (identical shape to the workstream helpers).
- In `dashboard_components.ex` (or the same namespace as `adw_card/1`), add
  `cancel_run_modal/1` mirroring `cancel_workstream_modal/1`, with copy: "Cancel
  <strong>{@title}</strong>? This stops the live agent session immediately and marks the
  run `cancelled`. The worktree branch (if any) is left intact for manual merge or
  cleanup." Confirm button `phx-click="cancel_run" phx-value-id={@id}`.
- Add the `defdelegate` so the console HEEx can render `<.cancel_run_modal>`.

#### B.5. Render the `<.adw_card>` Cancel chip
- In `dashboard_components.ex` `adw_card/1`, in the header row beside the `<span
  :if={@duration}>`, add:
  ```heex
  <button
    :if={@status in [:queued, :running]}
    type="button"
    id={"cancel-run-#{@id}"}
    phx-click="open_cancel_run_modal"
    phx-value-id={@run_id}
    phx-value-title={@title}
    class="cns-chip"
    style="background: #6b3a3a; color: #fff"
    title="Cancel this run (stop the live session, mark cancelled)"
  >
    ✕ Cancel
  </button>
  ```
  Add a `attr :run_id, :string, required: true` to `adw_card/1` if not already threaded
  (the card is keyed `id={"workflow-#{view.run_id}"}` today; thread `view.run_id`
  explicitly so the wire payload is the run id, not the DOM id).

#### B.6. Render `<.cancel_run_modal>` + add the run handlers
- In `console_live.ex`, after `<.cancel_workstream_modal ... />`, render:
  ```heex
  <.cancel_run_modal :if={@run_modal.open?} id={@run_modal.id} title={@run_modal.title} />
  ```
- Add `run_modal: %{open?: false, id: nil, title: ""}` to the mount assigns.
- Add the handlers beside the workstream ones:
  ```elixir
  @impl true
  def handle_event("open_cancel_run_modal", %{"id" => id, "title" => title}, socket) do
    {:noreply, assign(socket, :run_modal, %{open?: true, id: id, title: title})}
  end

  @impl true
  def handle_event("cancel_run", %{"id" => run_id}, socket) do
    socket =
      case WorkflowEngine.cancel_run(run_id) do
        {:ok, _run} ->
          # cancel_run/1 already broadcast {:workflow_update, run} on the per-run topic
          # the console handle_info consumes, so the card re-renders on the round-trip.
          socket
          |> assign(:run_modal, %{open?: false, id: nil, title: ""})
          |> put_flash(:info, "Cancelling run…")

        {:error, reason} ->
          socket
          |> assign(:run_modal, %{open?: false, id: nil, title: ""})
          |> put_flash(:error, "Could not cancel run: #{inspect(reason)}")
      end

    {:noreply, socket}
  end
  ```
  Again: `%{"id" => run_id}` is the WireType; the domain `:cancelled` atom lives inside
  `cancel_run/1` as a literal, never parsed from the wire.

### C. Phase 3 — CSS + tests

#### C.1. CSS
- In `assets/css/app.css`, add `cns-chip--abandoned` (mirror `cns-chip--blocked`) and
  confirm `cns-card--cancelled` exists next to `cns-card--succeeded` (the card already
  renders `class={["cns-card", "cns-card--#{@status}"]}`, so a `:cancelled` run needs a
  matching rule).

#### C.2. Integration test — `test_cancel_custom_adw_in_adws_tab_test.exs`
- `Phoenix.LiveViewTest` file mounting the console at `/`, toggling to the ADWS view,
  seeding a `default_orchestrator/0` + workstream + workflow run, and driving both cancel
  flows via `render_click/3`. Assert the DB row status, the rendered card class, and the
  PubSub round-trip. Cover all ten cases (a)–(j) listed under §New Files.

#### C.3. Unit/integration test — `cancel_run_test.exs`
- `RepoBuilder.DataCase`. Start a fake-harness run via `WorkflowEngine.start_workflow/2`,
  assert `Registry.lookup(RepoBuilder.WorkflowRunRegistry, run_id)` returns a pid, call
  `WorkflowEngine.cancel_run(run_id)`, assert `{:ok, %{status: :cancelled}}`, the
  in-flight step marked `:cancelled` in `step_states`, `Registry.lookup(...) == []`
  (Runner terminated), and the live session no longer registered under `SessionRegistry`.

## Testing Strategy
- **LiveView integration (both kinds).** `Phoenix.LiveViewTest` — mount, toggle to ADWS,
  click the swimlane `✕ Cancel workstream` and the `<.adw_card>` `✕ Cancel`, confirm in
  the modal, assert (1) the DB row flips to `:abandoned` / `:cancelled`, (2) the rendered
  card gains the tinted class, (3) a second console tab (a second `live/2`) subscribed to
  the same topic re-renders on the broadcast.
- **`cancel_run/1` unit/integration.** Start a fake run, cancel it, assert `:cancelled`
  on the run + in-flight step, the Runner is gone from `WorkflowRunRegistry`, and the
  session is stopped — the core Phase 2 contract in isolation.
- **Idempotency.** Cancel an already-`:cancelled` run ⇒ `{:ok, run}` with no second
  teardown, no crash, no duplicate broadcast side effects that matter.
- **Queued/Oban path.** Enqueue a run via `enqueue_workflow/2`, cancel before the job
  executes, assert the `StepWorker` job is `cancelled` in `oban_jobs` and the run is
  `:cancelled` (the next Oban tick does not resume it).
- **No-op guards.** No orchestrator/project selected ⇒ the Cancel chip is either absent
  or the handler no-ops with a clear flash (never a crash).
- **Regression.** The existing swimlane + adw_card render tests still pass unchanged
  (the Cancel chip is additive and `:if`-gated).
- Use the fake harness/provider throughout — no real LLM spend, deterministic terminal
  events. Sandbox via `RepoBuilder.DataCase` / `ConnCase`.

## Acceptance Criteria
- [ ] A `✕ Cancel workstream` chip renders on each swimlane phase card **only** when the
  workstream is `:running` or `:blocked`; clicking it opens the confirm modal naming that
  workstream.
- [ ] Confirming flips the workstream to `:abandoned` via `close_workstream/3`, keeps the
  row visible with an `ABANDONED` chip, and broadcasts so a second open console re-renders.
- [ ] A `✕ Cancel` chip renders on each `<.adw_card>` **only** when the run is `:queued`
  or `:running`; clicking it opens the confirm modal naming that run.
- [ ] Confirming a `:running` run: the live Runner is terminated, its live session is
  stopped (no agent keeps spending), the run + in-flight step persist `:cancelled`, and a
  `{:workflow_update, run}` broadcast re-renders the card as `cns-card--cancelled` on every
  open console.
- [ ] Confirming a `:queued` run cancels the durable `StepWorker` Oban job so the run does
  NOT resume on the next tick, and the run persists `:cancelled`.
- [ ] `WorkflowEngine.cancel_run/1` is idempotent: called on an already-terminal run it
  returns `{:ok, run}` unchanged with no second teardown.
- [ ] `RepoBuilder.WorkflowRunRegistry` exists in the supervision tree; every Runner
  registers under `run.id` in `init/1`; after cancel the entry is gone.
- [ ] A cancelled worktree-isolated run leaves its `adw/<run_id>` branch intact (no
  auto-merge, no auto-delete).
- [ ] Every new public function has an `@spec`; no `String.to_atom/1` on operator input;
  the domain atoms `:abandoned`/`:cancelled` are compile-time literals at the modal
  boundary.
- [ ] The full mix gate is green (see Validation Commands).

## Edge Cases
- **Cancel a run mid-step.** The Runner is in a `:running` step with a live session.
  `cancel_run/1` terminates the Runner; its `terminate/2` stops the session
  (SIGTERM→SIGKILL of the OS child + ledger delete). The in-flight step is marked
  `:cancelled`, not left `:running`.
- **Cancel a queued/Oban run.** No live Runner (Registry lookup misses); `cancel_run/1`
  still cancels the `StepWorker` job via `Oban.cancel_all_jobs/1` and persists
  `:cancelled` so the next Oban tick doesn't resume it.
- **Cancel an already-terminal run is idempotent.** `:succeeded`/`:failed`/`:cancelled`
  ⇒ `{:ok, run}` unchanged; no teardown, no double broadcast, no crash. A double-click on
  the Cancel button hits this on the second event.
- **Cancel fires while the run is still `:queued` but the Runner is mid-`init`.** The
  Runner registers in `init/1` before the first `handle_continue`, so the Registry entry
  exists by the time the pid is returned; the fallback `which_children` scan covers the
  narrow window if lookup still misses.
- **Worktree cleanup on an isolated (`:worktree`) run.** The branch is deliberately left
  intact — the terminal `merge` step is bypassed on cancel. Documented in §Notes; the
  operator merges or removes it manually.
- **No orchestrator/project selected.** The workstream Cancel chip only renders inside a
  swimlane bound to an orchestrator; with none selected there is no swimlane, so no chip.
  The run Cancel handler no-ops with an error flash if `run_id` resolves to no run
  (`{:error, :not_found}`), never a crash.
- **Cross-console race.** Two operators cancel the same entity; the second cancel hits the
  idempotent terminal-status guard. The `data-workstream-status` / `data-run-status`
  attributes let CSS belt-and-suspenders hide a stale Cancel button between the broadcast
  and the re-render.
- **Runner already exited when cancel arrives.** `terminate_child/2` on a dead pid is a
  no-op; `stop_session/1` on an absent agent is a no-op; the DB flip + broadcast still run.

## Validation Commands
Execute these to validate the feature works end-to-end. Every command must pass.

- `mix compile --warnings-as-errors` — no warnings (typed standard).
- `mix format --check-formatted` — formatting clean.
- `mix credo --strict` — 0 issues (the hard `@spec` gate covers every new public fn).
- `mix test test/repo_builder_web/live/test_cancel_custom_adw_in_adws_tab_test.exs` — both
  cancel flows green.
- `mix test test/repo_builder/workflow_engine/cancel_run_test.exs` — the `cancel_run/1`
  contract green.
- `mix test` — full suite green (no regressions).
- `mix dialyzer` — no new discrepancies (the `{:ok, run} | {:error, reason}` contract and
  the `terminate/2`/Registry specs typecheck).

## Notes
- **Registry vs. supervisor scan — decision.** We add a dedicated
  `RepoBuilder.WorkflowRunRegistry` (`:unique`) and register the Runner in `init/1`
  rather than relying on a `DynamicSupervisor.which_children/1` scan of
  `WorkflowSupervisor`. Rationale: (1) O(1) lookup by `run.id` vs. O(n) scan +
  `:sys.get_state` on every child to read its `run.id`; (2) it mirrors the existing
  `RepoBuilder.SessionRegistry` precedent (`application.ex:43`), so the pattern is
  already idiomatic in this tree; (3) registering in `init/1` (not via a `start_link`
  name) keeps `start_workflow/2` completely untouched — the run struct is in scope in
  `init`, not at `start_link/1` where only opts are threaded. The `which_children` scan
  survives only as a defensive fallback for the sub-millisecond window before `init`
  registers.
- **Teardown lives in `terminate/2`, called via `terminate_child/2`.** The Runner already
  does `Process.flag(:trap_exit, true)`, so a `DynamicSupervisor.terminate_child/2` sends
  it a shutdown it can trap and run `terminate/2` teardown before exiting. `cancel_run/1`
  also calls `stop_session/1` defensively, but the Runner's own `terminate/2` is the
  authoritative single place session teardown happens — so a cancel that races the
  Runner's normal `finalize/2` exit still cleans up exactly once (both paths are
  idempotent no-ops on an already-stopped session).
- **Two backends, one affordance.** The workstream path is a pure DB flip
  (`close_workstream/3` → `:abandoned`); the run path is a live-process teardown
  (`cancel_run/1` → `:cancelled`). They are deliberately different verbs to different
  seams, but the operator sees one identical `✕ Cancel` chip + one confirm-modal
  interaction on both card types.
- **Worktree branch is NOT auto-cleaned on cancel.** A `:worktree`-isolated run's
  terminal `merge` step (issue-adw-non-iso-merge) is bypassed when the run is cancelled,
  so the `adw/<run_id>` branch stays. This is deliberate: the partial work may be worth
  keeping/inspecting, and auto-deleting an operator's branch on a panic-cancel is
  surprising and irreversible. The operator merges or removes it manually. A future
  enhancement could add a "cancel and discard branch" secondary action.
- **No migration.** Both `WorkflowRun.status` and `Step.status` already enumerate
  `:cancelled`; `Workstream.status` already enumerates `:abandoned`. This feature is
  entirely UI + a lookup registry + one new context function + one Runner callback.
- **Broadcast shape reuse.** `cancel_run/1` emits the exact `{:workflow_update, run}`
  2-tuple the live Runner already sends from `broadcast_lane/2` (`runner.ex:312`), so the
  console's existing `handle_info` re-render path needs no changes — the cancelled card
  re-renders through the same seam a normal terminal transition uses.
- **Typed boundary.** Both handlers take a wire payload (`%{"id" => …}`) and pass a
  compile-time literal domain atom (`:abandoned` / `:cancelled`) to the context — the
  single WireType→DomainType bridge (typed standard §3, rule 6); no `String.to_atom/1`
  ever touches operator input.
