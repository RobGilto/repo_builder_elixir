# Feature: Orchestrator Focus Discipline ("work till it's done", two-level: orchestrator + per parallel workstream)

## Metadata
issue_number: `to`
adw_id: `implement`
issue_json: `focus`

## Design Decision: Two-Level Focus (parallel tilldones)
`tilldone.ts` governs a **single** pi agent, so it has exactly one in-progress task. This platform
is different: its unit of parallel autonomous work is the **`Workstream`** (`orchestrator_workstreams`),
and **multiple workstreams run concurrently** under one orchestrator (soft cap
`@active_workstream_cap = 5`). A single global focus would therefore be a lossy port — it cannot
name "the one thing" when the brain is legitimately advancing several parallel workstreams at once.

So focus is modeled at **two levels**, mirroring the duality the codebase already commits to. The
platform already carries `goal` + `definition_of_done` on **both** the single active `TaskLedger`
(orchestrator level) **and** on each `Workstream` (per parallel stream); focus follows the exact
same shape:

1. **Per-workstream focus** — each running `Workstream` carries its own `focus` + `focus_set_at`
   (the "N parallel tilldones": one in-flight focus per parallel stream). This is the primary
   discipline for spec-driven phased work.
2. **Orchestrator-level focus** — the single active `TaskLedger` also carries `focus` +
   `focus_set_at`, the fallback for **untagged** work — a `command_agent`/`start_adw` call that does
   not name a workstream (interactive or non-workstream autonomous runs). This preserves the
   discipline for the back-compatible non-workstream path that `maybe_tag_workstream` still supports.

The gate is **scope-aware**: a budget-spending worker tool that names a `workstream` is gated
against *that workstream's* focus; an untagged call is gated against the orchestrator-level focus.
`set_focus` / `clear_focus` take an **optional `workstream` ref** — present ⇒ operate on that
workstream's focus (via `Workstreams`); absent ⇒ operate on the orchestrator-level focus (via
`Ledgers`). This is Option 1 ("two-level") from the design discussion, chosen because it is the
update most consistent with how this codebase *already* models orchestrator-vs-workstream state,
and because it closes the discipline gap for **both** the workstream and the untagged paths —
consistent with the recent trajectory (`deterministic worker-fleet gate`, `self-healing autonomous
orchestrator`) of sealing unfocused-budget holes rather than leaving a whole mode ungated.

## Feature Description
Give **each orchestrator** — and **each of its parallel workstreams** — a single-focus,
"work-till-it's-done" discipline modeled on the `pi` community extension
[`tilldone.ts`](https://github.com/disler/pi-vs-claude-code/blob/main/extensions/tilldone.ts).

`tilldone.ts` enforces a task-driven discipline on a *single* pi agent through three
mechanisms: (1) a **blocking gate** — the agent may not call any work tool until it has
declared its tasks; (2) a **single in-progress task** invariant — exactly one task may be
"inprogress" at a time, and toggling a new one auto-demotes the others; and (3) an
**auto-nudge on agent-end** — if incomplete tasks remain when the turn ends, the agent is
re-prompted to keep going. It also surfaces the "current task" prominently in the UI
("● WORKING ON #id …").

This platform already has the durable substrate `tilldone.ts` lacks: the **Magentic-One dual
ledger** (`RepoBuilder.Orchestrator.TaskLedger` + `ProgressEntry`), a deterministic
**autonomous drive loop** (`Orchestrator.Driver`), and a live console. What it does *not* have
is a notion of the **one thing an orchestrator is actively focused on right now**. The goal +
definition-of-done + jsonb `plan` describe *what* and *how*, and per-turn Progress entries
describe *whether we advanced*, but nothing names the **single current focus** or enforces that
the brain declares it before it spends budget commanding/spawning workers.

This feature ports the three `tilldone.ts` mechanisms onto the platform's existing durable state,
at **both** levels (see Design Decision above):

1. **Focus state (two levels)** —
   - a `focus` string + `focus_set_at` on each **`Workstream`** (one in-flight focus per parallel
     stream), and
   - a `focus` string + `focus_set_at` on the single active **`TaskLedger`** (the fallback for
     untagged work).
   Set/replaced via a new `set_focus` tool taking an optional `workstream` ref (single-focus is
   enforced by overwrite at whichever scope it targets, mirroring tilldone's "only one inprogress");
   cleared via `clear_focus` when that stretch of work is verified done.
2. **Scope-aware focus gate** — a deterministic, config-toggleable gate in `Orchestrator.Tools` that
   **blocks budget-spending worker tools** (`command_agent`, `create_agent`, `start_adw`) with a
   structured `{:error, :focus_required}` when the *targeted scope* has no focus: a call naming a
   `workstream` is gated against that workstream's focus; an untagged call is gated against the
   orchestrator-level focus (only when a goal is active). `plan_phases` is **not** gated — it is the
   workstream *declaration* step (the analogue of tilldone "declaring your tasks"), which must run
   before a meaningful focus can be named. Read-only / ledger / workstream-read / focus tools are
   never gated.
3. **Focus-aware drive, nudge, and rehydrate** — the `Driver` surfaces the orchestrator-level focus
   in its drive prompt and, when an active-goal orchestrator has no untagged focus, issues a
   **focus-first nudge** turn (the durable analogue of tilldone's `agent_end` nudge). Per-workstream
   focus flows back to the brain every turn through `Queue.rehydrate_line/1` (built from
   `Workstreams.index_row/1`): each workstream line carries its focus, or a "no focus — set one"
   marker, so the brain is continually reminded which stream is unfocused.
4. **Console surface (two levels)** — the autonomy panel renders a prominent `🎯 FOCUS: …` line for
   the orchestrator-level focus, and the **Workstreams panel renders a per-row `🎯 FOCUS: …` line**
   for each workstream (the analogue of tilldone's "WORKING ON" widget). Both update live over the
   existing `ledger_updated` and `workstreams` PubSub broadcasts.

The value: focused, less-thrashy autonomous runs even under parallelism. Today a driven orchestrator
can fan out workers across several workstreams without ever naming the concrete thing each stream is
pursuing; the two-level focus discipline forces one in-flight objective **per parallel stream**,
makes each objective visible to the away human in its swimlane, and keeps budget from leaking into
unfocused work at either scope.

## User Story
As an **operator running an autonomous orchestrator** (fire-and-walk-away)
I want **each orchestrator to declare and display the one thing it is focused on, and to be
blocked from spending budget on workers until it has**
So that **autonomous runs stay focused and legible — I can glance at the console and see exactly
what the brain is working on, and the brain can't thrash across unfocused work while I'm away.**

## Problem Statement
The orchestrator's dual ledger captures the *goal*, the *definition-of-done*, a *plan*, and
*per-turn progress*, but there is no first-class notion of the **single current focus** — the one
concrete sub-objective the brain is actively pursuing right now. Consequences:

- A driven orchestrator can call `command_agent` / `create_agent` / `start_adw` without ever
  committing to a single in-flight objective, producing scattered, hard-to-audit runs.
- The away human cannot see "what is it working on *right now*" — only the static goal and the
  last progress summary.
- Nothing enforces the `tilldone.ts` "declare your work before you act, and don't stop till it's
  done" discipline that makes long autonomous runs converge.

## Solution Statement
Add a **focus** concept at two scopes: a `focus` string + `focus_set_at` on each **`Workstream`**
(the primary, per-parallel-stream focus) and the same pair on the active **`TaskLedger`** (the
untagged-work fallback). Both are manipulated by two new harness-blind tools (`set_focus`,
`clear_focus`) that take an **optional `workstream` ref**, implemented once in `Orchestrator.Tools`
(so Claude MCP, the pi extension, and the Fake loop all get identical behaviour, with the pi
manifest + MCP surface derived from `ToolCatalog` as today). DB writes stay behind each layer's sole
`Repo` caller: `Ledgers` for the orchestrator-level focus, `Workstreams` for the per-workstream one.

Enforce the discipline with a **deterministic, scope-aware focus gate** in `Tools.call/3`: for a
budget-spending worker tool (`command_agent`, `create_agent`, `start_adw`), resolve the target
scope — if the args carry a `workstream` ref that resolves, gate against *that workstream's* focus
(refuse if the workstream is `:running` with a blank focus); otherwise gate against the
orchestrator-level focus (refuse only when the `TaskLedger` is `:active` with a blank focus). A
refusal returns `{:error, :focus_required}` with a scope-specific message telling the brain to call
`set_focus` (with the workstream ref, when applicable) first — faithful to tilldone's blocking
`tool_call` gate. The gate is config-toggleable (`:focus_gate`, default `true`) and only engages for
goal-/workstream-driven work, preserving back-compat for interactive use. `plan_phases` is
deliberately **not** gated (it is the workstream-declaration step).

Wire focus into the existing autonomous machinery at both scopes: the `Driver` surfaces the
orchestrator-level focus in its drive prompt and issues a **focus-first nudge** turn when an
active-goal orchestrator has no untagged focus; per-workstream focus rides `Queue.rehydrate_line/1`
so every turn's workstream index shows each stream's focus (or a "set one" marker). Surface both
live in the console — the `🎯 FOCUS` line in the autonomy panel (orchestrator) and a per-row
`🎯 FOCUS` line in the Workstreams panel — via the existing `ledger_updated` / `workstreams`
broadcasts, and teach the system prompt the two-level focus discipline.

This reuses every existing seam (dual ledger + workstream layer, `Ledgers` and `Workstreams` as the
sole `Repo` callers for their tables, the `ToolCatalog` single-source-of-truth, the `Driver` drive
loop, the `Queue` rehydrate index, `Dashboard.broadcast_ledger_updated` /
`Dashboard.broadcast_workstreams`, the autonomy + workstreams panels) — no new subsystem, no new
dependency.

## Relevant Files
Use these files to implement the feature:

- `lib/repo_builder/orchestrator/task_ledger.ex` — the durable Task Ledger schema (orchestrator
  level). **Add** the `focus` (`:string`, nullable) and `focus_set_at` (`:utc_datetime_usec`,
  nullable) fields, the `@type t`, and cast them in `changeset/2`.
- `lib/repo_builder/orchestrator/workstream.ex` — the durable Workstream schema (per-parallel-stream
  level). **Add** the same `focus` + `focus_set_at` fields, `@type t` entries, and cast them in
  `changeset/2` (mirrors the `goal`/`definition_of_done` fields already present at both levels).
- `priv/repo/migrations/` — **two new migrations** (or one with two `alter table`s): add
  `focus` + `focus_set_at` to `task_ledgers` **and** to `orchestrator_workstreams` (both binary_id
  tables; nullable columns; no backfill, no index). Generate with
  `mix ecto.gen.migration add_focus_to_orchestrator_focus_state`.
- `lib/repo_builder/orchestrator/ledgers.ex` — the ONLY `Repo` caller for `task_ledgers` /
  `progress_entries`. **Add** `set_focus/2`, `clear_focus/1`; extend the `view/1` `view()` type
  and map with `focus` + `focus_set_at`.
- `lib/repo_builder/orchestrator/workstreams.ex` — the ONLY `Repo` caller for
  `orchestrator_workstreams` / phases. **Add** `set_focus/3` (orchestrator_id, ref, focus),
  `clear_focus/2` (orchestrator_id, ref) — both resolving the ref via the existing `resolve/2` and
  updating through `Workstream.changeset` + `Repo.update` (same pattern as `close_workstream/3`);
  add `focus` + `focus_set_at` to **both** the `index_row/1` view (so the Queue rehydrate index +
  console feed carry it) and the `record/1` full view. Extend `rehydrate_line/1`'s source data
  accordingly (or add focus to the line text — see Driver/Queue step).
- `lib/repo_builder/orchestrator/tools.ex` — harness-blind tool logic + `call/3` single entry
  point. **Add** the `set_focus` / `clear_focus` handlers (branching on the optional `workstream`
  arg) and dispatch clauses; **add** the deterministic **scope-aware** focus gate in `call/3`
  (before `dispatch/3`) covering `command_agent` / `create_agent` / `start_adw`; extend
  `ledger_tool_map/1` with the orchestrator-level focus; broadcast the ledger (untagged) or
  workstreams (workstream-scoped) after focus changes.
- `lib/repo_builder/orchestrator/tool_catalog.ex` — the single source of truth for the tool
  surface (MCP `tools/list` + pi manifest are both derived from `tools/0`). **Add** the two new
  tool defs (`set_focus`, `clear_focus`), each with an **optional `"workstream"` string** in the
  `input_schema` (id-or-title, "omit to focus the orchestrator itself"), so both harness bindings
  advertise them automatically.
- `lib/repo_builder/orchestrator/queue.ex` — builds the per-turn workstream rehydrate index via
  `rehydrate_line/1` (from `Workstreams.index_row/1`). **Add** each workstream's focus (or a
  "⚠ no focus — set_focus first" marker) to the rehydrate line so the brain sees which streams are
  unfocused every turn (the per-workstream analogue of the Driver nudge).
- `lib/repo_builder/orchestrator/driver.ex` — the autonomous drive loop (orchestrator level). **Add**
  a `focus_prompt` and route an active-goal-but-no-(untagged)-focus orchestrator to a focus-first
  nudge turn; surface the orchestrator-level focus inside `drive_prompt`.
- `lib/repo_builder/orchestrator/system_prompt.ex` — the orchestrator's leadership doctrine
  (set_goal / record_progress / ONE STEP per turn / workstream discipline). **Add** the two-level
  focus discipline ("before commanding a worker, `set_focus` on the workstream you are advancing —
  or on yourself for untagged work; keep one focus per stream; `clear_focus` only once that focus is
  verified done").
- `lib/repo_builder_web/components/console_components.ex` — defines `autonomy_panel/1` **and**
  `workstreams_panel/1`. **Add** the `🎯 FOCUS: …` line to the autonomy panel (from `@ledger.focus`)
  **and** a per-workstream-row `🎯 FOCUS: …` line to the Workstreams panel (from each `ws.focus`),
  with a stable id (`id={"workstream-#{ws.id}-focus"}`).
- `lib/repo_builder_web/live/console_live.ex` — already handles `{:ledger_updated, …}` and
  `{:workstreams, …}` and renders both panels; the focus rides the existing `ledger` view and the
  workstream index/record rows, so this needs no logic change beyond confirming both views carry
  `focus`.
- `config/config.exs` — **add** `focus_gate: true` under `config :repo_builder, :orchestrator`
  (the same keyword the `Driver` reads via `config()`), and document it.
- `config/test.exs` — set `focus_gate` explicitly for deterministic tests if needed (see Testing
  Strategy / back-compat note).
- `priv/orchestrator/pi_extension/orchestrator-tools.ts` — loads the manifest from `ToolCatalog`
  at runtime (no static array). **No code change expected**; it picks up the two new tools
  automatically. The pi-parity test's hard count assertion must be updated (see below).
- `test/repo_builder/orchestrator/tool_catalog_pi_parity_test.exs` — asserts the pi manifest equals
  `ToolCatalog.names/0` **and a hard tool count** (currently 34). **Update** the count (34 → 36).

Conditional docs consulted (per `.claude/commands/conditional_docs.md`):
- `ai_docs/typed-elixir-standard.md` — **(always)** the enforced typed standard (`@spec`, typed
  structs, precise types, tagged tuples, wire-vs-domain).
- `BUILD_PROMPT.md` §3 (typed style), §7 (workflow/drive engine), §8 (Ecto contexts / migrations /
  `Repo`-callers), §9 (LiveView dashboard), §10 (open-identity/closed-contract extensibility).
- `ai_docs/adw-orchestration.md` — the drive loop / ledger orchestration model.

### New Files
- `priv/repo/migrations/<timestamp>_add_focus_to_orchestrator_focus_state.exs` — adds `focus` +
  `focus_set_at` columns to **`task_ledgers`** and **`orchestrator_workstreams`**.
- `test/repo_builder/orchestrator/tools_focus_test.exs` — unit tests for `set_focus` /
  `clear_focus` tool handlers (both the untagged and `workstream`-scoped paths) + the scope-aware
  focus gate (`{:error, :focus_required}` for worker tools when the targeted scope has no focus;
  allowed once that scope's focus is set; never gated without an active goal / a running targeted
  workstream; never gates read-only/ledger/workstream-read/focus tools; `plan_phases` never gated).
- `test/repo_builder/orchestrator/ledgers_focus_test.exs` — unit tests for `Ledgers.set_focus/2`,
  `clear_focus/1`, and the `view/1` focus fields (incl. `{:error, :no_active_ledger}`).
- `test/repo_builder/orchestrator/workstreams_focus_test.exs` — unit tests for
  `Workstreams.set_focus/3`, `clear_focus/2`, focus in the `index_row/1` + `record/1` views, ref
  resolution by id and title, and `{:error, :not_found}` for an unknown ref.
- `test/repo_builder/orchestrator/driver_focus_test.exs` — drives `Driver.tick/0`: an active-goal
  orchestrator with no untagged focus gets a focus-first nudge turn; with a focus set, a normal
  drive turn whose prompt surfaces the focus.
- `test/repo_builder_web/live/test_orchestrator_focus_test.exs` — `Phoenix.LiveViewTest`
  integration test: mount `ConsoleLive`, broadcast a `ledger_updated` view carrying an
  orchestrator-level `focus` **and** a `workstreams` list whose rows carry per-stream `focus`, and
  assert the autonomy panel renders `#orchestrator-focus` and each workstream row renders its
  `#workstream-<id>-focus` element.

## Implementation Plan
### Phase 1: Foundation (both levels)
Add the durable focus state at both scopes: one migration adding `focus` + `focus_set_at` to
`task_ledgers` **and** `orchestrator_workstreams`, the schema fields/type/changeset on both
`TaskLedger` and `Workstream`, and the context functions — `Ledgers.set_focus/2` / `clear_focus/1`
+ extended `view/1`, and `Workstreams.set_focus/3` / `clear_focus/2` + focus in the `index_row/1`
and `record/1` views. Everything DB-touching stays behind `Ledgers` and `Workstreams` (the sole
`Repo` callers for their tables). This phase is independently green (schemas + contexts + their unit
tests) before any tool/gate/UI work.

### Phase 2: Core Implementation
Expose focus to the brain and enforce the discipline: the `set_focus` / `clear_focus` tools in
`Orchestrator.Tools` (dispatch + handlers branching on the optional `workstream` arg +
`ledger_tool_map` extension + ledger/workstreams broadcast), the two `ToolCatalog` tool defs with
the optional `workstream` field (auto-deriving the MCP + pi surfaces), and the deterministic
**scope-aware** focus gate in `Tools.call/3`. Update the pi-parity count. Add the two-level focus
discipline to the system prompt.

### Phase 3: Integration
Wire focus into the autonomous loop and the console at both levels: the `Driver` focus-first nudge +
orchestrator-level focus in the drive prompt, the per-workstream focus (or "set one" marker) in
`Queue.rehydrate_line/1`, the `🎯 FOCUS` line in the autonomy panel, and the per-row `🎯 FOCUS` line
in the Workstreams panel (live over the existing `ledger_updated` / `workstreams` broadcasts). Add
the LiveView integration test and run the full green gate.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Migration — add focus columns to `task_ledgers` AND `orchestrator_workstreams`
- Run `mix ecto.gen.migration add_focus_to_orchestrator_focus_state`.
- In the generated migration, two `alter table` blocks:
  - `alter table(:task_ledgers)`: `add :focus, :text` (nullable), `add :focus_set_at,
    :utc_datetime_usec` (nullable).
  - `alter table(:orchestrator_workstreams)`: the same two columns.
- No backfill, no index (focus is read with the already-fetched row on each side). Keep it
  reversible (plain `add` rolls back automatically).
- Apply locally: `mix ecto.migrate` (Postgres must be running — `scripts/pg.sh start`).

### 2. Schemas — `TaskLedger` AND `Workstream` focus fields
- In `lib/repo_builder/orchestrator/task_ledger.ex`: add `focus: String.t() | nil` and
  `focus_set_at: DateTime.t() | nil` to `@type t`; add `field :focus, :string` and
  `field :focus_set_at, :utc_datetime_usec` to the `schema`; add both to the `cast/3` list in
  `changeset/2`. Do **not** add them to `validate_required` (focus is optional). Bound `focus`
  length defensively (`validate_length(:focus, max: 2_000)`).
- In `lib/repo_builder/orchestrator/workstream.ex`: the identical additions (`@type t`, two
  `field`s, `cast/3`, `validate_length`). This mirrors the `goal`/`definition_of_done` fields the
  schema already carries at this level.

### 3. Contexts — `Ledgers` (orchestrator) AND `Workstreams` (per-stream)
- In `lib/repo_builder/orchestrator/ledgers.ex`:
  - Add `@spec set_focus(Ecto.UUID.t(), String.t()) :: {:ok, TaskLedger.t()} | {:error, reason()}`
    via the existing private `update_active/2`, setting `%{focus: focus, focus_set_at:
    DateTime.utc_now()}`. Keep the context permissive (caller-validated), consistent with
    `upsert_goal`; blank rejection lives at the tool boundary (Step 5).
  - Add `@spec clear_focus(Ecto.UUID.t()) :: {:ok, TaskLedger.t()} | {:error, reason()}` via
    `update_active/2` setting `%{focus: nil, focus_set_at: nil}`.
  - Extend the `view()` type + `view/1` map with `focus` + `focus_set_at` (off the active
    `TaskLedger`).
- In `lib/repo_builder/orchestrator/workstreams.ex`:
  - Add `@spec set_focus(Ecto.UUID.t(), String.t(), String.t()) :: {:ok, Workstream.t()} |
    {:error, reason()}` — `resolve/2` the ref, then `Workstream.changeset(%{focus: focus,
    focus_set_at: DateTime.utc_now()}) |> Repo.update()` (same shape as `close_workstream/3`).
  - Add `@spec clear_focus(Ecto.UUID.t(), String.t()) :: {:ok, Workstream.t()} | {:error,
    reason()}` setting `%{focus: nil, focus_set_at: nil}`.
  - Add `focus` + `focus_set_at` to **both** `index_row/1` (so the Queue rehydrate index + console
    feed carry them) and `record/1` (full rehydration record), and to their view types.
- Add `test/repo_builder/orchestrator/ledgers_focus_test.exs` (mirror `ledgers_test.exs`): set focus
  on an active ledger → `view/1` shows it + `focus_set_at`; `clear_focus/1` nulls both;
  `{:error, :no_active_ledger}` with no goal.
- Add `test/repo_builder/orchestrator/workstreams_focus_test.exs` (mirror `workstreams_test.exs`):
  `set_focus/3` by id and by title persists + surfaces in `index_row`/`record`; `clear_focus/2`
  nulls both; `{:error, :not_found}` for an unknown ref.

### 4. ToolCatalog — declare `set_focus` / `clear_focus` (with optional `workstream`)
- In `lib/repo_builder/orchestrator/tool_catalog.ex` `tools/0`, add two `tool_def` maps near the
  ledger tools (`set_goal` / `record_progress`):
  - `set_focus` — `input_schema` object with a required `"focus"` string ("The single concrete
    thing you are working on right now.") and an **optional** `"workstream"` string ("Workstream id
    or title to focus; omit to focus the orchestrator itself for untagged work."). Description
    states the single-focus-per-scope invariant and that it must be set before commanding/spawning
    workers for that scope.
  - `clear_focus` — `input_schema` object with only the optional `"workstream"` string; description:
    "Clear a focus once it is verified done (name the workstream, or omit for the orchestrator);
    set a new one before continuing."
- Because the MCP `tools/list` and `pi_manifest_json/0` both derive from `tools/0`, no per-harness
  edits are needed.

### 5. Tools — handlers, dispatch, scope-aware gate, broadcast
- In `lib/repo_builder/orchestrator/tools.ex`:
  - Add dispatch clauses: `dispatch("set_focus", …)` and `dispatch("clear_focus", …)`.
  - `defp set_focus(orchestrator_id, args)`: `fetch_string(args, "focus")` (rejects blank), then
    branch on `blank_to_nil(args["workstream"])`:
    - present ⇒ `Workstreams.set_focus(orchestrator_id, ref, focus)`, `broadcast_workstreams/1`,
      return `{:ok, %{"status" => "focused", "scope" => "workstream", "workstream" => ref,
      "focus" => focus}}`; map `{:error, :not_found}` as the other workstream tools do.
    - absent ⇒ `Ledgers.set_focus(orchestrator_id, focus)`, `broadcast_ledger/1`, return
      `{:ok, %{"status" => "focused", "scope" => "orchestrator", "focus" => focus}}`; map
      `{:error, :no_active_ledger}` and changeset errors as the other ledger tools do.
  - `defp clear_focus(orchestrator_id, args)`: same present/absent branch calling
    `Workstreams.clear_focus/2` (+ `broadcast_workstreams/1`) or `Ledgers.clear_focus/1`
    (+ `broadcast_ledger/1`); return `{:ok, %{"status" => "focus_cleared", "scope" => …}}`.
  - Extend `ledger_tool_map/1` to include `"focus"` + `"focus_set_at"` so `get_ledger` returns the
    orchestrator-level focus.
  - **Scope-aware focus gate** in `call/3`, before `dispatch/3`: evaluate
    `focus_gate_block(tool, orchestrator_id, args)`. Implement a private
    `@spec focus_gate_block(String.t(), Ecto.UUID.t(), map()) :: :ok | {:error, :focus_required}`
    that returns `:ok` unless **all** hold: (a) `focus_gate_enabled?()` (config, default `true`);
    (b) `tool` ∈ module attribute `@focus_gated_tools` (`~w(command_agent create_agent start_adw)` —
    note **`plan_phases` is intentionally excluded**, it is the workstream-declaration step);
    (c) the **targeted scope** has a blank focus, where the scope is:
    - if `blank_to_nil(args["workstream"])` resolves via `Workstreams.resolve/2` to a `:running`
      `%Workstream{}` ⇒ gate on **that workstream's** `focus`;
    - else ⇒ gate on the orchestrator-level focus: `Ledgers.current(orchestrator_id)` is an
      `:active` `%TaskLedger{}` with a blank `focus`.
    Any other case (gate disabled, ungated tool, resolved-but-not-running workstream, no active
    ledger, focus already set) ⇒ `:ok`. Wire it so a blocked call short-circuits `dispatch` but
    still logs the invocation (`log_invocation/4`); keep the existing rescue/catch wrapper intact.
    Add `@spec`'d helper `focus_gate_enabled?/0` reading `config()[:focus_gate]` (default `true`,
    mirroring `Driver`'s config readers).
  - Surface a human-readable, **scope-specific** message for the gate: an untagged block →
    "Declare your focus with `set_focus` before commanding or spawning workers."; a
    workstream-scoped block → "Declare this workstream's focus with `set_focus(workstream: …)`
    before commanding a worker on it." Add the clause wherever tool-result error reasons are
    stringified (or return the message directly from the gate).
- Add `test/repo_builder/orchestrator/tools_focus_test.exs`:
  - `set_focus` (untagged) then `get_ledger` shows the focus; `clear_focus` removes it.
  - `set_focus` with a `workstream` ref → the workstream's `record`/`index_row` shows the focus;
    `clear_focus(workstream: …)` removes it.
  - **Untagged gate**: active goal + no orchestrator focus ⇒ `Tools.call("command_agent", …)` (no
    workstream arg) → `{:error, :focus_required}`; after untagged `set_focus`, the same call
    proceeds (assert **not** `:focus_required`).
  - **Workstream gate**: a `:running` workstream with no focus ⇒
    `Tools.call("command_agent", %{"workstream" => ref, …})` → `{:error, :focus_required}`; after
    `set_focus(workstream: ref)`, it proceeds — **even if the orchestrator-level focus is blank**
    (independence of scopes). Conversely an untagged focus does **not** satisfy a workstream-scoped
    call, and vice-versa.
  - No active goal AND no targeted running workstream ⇒ worker tools **never** gated (back-compat).
  - `plan_phases` is **never** gated (declaration step).
  - Read-only/ledger/workstream-read/focus tools (`get_ledger`, `set_goal`, `set_focus`,
    `clear_focus`, `list_agents`, `list_workstreams`, `get_workstream`) are never gated.
  - With `focus_gate: false` in config, the gate never engages at either scope.

### 6. System prompt — two-level focus discipline
- In `lib/repo_builder/orchestrator/system_prompt.ex`, in the leadership/ledger + workstream section
  (near the `set_goal` / `record_progress` / "ONE STEP per turn" / workstream bullets), add a FOCUS
  bullet: before commanding a worker on a workstream, `set_focus` on **that workstream** naming the
  single concrete thing you are advancing; for untagged work, `set_focus` on yourself; keep exactly
  one focus per scope; `clear_focus` (naming the workstream, or omitting for the orchestrator) only
  once that focus is verified done against the tree, then set the next one. Keep the terse,
  imperative style.
- Update `test/repo_builder/orchestrator/system_prompt_test.exs` (or add an assertion) that the
  rendered prompt mentions `set_focus`.

### 7. Driver + Queue — focus-aware drive, nudge, and per-workstream rehydrate
- In `lib/repo_builder/orchestrator/driver.ex` (orchestrator level, unchanged from the original
  single-level plan):
  - In `act_on/3`, before the normal drive branch (after escalate/replan), add a branch: when the
    ledger is `:active`, `blank?(ledger.focus)`, and `focus_gate_enabled?()`,
    `Queue.enqueue_drive(orchestrator.id, focus_prompt(ledger))` instead of the generic drive turn.
  - Add `@spec focus_prompt(TaskLedger.t()) :: String.t()` instructing the brain to `set_focus`
    (naming the single concrete thing) *before* spending budget, citing goal + definition-of-done.
  - In `drive_prompt/2`, add a `FOCUS:` line surfacing `ledger.focus` (or "(none set)").
  - Read `focus_gate_enabled?` from the same `config()` keyword the Driver already uses.
- In `lib/repo_builder/orchestrator/queue.ex` (per-workstream level): in `rehydrate_line/1` (built
  from `Workstreams.index_row/1`), append each workstream's focus to the line — e.g.
  `… 🎯 <focus>` when set, or `⚠ no focus — set_focus(workstream: …) first` when blank and the
  workstream is `:running`. This is the durable per-stream analogue of the Driver nudge: every turn's
  workstream index reminds the brain which streams are unfocused.
- Add `test/repo_builder/orchestrator/driver_focus_test.exs` (mirror `driver_test.exs`): seed an
  active ledger with no focus, `Driver.tick/0`, assert the enqueued drive prompt is the focus-first
  nudge (mentions `set_focus`); set a focus, tick again, assert the drive prompt surfaces the focus.
  Drive `tick/0` explicitly (`drive_on_boot: false`, `drive_interval_ms: :infinity`).
- Extend the existing Queue rehydrate test (or add one) asserting an unfocused `:running` workstream
  renders the "no focus" marker and a focused one renders its focus text.

### 8. Console — `🎯 FOCUS` in the autonomy panel AND per workstream row
- In `lib/repo_builder_web/components/console_components.ex`:
  - `autonomy_panel/1`: render `🎯 FOCUS: {@ledger.focus}` (id `orchestrator-focus`) when `@ledger`
    is present with a non-nil `focus`; when nil but a goal is active, a muted "no focus set" hint.
  - `workstreams_panel/1`: inside each `id={"workstream-#{ws.id}"}` row, render
    `🎯 FOCUS: {ws.focus}` with `id={"workstream-#{ws.id}-focus"}` when `ws.focus` is non-nil; a
    muted "no focus" hint when the row is `:running` and unfocused. Match existing panel styling.
- Confirm `console_live.ex` already feeds the `ledger` view to the autonomy panel (updated on
  `{:ledger_updated, …}`) and the workstream rows to the workstreams panel (updated on
  `{:workstreams, …}`); the focus rides both feeds (Step 3), so no new socket logic — just verify
  the `mount`/`assign` paths carry the new keys.

### 9. LiveView integration test (both levels)
- Add `test/repo_builder_web/live/test_orchestrator_focus_test.exs` using `Phoenix.LiveViewTest`:
  - Mount `ConsoleLive` at `/` for an orchestrator with an active goal and ≥1 workstream.
  - Broadcast a `ledger_updated` view carrying `focus: "ship the focus gate"` and a `workstreams`
    list whose row carries `focus: "land phase 2 spec"` over the same topics `console_live`
    subscribes to (mirror `console_autonomy_test.exs` / the workstreams-panel test), or drive both
    through the `set_focus` tool.
  - Assert `has_element?(view, "#orchestrator-focus")` with the orchestrator focus text **and**
    `has_element?(view, "#workstream-<id>-focus")` with the workstream focus text. Prefer
    element/`has_element?` assertions over raw HTML (per `AGENTS.md`).
- Optionally capture a Playwright screenshot of `http://localhost:4000` for visual proof of both
  `🎯 FOCUS` lines (non-blocking).

### 10. Config + docs
- `config/config.exs`: add `focus_gate: true` to `config :repo_builder, :orchestrator, …` with a
  one-line comment (governs both scopes). `config/test.exs`: if any existing goal-/workstream-driven
  test would break under the gate, either set `focus_gate: false` there OR (preferred) update those
  tests to `set_focus` first — see the back-compat audit in Step 11.
- Update the pi-parity count assertion in
  `test/repo_builder/orchestrator/tool_catalog_pi_parity_test.exs` (34 → 36) and the inline comment.

### 11. Back-compat audit of goal-/workstream-driven tests
- Grep existing tests for ones that (a) `set_goal`/seed an active ledger and then call an untagged
  gated worker tool, OR (b) create a `:running` workstream and then `command_agent` **on that
  workstream** — e.g. `command_agent_autonomous_test.exs`, `self_healing_e2e_test.exs`,
  `tools_workstream_test.exs`, `workstreams_test.exs`. For each, add the appropriate `set_focus`
  (untagged, or `set_focus(workstream: ref)`) after the goal/workstream setup so the gate passes
  (the intended new contract), OR scope that test's config to `focus_gate: false` if it specifically
  asserts pre-focus behaviour. Document the choice in the test.

### 12. Validate
- Run every command in **Validation Commands** below and confirm zero failures / zero new warnings.

## Testing Strategy
### Unit Tests
- **`Ledgers` (`ledgers_focus_test.exs`)**: `set_focus/2` persists `focus` + `focus_set_at`;
  `view/1` surfaces them; `clear_focus/1` nulls both; `{:error, :no_active_ledger}` with no goal.
- **`Workstreams` (`workstreams_focus_test.exs`)**: `set_focus/3` (by id and title) persists +
  surfaces in `index_row`/`record`; `clear_focus/2` nulls both; `{:error, :not_found}` for an
  unknown ref.
- **`Tools` (`tools_focus_test.exs`)**: `set_focus` / `clear_focus` handlers (both scopes) return
  the right tagged maps and broadcast ledger-or-workstreams; the **scope-aware gate** blocks each
  gated worker tool with `{:error, :focus_required}` iff the *targeted scope* is unfocused (active
  ledger for untagged, running workstream for tagged) with the gate enabled; the two scopes are
  **independent** (a workstream focus doesn't satisfy an untagged call, nor vice-versa); allows once
  that scope is focused; never gates without an active goal / running targeted workstream; never
  gates `plan_phases` or read-only/ledger/workstream-read/focus tools; respects `focus_gate: false`.
- **`ToolCatalog` (existing parity test + count bump)**: the pi manifest and MCP name set both
  include `set_focus` / `clear_focus` (with the optional `workstream` field); the hard count
  assertion updated (34 → 36).
- **`Driver` (`driver_focus_test.exs`)**: active-goal-no-focus → focus-first nudge turn enqueued;
  active-goal-with-focus → drive prompt surfaces the focus. Drive `tick/0` explicitly.
- **`Queue` (rehydrate line)**: an unfocused `:running` workstream renders the "no focus" marker; a
  focused one renders its focus text.
- **`SystemPrompt`**: rendered prompt mentions `set_focus`.
- **LiveView (`test_orchestrator_focus_test.exs`)**: the autonomy panel renders `#orchestrator-focus`
  and each workstream row renders `#workstream-<id>-focus` with the right focus text after the
  `ledger_updated` / `workstreams` broadcasts.

### Edge Cases
- **No active goal AND no targeted running workstream**: gate never engages; untagged `set_focus`
  returns `{:error, :no_active_ledger}`; interactive orchestrators are entirely unaffected.
- **Scope independence**: a workstream-scoped `command_agent` is gated on that workstream's focus
  **only** — a set orchestrator-level focus does not unblock it, and a workstream focus does not
  unblock an untagged call. Each parallel workstream is gated on its own focus, independently.
- **Unresolvable / non-running workstream ref**: if `args["workstream"]` doesn't resolve, or resolves
  to a non-`:running` workstream, the gate does **not** engage on the workstream scope (the call
  falls through to normal dispatch, which handles the bad ref as today).
- **Blank/whitespace focus**: `set_focus` with empty/blank `focus` is rejected at the tool boundary
  (`fetch_string` blank check) at either scope — it must not "set" an empty focus that silently
  passes the gate.
- **Re-focus (overwrite)**: calling `set_focus` again for the same scope replaces its focus and
  refreshes `focus_set_at` (single-focus-per-scope invariant — the tilldone "only one inprogress"
  rule, applied per parallel stream).
- **Gate config off**: `focus_gate: false` ⇒ worker tools never blocked at either scope (full
  back-compat / escape hatch).
- **Goal / workstream completion**: `report_complete` / `mark_done` deactivates the ledger and
  `close_workstream` moves a stream off `:running`; a stale `focus` on a done ledger/workstream is
  irrelevant (the gate keys off the `:active` ledger / `:running` workstream only). Fresh
  goals/workstreams start unfocused (gate re-engages until `set_focus`).
- **Pi vs Claude parity**: both harnesses advertise + execute `set_focus` / `clear_focus` (with the
  optional `workstream` arg) identically (catalog-derived); the in-process Fake loop too.
- **Migration rollback**: `mix ecto.rollback` drops all four columns cleanly (plain `add`).

## Acceptance Criteria
- A new migration adds nullable `focus` + `focus_set_at` to **both** `task_ledgers` and
  `orchestrator_workstreams`; both schemas' `@type t` and `changeset/2` include them.
- `Ledgers.set_focus/2` / `clear_focus/1` and `Workstreams.set_focus/3` / `clear_focus/2` exist, are
  `@spec`'d, return tagged tuples, and are the only `Repo` paths for the new columns on their tables;
  `Ledgers.view/1` and `Workstreams.index_row/1` + `record/1` surface `focus` + `focus_set_at`.
- `set_focus` / `clear_focus` are real harness-blind tools (in `Tools` + `ToolCatalog`) with an
  optional `workstream` ref, advertised on **both** the MCP `tools/list` and the pi manifest (parity
  test green with the bumped count).
- The deterministic **scope-aware** gate refuses `command_agent` / `create_agent` / `start_adw` with
  `{:error, :focus_required}` exactly when the *targeted scope* is unfocused (its running workstream
  when a `workstream` ref resolves, else the active ledger) and `focus_gate` is enabled, and never
  otherwise; the two scopes are independent; `plan_phases` is never gated; the gate is
  config-toggleable and defaults on.
- The `Driver` issues a focus-first nudge turn for an active-goal-no-focus orchestrator and surfaces
  the orchestrator-level focus in drive prompts; `Queue.rehydrate_line/1` surfaces each workstream's
  focus (or a "set one" marker) every turn.
- The console autonomy panel renders a live `🎯 FOCUS: …` line (`#orchestrator-focus`) **and** each
  Workstreams-panel row renders a live `🎯 FOCUS: …` line (`#workstream-<id>-focus`), driven by the
  existing `ledger_updated` / `workstreams` broadcasts, proven by a `Phoenix.LiveViewTest`.
- The system prompt teaches the two-level focus discipline.
- The full green gate passes with zero regressions and no new Dialyzer warnings or stale ignores.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `scripts/pg.sh start` — ensure the local Postgres cluster is up (once per session).
- `mix ecto.migrate` — apply the new `task_ledgers` + `orchestrator_workstreams` focus migration.
- `mix test test/repo_builder/orchestrator/ledgers_focus_test.exs` — orchestrator-level context.
- `mix test test/repo_builder/orchestrator/workstreams_focus_test.exs` — per-workstream context.
- `mix test test/repo_builder/orchestrator/tools_focus_test.exs` — tool handlers + scope-aware gate.
- `mix test test/repo_builder/orchestrator/driver_focus_test.exs` — focus-first nudge + drive prompt.
- `mix test test/repo_builder/orchestrator/tool_catalog_pi_parity_test.exs` — pi/MCP parity + count.
- `mix test test/repo_builder_web/live/test_orchestrator_focus_test.exs` — LiveView autonomy-panel
  focus rendering.
- `mix compile --warnings-as-errors` — gradual type checker + `warnings_as_errors` clean.
- `mix test --warnings-as-errors` — full ExUnit suite (Postgres-backed) green, zero failures.
- `mix format --check-formatted` — formatting.
- `mix credo --strict` — lint incl. the "`@spec` on every public function" rule.
- `mix dialyzer` — `@spec`/contract checking, no new warnings, no stale ignore filters.

Runtime validation via **Tidewave** (preferred over ad-hoc IEx):
- `project_eval` (orchestrator scope):
  `{:ok, _} = RepoBuilder.Orchestrator.Tools.call("set_focus", oid, %{"focus" => "ship focus gate"})`
  then `RepoBuilder.Orchestrator.Ledgers.view(oid).focus` returns the focus.
- `project_eval` (workstream scope):
  `{:ok, _} = RepoBuilder.Orchestrator.Tools.call("set_focus", oid, %{"workstream" => ws_ref,
  "focus" => "land phase 2"})` then
  `RepoBuilder.Orchestrator.Workstreams.get_workstream(oid, ws_ref)` shows the focus.
- `execute_sql_query`:
  `SELECT focus, focus_set_at FROM task_ledgers WHERE status = 'active';` and
  `SELECT title, focus, focus_set_at FROM orchestrator_workstreams WHERE status = 'running';`
  confirm the persisted columns at both levels.
- `get_logs`: inspect any stacktrace if a tool dispatch errors during manual validation.

## Notes
- **No new dependency.** This reuses the dual ledger **and** the workstream layer, the `ToolCatalog`
  single source of truth, the `Driver` loop, the `Queue` rehydrate index,
  `Dashboard.broadcast_ledger_updated` / `broadcast_workstreams`, and the autonomy + workstreams
  panels.
- **Why two levels (parallel tilldones), not one.** `tilldone.ts` governs a single agent, so one
  focus is faithful for *it*. This platform runs **multiple parallel workstreams** per orchestrator,
  so the faithful port is one focus **per running workstream** (the primary discipline) plus a single
  orchestrator-level focus for untagged work. This mirrors the duality the codebase already
  commits to — `goal` + `definition_of_done` live at both the `TaskLedger` and `Workstream` levels —
  so focus adds no new mental model, only follows the established one. (Option 1 of the design
  discussion; Options "pure per-workstream" and "require-workstream" were rejected for leaving
  untagged work ungated, and for over-committing to mandatory workstreams the platform kept optional,
  respectively.)
- **Open-identity / closed-contract fit (§10).** `set_focus` / `clear_focus` are harness-blind tools
  declared once in `ToolCatalog`; both the Claude MCP surface and the pi manifest derive from it, so
  the new ability appears on every orchestrator-capable harness with no per-adapter edit.
- **Why a denormalized `focus` string, not a new table or a plan-step status.** Both the active
  `TaskLedger` and each `Workstream` row are already fetched on the paths that need focus (drive
  tick, `view/1`, `index_row/1`, rehydrate); a single string column per level is the cheapest
  faithful port of tilldone's "one inprogress task" and avoids fiddly jsonb plan-step mutation. A
  future three-state plan-step lifecycle (idle → in_focus → done) can layer onto phase `stages`
  maps, with these `focus` columns as the denormalized pointer.
- **Back-compat is the main risk.** The gate must engage **only** for goal-driven orchestrators
  (active ledger) or workstream-tagged calls on a `:running` workstream, be scope-independent, and be
  config-toggleable; the Step 11 audit must catch any existing test that commands a worker (tagged or
  untagged) without the matching focus. Defaulting `focus_gate: true` is the higher-value choice; if
  the audit surfaces broad breakage, fall back to `false` by default and enable it in `dev`/the focus
  test — but prefer fixing the handful of tests to `set_focus` first, the intended new contract.
- **Future extension (not in scope).** A `/focus` console overlay (tilldone's interactive overlay), a
  focus-staleness telemetry signal (a focus held too long without progress on that stream), a
  workstream-focus in the worker swimlane header, and wiring `ready_workstreams/1` into an
  autonomous per-workstream driver that auto-nudges each unfocused stream are natural follow-ons.
```
