# Chore: Remove agents entirely from the ADWs screen

## Metadata
issue_number: `should`
adw_id: `be`
issue_json: `removed`

## Chore Description

ADWs (AI Developer Workflows) and agents are conceptually separate, but the
ADWs view of the orchestration console currently renders **agent** cards
alongside the ADW workflow cards. The chore is to remove agents **entirely**
from the ADWs screen so that view shows only AI Developer Workflow cards.

### Where the leak is today

The console (`RepoBuilderWeb.ConsoleLive`) has two render modes toggled by
`@view_mode` (`:logs` / `:adws`). The ADWs panel (`id="swimlanes"`,
`console_live.ex:3652`, shown only when `@view_mode == :adws`) stacks two
sections:

1. **`#workflow-runs`** (`console_live.ex:3700`) — the real ADW cards, derived
   from `@workflow_progress`. Each ADW worker's events already render as
   step-squares *inside* its own card via `workflow_step_squares/3`. **This is
   correct and stays.**
2. **`#agent-cards`** (`console_live.ex:3729`) — a section literally labelled
   **"AGENTS"**, rendered from the `@swimlanes` assign. `@swimlanes` is computed
   by `agent_swimlanes/1` (`console_live.ex:4092`), which groups the **entire**
   `@event_buffer` by `agent_key` with **no filtering**. That sweeps in ADW
   worker lanes (`wf-<run_id>-<step>` keys, already shown in the workflow card),
   orchestrator lanes (`orch-<id>…` keys, which belong to the chat pane), and
   genuine standalone agents — and renders them all as agent cards on the ADWs
   screen. **This whole section must go.**

After this chore the ADWs view renders **only** `#workflow-runs` plus its
empty-state placeholder; no `#agent-cards`, no `adw_agent_card`, no "AGENTS"
header.

This is a UI/dead-code change only. No schema, migration, context, or runtime
behaviour changes. The `clear_workflows` handler keeps trimming the event buffer
(it also feeds the LOGS view and the workflow step-squares); only its button
gating changes to depend on finished workflows alone.

## Relevant Files

Use these files to resolve the chore:

- `lib/repo_builder_web/live/console_live.ex` — the console LiveView. Holds the
  ADWs panel template (`#swimlanes` at ~3652), the `#agent-cards` AGENTS section
  to remove (~3729–3751), the empty-state (`#no-adws`, ~3717–3727), the CLEAR
  button disabled gate (~3685–3697), the `@swimlanes` derived assign
  (`assign(assigns, :swimlanes, agent_swimlanes(assigns))` at ~3484), the
  component import list (~33–35: `adw_agent_card`, `stage_lane`, `event_square`),
  and the private helpers that become dead: `agent_swimlanes/1` (~4092),
  `group_by_step/1` (~4125), `visible_stages/1` (~4145), `adw_type/1` (~4118),
  `any_clearable_swimlanes?/1` (~4073). The `clear_workflows` handler (~1969) and
  `any_finished_workflows?/1` (~4066) stay.
- `lib/repo_builder_web/components/dashboard_components.ex` — defines
  `adw_agent_card/1` (~71) and `stage_lane/1` (~199), the components used only by
  the section being removed. `adw_card/1` (the ADW workflow card) and
  `event_square/1` stay. After the section is gone these two become unreferenced
  and should be removed (gate on a grep, see Step 5).
- `test/repo_builder_web/live/test_adws_clear_swimlanes_test.exs` — an
  integration test wholly about agent-swimlane cards + the CLEAR gating on the
  ADWs screen. Becomes obsolete; delete it.
- `test/repo_builder_web/live/test_adw_swimlane_test.exs`,
  `test/repo_builder_web/live/test_unified_adw_swimlane_cards_test.exs`,
  `test/repo_builder_web/live/test_adws_stage_swimlanes_test.exs`,
  `test/repo_builder_web/live/test_holding_status_test.exs`,
  `test/repo_builder_web/live/test_activity_orb_test.exs`,
  `test/repo_builder_web/live/test_orchestration_console_test.exs`,
  `test/repo_builder_web/live/test_orchestration_console_ui_test.exs`,
  `test/repo_builder_web/live/test_live_agent_mention_chips_test.exs`,
  `test/e2e/adw_e2e_test.exs` — these reference "swimlane"/agent cards. Each must
  be audited: keep workflow-card assertions, remove/realign any that assert an
  agent card (`#swimlane-<agent_id>`, `#agent-cards`, the `AGENTS` label, or
  `adw_agent_card`) on the `:adws` view (Step 6).
- `AGENTS.md` / `BUILD_PROMPT.md` §3 — typed-Elixir standard the change must
  respect (`@spec` on public fns, `--warnings-as-errors`, Credo `--strict`,
  Dialyzer). No new docs are required by `.claude/commands/conditional_docs.md`
  for a pure LiveView/dead-code change beyond the always-on typed standard.

## Step by Step Tasks

IMPORTANT: Execute every step in order, top to bottom.

### Step 1 — Delete the AGENTS section from the ADWs template

- In `lib/repo_builder_web/live/console_live.ex`, remove the entire
  `<div :if={@swimlanes != []} id="agent-cards" class="mt-1 flex flex-col gap-2">`
  block (~3729–3751), including the nested `<.adw_agent_card>` / `<.stage_lane>` /
  `<.event_square>` markup. Leave `#workflow-runs` and the `#no-adws` empty-state
  div in place.

### Step 2 — Make the empty-state and CLEAR gating workflow-only

- Empty-state `#no-adws` (~3717–3727): change the guard from
  `:if={@workflow_progress == %{} and @swimlanes == []}` to
  `:if={@workflow_progress == %{}}`.
- CLEAR button `#clear-workflows` disabled predicate (~3689–3692): change
  `not (any_finished_workflows?(@workflow_progress) or any_clearable_swimlanes?(@swimlanes))`
  to `not any_finished_workflows?(@workflow_progress)`.
- Do **not** change the `clear_workflows` `handle_event` body (~1969) — it trims
  `@event_buffer` and `@statuses`, which still feed the LOGS view and the
  workflow step-squares. Only its gating moved.

### Step 3 — Drop the now-unused `:swimlanes` derived assign

- Remove the `assigns = assign(assigns, :swimlanes, agent_swimlanes(assigns))`
  line in the ADWs `render/1` clause (~3484).
- Grep `@swimlanes` / `:swimlanes` in `console_live.ex` and confirm there are no
  remaining references after Steps 1–2.

### Step 4 — Remove dead private helpers and component imports

- Delete these private functions from `console_live.ex` (each is referenced only
  by the removed section / assign — confirm with a grep before deleting):
  - `agent_swimlanes/1` (~4092)
  - `group_by_step/1` (~4125)
  - `visible_stages/1` (~4145)
  - `adw_type/1` (~4118)
  - `any_clearable_swimlanes?/1` (~4073)
- Keep `presence/1` (still used by `meta_title/1`, `worker_title`, `type_title`,
  `step_title`), `any_finished_workflows?/1`, and `workflow_step_squares/3`.
- In the component import block (~33–35), remove the now-unused imports
  `adw_agent_card: 1`, `stage_lane: 1`, and `event_square: 1`. Confirm via grep
  that none of the three are referenced anywhere else in `console_live.ex` (after
  Step 1 they are not). Keep `adw_card: 1` and the rest.

### Step 5 — Remove the orphaned components (gated)

- Grep the whole repo for `adw_agent_card` and `stage_lane`. If — as expected —
  the only remaining definitions are in
  `lib/repo_builder_web/components/dashboard_components.ex` with no callers,
  delete `adw_agent_card/1` (~71) and `stage_lane/1` (~199) along with their
  `@spec`s and doc/attr declarations. Keep `adw_card/1`, `event_square/1`, and
  every other component. If any caller remains, leave the component and note it.

### Step 6 — Prune and realign affected tests

- Delete `test/repo_builder_web/live/test_adws_clear_swimlanes_test.exs` outright
  — every test in it drives agent-swimlane cards (`#swimlane-<agent_id>`) and the
  old CLEAR-enables-on-clearable-swimlane behaviour that no longer exists.
- For each remaining test file listed in **Relevant Files**, grep for
  `swimlane`, `agent-cards`, `AGENTS`, and `adw_agent_card`, then:
  - Keep assertions about ADW **workflow** cards (`#workflow-<run_id>`,
    `adw_card`, step-squares, `#no-adws`, the LOGS-view swimlanes if any).
  - Remove or rewrite assertions that expect an **agent** card
    (`#swimlane-<agent_id>`, `#agent-cards`, the "AGENTS" header) on the `:adws`
    view, since those elements no longer render.
- Re-run the suite after each file edit (`mix test <file>`) to converge quickly.

### Step 7 — Validate the full green gate

- Run every command in **Validation Commands** and fix any failure before
  considering the chore complete. Pay special attention to
  `mix compile --warnings-as-errors` flagging any *other* helper that became
  unused (e.g. if a grep missed a reference) and to `mix credo --strict` /
  `mix dialyzer` after the deletions.

## Validation Commands

Execute every command to validate the chore is complete with zero regressions.

- `mix compile --warnings-as-errors` - Compile clean; the gradual set-theoretic type checker and `warnings_as_errors` must pass (catches any leftover unused private function / import after the deletions).
- `mix test --warnings-as-errors` - Run the full ExUnit suite with zero failures (confirms the realigned/removed tests and that no agent card renders on the ADWs view).
- `mix format --check-formatted` - Ensure code is formatted.
- `mix credo --strict` - Lint, including the "every public function has an `@spec`" convention.
- `mix dialyzer` - `@spec`/contract checking with no new warnings.

## Notes

- **Scope is UI + dead-code only.** No Ecto schema, migration, context, OTP
  process, or harness-event change. DB access stays behind the existing `@spec`'d
  contexts; none are touched.
- **Why the `clear_workflows` body stays.** The handler trims `@event_buffer`
  (and soft-hides worker logs in the DB), which also backs the LOGS view and the
  per-step squares inside ADW cards. Removing the AGENTS section only removes a
  *consumer* of that data; the handler's effect on the rest of the console must
  be preserved. Only the button's disabled gating changes.
- **Standalone manual agents.** With the AGENTS section gone, agents that are not
  part of any workflow no longer appear on the ADWs view. They remain visible in
  the LOGS view (the event stream) and via the orchestrator roster/chat — this is
  the intended outcome of the chore (ADWs screen = ADWs only).
- **Test surface.** Several `*_swimlane*` / console tests assert agent cards on
  the ADWs view; the green gate will not pass until each is realigned (Step 6).
  Treat a still-failing `swimlane-<agent_id>` assertion as expected churn, not a
  regression. The `Logs.hide_logs_for_agents/1` durability path previously
  covered by `test_adws_clear_swimlanes_test.exs` is exercised indirectly by the
  remaining clear behaviour; if direct coverage is desired, add a focused context
  test for `Logs.hide_logs_for_agents/1` rather than re-introducing a UI test for
  the removed cards.
- Use **Tidewave** (`project_eval`) for a quick runtime sanity check of the
  `:adws` render if desired, but the ExUnit LiveView tests are the authoritative
  validation here.
