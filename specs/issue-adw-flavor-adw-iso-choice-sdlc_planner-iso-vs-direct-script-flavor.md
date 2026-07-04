# Feature: Choose Between Iso and Non-Iso (Direct) ADW Scripts

## Metadata
issue_number: `adw-flavor`
adw_id: `iso-choice`
issue_json: `{"title":"Option to choose between iso and non-iso scripts","body":"When saving an ADW combo, let the operator pick the generated script flavor: isolated (iso) vs non-isolated (direct/in-place), instead of only the binary local toggle.","adw_id":"iso-choice"}`

## Feature Description
The ADW Builder in the console (`⌘K` → **ADW**) currently materializes a portable Python
script when the operator clicks **⭑ Save combo**. Today the only choice is a binary **local**
toggle that flips between exactly two *isolated* flavors:

- `:iso` — `adws/adw_<name>_iso.py`: chains `adw_<step>_iso.py` sub-scripts via subprocess,
  threads state through `adw_state.json`, runs each phase in an **isolated git worktree**, and
  requires a GitHub issue number.
- `:local_iso` — `adws/adw_<name>_local_iso.py`: monolithic, GitHub-optional (single `<adw-id>`
  + `agents/<adw-id>/run.json` contract), but still runs in an **isolated git worktree** via
  `adw_modules.workflow_ops.run_local_workflow`.

Both existing flavors are "iso" — they always create a throwaway worktree/branch. There is no
way to generate a **non-iso** script that runs the workflow *directly in the current checkout*
(in place, on the current branch, no worktree). This feature adds a third flavor, `:direct`,
and replaces the binary **local** toggle with a three-way **flavor selector** (Iso / Local iso /
Direct) so the operator explicitly chooses the isolation model of the generated script.

The `:direct` flavor produces `adws/adw_<name>_direct.py`: a monolithic script that reuses the
same single-`<adw-id>` + `run.json` launch contract as `:local_iso`, but delegates to
`run_local_workflow(..., isolated=False)`, which runs the ordered steps against the current
working directory instead of creating a worktree.

## User Story
As an operator building a custom ADW combo in the console
I want to choose whether the generated script runs isolated (iso) or directly in the current checkout (non-iso)
So that I can generate lightweight in-place workflows for trusted/local repos without the overhead of a throwaway worktree, while still being able to opt into worktree isolation when I need it.

## Problem Statement
The builder only exposes a binary `local` toggle mapping to two *isolated* flavors. Operators
who want a workflow that mutates the current checkout in place (no worktree, no branch, no
merge-to-trunk) have no way to generate one from the UI. The isolation model is an implicit
consequence of the "local" boolean rather than an explicit, discoverable choice, and the third
useful mode (non-iso / direct) does not exist at all in the generator, the domain model, or the
Python runner.

## Solution Statement
Introduce a third script flavor `:direct` end-to-end:

1. **Domain** (`RepoBuilder.Adw.Combo`): widen `flavor()` to `:iso | :local_iso | :direct`, and
   parse/serialize the `"direct"` wire string.
2. **Generator** (`RepoBuilder.Adw.Scaffold`): add the `_direct` filename suffix, a `:direct`
   branch in `render/1`/`flavor/1`, and a `render_direct/2` template that emits a monolithic
   script delegating to `run_local_workflow(adw_id, STEPS, logger, isolated=False)`.
3. **Context** (`RepoBuilder.Adw.Combos`): canonicalize the incoming flavor (including `:direct`)
   so `save/2` materializes `adw_<name>_direct.py`.
4. **Python runner** (`adws/adw_modules/workflow_ops.py`): add an `isolated: bool = True`
   parameter to `run_local_workflow/…` that, when `False`, skips `_local_setup_worktree` and runs
   every step against the repo root (current checkout), and makes the `ship` step a direct commit
   on the current branch (no worktree merge).
5. **UI** (`AdwBuilderComponents` + `AdwBuilderPanel` + `ConsoleLive`): replace the `adw_local?`
   boolean assign and single **local** toggle button with an `adw_flavor` atom assign
   (`:iso | :local_iso | :direct`) rendered as a three-way segmented selector, wiring save/load
   to the chosen flavor.

This keeps the "context owns all I/O", typed-tagged-tuple, and byte-parity-tested doctrines
intact. The existing `GeneratedDriftTest` covers `:direct` sidecars automatically because it
renders from `combo.flavor`. No new dependency is required.

## Relevant Files
Use these files to implement the feature:

- `lib/repo_builder/adw/combo.ex` — Typed domain value + JSON wire parse/serialize/validate for a
  saved combo. `flavor()` type, `@flavors` string→atom map, and `parse_flavor/1` must learn
  `:direct`.
- `lib/repo_builder/adw/scaffold.ex` — Deterministic Python generator. Needs the `_direct` suffix
  in `script_path/3`, a `:direct` clause in `render/1` and `flavor/1`, and a new `render_direct/2`
  template (a near-twin of `render_local_iso/2` that passes `isolated=False`).
- `lib/repo_builder/adw/combos.ex` — Filesystem context that calls `Scaffold.generate/1`.
  `flavor_of/1` must canonicalize `:direct`/`"direct"` (today it only distinguishes local vs iso).
- `lib/repo_builder/definitions/adw.ex` — Discovery of `adws/adw_*.py`. The glob `adws/adw_*.py`
  already matches `adw_<name>_direct.py`; verify no changes needed (documentation touch only).
- `lib/repo_builder_web/components/console/adw_builder_components.ex` — The `global_command_input`
  function component. Replace the `adw_local?` attr + the single **local** `<button>` (around
  line 301–308) with an `adw_flavor` attr and a three-way segmented selector.
- `lib/repo_builder_web/live/console_live/adw_builder_panel.ex` — Panel event handlers. Replace
  `adw_toggle_local` with `adw_set_flavor` (`%{"flavor" => ...}`), read `adw_flavor` in
  `adw_save_combo`, and set `adw_flavor` in `adw_load_combo` (from `combo.flavor`).
- `lib/repo_builder_web/live/console_live.ex` — Mount defaults (line ~272–281) and the
  `<.global_command_input>` invocation (line ~2112–2127). Swap `adw_local?: false` for
  `adw_flavor: :iso` and pass `adw_flavor={@adw_flavor}`.
- `adws/adw_modules/workflow_ops.py` — `run_local_workflow/…` and `_local_setup_worktree/…`.
  Add the `isolated` parameter and the in-place (non-worktree) execution path + direct-commit ship.
- `test/repo_builder/adw/scaffold_test.exs` — Add `:direct` render + generate coverage.
- `test/repo_builder/adw/combo_test.exs` (create if absent; see New Files) or existing combo tests
  — Add `parse_flavor("direct")` / round-trip coverage.
- `test/repo_builder/adw/combos_test.exs` — Add a `save(flavor: :direct)` → `adw_<name>_direct.py`
  case.
- `test/repo_builder/adw/generated_drift_test.exs` — No change required; confirm it stays green
  with a `:direct` combo present (it renders from `combo.flavor`).

### New Files
- `test/repo_builder_web/live/test_adw_flavor_selector_test.exs` — `Phoenix.LiveViewTest`
  integration test that mounts `ConsoleLive`, opens the ADW Builder, selects the **Direct**
  flavor, adds a step, saves the combo, and asserts the generated `adw_<name>_direct.py` script is
  written and the success flash names it. Uses the `Application.get_env(:repo_builder,
  RepoBuilder.Adw.Combos)[:root]` tmp-root test seam so no real repo file is written.
- `test/repo_builder/adw/combo_flavor_test.exs` — (Optional, only if the existing combo test module
  does not already have a natural home) focused unit tests for `Combo.parse_flavor/1` and
  `Combo.from_json/1`/`to_json/1` round-trips including `:direct`.

## Implementation Plan
### Phase 1: Foundation
Widen the typed domain and generator to know a third flavor without changing any UI yet. This is
the shared substrate: `Combo.flavor()`, `Scaffold.flavor/1`/`script_path/3`/`render/1`, and
`Combos.flavor_of/1`. Everything is `@spec`'d, returns tagged tuples, and never raises. Because
the drift gate renders from `combo.flavor`, the generator template for `:direct` must be
deterministic and self-consistent from day one.

### Phase 2: Core Implementation
Add the `render_direct/2` template (monolithic, single-`<adw-id>` contract, `isolated=False`) and
the Python-side `isolated` parameter in `run_local_workflow` so a generated `_direct.py` script
actually runs in place. Add the generator/context unit tests.

### Phase 3: Integration
Replace the binary `local` toggle with the three-way `adw_flavor` selector across the component,
the panel event handlers, and the `ConsoleLive` mount + invocation. Add the LiveView integration
test and run the full validation gate.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Widen the domain flavor in `RepoBuilder.Adw.Combo`
- Change `@type flavor :: :iso | :local_iso` to `@type flavor :: :iso | :local_iso | :direct`.
- Add `"direct" => :direct` to the `@flavors` map.
- Extend `parse_flavor/1`: the atom guard `when flavor in [:iso, :local_iso]` becomes
  `when flavor in [:iso, :local_iso, :direct]`; the binary clause already handles the map lookup.
- No change needed to `to_json/1` (`Atom.to_string(combo.flavor)` already serializes `:direct`).
- Confirm `validate/1` still routes through `parse_flavor/1` (it does).

### 2. Add the `:direct` flavor to `RepoBuilder.Adw.Scaffold`
- `@type flavor :: :iso | :local_iso` → add `| :direct`; likewise the `request()`/`flavor/1`
  typespecs.
- `script_path/3`: replace the two-way suffix with a case:
  `:local_iso -> "_local_iso"`, `:direct -> "_direct"`, `_ -> "_iso"`.
- `flavor/1`: add `defp flavor(:direct), do: {:ok, :direct}` (or widen the `in` guard).
- `render/1`: add `:direct -> {:ok, render_direct(stem, steps)}` to the case.
- Add `render_direct/2`: copy `render_local_iso/2`, then change:
  - `script_name = "adw_#{stem}_direct.py"`, `workflow_name = "adw_#{stem}_direct"`.
  - Docstring title suffix "Direct" and a one-line note that it runs in the **current checkout
    (no worktree)** and makes ZERO GitHub calls; keep the "run record IS the task context" note.
  - The runner call becomes `run_local_workflow(adw_id, STEPS, logger, isolated=False)`.
  - Keep the identical single-`<adw-id>` CLI contract, `check_env_vars`, and `local_ops.load_run`
    guard as `render_local_iso/2`.
- Keep `render_direct/2` deterministic (pure string) so `mix test` fully covers it.

### 3. Canonicalize `:direct` in `RepoBuilder.Adw.Combos.flavor_of/1`
- Rewrite `flavor_of/1` to a total canonicalizer over both atom and string keys:
  - `:direct` / `"direct"` → `:direct`
  - `:local_iso` / `"local_iso"` → `:local_iso` (or `local: true` → `:local_iso`, preserved)
  - everything else → `:iso`.
- Update the `get/2` typespec key union if a new key is referenced (none expected).

### 4. Unit-test the generator + domain (Phase 1/2 gate)
- In `test/repo_builder/adw/scaffold_test.exs` add a `describe "render/1 :direct"` block asserting
  the rendered script:
  - `=~ "Usage: uv run adw_<stem>_direct.py <adw-id>"`
  - `=~ "run_local_workflow(adw_id, STEPS, logger, isolated=False)"`
  - `=~ ~s(STEPS = ["plan", "build"])`
  - `refute =~ "issue_number"` and `refute =~ "subprocess.run"` (monolithic, non-chaining).
  - a `generate/1` case asserting `Path.basename(gen.path) == "adw_<stem>_direct.py"` and mode
    `0755`.
- In the combo test module (existing `combos_test.exs` or new `combo_flavor_test.exs`) assert
  `Combo.parse_flavor` accepts `"direct"`, `from_json`/`to_json` round-trip `:direct`, and
  `Combos.save(valid(%{name: "direct demo", flavor: :direct}))` materializes
  `adw_direct_demo_direct.py`.

### 5. Add the Python `isolated` execution path in `adws/adw_modules/workflow_ops.py`
- Change `def run_local_workflow(adw_id: str, steps: list, logger)` →
  `def run_local_workflow(adw_id: str, steps: list, logger, isolated: bool = True)`.
- When `isolated` is `True`: behavior is byte-identical to today (calls `_local_setup_worktree`).
- When `isolated` is `False`:
  - Skip `_local_setup_worktree`; set `worktree_path` to the repo root (`os.path.dirname(script_dir)`
    equivalent — resolve the project root the same way the ship block does today) and do NOT create
    a branch/ports. Persist `branch_name = None`, `worktree_path = <root>` in state so downstream
    step ops (`build_plan(..., working_dir=...)`, etc.) target the current checkout.
  - The `ship` step must NOT merge a worktree branch: in direct mode, commit pending changes in
    place on the current branch (reuse `_commit_pending`) and skip `merge_branch_into_trunk`.
  - Narrate "running in place (no worktree)" instead of the worktree-ready message.
- Keep the default-argument at `True` so `adw_<name>_local_iso.py` (which calls
  `run_local_workflow(adw_id, STEPS, logger)`) is entirely unchanged. Only the generated
  `_direct.py` passes `isolated=False`.
- This is deterministic Elixir-tested at the render layer; the live `uv` execution stays under the
  existing `:external` manual smoke (note it in Validation Commands as optional).

### 6. Replace the binary toggle with a flavor selector in the component
- `adw_builder_components.ex`: replace `attr :adw_local?, :boolean, default: false` with
  `attr :adw_flavor, :atom, default: :iso, values: [:iso, :local_iso, :direct]`.
- Replace the single **local** `<button phx-click="adw_toggle_local">` (≈ line 301–308) with a
  three-chip segmented control, each chip `phx-click="adw_set_flavor" phx-value-flavor="iso" |
  "local_iso" | "direct"`, applying `cns-chip--active` when `@adw_flavor == <that>`. Labels:
  **Iso**, **Local iso**, **Direct**; titles: "Isolated worktree — GitHub issue required",
  "Isolated worktree — no GitHub issue", "In-place (no worktree) — runs in the current checkout".
- Update the `Save combo` comment block (≈ line 487–489) to mention `_direct.py` alongside `_iso`
  /`_local_iso`.

### 7. Wire the flavor through the panel handlers
- `adw_builder_panel.ex`:
  - Replace `adw_toggle_local` in `@events` with `adw_set_flavor`.
  - Replace the `handle_event("adw_toggle_local", …)` clause with
    `handle_event("adw_set_flavor", %{"flavor" => f}, socket)` that maps the string to
    `:iso | :local_iso | :direct` via a small fixed map (never `String.to_atom/1`), defaulting to
    `:iso` on an unknown value, and assigns `adw_flavor`.
  - In `adw_save_combo`, read `%{adw_flavor: flavor}` instead of `adw_local?`, and set
    `flavor: flavor` directly in `attrs` (drop the `if local?, do: :local_iso, else: :iso`).
  - In `adw_load_combo`, set `adw_flavor: combo.flavor` instead of
    `adw_local?: combo.flavor == :local_iso`.

### 8. Update `ConsoleLive` mount + invocation
- `console_live.ex`: change mount default `adw_local?: false` → `adw_flavor: :iso`.
- Change the `<.global_command_input>` prop `adw_local?={@adw_local?}` → `adw_flavor={@adw_flavor}`.
- Grep the module for any other `adw_local?` reference and migrate it (there should be none beyond
  these two).

### 9. Create the LiveView integration test
- Create `test/repo_builder_web/live/test_adw_flavor_selector_test.exs` using
  `Phoenix.LiveViewTest`:
  - Set the `RepoBuilder.Adw.Combos` `:root` app env to a per-test tmp dir (mirror
    `test_adw_builder_save_combo_test.exs`) and restore/clean on exit.
  - `live/2` the console, open the builder (`render_click` the **ADW** toggle), select **Direct**
    (`render_click` the flavor chip with `phx-value-flavor="direct"`), add a `plan` step, set the
    name, then `render_click` **⭑ Save combo**.
  - Assert the flash contains `adw_<name>_direct.py` and that
    `File.exists?(Path.join([tmp, "adws", "adw_<name>_direct.py"]))`.
  - Assert the saved combo (`Combos.fetch(name, tmp)`) has `flavor: :direct`.
- Follow the existing save-combo test for the exact selectors/seed helpers.

### 10. Run the full validation gate
- Execute every command in **Validation Commands**; fix any compile/type/format/credo/dialyzer or
  test failure until all are green with zero regressions.

## Testing Strategy
### Unit Tests
- **Scaffold**: `render/1 :direct` emits the monolithic `_direct` script with
  `isolated=False`, correct `STEPS`, correct usage line, and NO chaining/`issue_number`;
  `generate/1` writes `adw_<stem>_direct.py` at `0755` and refuses to clobber without `overwrite`.
- **Combo**: `parse_flavor("direct")` → `{:ok, :direct}`; `from_json`/`to_json` round-trip a
  `:direct` combo; `validate/1` accepts `flavor: :direct`.
- **Combos**: `save(%{flavor: :direct})` materializes `adw_<stem>_direct.py`, writes the sidecar
  with `"flavor": "direct"`, and `fetch/2` reads it back as `:direct`.
- **GeneratedDrift**: remains green (renders from `combo.flavor`, so `:direct` sidecars are covered
  with no test change).
- **LiveView**: the flavor selector drives `adw_flavor` and Save materializes the `_direct` script
  + names it in the flash.

### Edge Cases
- Unknown/tampered `phx-value-flavor` string (e.g. `"deploy"`) → `adw_set_flavor` defaults to
  `:iso` without crashing the LiveView (fixed-map lookup, no `String.to_atom/1`).
- Legacy sidecars with `"flavor": "iso"` / `"local_iso"` still parse unchanged; a sidecar with an
  invalid flavor string still yields `{:error, {:invalid_flavor, _}}`.
- Loading a `:direct` combo repopulates the selector to **Direct** (round-trips `adw_flavor`).
- `render_direct/2` produces byte-identical output regardless of custom step prompts (prompts are
  runner templates, not embedded — parity with the `:local_iso` behavior).
- Python: `run_local_workflow(..., isolated=True)` default path is byte-behavior-unchanged for the
  shipped `_local_iso` scripts (no regression to existing combos).

## Acceptance Criteria
- The ADW Builder shows a three-way flavor selector (**Iso / Local iso / Direct**) in place of the
  binary **local** toggle; the active flavor is visually indicated.
- Selecting **Direct** and saving a combo writes `adws/adw_<name>_direct.py` (a monolithic script
  delegating to `run_local_workflow(..., isolated=False)`) and a `.combos/<stem>.json` sidecar with
  `"flavor": "direct"`, and the success flash names the `_direct.py` file.
- Selecting **Iso** / **Local iso** still produces `adw_<name>_iso.py` / `adw_<name>_local_iso.py`
  exactly as before (no regression).
- Loading a saved `:direct` combo restores the **Direct** selection and its steps.
- `RepoBuilder.Adw.Combo.flavor()` is `:iso | :local_iso | :direct` and all three round-trip
  through the JSON sidecar.
- `run_local_workflow` accepts `isolated: bool = True`; `isolated=False` runs steps in the current
  checkout without creating a worktree and ships via a direct in-place commit.
- All Validation Commands pass with zero failures and no new dialyzer/credo warnings.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix test test/repo_builder_web/live/test_adw_flavor_selector_test.exs` — the new LiveView
  integration test drives the selector + Save and asserts the `_direct.py` materialization.
- `mix test test/repo_builder/adw/scaffold_test.exs test/repo_builder/adw/combos_test.exs test/repo_builder/adw/generated_drift_test.exs` —
  generator/context/drift coverage for the new flavor.
- `mix compile --warnings-as-errors` — clean compile; the gradual set-theoretic type checker and
  `warnings_as_errors` must pass.
- `mix test --warnings-as-errors` — full ExUnit suite (Postgres-backed) with zero failures.
- `mix format --check-formatted` — formatting.
- `mix credo --strict` — lint, including the "every public function has an `@spec`" gate.
- `mix dialyzer` — contract checking with no new warnings and no stale ignore filters.
- (Optional, `uv` present) `uv run adws/adw_<name>_direct.py` against a scratch
  `agents/<adw-id>/run.json` — manual `:external` smoke that the generated direct script runs in
  place; NOT part of the `mix` gate.

## Notes
- **No new dependency** is required.
- **Why a monolithic `:direct` template (not a chaining one):** the repo has no non-iso per-step
  sub-scripts (`adw_plan.py`, `adw_build.py`, …) — only `_iso`/`_local_iso` exist. A chaining
  non-iso composite would reference non-existent files and be broken at runtime. Reusing the
  `:local_iso` monolithic delegation to `run_local_workflow` (with `isolated=False`) is the only
  coherent path and keeps the generator deterministic and fully `mix test`-covered.
- **Parity scope:** `adws/adw_new.py` (the Python CLI twin) only knows `iso`/`--local`. `:direct`
  is intentionally an Elixir-generator-only flavor with no `adw_new.py` counterpart; the byte-parity
  golden fixture stays scoped to `:iso`. The `GeneratedDriftTest` still binds every sidecar-backed
  combo (any flavor) to `Scaffold.render/1`, so `:direct` combos are drift-gated automatically.
- **Discovery:** `adws/adw_*.py` already globs `adw_<name>_direct.py`, so a generated direct script
  appears in the ADWs palette with no change to `Definitions.Adw.scan/2`.
- **Future consideration:** if `adw_new.py` should also emit a `--direct` variant for CLI parity,
  that is a separate follow-up; this feature scopes the choice to the console builder + generator.
- **Naming:** the `_direct` suffix was chosen over reusing "local" (already bound to `_local_iso`)
  and over a bare `adw_<name>.py` (ambiguous, and risks colliding with the classic per-step naming
  convention).
