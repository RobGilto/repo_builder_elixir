# Feature: Unified Harness-Blind Reasoning Effort for the Orchestrator

## Metadata
issue_number: `spec`
adw_id: `this`
issue_json: `out` (interactive request — no GitHub issue)

## Feature Description
Add an operator-controllable **reasoning effort** setting to the orchestrator: a single,
harness-blind enum (`:default | :off | :low | :medium | :high | :max`) that each
orchestrator-capable adapter translates into its native "think harder" CLI flag. The
operator picks one intent ("think harder") in the console Settings; the platform maps it
correctly per harness with **no per-harness UI tabs**.

Web research (firecrawl, 2026-06-17) against the authoritative CLI docs confirms BOTH
harnesses already expose a *declarative* effort flag — so this is a flag-selection seam,
exactly like the `system_prompt_mode` (`--append-system-prompt` vs `--system-prompt`)
feature that shipped immediately before this one:

- **Claude Code CLI** (`code.claude.com/docs/en/cli-reference`): `--effort <level>` with
  `low | medium | high | xhigh | max` (available levels depend on the model). Works in
  print mode; overrides the `effortLevel` setting for the session and does not persist.
  There is **no `--effort off`** — the lowest Claude level is `low`. (The interactive
  "ultrathink" keyword is NOT needed: `--effort` is the programmatic path.)
- **pi CLI** (`github.com/earendil-works/pi` coding-agent README → "Model Options"):
  `--thinking <level>` with `off | minimal | low | medium | high | xhigh`. (pi also accepts
  a `:level` suffix on `--model`, e.g. `sonnet:high`, but `--thinking` is the explicit flag
  we map to.)

Because both harnesses speak the same vocabulary, the operator's intent maps cleanly and
harness-blind, and a future orchestrator-capable harness only needs to map the enum to its
own flag in its adapter — consistent with the §10 "one module" promise.

## User Story
As an **operator driving the orchestration console**
I want to **set how hard the orchestrator's model reasons (off → max) from Settings, once,
regardless of whether it is running on Claude or pi**
So that **I can dial reasoning up for gnarly coordination/debugging and down for cheap,
fast turns, without editing code, learning each harness's flag, or re-setting it every time
I switch harnesses.**

## Problem Statement
The orchestrator currently spawns its harness CLI with no reasoning/effort control: both
`Claude.command/1` and `Pi.command/1` emit no `--effort`/`--thinking` flag, so each harness
silently uses its own default. An operator who wants the orchestrator to "think harder" for
a hard planning turn (or "think less" to save tokens on a trivial one) has no lever. The
capability exists at both CLIs but is neither surfaced nor controllable, and the two
harnesses express it with different flags and slightly different level vocabularies — so a
naive UI would leak harness specifics to the operator.

## Solution Statement
1. Persist a typed `reasoning_effort` `Ecto.Enum` column on the `orchestrators` row
   (default `:default` — meaning "omit the flag; preserve today's exact behavior").
2. Thread `reasoning_effort` through the **mandatory** harness seam: add an optional
   `:reasoning_effort` key to `Harness.start_opts` (it affects EVERY session — workers and
   orchestrator — not just orchestrator tool binding, so `start_opts` is the correct home,
   NOT `Orchestrating.tool_ctx`). The session runtime fills it from the orchestrator row.
3. Teach the **Claude** and **pi** adapters to map the enum to their native flag inside
   `command/1` via a small `@spec`'d private helper each (self-contained per §10). `:default`
   emits no flag (zero regression); the Fake adapter ignores it.
4. Add `@spec`'d context functions on `RepoBuilder.Orchestrators` to set the effort and to
   read a display list, returning tagged tuples — mirroring `set_system_prompt/3`.
5. Add a single **harness-blind** segmented "Reasoning effort" control to the console
   Settings General tab (NOT a per-harness tab); wire the LiveView event/assigns.
6. Cover with a `Phoenix.LiveViewTest` integration test, context unit tests, and adapter
   argv unit tests asserting the correct per-harness flag mapping (and that `:default`
   produces NO flag).

### Why no per-harness tabs (design rationale, locked)
The orchestrator is ONE brain whose intent ("think harder") is harness-independent. Per-harness
horizontal tabs would duplicate state, invite drift, and break the "switching harness preserves
orchestrator-level settings" guarantee already honored by `apply_harness_defaults/2` (it only
touches harness/provider/model/session_id). The *translation* (which flag, which level word) is
an adapter concern behind the seam, never an operator concern. This mirrors `system_prompt_mode`.

## Relevant Files
Use these files to implement the feature:

- `lib/repo_builder/orchestrator/orchestrator.ex` — the durable orchestrator schema/changeset.
  Add the `reasoning_effort` `Ecto.Enum` field, `@type effort`, the `@type t` entry, the
  `cast/3` list, and a defensive `validate_inclusion/3`. (Just added `system_prompt_mode` here
  the same way — follow that exact pattern.)
- `lib/repo_builder/orchestrator.ex` (`RepoBuilder.Orchestrators` context) — the ONLY `Repo`
  caller for orchestrators. Add `set_reasoning_effort/2` (tagged tuple, via `update_fields/2`)
  and `reasoning_efforts/0` (the ordered enum list for the UI). Mirrors `set_system_prompt/3`.
- `lib/repo_builder/harness.ex` — the MANDATORY behaviour. Add `optional(:reasoning_effort) =>
  reasoning_effort()` to `@type start_opts` and a new `@type reasoning_effort ::
  :default | :off | :low | :medium | :high | :max`, documented in the `@typedoc`.
- `lib/repo_builder/session/server.ex` — `build_state/3` + `handle_continue(:spawn)` assemble
  `start_opts` for `command/1`. Add a `reasoning_effort` field to `State` (default `:default`,
  read from `opts[:reasoning_effort]`) and include it in the `start_opts` map. This is the
  single point where the value reaches BOTH worker and orchestrator command builds.
- `lib/repo_builder/orchestrator/server.ex` — `handle_continue(:launch)` builds the opts passed
  to `Session.Supervisor.start_session/1`. Add `reasoning_effort: orchestrator.reasoning_effort`
  so the orchestrator turn carries the operator's choice. (Unchanged: `tool_ctx/2`.)
- `lib/repo_builder/harness/claude.ex` — `command/1`. Append `effort_args(opts[:reasoning_effort])`
  → `["--effort", level]` for `:low/:medium/:high`, `["--effort", "xhigh"]`/`["--effort","max"]`
  for `:max`, and `[]` for `:default`/`:off` (Claude has no `off`; falls back to model default).
  Add an `@spec`'d private helper.
- `lib/repo_builder/harness/pi.ex` — `command/1`. Append `thinking_args(opts[:reasoning_effort])`
  → `["--thinking", level]` mapping `:max → "xhigh"`, `:off → "off"`, `:low/:medium/:high`
  verbatim, and `[]` for `:default`. Add an `@spec`'d private helper (self-contained; do NOT
  cross-module share).
- `lib/repo_builder/harness/fake.ex` — confirm `command/1` ignores unknown `start_opts` keys
  (no change expected; referenced so the Fake LiveView tests still pass).
- `lib/repo_builder_web/live/console_live.ex` — add `orchestrator_reasoning_effort` to the
  initial `mount/3` assigns (default `:default`) and to `assign_orchestrator_selection/2`; add
  a `set_reasoning_effort` handler (reuse `update_orchestrator/3`); add a `@spec`'d
  `reasoning_effort/1` string→atom guard (closed mapping, never `String.to_atom/1` on input,
  mirroring `system_prompt_mode/1`); pass the assign into `<.settings_modal>`.
- `lib/repo_builder_web/components/console_components.ex` — add a `reasoning_effort` attr
  (`:atom`, default `:default`, `values:` the closed set) and the `reasoning_efforts` list attr
  to `settings_modal/1`; render a segmented `cns-toggle` of the levels in the **General** tab
  (`phx-click="set_reasoning_effort"`, `phx-value-effort`) using `<.settings_field>`. Unique ids.
- `lib/repo_builder/harness/registry.ex` — referenced only: confirm `orchestrating?/1` and
  `orchestrator_defaults/1` are untouched (effort is orchestrator-row state, not registry config).
- `test/repo_builder/orchestrators_provider_test.exs` — existing context test; add a describe
  block for `set_reasoning_effort/2` (persist, default, `:not_found`).
- `test/repo_builder/harness/orchestrator_autonomy_test.exs` — existing adapter `command/1`
  tests; reference for how `base_opts/1` builds `start_opts` and how argv assertions are written.
- `test/repo_builder_web/live/test_orchestrator_thinking_toggle_test.exs` — closest Settings-tab
  LiveView test; mirror its structure (`async: false`, `live/2`, `fake` harness, `render_click`).
- `config/test.exs` — registers the `fake` harness used by the LiveView test (no change expected).
- `ai_docs/typed-elixir-standard.md` — the enforced typed standard (the **(always)** conditional-
  docs row): `@spec` on every public function, precise types over `any()`/`map()`, tagged tuples.
- `BUILD_PROMPT.md` §4.2 (mandatory harness behaviour + `start_opts`), §4.3 (per-harness flag
  mapping), §6 (session runtime / where `command/1` is called), §8 (persistence/migrations,
  Enum-as-string), §9 (LiveView/components), §10 (extensibility seam).

### New Files
- `priv/repo/migrations/<timestamp>_add_reasoning_effort_to_orchestrators.exs` — adds
  `reasoning_effort :string NOT NULL DEFAULT 'default'` (Enum-as-string per §8). Generate with
  `mix ecto.gen.migration add_reasoning_effort_to_orchestrators`.
- `test/repo_builder/harness/orchestrator_reasoning_effort_flag_test.exs` — unit test asserting
  `Claude.command/1` and `Pi.command/1` argv select the correct flag per effort level, and that
  `:default` emits neither `--effort` nor `--thinking`.
- `test/repo_builder_web/live/test_orchestrator_reasoning_effort_test.exs` — `Phoenix.LiveViewTest`
  integration test for the new Settings control.

## Implementation Plan
### Phase 1: Foundation
Persist the effort enum and expose it through the typed context and the MANDATORY harness
`start_opts` seam. This is the shared substrate: schema column + migration, the `Orchestrators`
context function, the `start_opts` type extension, and the `Session.Server` + `Orchestrator.Server`
wiring that carries the value from the row to `command/1`.

### Phase 2: Core Implementation
Teach the Claude and pi adapters to map the enum to their native flag (`--effort` / `--thinking`)
inside `command/1`, with `:default` emitting nothing (zero regression). Then build the single
harness-blind "Reasoning effort" segmented control in the General settings tab + the LiveView
event/assigns.

### Phase 3: Integration
Verify the full path (pick effort → persisted on the row → next `run_turn` spawns the harness
with the correct flag → harness honors it) and lock it down with the LiveView test, the adapter
argv tests, and the green gate. Confirm harness switching preserves the effort (orchestrator-level,
not harness-level) and that the disconnected mount render is safe.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Add the `reasoning_effort` column (migration)
- Run `mix ecto.gen.migration add_reasoning_effort_to_orchestrators`.
- In `change/0`: `alter table(:orchestrators) do add :reasoning_effort, :string, null: false,
  default: "default" end`. (Enum stored as `:string` per §8; no DB enum type.)
- Do NOT backfill — the default covers all existing rows and preserves current behavior.

### 2. Extend the orchestrator schema + changeset
- In `lib/repo_builder/orchestrator/orchestrator.ex`:
  - Add `@type effort :: :default | :off | :low | :medium | :high | :max` with a `@typedoc`
    noting it is harness-blind (each adapter maps it; `:default` = omit the flag).
  - Add `reasoning_effort: effort()` to `@type t`.
  - Add `field :reasoning_effort, Ecto.Enum, values: [:default, :off, :low, :medium, :high, :max],
    default: :default`.
  - Add `:reasoning_effort` to the `cast/3` field list.
  - Add `validate_inclusion(:reasoning_effort, [:default, :off, :low, :medium, :high, :max])`
    (defensive; Enum already constrains).

### 3. Add context functions on `RepoBuilder.Orchestrators`
- `@spec set_reasoning_effort(Ecto.UUID.t(), Orchestrator.effort()) :: {:ok, Orchestrator.t()} |
  {:error, :not_found}` — guard `effort in [:default, :off, :low, :medium, :high, :max]`,
  persist via the existing `update_fields/2`.
- `@spec reasoning_efforts() :: [Orchestrator.effort()]` — returns the ordered list
  `[:default, :off, :low, :medium, :high, :max]` (single source of truth for the UI segmented
  control; the changeset/Enum reference the same list).

### 4. Write the context unit test
- In `test/repo_builder/orchestrators_provider_test.exs`, add a `describe "reasoning effort"`:
  - `set_reasoning_effort/2` persists each non-default level (assert `:high`, `:max`).
  - The default for a freshly created orchestrator is `:default`.
  - `{:error, :not_found}` for a bogus id.
  - `reasoning_efforts/0` returns the full ordered list with `:default` first.

### 5. Extend the `Harness.start_opts` contract
- In `lib/repo_builder/harness.ex`: add `@type reasoning_effort :: :default | :off | :low |
  :medium | :high | :max`, add `optional(:reasoning_effort) => reasoning_effort()` to
  `@type start_opts`, and document in the `@typedoc` that adapters map it to their native
  effort/thinking flag and that `:default` means "omit the flag (harness default)".

### 6. Thread the effort through `Session.Server`
- In `lib/repo_builder/session/server.ex`:
  - Add `field :reasoning_effort, atom(), default: :default` to `State`.
  - In `build_state/3`, set `reasoning_effort: opts[:reasoning_effort] || :default`.
  - In `handle_continue(:spawn)`, add `reasoning_effort: state.reasoning_effort` to the
    `start_opts` map handed to `state.adapter.command/1`.

### 7. Pass the effort from `Orchestrator.Server`
- In `lib/repo_builder/orchestrator/server.ex` `handle_continue(:launch)`, add
  `reasoning_effort: orchestrator.reasoning_effort` to the `opts` keyword list passed to
  `Session.Supervisor.start_session/1`. (No change to `tool_ctx/2`.)

### 8. Update the Claude adapter
- In `lib/repo_builder/harness/claude.ex` `command/1`, append `effort_args(opts[:reasoning_effort])`
  to the built args (after model/permission flags). Add an `@spec`'d private helper:
  - `:low → ["--effort", "low"]`, `:medium → ["--effort", "medium"]`, `:high → ["--effort", "high"]`,
    `:max → ["--effort", "max"]`.
  - `:default → []` and `:off → []` (Claude has no `off`; falls back to the model default).
  - `nil → []` (defensive — worker sessions that don't set the key).
- Note in a code comment: available `--effort` levels depend on the model (`xhigh`/`max` may be
  rejected by some models); the operator owns that choice.

### 9. Update the pi adapter
- In `lib/repo_builder/harness/pi.ex` `command/1`, append `thinking_args(opts[:reasoning_effort])`
  to the args (alongside provider/model/approve). Add an `@spec`'d private helper:
  - `:off → ["--thinking", "off"]`, `:low → ["--thinking", "low"]`, `:medium → ["--thinking",
    "medium"]`, `:high → ["--thinking", "high"]`, `:max → ["--thinking", "xhigh"]` (pi's top level).
  - `:default → []` and `nil → []`.

### 10. Write the adapter argv unit test
- Create `test/repo_builder/harness/orchestrator_reasoning_effort_flag_test.exs` (`async: true`):
  - Build a `start_opts` (mirror `base_opts/1` from `orchestrator_autonomy_test.exs`) with each
    `reasoning_effort`, call `Claude.command/1` and `Pi.command/1`, and assert:
    - `:high` ⇒ Claude args contain `["--effort", "high"]` (adjacent); pi args contain
      `["--thinking", "high"]`.
    - `:max` ⇒ Claude `["--effort", "max"]`; pi `["--thinking", "xhigh"]`.
    - `:off` ⇒ pi `["--thinking", "off"]`; Claude contains NO `--effort`.
    - `:default` ⇒ NEITHER `--effort` NOR `--thinking` appears (zero-regression guard).
    - The existing args (`-p`/`--output-format` for Claude, `--mode json` for pi) are preserved.

### 11. Add the LiveView integration test (early UI lock-in)
- Create `test/repo_builder_web/live/test_orchestrator_reasoning_effort_test.exs` (`async: false`,
  mirror the thinking-toggle test):
  - `live(conn, ~p"/")`; assert the General tab renders the reasoning-effort control
    (`#settings-reasoning-effort`) and the `:default` segment is active by default.
  - Click `#settings-reasoning-effort-high` (`phx-click="set_reasoning_effort"`,
    `phx-value-effort="high"`); fetch the default orchestrator via
    `Orchestrators.get_or_create_default()` and assert `reasoning_effort == :high`; assert the
    `high` segment now renders active.
  - Click `#settings-reasoning-effort-default`; assert the row is back to `:default`.

### 12. Extend the `settings_modal` component
- In `lib/repo_builder_web/components/console_components.ex`:
  - Add attrs: `reasoning_effort` (`:atom`, default `:default`, `values: [:default, :off, :low,
    :medium, :high, :max]`) and `reasoning_efforts` (`:list`, default `[]`).
  - In the **General** tab panel, add a `<.settings_field label="Reasoning effort">` containing a
    `cns-toggle` with a button per level: `id={"settings-reasoning-effort-#{e}"}`,
    `phx-click="set_reasoning_effort"`, `phx-value-effort={e}`, active class when
    `@reasoning_effort == e`. Label each segment with the upcased atom. Add one line of help text:
    "How hard the orchestrator's model reasons. DEFAULT keeps each harness's own default."

### 13. Wire LiveView assigns + handler in `console_live.ex`
- Add `orchestrator_reasoning_effort: :default` to the initial `assign(...)` in `mount/3`.
- In `assign_orchestrator_selection/2`, add
  `orchestrator_reasoning_effort: orchestrator.reasoning_effort`.
- Add a handler: `handle_event("set_reasoning_effort", %{"effort" => effort}, socket)` →
  `update_orchestrator(socket, &Orchestrators.set_reasoning_effort(&1, reasoning_effort(effort)),
  "Could not set reasoning effort")`.
- Add a `@spec reasoning_effort(String.t()) :: Orchestrator.effort()` guard with an explicit
  clause per level and `defp reasoning_effort(_), do: :default` (never `String.to_atom/1` on input).
- Pass `reasoning_effort={@orchestrator_reasoning_effort}` and
  `reasoning_efforts={Orchestrators.reasoning_efforts()}` into `<.settings_modal ...>` in `render/1`.

### 14. Run the validation commands
- Run every command in **Validation Commands** and fix any failure until all are green. Confirm
  `mix ecto.rollback` then `mix ecto.migrate` round-trips the new migration cleanly.

## Testing Strategy
### Unit Tests
- **Context (`Orchestrators`)**: `set_reasoning_effort/2` persists each level; default is
  `:default`; `{:error, :not_found}` for unknown id; `reasoning_efforts/0` lists all six with
  `:default` first.
- **Adapters (`Claude`, `Pi`)**: `command/1` emits `--effort <level>` (Claude) / `--thinking
  <level>` (pi) for explicit levels with the correct per-harness level word (`:max` ⇒ Claude
  `max`, pi `xhigh`); `:default` emits no effort/thinking flag at all; `:off` ⇒ pi `off`, Claude
  none; existing argv is preserved.
- **Schema/changeset**: a changeset with an out-of-set `reasoning_effort` is rejected; default is
  `:default`.

### Edge Cases
- `:default` (the default) must produce byte-identical argv to today — no `--effort`/`--thinking`
  (explicit zero-regression test assertion).
- `:off` with Claude → no Claude `off` exists; the adapter omits `--effort` (model default). Assert
  Claude emits no `--effort` for `:off`, while pi emits `--thinking off`. Document the asymmetry.
- `:max` maps to DIFFERENT level words per harness (Claude `max`, pi `xhigh`) — the seam hides this.
- Worker sessions (no `:reasoning_effort` in `start_opts`) → `nil` → helper returns `[]` (no flag);
  the orchestrator-only wiring doesn't regress worker spawns.
- Harness switch (Claude ⇄ pi) preserves `reasoning_effort` (orchestrator-level) —
  `apply_harness_defaults/2` must NOT clear it (verify; it only touches harness/provider/model/
  session_id).
- Disconnected mount render (mount runs twice) must not crash — the initial `assign/2` provides the
  `:default` before `assign_orchestrator/1` runs on the connected socket.
- A model that rejects a high level (e.g. `--effort xhigh` on an unsupported model) surfaces as a
  harness error on the console feed — operator's choice, not a platform bug (documented).

## Acceptance Criteria
- A "Reasoning effort" segmented control (`default/off/low/medium/high/max`) appears in the console
  Settings General tab, defaulting to `default`.
- Selecting a level persists to the `orchestrators` row (verifiable via `Orchestrators.fetch/1`),
  and the next `OrchestratorServer.run_turn/2` spawns the harness with the correct flag:
  `--effort <level>` (Claude) or `--thinking <level>` (pi), with `:max ⇒ xhigh` for pi.
- `default` (the default) spawns with NO `--effort`/`--thinking` flag — existing orchestrators
  behave exactly as before the change (no regression in `command/1` argv).
- Switching the orchestrator harness preserves the chosen reasoning effort.
- No per-harness tabs are introduced; the control is a single harness-blind setting.
- All five green-gate commands pass, plus the new LiveView and unit tests.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix ecto.migrate` — apply the new `reasoning_effort` migration cleanly (then confirm
  `mix ecto.rollback` followed by `mix ecto.migrate` round-trips).
- `mix test test/repo_builder_web/live/test_orchestrator_reasoning_effort_test.exs` — the new
  LiveView integration test passes.
- `mix test test/repo_builder/harness/orchestrator_reasoning_effort_flag_test.exs` — the adapter
  argv unit test passes (including the `:default`-emits-no-flag guard).
- `mix test test/repo_builder/orchestrators_provider_test.exs` — context tests pass (including the
  new reasoning-effort functions).
- `mix compile --warnings-as-errors` — clean compile under the gradual type checker.
- `mix test --warnings-as-errors` — full suite green.
- `mix format --check-formatted` — formatted.
- `mix credo --strict` — lint clean (every new public function has an `@spec`).
- `mix dialyzer` — no new contract warnings, no stale ignore filters (the `start_opts` map-type
  change must keep Claude/pi/Fake `command/1` consistent with the behaviour).

Optional runtime validation via **Tidewave** (`http://localhost:4000/tidewave/mcp`):
- `project_eval`: `RepoBuilder.Orchestrators.get_or_create_default() |> elem(1) |>
  Map.get(:reasoning_effort)` to confirm the persisted value.
- `project_eval`: build a `start_opts` map with `reasoning_effort: :max` and call
  `RepoBuilder.Harness.Claude.command/1` / `RepoBuilder.Harness.Pi.command/1` to eyeball the argv.
- `execute_sql_query`: `select reasoning_effort from orchestrators;` to confirm persistence.
- Optionally screenshot `http://localhost:4000` (Settings → General → Reasoning effort) via the
  Playwright MCP tools as visual proof.

## Notes
- **No new dependencies.** Uses existing Ecto, Phoenix LiveView, and the typed harness contract.
  No `mix.exs` change.
- **Research provenance (firecrawl, 2026-06-17):**
  - Claude `--effort` (`low|medium|high|xhigh|max`, print-mode, overrides `effortLevel`, non-
    persistent, model-dependent levels) from `https://code.claude.com/docs/en/cli-reference`
    ("CLI flags" table). Claude has no `off`; the lowest level is `low`. The interactive
    "ultrathink" keyword is deliberately NOT used — `--effort` is the declarative path.
  - pi `--thinking` (`off|minimal|low|medium|high|xhigh`) from the
    `github.com/earendil-works/pi` coding-agent README "Model Options" (also `--model <id>:<level>`).
- **Unified vocabulary decision:** the enum is the operator-meaningful intersection plus `:default`
  and `:off`, NOT the raw union — `:minimal` is intentionally dropped (folds into `:low`) to keep
  the cross-harness mapping tight and deterministic. `:max` is the single "think as hard as
  possible" intent, mapped to each harness's top level (Claude `max`, pi `xhigh`).
- **`start_opts`, not `tool_ctx`:** reasoning effort is a property of EVERY session (it would apply
  equally to a worker spawn), so it belongs on the mandatory `Harness.start_opts` seam consumed by
  `command/1`, not on the orchestrator-only `Orchestrating.tool_ctx`. This also means the same
  plumbing trivially extends to per-worker effort later.
- **Extensibility (§10):** a future orchestrator-capable harness maps `reasoning_effort` to its own
  flag in its `command/1` and needs ZERO UI or schema changes — the control and column are
  harness-blind. Document the per-harness mapping near each adapter's helper.
- **Future consideration:** a per-worker-tier reasoning effort could reuse the same enum on the
  `agents`/roster (the `agent_models` metadata pattern), letting `fast` run `:low` and `heavy` run
  `:max`. Out of scope here (orchestrator-level only).
- **Companion feature:** this deliberately mirrors the just-shipped `system_prompt_mode`
  append/replace seam — same Enum-as-string column, same `@spec`'d setter, same harness-blind
  flag-selection helper per adapter, same single-control (no per-harness tab) UI philosophy.
```
