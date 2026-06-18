# Feature: Release Hidden Logs & Workflows (one-shot reveal, not a view toggle)

## Metadata
issue_number: `logs`
adw_id: `visable`
issue_json: `again`

## Feature Description
Today the console's "CLEAR" actions soft-hide rows (`agent_logs.hidden` /
`workflow_runs.hidden` set to `true`) so a cleared view survives a reconnect without
deleting data. The only way to see those rows again is the Settings → **"Show cleared
logs & workflows (troubleshooting)"** control, which is an **ON/OFF view toggle**: it
flips an in-memory `show_hidden?` assign and re-seeds the streams to *temporarily*
include hidden rows. When toggled OFF again, the rows vanish from the view; the
`hidden` flag in the database is never changed.

The operator's mental model is different: **making logs visible again is not a
temporary toggle — it is a release.** They want a single, explicit action that
*permanently un-hides everything* — sets `hidden = false` on all soft-hidden
`agent_logs` and `workflow_runs` rows so they are genuinely back in the normal view
for good (and stay visible after the next reconnect, with no troubleshooting flag
held on).

This feature replaces the view-only ON/OFF toggle semantics with a **"Release hidden
logs & workflows"** action button. Pressing it un-hides all currently-hidden rows in
one shot, re-seeds the console streams from the (now fully-visible) database, and
reports how many rows were released. The CLEAR actions are unchanged — release is the
inverse of CLEAR.

## User Story
As a platform operator using the console
I want a single "Release" action that permanently makes all previously-cleared logs and workflows visible again
So that I don't have to hold a troubleshooting toggle ON to see them — once released, they're back in the normal view and stay there across reconnects.

## Problem Statement
The current "Show cleared logs & workflows" control is a transient view toggle bound
to the `show_hidden?` assign:
- It does **not** mutate the persisted `hidden` flag, so cleared rows are only visible
  while the toggle is held ON; turning it OFF (or a fresh session, which defaults
  `show_hidden?: false`) hides them again.
- This conflicts with the operator's expectation that "make logs visible again"
  is a durable un-hide ("release"), the true inverse of CLEAR.
- The toggle also conflates two concerns: a *temporary troubleshooting peek* and a
  *permanent restore*. The operator wants the permanent restore.

## Solution Statement
Add a one-shot **release** operation that sets `hidden = false` on every soft-hidden
row, the durable inverse of `Logs.hide_all_logs/0` and `Workflows.hide_finished_runs/0`:

1. **Context layer** — add `Logs.release_hidden_logs/0` and
   `Workflows.release_hidden_runs/0` (both `@spec`'d, returning the count released)
   that `Repo.update_all(set: [hidden: false])` over rows where `hidden == true`.
2. **LiveView layer** — add a `handle_event("release_hidden", …)` that calls both
   context functions, re-seeds the log stream (`backfill_events/1`) and workflow
   swimlanes (`seed_workflow_progress/1`) from the now-visible DB, and surfaces a
   transient confirmation (released count). Because all rows are now `hidden == false`,
   the existing default reads (`include_hidden? == false`) show everything — no held
   flag required.
3. **UI layer** — in the Settings modal, replace the ON/OFF "Show cleared logs &
   workflows" toggle with a **"Release hidden logs & workflows"** action button
   (`phx-click="release_hidden"`) plus a short helper line. The button is an action,
   not a stateful chip.

### Decision: keep or drop the `show_hidden?` troubleshooting peek?
The toggle currently also gates the cost-center rollup (`include_hidden?:
show_hidden?`) and is the *only* way CLEAR can be a "view-only reset" (the
`unless show_hidden?` guards in `clear_filters`/`clear_workflows`). To keep this
change focused and non-regressive, **retain the `show_hidden?` assign and its plumbing**
(so CLEAR-while-peeking still works and the cost rollup behavior is unchanged), but
the **primary, prominent control becomes the Release action**. The plan keeps the
troubleshooting toggle as a secondary control labeled clearly as a *temporary peek*,
and adds Release as the durable operation. (If the operator later wants the toggle
gone entirely, that's a trivial follow-up — see Notes.)

## Relevant Files
Use these files to implement the feature:

- `lib/repo_builder/logs.ex` — context for `agent_logs`. Holds `hide_all_logs/0`,
  `list_recent_global/2`, and the `filter_hidden/2` helper. Add `release_hidden_logs/0`
  here next to `hide_all_logs/0` (its inverse).
- `lib/repo_builder/workflows.ex` — context for `workflow_runs`. Holds
  `hide_finished_runs/0` and `list_recent_runs/2`. Add `release_hidden_runs/0` here.
- `lib/repo_builder_web/live/console_live.ex` — the console LiveView. Holds
  `toggle_show_hidden`, `clear_filters`, `clear_workflows`, the `show_hidden?` assign
  (mounted at `show_hidden?: false`), and the `backfill_events/1` +
  `seed_workflow_progress/1` re-seed helpers. Add the `release_hidden` handler here and
  pass any new assigns to the settings component.
- `lib/repo_builder_web/components/console_components.ex` — the Settings modal
  (`settings_modal/1`). Holds the `settings-show-hidden` toggle button and the
  `show_hidden?` attr. Replace/augment with the Release action button; add a
  `hidden_count` (or similar) attr if we choose to display the pending count.
- `lib/repo_builder/logs/agent_log.ex` — `AgentLog` schema (has `hidden` field).
  Reference only; no change expected.
- `lib/repo_builder/workflows/workflow_run.ex` — `WorkflowRun` schema (has `hidden`
  field). Reference only; no change expected.
- `test/repo_builder/clear_persistence_test.exs` — existing unit tests for the
  soft-hide CLEAR behavior. Extend with release coverage (round-trip: hide → release →
  visible by default).
- `priv/repo/migrations/20260618091503_add_hidden_flag_to_logs_and_workflow_runs.exs`
  — the migration that added `hidden` + its index. Reference only; no schema change
  needed (release reuses the existing column and indexes).

### New Files
- `test/repo_builder_web/live/test_release_hidden_logs_test.exs` — `Phoenix.LiveViewTest`
  integration test: seed hidden logs + finished runs, mount the console, trigger the
  Release action, assert the previously-hidden rows render in the default view and the
  DB rows now have `hidden == false`.

### Relevant Docs (from `.claude/commands/conditional_docs.md`)
- `ai_docs/typed-elixir-standard.md` — **(always)** the enforced typed standard:
  `@spec` on every new public function, precise return types, Credo `@spec` gate,
  Dialyzer. The two new context functions and any new private helpers must comply.
- `BUILD_PROMPT.md` §8 — persistence: DB access stays behind `@spec`'d context
  modules; LiveView never touches `Repo`/`Ecto.Query` directly (the release writes
  live in `Logs`/`Workflows`, not the LiveView).
- `BUILD_PROMPT.md` §9 + `AGENTS.md` — LiveView dashboard: streams, swimlane seeding,
  reconnect rule (the release must re-seed via the existing backfill helpers so the
  reveal is consistent with reconnect behavior).

## Implementation Plan
### Phase 1: Foundation (context layer — the durable un-hide)
Add the inverse of the existing hide operations to the two contexts. Each is a single
`Repo.update_all` over `hidden == true` rows setting `hidden: false`, returning the
count released. These reuse the existing `hidden` indexes for cheap scans. No schema or
migration changes.

### Phase 2: Core Implementation (LiveView action + re-seed)
Add a `release_hidden` event handler to `console_live.ex` that calls both context
functions, re-seeds the log stream and workflow swimlanes from the (now-visible) DB
using the existing `backfill_events/1` and `seed_workflow_progress/1`, and stores a
transient "released N rows" confirmation for display. Since all rows become
`hidden == false`, the default reads surface them with no held flag.

### Phase 3: Integration (Settings UI + tests)
Swap the ON/OFF "Show cleared logs & workflows" toggle for a **"Release hidden logs &
workflows"** action button wired to `release_hidden`, keep the troubleshooting peek
toggle as a clearly-labeled secondary control, add the LiveView integration test plus
context unit tests, and run the full validation gate.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Add `Logs.release_hidden_logs/0` (context)
- In `lib/repo_builder/logs.ex`, directly after `hide_all_logs/0`, add:
  - `@doc` describing it as the inverse of `hide_all_logs/0` — un-hides EVERY
    soft-hidden `agent_logs` row so it returns to the default view permanently
    (the "Release" action). Rows already visible are untouched. Returns the count released.
  - `@spec release_hidden_logs() :: non_neg_integer()`
  - Body: `AgentLog |> where([l], l.hidden == true) |> Repo.update_all(set: [hidden: false])`,
    return the count from the `{count, _}` tuple.
- Mirror the existing style of `hide_all_logs/0` exactly (same import/alias usage).

### 2. Add `Workflows.release_hidden_runs/0` (context)
- In `lib/repo_builder/workflows.ex`, directly after `hide_finished_runs/0`, add:
  - `@doc` describing it as the inverse of `hide_finished_runs/0` — un-hides EVERY
    soft-hidden `workflow_runs` row (any status) so finished runs return to the
    swimlane view permanently. Returns the count released.
  - `@spec release_hidden_runs() :: non_neg_integer()`
  - Body: `from(r in WorkflowRun, where: r.hidden == true) |> Repo.update_all(set: [hidden: false])`,
    return the count.
- Match the `from`-query style used by `hide_finished_runs/0`.

### 3. Context unit tests (extend `clear_persistence_test.exs`)
- Add a `describe "Logs.release_hidden_logs/0"` block:
  - hide a log via `hide_all_logs/0`, assert it's excluded from the default
    `list_recent_global/500`, call `release_hidden_logs/0`, assert it returns the
    correct count AND the log is now in the **default** read (no `true` flag needed).
  - assert calling release again returns `0` (nothing left hidden — idempotent).
- Add a `describe "Workflows.release_hidden_runs/0"` block:
  - create finished runs, `hide_finished_runs/0`, then `release_hidden_runs/0`; assert
    the count and that the runs reappear in the default `list_recent_runs/50`.
  - assert running/queued runs (never hidden) are unaffected.

### 4. Add the `release_hidden` LiveView handler (`console_live.ex`)
- Add `def handle_event("release_hidden", _params, socket)` that:
  - calls `released = Logs.release_hidden_logs() + Workflows.release_hidden_runs()`.
  - re-seeds via the existing helpers: `socket |> backfill_events() |> seed_workflow_progress()`
    (verify these helper names/signatures against the current file; reuse exactly what
    `toggle_show_hidden` uses so the reveal path is identical).
  - assigns a transient confirmation, e.g. `release_notice: released` (and schedule a
    `Process.send_after(self(), :clear_release_notice, 2_000)` clear, mirroring the
    existing `:clear_agent_model_saved` pattern at console_live.ex ~line 530/1371).
  - because every row is now `hidden == false`, the default backfill (`show_hidden? == false`)
    shows them — no need to force `show_hidden?` on.
- Add the matching `handle_info(:clear_release_notice, socket)` to reset `release_notice`.
- Add `release_notice` to the mount assigns (default `nil`) near `show_hidden?: false`
  (console_live.ex ~line 113).

### 5. Replace the toggle with a Release action in the Settings modal (`console_components.ex`)
- In `settings_modal/1`, change the `<.settings_field label="Show cleared logs & workflows (troubleshooting)">`
  block:
  - Rename the primary control to a **Release** action:
    `<.settings_field label="Release hidden logs & workflows">` containing a button
    `id="settings-release-hidden"`, `phx-click="release_hidden"`, styled as an action
    button (reuse an existing button class, e.g. the same class as the CLEAR buttons /
    `cns-chip` without the active-state coloring) with label "Release" (or
    "Release N" if a count is passed).
  - Add a short helper line clarifying it permanently un-hides everything cleared by
    the CLEAR actions (inverse of CLEAR), distinct from the temporary peek.
  - Keep the existing `show_hidden?` ON/OFF toggle as a **secondary** field relabeled
    "Temporarily show cleared rows (peek)" so the troubleshooting behavior and the
    cost-rollup gating are preserved (it still drives `include_hidden?` in the rollup
    and the CLEAR view-only guards).
- Add a new `attr :release_notice, :any, default: nil` (and optionally
  `attr :hidden_count, :integer, default: 0` if displaying the pending count) and render
  the transient "Released N rows" confirmation when present.
- Pass the new assign(s) from the `settings_modal` invocation in `console_live.ex`
  (~line 1980 where `show_hidden?={@show_hidden?}` is already passed) — add
  `release_notice={@release_notice}`.

### 6. LiveView integration test (`test/repo_builder_web/live/test_release_hidden_logs_test.exs`)
- `use RepoBuilder.ConnCase` (+ whatever the existing console LiveView tests use; mirror
  `test/repo_builder_web/live/test_orchestrator_thinking_toggle_test.exs` for setup).
- Seed: create an agent + a log, then `Logs.hide_all_logs()`; create a workflow + a
  finished run, then `Workflows.hide_finished_runs()`.
- `{:ok, view, _html} = live(conn, "/")`.
- Assert the hidden log/run are NOT in the default rendered view.
- Open settings (mirror how existing tests reach the settings modal — the modal is
  always in the DOM) and `view |> element("#settings-release-hidden") |> render_click()`.
- Assert: the previously-hidden log row now renders in the event stream; assert the
  DB rows now have `hidden == false` (`Logs.list_recent_global(500)` includes it WITHOUT
  the `true` flag; `Repo`-free assertion via the context); and assert the "Released …"
  confirmation text is present.
- Optionally capture a Playwright screenshot of `http://localhost:4000` as visual proof.

### 7. Run the full validation gate
- Run every command in **Validation Commands** and fix any failure until all are green
  with zero regressions.

## Testing Strategy
### Unit Tests
- `Logs.release_hidden_logs/0`: returns the count of rows flipped `true → false`;
  released rows appear in the **default** (`include_hidden? == false`) read; idempotent
  (second call returns `0`); logs that were never hidden are untouched.
- `Workflows.release_hidden_runs/0`: same shape for `workflow_runs`; finished runs
  reappear in the default `list_recent_runs/50`; running/queued runs unaffected;
  idempotent.

### Edge Cases
- **Nothing hidden** → release returns `0`, view unchanged, confirmation reads "0".
- **CLEAR then Release round-trip** → after `hide_all_logs/0` + release, the default
  read equals the pre-clear set (no rows lost; nothing deleted).
- **New rows after release** → rows inserted after release stay visible (default
  `hidden == false`); release doesn't affect future inserts.
- **Release while the peek toggle is ON** → no double-counting or crash; after release,
  toggling the peek OFF still shows everything (all rows are genuinely visible now).
- **Reconnect after release** → a fresh mount (`show_hidden?: false`) still shows the
  released rows (the durable difference vs. the old toggle).

## Acceptance Criteria
- A "Release hidden logs & workflows" action button exists in the Settings modal and is
  wired to a `release_hidden` event.
- Pressing Release sets `hidden = false` on all previously-hidden `agent_logs` and
  `workflow_runs` rows (verified in the DB), and the rows render in the **default**
  console view with no troubleshooting flag held ON.
- After Release, a fresh reconnect (new LiveView mount) still shows the released rows.
- `Logs.release_hidden_logs/0` and `Workflows.release_hidden_runs/0` exist, are
  `@spec`'d, return the released count, and are idempotent.
- CLEAR behavior, the cost-center rollup, and the troubleshooting peek are unchanged
  (no regressions).
- All validation commands pass with zero failures/warnings.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix test test/repo_builder_web/live/test_release_hidden_logs_test.exs` - The new LiveView integration test passes.
- `mix test test/repo_builder/clear_persistence_test.exs` - The extended context unit tests (hide + release round-trip) pass.
- `mix compile --warnings-as-errors` - Compile clean; the gradual set-theoretic type checker and `warnings_as_errors` must pass.
- `mix test --warnings-as-errors` - Run the full ExUnit suite (spawns Postgres-backed cases) with zero failures.
- `mix format --check-formatted` - Ensure code is formatted.
- `mix credo --strict` - Lint, including the "every public function has an `@spec`" convention.
- `mix dialyzer` - `@spec`/contract checking with no new warnings and no stale ignore filters.

Optional runtime verification via **Tidewave** (the app must be running on
`http://localhost:4000`):
- `project_eval`: `RepoBuilder.Logs.hide_all_logs(); RepoBuilder.Logs.release_hidden_logs()`
  — confirm the round-trip returns sane counts against the live DB.
- `execute_sql_query`: `SELECT count(*) FROM agent_logs WHERE hidden = true;` before/after
  Release to confirm zero hidden rows remain.

## Notes
- **No migration needed**: release reuses the existing `hidden` column and its indexes
  (`agent_logs(hidden)`, `workflow_runs(hidden)`), which already keep both the
  visible-only scans and the `hidden == true` release scans cheap.
- **Scope decision**: this plan keeps the `show_hidden?` troubleshooting peek toggle to
  avoid regressing the cost-center rollup gating (`include_hidden?: show_hidden?` at
  console_live.ex ~line 2169) and the CLEAR view-only guards. If the operator wants the
  peek removed entirely so Release is the *only* reveal path, that is a clean follow-up:
  delete the `show_hidden?` assign + `toggle_show_hidden` + the `unless show_hidden?`
  guards (CLEAR would then always persist) and hard-code `include_hidden?: false` in the
  rollup. Flag this to the operator after shipping the durable Release.
- **Naming**: the user's word is "release". The context functions are named
  `release_hidden_logs/0` / `release_hidden_runs/0` and the event is `release_hidden` to
  match that vocabulary (the inverse verb of "clear/hide").
- **Confirmation UX**: the transient "Released N rows" notice follows the existing
  `:clear_agent_model_saved` self-message pattern already in `console_live.ex`; no new
  library or mechanism is introduced.
