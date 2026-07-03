# Chore: ADW Builder — expose all prompts as selectable step options, and auto-populate a saved combo in the Load-combo list

## Metadata
issue_number: `adw-builder-prompt-steps`
adw_id: `adw-prompt-step-picker`
issue_json: `null` (freeform operator request captured from the ⌘K ADW Builder in ConsoleLive)

## Chore Description
Two operator asks against the ⌘K command modal's **ADW BUILDER** mode
(`console_components.ex` → `global_command_input/1`, the `@adw_builder?` branch):

1. **All prompts should be selectable as step options.** Today the **ADD STEP** palette
   (`console_components.ex:4228-4239`) is hardcoded to the seven canonical steps
   `~w(plan patch build test review document ship)`. The operator wants **every discovered
   prompt / slash-command** (the same file-driven set already listed as `SLASH` chips in the
   COMMAND-mode palette and threaded into the component as `@slash_commands`) to be pickable as
   a step, **the same way the ADW section already surfaces its discovered artifacts**. A step
   built from an arbitrary `/command` must (a) **launch** correctly and (b) be **saveable** as a
   combo + materialized ADW script.

2. **A newly-created ADW must populate in the list.** When the operator clicks **Save combo**,
   the just-created ADW should appear **and be selected** in the **LOAD COMBO** `<select>`
   immediately, without reopening the modal.

### Why each ask is currently unmet
- **Ask 1 — launch already works, save does not.** Arbitrary step names already render sane
  prompts on launch via the catch-all `Catalog.default_prompt_template/1`
  (`catalog.ex:197`), and the UI helpers `adw_step_command/1` (`console_components.ex:4552`)
  and `adw_step_hint/1` (`console_components.ex:4576`) already fall through for custom names.
  But the palette never *offers* those commands, and the **save path rejects them**:
  - `console_live.ex:1690` coerces every step via `String.to_existing_atom(s.name)` — a
    slash-command whose atom was never created raises `ArgumentError`.
  - `RepoBuilder.Adw.Scaffold` enforces a seven-atom allowlist
    (`scaffold.ex:36` `@valid_steps`, checked in `scaffold.ex:129`), so a non-canonical step
    returns `{:error, {:invalid_step, bad}}` and `Combos.save/2` fails.
  - There **is** a generic runner already in the tree — `adws/adw_slash_command.py` — which the
    generated script can chain for any non-canonical `/command`, so materialization stays
    faithful to the existing composites.
- **Ask 2 — the entry lands unselected (or the save fails).** `adw_save_combo`
  (`console_live.ex:1697-1704`) re-assigns `adw_combos: Combos.list(working_dir)` but **never
  sets `adw_selected_combo`**, so the new combo appears in the dropdown but is not the active
  selection. And when the build contains a custom-prompt step, the save fails per Ask 1, so
  **nothing** populates. Fixing Ask 1 (saveable custom steps) + auto-selecting the saved combo
  resolves this.

## Relevant Files
Use these files to resolve the chore:

- `lib/repo_builder_web/components/console_components.ex` — the ⌘K modal.
  - `global_command_input/1` `@adw_builder?` branch: the **ADD STEP** palette
    (`~4228-4239`) is where the discovered-prompt chips are added; the **LOAD COMBO** `<select>`
    (`~4160-4193`, gated `:if={@adw_combos != []}`) is where the saved combo must appear.
  - The component already receives `@slash_commands` (declared alongside the other palette
    assigns; passed at the `<.global_command_input …>` call site) and normalizes it via
    `palette_chips(:slash_command, …)` (`~4417`) — reuse this list/shape for the step chips.
  - `adw_step_command/1` (`~4549-4552`) and `adw_step_hint/1` (`~4555-4576`) already fall
    through for non-canonical names — reuse; no change required beyond confirming labels read well.
- `lib/repo_builder_web/live/console_live.ex` — builder state + handlers.
  - `adw_add_step` (`1586-1591`) already accepts any `step` string — no change needed for launch.
  - `launch_adw_builder/4` (`2415-2437+`) already derives a real `prompt_template` per step via
    the `Catalog` catch-all — confirm it stays correct for custom steps.
  - `adw_save_combo` (`1675-1714`): stop coercing with `String.to_existing_atom` (`1690`) and add
    `adw_selected_combo: combo.name` to the `{:ok, combo}` assign (`~1701`) — **this is the Ask-2 fix**.
  - `adw_load_combo` (`1722-1753`) rebuilds step rows from `{atom, prompt}` via `Atom.to_string`
    (`1731`) — must round-trip the new generic-slash step representation.
  - `@slash_commands` is assigned in `assign_definitions` (`~678`) and refreshed by the
    `{:definitions_changed, :slash_command, …}` handler (`~3084`) — the step palette is driven by
    the same list, so it auto-refreshes with the palette.
  - The `<.global_command_input …>` call site (`~4048-4061`) already passes `slash_commands`,
    `adw_combos`, `adw_selected_combo` — no new assign plumbing needed unless a filtered
    step-source list is introduced.
- `lib/repo_builder/workflow_engine/catalog.ex` — `default_prompt_template/1` (`179-197`); the
  catch-all clause (`197`) already covers custom `/command` steps on launch. Extend only if a
  smarter default (e.g. embedding the command name) is wanted.
- `lib/repo_builder/adw/scaffold.ex` — the deterministic Python-ADW generator.
  `@type step` (`21`), `@valid_steps` (`36`), the allowlist check (`~129`), and the `_iso` /
  `_local_iso` template bodies. Must learn to emit a **generic slash-command step** (chaining
  `adws/adw_slash_command.py`) for any non-canonical `/command`, alongside the existing per-step
  `adw_<step>_iso.py` chaining for canonical steps.
- `lib/repo_builder/adw/combo.ex` — `RepoBuilder.Adw.Combo` typedstruct + `parse_steps/1`
  (`~130`), `validate/1`, `to_json/1`, `from_json/1`. The step element type
  `{Scaffold.step(), String.t() | nil}` must widen to also carry a generic slash step
  (e.g. `{:slash, command} | canonical_atom`) so custom steps round-trip through the JSON sidecar.
- `lib/repo_builder/adw/combos.ex` — `save/2` (`80-114`) / `list/1` (`33-48`); no signature change
  expected — it delegates step handling to `Combo`/`Scaffold`. Confirm a custom-step combo saves,
  lists, and round-trips.
- `adws/adw_slash_command.py` — the **existing generic slash runner**; read its CLI/arg contract
  (positional args + `--prompt`/`--emit`) so the `Scaffold` template chains it with the exact
  argument shape the other `adw_*_iso.py` scripts use.
- `adws/adw_new.py` — `VALID_STEPS` + `make_script/3`; the `_iso` golden reference. The generic
  slash step is an **extension** of this style, not a divergence — keep byte-parity for the
  canonical-only case so the existing golden fixture still matches.
- `adws/adw_plan_build_iso.py` — ground-truth GitHub composite; the chaining shape the generic
  step must mirror (`subprocess.run([sys.executable, str(SCRIPT_DIR / "adw_<x>.py"), issue_number, adw_id])`).
- `test/repo_builder/adw/scaffold_test.exs` — extend with a generic-slash-step render case
  (asserts the generated script chains `adw_slash_command.py` for a `/command`, and that the
  canonical-only render still equals the committed golden fixture).
- `test/repo_builder/adw/combos_test.exs` — extend with a custom-step save/list/fetch round-trip.
- `test/repo_builder_web/live/test_adw_builder_combos_test.exs` — extend the LiveView integration
  test: assert a discovered slash-command chip renders in ADD STEP, adding it + Save combo
  populates AND selects it in LOAD COMBO (`adw_selected_combo`), and Load repopulates the step.

### New Files
- `test/support/fixtures/adw/adw_slash_demo_iso.py.golden` (only if a golden-parity assertion for
  a mixed canonical+slash combo is added) — expected generated script for a
  `[:plan, {:slash, "commit"}]`-style build; keeps the generic-step template from silently drifting.

### Conditional docs consulted (per `.claude/commands/conditional_docs.md`)
- **(always)** `ai_docs/typed-elixir-standard.md` — `@spec`, typedstruct, tagged tuples, wire-vs-domain,
  no `map()`/`any()`; the `Scaffold.step()` / `Combo` step-type widening must stay typed.
- `BUILD_PROMPT.md` §9 + `AGENTS.md` — LiveView dashboard + Phoenix 1.8/LiveView guidelines (the modal UI work).
- `BUILD_PROMPT.md` §7 + `ai_docs/adw-orchestration.md` — the workflow/ADW engine, step state machine, `inputs`/artifacts.
- `BUILD_PROMPT.md` §6 + `ai_docs/adw-primitives.md` — the portable ADW / `start_adw` adapter contract.
- `adws/README.md` — the Astral `uv` single-file-script conventions any generated/edited script obeys.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Model a generic slash-command step (shared type foundation)
- In `lib/repo_builder/adw/scaffold.ex`, widen the step type from the seven-atom allowlist to
  `@type step :: :plan | :patch | :build | :test | :review | :document | :ship | {:slash, String.t()}`.
- Keep `@valid_steps` (the canonical atoms) and `valid_steps/0` as-is for the palette/UI, but change
  the validation (`~129`) to **accept** a `{:slash, name}` element (reject only truly malformed
  values: blank/invalid slash names, or a bare unknown atom). Never raise — return
  `{:error, {:invalid_step, bad}}` for genuinely bad input.
- Add a private helper `command_slug/1` that maps a slash name to a safe token
  (strip a leading `/`, dashes/underscores allowed, reject path separators / empties).

### 2. Teach `Scaffold` to materialize a generic slash step
- Read `adws/adw_slash_command.py` and note its exact CLI contract.
- In the `_iso` (chaining) template: for a canonical step emit the existing
  `subprocess.run([sys.executable, str(SCRIPT_DIR / "adw_<step>_iso.py"), issue_number, adw_id])`
  block (unchanged); for a `{:slash, cmd}` step emit the equivalent block chaining
  `adw_slash_command.py` with the command name, matching the arg shape the other composites use.
- In the `_local_iso` (monolithic) template: route a `{:slash, cmd}` step through the same
  local runner path the canonical steps use, passing the `/command` through (do NOT invent a new
  local contract — reuse `workflow_ops`/`run_local_workflow` semantics already relied on).
- Preserve **byte-parity** for the canonical-only case so the existing golden fixture
  (`test/support/fixtures/adw/adw_plan_build_review_iso.py.golden`) still matches.

### 3. Round-trip generic steps through `Combo`
- In `lib/repo_builder/adw/combo.ex`, widen the step element type used by `parse_steps/1`,
  `to_json/1`, and `from_json/1` to carry either a canonical atom or `{:slash, name}` plus the
  optional custom prompt: `{Scaffold.step(), String.t() | nil}`.
- Encode a slash step to JSON as a stable wire form (e.g. `%{"kind" => "slash", "command" => name}`
  or `"slash:<name>"`) and decode it back; keep canonical steps encoded exactly as today (no
  migration of existing sidecars). Blank prompt → `nil` per rule 6 (wire vs domain).
- `validate/1` must accept the widened steps and still reject empty/invalid.

### 4. Fix the save handler (stop the atom coercion; wire generic steps) — Ask 1 (save)
- In `lib/repo_builder_web/live/console_live.ex` `adw_save_combo` (`1675-1714`), replace
  `String.to_existing_atom(s.name)` (`1690`) with a total mapper: a name in
  `Scaffold.valid_steps()` (compare as strings) becomes the canonical atom; any other name becomes
  `{:slash, s.name}`. Never call `String.to_existing_atom` on operator-supplied text.
- Keep passing `{step, s[:prompt]}` pairs so custom per-step prompts persist.

### 5. Auto-select the saved combo in the list — Ask 2
- In the same `{:ok, combo}` branch (`~1699-1704`), add `adw_selected_combo: combo.name` to the
  `assign(...)` (keeping `adw_combos: Combos.list(working_dir)`), so the LOAD COMBO `<select>`
  shows the new combo **selected** immediately. The `:if={@adw_combos != []}` gate is now satisfied,
  so the dropdown renders on the first save.
- Confirm `adw_load_combo` (`1722-1753`) rebuilds a `{:slash, name}` step into a step row with the
  correct string `name` (extend the `Atom.to_string(step_name)` mapping at `1731` to handle the
  tuple form → the bare command string) so a loaded custom combo re-renders its steps.

### 6. Surface all prompts in the ADD STEP palette — Ask 1 (UI)
- In `lib/repo_builder_web/components/console_components.ex`, in the `@adw_builder?` ADD STEP block
  (`~4223-4240`), keep the seven canonical chips, then render a second labelled group (e.g.
  `PROMPTS`) of chips built from `@slash_commands` — mirroring the COMMAND-mode `SLASH` palette so
  base + project commands both appear. Each chip fires `phx-click="adw_add_step"` with
  `phx-value-step={cmd.name}` and a `title` explaining it runs `/<name>`.
- De-duplicate: if a discovered command name collides with a canonical step name, show it once
  (prefer the canonical chip). Reuse `palette_chips(:slash_command, @slash_commands)` /
  `source_chips/3` so the `wd` (working-dir) badge and descriptions render consistently.
- No new assign is required — `@slash_commands` is already passed to the component.

### 7. Confirm the launch path for custom steps
- Verify `launch_adw_builder/4` (`2415-2437`) produces a non-empty `prompt_template` for a custom
  step via `Catalog.default_prompt_template/1` (catch-all at `catalog.ex:197`), and that the step
  chaining (`on_success` = next step name) is unaffected by non-canonical names. Adjust the
  catch-all only if a per-command default reads better than the generic `"Work on: {{input}} …"`.

### 8. Tests
- `test/repo_builder/adw/scaffold_test.exs`: add a render case for a build containing a
  `{:slash, "commit"}` step — assert the generated `_iso` chains `adw_slash_command.py`, the
  `_local_iso` routes it through the local runner, invalid slash names return `{:error, …}` and
  never raise, and the canonical-only render still equals the committed golden fixture.
- `test/repo_builder/adw/combos_test.exs`: add a custom-step combo `save/2` → `list/1` → `fetch/2`
  round-trip under an app-env tmp root (asserts the sidecar encodes/decodes the slash step).
- `test/repo_builder_web/live/test_adw_builder_combos_test.exs`: open the builder, assert a
  discovered slash-command chip renders in ADD STEP; `render_click("adw_add_step", %{"step" => …})`,
  set a name, `render_click("adw_save_combo")`; assert the LOAD COMBO option list includes the combo
  **and** `adw_selected_combo` equals it (Ask 2); then `render_change("adw_load_combo")` repopulates
  the step rows (Ask 1 round-trip).

### 9. Runtime verification via Tidewave (optional, app running)
- `RepoBuilder.Adw.Scaffold.render(%{name: "demo_slash", steps: [:plan, {:slash, "commit"}], flavor: :iso, …})`
  → `{:ok, script}` containing the `adw_slash_command.py` chain; `RepoBuilder.Adw.Combos.save(%{…})`
  → `{:ok, _}`, and `RepoBuilder.Definitions.list(:adw, nil)` includes the new stem.
- Use `get_logs` if any launch path errors; `get_docs`/`get_source_location` for exact-version
  Phoenix/LiveView APIs.

### 10. Run the full Validation Commands
- Execute every command in **Validation Commands** and fix any failure or regression until green.

## Validation Commands
Execute every command to validate the chore is complete with zero regressions.

- `mix test test/repo_builder/adw/scaffold_test.exs` - generator parity + generic-slash-step render.
- `mix test test/repo_builder/adw/combos_test.exs` - custom-step combo save/list/fetch round-trip.
- `mix test test/repo_builder_web/live/test_adw_builder_combos_test.exs` - ADD STEP prompt chips,
  Save-combo populate+select, Load-combo repopulate.
- `mix compile --warnings-as-errors` - Compile clean; the gradual set-theoretic type checker and `warnings_as_errors` must pass.
- `mix test --warnings-as-errors` - Run the full ExUnit suite with zero failures.
- `mix format --check-formatted` - Ensure code is formatted.
- `mix credo --strict` - Lint, including the "every public function has an `@spec`" convention.
- `mix dialyzer` - `@spec`/contract checking with no new warnings.

## Notes
- **This chore builds directly on the just-implemented ADW Builder Combos feature** (uncommitted
  WIP: `lib/repo_builder/adw/{combo,combos,scaffold}.ex`, the `@adw_builder?` UI, and the three combo
  tests). It is a follow-up refinement, not a from-scratch build.
- **No new mix deps and no new Python deps.** Ask 1's materialization reuses the existing generic
  `adws/adw_slash_command.py`; the generator stays pure Elixir and inside the green gate.
- **Ask 2 is a two-line behavioral fix** (`adw_selected_combo: combo.name` on save + stop
  `String.to_existing_atom`), but it only *fully* works once Ask 1 makes custom-step combos
  saveable — otherwise a build containing a prompt step fails to save and nothing populates.
- **Keep the canonical-step golden fixture green.** The generic slash step must be additive; a
  plan/build/review-only combo must still render byte-for-byte identical to today so
  `adw_plan_build_review_iso.py.golden` (and `adw_new.py` parity) do not drift.
- **Typed throughout.** Widen `Scaffold.step()` and the `Combo` step element to a proper union
  (`… | {:slash, String.t()}`) rather than reaching for `map()`/`any()`, per
  `ai_docs/typed-elixir-standard.md`.
- **Out of scope:** an "overwrite" affordance on Save; committing/gitignoring `adws/.combos/`;
  migrating shipped hand-written composites onto a shared runner. Track separately.
```