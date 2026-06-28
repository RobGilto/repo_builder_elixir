# Bug: Orchestrator has no tool to write a lesson — "memory-write tooling isn't available"

## Metadata
issue_number: `expertise`
adw_id: `system`
issue_json: `Important`

## Bug Description

The orchestrator's expertise/memory system is **read-only from the LLM's seat**. The
running orchestrator (the LLM driving the work) can *see* its past lessons — the system
prompt injects the last N reflections ("Lessons from past runs…") and the code-validated
stack expertise — but it has **no tool it can call to record a new lesson when it learns
one mid-run**.

Live symptom (from the issue report): after the orchestrator discovered a real,
durable lesson —

> *"check disk before re-dispatching a 'retired without handover' worker — the work is
> often already committed"*

— it tried to persist it and concluded:

> *"Memory-write tooling isn't available in this context, so I'll skip that and just keep
> the lesson in mind for this session."*

So a genuinely useful, generalizable lesson (one that had already cost two redundant
re-dispatches) was **lost the moment the session ended**. The whole point of the
self-healing Reflexion loop (Phase 5) — "each run starts ahead of the last" — silently
fails for any lesson learned *during* a run rather than *at the terminal moments*.

- **Expected:** when the orchestrator LLM learns a lesson worth carrying forward, it can
  call a tool (e.g. `record_reflection`) that persists it via the existing
  `Orchestrator.Reflections` store, scoped to its project, so the next run for that
  project is primed with it. Symmetric with the read path that already injects lessons
  into the system prompt.
- **Actual:** there is **no such tool**. Reflections are written *only* by the platform
  itself at two fixed, non-LLM-driven moments:
  - `Tools.report_complete/2` → `record_completion_reflection/3` (on goal completion), and
  - `Orchestrator.Driver` escalation (`driver.ex:209`, on a stalled/blocked goal).

  The LLM cannot trigger a write itself, in any harness.

## Problem Statement

The orchestrator tool catalog (`RepoBuilder.Orchestrator.ToolCatalog`, the SINGLE source
of truth advertised identically to the Claude MCP binding and the pi extension) exposes
no write path into the verbal-memory store. `RepoBuilder.Orchestrator.Reflections.record/1`
exists and is fully `@spec`'d and fail-soft, but it is reachable only from internal
platform call sites — never from `Tools.call/3` (the harness-blind tool entry point) and
never from `ToolCatalog.tools/0`. Therefore an LLM orchestrator that learns a lesson at
any point other than goal-completion/escalation has no way to bank it, and the lesson is
discarded at session end.

## Solution Statement

Add a single new harness-blind orchestrator tool, **`record_reflection`**, that lets the
orchestrator write one verbal lesson on demand into the existing reflections store —
mirroring how `save_agent_template` already exposes the template store as a write tool.

The fix reuses every existing seam and adds no new subsystem:

1. **`ToolCatalog.tools/0`** — append a `record_reflection` tool definition (name +
   description + JSON-Schema). One required field `lesson`; one optional `goal`. This
   propagates automatically to both bindings (MCP `tools/list` and the pi manifest),
   because both render from this list.
2. **`Tools.dispatch/3` + a `record_reflection/2` handler** — delegate to
   `Reflections.record/1`, scoping the write to the orchestrator's bound project
   (`orchestrator_project_id/1`, the same helper `record_completion_reflection/3`
   already uses) and stamping `orchestrator_id` and (optional) `goal`. Return a normal
   `{:ok, map()}` tool result; never raise (the `Tools.call/3` wrapper already guarantees
   this, and `Reflections.record/1` is itself fail-soft).
3. **System-prompt mention (optional, low-risk):** add one line to the leadership-tools
   guidance so the orchestrator knows the tool exists and when to use it (learned a
   durable lesson → bank it). This closes the loop the LLM explicitly looked for.

This is surgical: no schema/migration change (the `orchestrator_reflections` table and
`Reflection` changeset already accept exactly these fields), no new process, no change to
the existing auto-write call sites, and the read path is untouched.

## Steps to Reproduce

1. Start an orchestrator with a goal and let it drive work.
2. Have it reach a state where it articulates a generalizable lesson mid-run (e.g. a
   wasted re-dispatch).
3. Observe (in the live transcript) the orchestrator note that it *wants* to persist the
   lesson but cannot — there is no memory-write tool — and it "keeps it in mind for this
   session" only.
4. Confirm the gap deterministically:
   - `RepoBuilder.Orchestrator.ToolCatalog.names()` contains **no** reflection/expertise
     write tool.
   - `RepoBuilder.Orchestrator.Tools.call("record_reflection", orch_id, %{"lesson" => "x"})`
     returns `{:error, :unknown_tool}` (pre-fix).
   - End the session and start a new run for the same project: the lesson is absent from
     `Reflections.list_recent(project_id, 5)` and from the next run's system prompt.

Deterministic reproduction (test): call `Tools.call("record_reflection", orch.id, %{...})`
and assert it returns `{:error, :unknown_tool}` pre-fix; post-fix assert `{:ok, …}` and
that `Reflections.list_recent(project_id, 5)` now contains the lesson scoped to the
orchestrator's project.

## Root Cause Analysis

The Reflexion memory loop was built **read-complete but write-incomplete** for the LLM:

- **Read path (works):** `Orchestrator.SystemPrompt.reflections_block/1`
  (`system_prompt.ex:557`) and `expertise_block/1`/`leader_expertise_block/0` inject past
  lessons + code-validated expertise into every run's prompt.
- **Write path (incomplete):** `Reflections.record/1` is only ever called by the platform
  at two internal, non-LLM moments —
  - `Orchestrator.Tools.record_completion_reflection/3` (`tools.ex:521`), fired by
    `report_complete`, and
  - `Orchestrator.Driver` escalation (`driver.ex:209`).

  Neither `ToolCatalog.tools/0` nor `Tools.dispatch/3` exposes a write. So the ACT→LEARN→
  REUSE loop can only LEARN at the terminal beats of a goal; a lesson surfaced *during*
  the run (the common case, and exactly what happened here) has nowhere to go. The LLM
  correctly reported "memory-write tooling isn't available in this context" — that is a
  literal description of the catalog gap, not a context/permission problem.

The analogous template store (`Templates`) *does* expose both read (`get_agent_template`,
`list_agent_templates`) **and** write (`save_agent_template`) tools; reflections were left
with read-injection only. This bug closes that asymmetry.

## Relevant Files

Use these files to fix the bug:

- `lib/repo_builder/orchestrator/tool_catalog.ex` — the SINGLE source of truth for tool
  definitions advertised to BOTH harness bindings. Add the `record_reflection` tool def
  here (next to the leadership/ledger tools `set_goal`/`record_progress`/`report_complete`).
- `lib/repo_builder/orchestrator/tools.ex` — the harness-blind tool LOGIC + `call/3`
  entry point. Add a `dispatch("record_reflection", …)` clause and a `record_reflection/2`
  handler that delegates to `Reflections.record/1`. `Reflections` is already aliased
  (`tools.ex:43`) and `orchestrator_project_id/1` already exists and is used by
  `record_completion_reflection/3` (`tools.ex:530`).
- `lib/repo_builder/orchestrator/reflections.ex` — the write context. **No change** —
  `record/1` already accepts `:lesson`/`:goal`/`:project_id`/`:orchestrator_id` and is
  fail-soft. The fix only adds a new caller.
- `lib/repo_builder/orchestrator/reflection.ex` — the Ecto schema/changeset. **No change**
  — the changeset already casts exactly these fields and requires `:lesson`
  (min 1 / max 2000). Confirms no migration is needed.
- `lib/repo_builder/orchestrator/system_prompt.ex` — the read-injection of lessons
  (`reflections_block/1`) and where the leadership-tools guidance lives; optionally add a
  one-line "bank a durable lesson with `record_reflection`" hint so the LLM discovers the
  tool. The read path itself is untouched.
- `lib/repo_builder/orchestrator/driver.ex` — reference only: shows the existing
  escalation auto-write (`driver.ex:209`) that must remain unchanged.

### New Files

- `test/repo_builder/orchestrator/tools_reflection_test.exs` — a new ExUnit test (mirrors
  `tools_ledger_test.exs`'s structure: `use RepoBuilder.DataCase, async: true`, create an
  orchestrator, round-trip through `Tools.call/3`) that fails before the fix (`unknown_tool`)
  and proves the lesson persists + is project-scoped + missing-`lesson` is rejected after.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Add the `record_reflection` tool definition to the catalog

- In `lib/repo_builder/orchestrator/tool_catalog.ex`, append a new tool map to the list
  returned by `tools/0`, placed alongside the leadership/ledger tools (after
  `report_complete`/`inspect_repo`).
- Definition:
  - `name: "record_reflection"`.
  - `description:` concise, action-oriented — e.g. *"Bank a durable verbal lesson you
    learned this run into your project memory so the NEXT run for this project starts
    ahead. Use it the moment you learn something generalizable (a wasted step, a
    non-obvious gotcha, a workflow that worked) — don't wait for `report_complete`.
    `lesson` is one or two sentences, imperative and concrete. Optional `goal` ties it to
    what you were driving. Persisted, project-scoped, and injected into future runs'
    prompts."*
  - `input_schema:` object with `lesson` (string, required) and `goal` (string, optional);
    `required: ["lesson"]`.
- This automatically flows to both the MCP `tools/list` response and the pi extension
  manifest (both render from `ToolCatalog.tools/0`); no separate binding edits needed.

### 2. Wire the dispatch + handler in `Tools`

- In `lib/repo_builder/orchestrator/tools.ex`, add a dispatch clause next to the other
  leadership/ledger dispatch clauses (near `record_progress`/`report_complete`):
  ```elixir
  defp dispatch("record_reflection", orchestrator_id, args),
    do: record_reflection(orchestrator_id, args)
  ```
- Add the handler (place it near `record_completion_reflection/3`):
  ```elixir
  @spec record_reflection(Ecto.UUID.t(), map()) :: result()
  defp record_reflection(orchestrator_id, args) do
    with {:ok, lesson} <- fetch_string(args, "lesson") do
      case Reflections.record(%{
             lesson: lesson,
             goal: blank_to_nil(args["goal"]) || current_goal(orchestrator_id),
             orchestrator_id: orchestrator_id,
             project_id: orchestrator_project_id(orchestrator_id)
           }) do
        {:ok, reflection} ->
          {:ok, %{"status" => "recorded", "reflection_id" => reflection.id}}

        :error ->
          {:error, :reflection_not_recorded}
      end
    end
  end
  ```
  - Reuse `fetch_string/2` (validates non-blank `lesson`, mirroring the other handlers),
    `blank_to_nil/1`, `current_goal/1`, and `orchestrator_project_id/1` — all already in
    this module. Default the `goal` to the active ledger goal when the LLM omits it, so a
    lesson is tied to context without requiring the field.
  - Keep the return shape consistent with `record_progress`/`set_goal` (`"status"` plus an
    id). Preserve precise `@spec`s and tagged-tuple returns per BUILD_PROMPT §3.

### 3. (Optional, low-risk) Surface the tool in the system prompt

- In `lib/repo_builder/orchestrator/system_prompt.ex`, in the leadership-tools guidance
  block (the same region that documents `set_goal`/`record_progress`/`report_complete`),
  add ONE sentence telling the orchestrator to bank durable lessons with
  `record_reflection` when it learns one mid-run. Keep it short; do not alter
  `reflections_block/1`'s read injection.

### 4. Write the failing-then-passing test

- Create `test/repo_builder/orchestrator/tools_reflection_test.exs`:
  - `use RepoBuilder.DataCase, async: true`; alias `Tools`, `Reflections`, `Orchestrators`.
  - Create an orchestrator (no project needed for the unscoped case; for the scoped
    assertion, create a `Projects.Project` and an orchestrator bound to it — follow the
    pattern in `tools_worker_project_pin_test.exs` for binding a project).
  - Test A (the regression guard): `Tools.call("record_reflection", orch.id, %{"lesson" =>
    "check disk before re-dispatching a retired worker"})` returns `{:ok, %{"status" =>
    "recorded"}}`, and `Reflections.list_recent(project_id, 5)` (for the orchestrator's
    project, or `nil`) contains the lesson. This is the pre-fix `{:error, :unknown_tool}`
    → post-fix pass case.
  - Test B: a blank/missing `lesson` returns `{:error, _}` (no row written).
  - Test C (scoping): the recorded reflection's `project_id` equals the orchestrator's
    bound project id and `goal` is back-filled from the active ledger when omitted (set a
    goal via `Tools.call("set_goal", …)` first, then record with no `goal`).
- This bug does NOT touch the LiveView UI, so no `Phoenix.LiveViewTest` is required.

### 5. Run the full validation suite

- Run every command in **Validation Commands** and confirm zero failures, zero new
  warnings, and a clean type/lint/format pass.

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- `mix test test/repo_builder/orchestrator/tools_reflection_test.exs` — the new test:
  fails before the fix (`record_reflection` is `:unknown_tool`), passes after.
- `mix test test/repo_builder/orchestrator/tools_ledger_test.exs test/repo_builder/orchestrator/reflections_test.exs`
  — the adjacent ledger + reflections suites still green (no regression in the existing
  read/auto-write paths).
- `mix compile --warnings-as-errors` — clean compile; the gradual set-theoretic type
  checker and `warnings_as_errors` pass.
- `mix test --warnings-as-errors` — full ExUnit suite, zero failures.
- `mix format --check-formatted` — formatting clean.
- `mix credo --strict` — lint clean, including the "every public function has an `@spec`"
  gate (the new private handler carries a `@spec`).
- `mix dialyzer` — no new contract warnings and no stale ignore filters.

## Notes

- **No new dependency, no migration.** The `orchestrator_reflections` table and the
  `Reflection` changeset already accept `:lesson`/`:goal`/`:project_id`/`:orchestrator_id`;
  this bug is purely a missing *tool surface* over an existing, fully-built store.
- **Symmetry precedent:** `save_agent_template` is the existing model — a write tool over
  a versioned store that the orchestrator can call on demand. `record_reflection` does the
  same for the verbal-memory store, closing the read-only-from-the-LLM gap.
- **Both harnesses covered for free:** because `ToolCatalog.tools/0` is the single source
  of truth for the MCP `tools/list` and the pi manifest, adding the def there advertises
  the tool to Claude and pi identically — consistent with the harness-blind doctrine in
  `Tools`' moduledoc.
- **Fail-soft preserved:** `Reflections.record/1` already swallows write errors to `:error`
  rather than raising; the handler maps that to a typed `{:error, :reflection_not_recorded}`
  tool result so a transient DB hiccup never crashes the orchestrator turn.
- **Tidewave for live confirmation (optional):** after the fix, on the running app, drive
  an orchestrator to call `record_reflection`, then use Tidewave `execute_sql_query`
  (`select lesson, project_id, goal from orchestrator_reflections order by inserted_at
  desc limit 5`) to confirm the row landed, and `project_eval`
  (`RepoBuilder.Orchestrator.Reflections.list_recent(project_id, 5)`) to confirm it
  surfaces in the next run's prompt.
- **Scope discipline:** do not change the auto-write call sites
  (`record_completion_reflection/3`, the driver escalation write) or the read-injection
  blocks — they already work; the only gap is the on-demand LLM write tool.
