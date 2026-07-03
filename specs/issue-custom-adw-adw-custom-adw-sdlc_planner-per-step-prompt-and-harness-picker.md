# Feature: Custom ADW — per-step prompt overrides and harness picker in the ADW Builder

## Metadata
adw_id: `custom-adw`

## Description
The ADW Builder assembles ordered step chains that launch as custom workflow runs. Today every
step's prompt template is fixed (the catalog default from `Catalog.default_prompt_template/1`)
and the harness used for every step falls back silently to the orchestrator's harness. There is
no way in the UI to:

1. Override a step's prompt template (e.g. give the `build` step a specialized instruction
   beyond the default "Build from the plan: {{plan}}").
2. Choose which harness / agent CLI (claude, pi, …) the ADW run should use, independent of
   whatever harness the active orchestrator session happens to be configured with.

This feature adds both affordances to the ADW Builder and persists them in the `Combo` sidecar
when the operator saves the build.

## Problem Statement
- **Prompt inflexibility**: All builder-assembled ADWs use the same fixed catalog templates per
  step name, making it impossible to write a specialized prompt for, say, a `build` step that
  targets a particular framework or constraint. The `expanded` step row only shows a static
  read-only hint (`adw_step_hint/1`), not an editable template.
- **Silent harness fallback**: `launch_adw_builder/4` derives `harness` from
  `socket.assigns.adw_harness || socket.assigns.orchestrator_harness || "fake"`. The first
  branch (`adw_harness`) is always `nil` (mount default, no UI). Operators who want a
  different agent for an ADW than for their orchestrator chat have no control knob.
- **Combo data loss**: When a saved combo is loaded, any per-step prompt customization is lost
  because the `Combo` struct stores only step names (`steps :: [Scaffold.step()]`), not the
  associated custom templates or the chosen harness.

## Solution Statement

### Per-step custom prompt overrides
Extend the step map in `@adw_steps` with a `prompt` field (default `nil`, meaning "use
catalog default"). When a step row is expanded, show an editable `<textarea>` pre-filled with
the resolved default template. If the operator edits it, the step's `prompt` is stored in
the assign and picked up by `launch_adw_builder/4` (already the right shape: `s.prompt ||
Catalog.default_prompt_template(s.name)`).

### ADW-level harness picker
Add a `<select>` to the ADW Builder header listing the registered harnesses
(`Harness.Registry.list/0`). Wire it to a new `handle_event("adw_set_harness", …)` handler
that sets `adw_harness` (already initialized as `nil` in mount). `launch_adw_builder/4`
already reads `adw_harness` — setting it from the UI is the only missing piece.

### Persist in Combo
Extend `RepoBuilder.Adw.Combo` to carry `harness :: String.t() | nil` and make `steps` a
richer type `[{step_name :: atom(), prompt :: String.t() | nil}]` (a list of 2-tuples or
small maps) so the sidecar round-trips both the step order and any custom templates. Migrate
the JSON encode/decode and the scaffold generator accordingly.

## Relevant Files
Use these files to implement the feature:

- `lib/repo_builder_web/components/console_components.ex` — `global_command_input/1`:
  - `@adw_builder?` branch (lines ~4123–4318): add harness `<select>` to the header bar
    (lines ~4125–4143) and convert the static `adw_step_hint/1` expanded panel (lines
    ~4287–4293) into an editable `<textarea>`.
  - Declare `attr :adw_harness, :string, default: ""` and `attr :harness_names, :list,
    default: []` alongside existing attrs (lines ~3878–3893).
- `lib/repo_builder_web/live/console_live.ex` —
  - Mount defaults (lines ~267–277): already has `adw_harness: nil`; add
    `harness_names: Harness.Registry.list()` (or derive at mount).
  - `handle_event("adw_set_harness", …)` handler: assign `adw_harness`.
  - `handle_event("adw_set_step_prompt", …)` handler: find the step by id and update its
    `prompt` field.
  - `handle_event("adw_toggle_step", …)` (lines ~1611–1619): pre-fill the step's `prompt`
    field with `Catalog.default_prompt_template(s.name)` on first expand (so the textarea
    shows the default to edit from), rather than on add.
  - `launch_adw_builder/4` (lines ~2396–2445): change
    `"prompt_template" => Catalog.default_prompt_template(s.name)` to
    `"prompt_template" => s.prompt || Catalog.default_prompt_template(s.name)`.
  - `handle_event("adw_save_combo", …)` (lines ~1658–1700): include `harness` and per-step
    prompts in the attrs map passed to `Combos.save/2`.
  - `handle_event("adw_load_combo", …)` (lines ~1704–1736): repopulate `adw_harness` and per-
    step `prompt` from the loaded combo.
  - `handle_event("adw_add_step", …)` (lines ~1585–1589): add `prompt: nil` to the new step
    map.
- `lib/repo_builder/adw/combo.ex` — extend the typedstruct:
  - Change `steps :: [Scaffold.step()]` to
    `steps :: [{atom(), String.t() | nil}]` (step name + optional custom prompt).
  - Add `harness :: String.t() | nil, enforce: false`.
  - Update `to_json/1`, `from_json/1`, and `validate/1` accordingly; validate that step names
    remain in the `Scaffold.valid_steps()` allowlist.
- `lib/repo_builder/adw/combos.ex` — update `save/2` to thread the new step tuples and
  harness field through to `Scaffold.generate/1`.
- `lib/repo_builder/adw/scaffold.ex` — the generator currently accepts `steps :: [step()]`;
  extend `request()` to carry `steps :: [{step(), String.t() | nil}]` (name + optional
  custom prompt). The generated `_iso` script already receives only step names (it chains
  individual per-step scripts); `_local_iso` passes steps to `run_local_workflow`; custom
  prompts are intentionally NOT embedded in the generated `.py` (the `.py` is a runner
  template, not a prompt carrier; the combo sidecar is the prompt source). Keep the
  generator pure — step names extracted from the tuple for script generation.
- `lib/repo_builder/harness/registry.ex` — `@spec list() :: [atom()]` (or the existing
  equivalent) supplies the harness options for the picker.
- `lib/repo_builder/workflow_engine/catalog.ex` — `default_prompt_template/1` is already
  `@spec`'d and public; no changes needed.
- `test/repo_builder_web/live/test_adw_builder_combos_test.exs` — extend existing Phase-3
  test and add new assertions for per-step prompt override and harness picker (or add a
  dedicated test module; see New Files).

### New Files
- `test/repo_builder_web/live/test_adw_builder_custom_adw_test.exs` — `Phoenix.LiveViewTest`
  integration tests covering: (a) harness picker renders harness options and sets `adw_harness`;
  (b) expanding a step shows an editable textarea pre-filled with the default template;
  (c) editing the textarea stores the override and it appears in the launched step's
  `prompt_template`; (d) save-combo round-trips harness + per-step prompts through the sidecar;
  (e) load-combo repopulates harness and step prompts in the builder.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Extend the step map in `adw_steps` with a `prompt` field
- In `console_live.ex` `handle_event("adw_add_step", …)` (line ~1585), add `prompt: nil` to
  the new step map: `%{id: id, name: step, expanded: false, prompt: nil}`.
- In `handle_event("adw_load_combo", …)`, when rebuilding steps from the loaded combo, map
  each `{step_name, custom_prompt}` tuple to `%{id: …, name: step_name, expanded: false,
  prompt: custom_prompt}`.
- No other existing handlers need changes at this stage (the `prompt` field is ignored until
  the textarea wiring in Step 3).

### 2. Add harness picker to the ADW Builder header
- In `console_live.ex` mount (or `seed_definitions/1`), add `harness_names:
  Harness.Registry.list() |> Enum.map(&Atom.to_string/1)` to the socket assigns.
- Add `handle_event("adw_set_harness", %{"harness" => h}, socket)` that assigns `adw_harness:
  h`.
- In `console_components.ex`, declare `attr :adw_harness, :string, default: ""` and `attr
  :harness_names, :list, default: []` alongside existing ADW builder attrs.
- In the `@adw_builder?` branch header bar (lines ~4125–4143, next to the `local` toggle),
  add a `<select name="harness" phx-change="adw_set_harness">` listing
  `@harness_names` options (including a blank "— pick harness —" first option). Highlight the
  currently selected value via `selected={h == @adw_harness}`.
- Pass `adw_harness={@adw_harness}` and `harness_names={@harness_names}` from the
  `<.global_command_input …>` call site in `console_live.ex`.

### 3. Make expanded step row show an editable prompt textarea
- In `console_components.ex`, the `:if={step.expanded}` div (lines ~4287–4293) currently
  renders `{adw_step_hint(step.name)}` as static text. Replace with:
  ```heex
  <textarea
    name={"prompt-#{step.id}"}
    phx-change="adw_set_step_prompt"
    phx-value-id={step.id}
    rows="3"
    class="cns-cmd-textarea"
    style="font-size: 0.65rem"
    placeholder={adw_step_hint(step.name)}
  >{step.prompt || ""}</textarea>
  ```
  The `placeholder` shows the step hint (descriptive text); the `value` shows any custom
  template if set (empty string = "use default").
- Add `handle_event("adw_set_step_prompt", %{"id" => id, "value" => v}, socket)` in
  `console_live.ex`: parse `id` to integer, find the step, update its `prompt` field to `v`
  (nil-ify blank: `if String.trim(v) == "", do: nil, else: v`).
  ```elixir
  def handle_event("adw_set_step_prompt", %{"id" => id, "value" => v}, socket) do
    id = String.to_integer(id)
    prompt = if String.trim(v) == "", do: nil, else: v
    steps = Enum.map(socket.assigns.adw_steps, fn s ->
      if s.id == id, do: %{s | prompt: prompt}, else: s
    end)
    {:noreply, assign(socket, adw_steps: steps)}
  end
  ```

### 4. Wire custom prompts and harness through `launch_adw_builder/4`
- In `launch_adw_builder/4` (line ~2409), change:
  ```elixir
  "prompt_template" => Catalog.default_prompt_template(s.name),
  ```
  to:
  ```elixir
  "prompt_template" => s.prompt || Catalog.default_prompt_template(s.name),
  ```
- No change needed for harness: the existing `harness = socket.assigns.adw_harness ||
  socket.assigns.orchestrator_harness || "fake"` already picks up a non-nil `adw_harness`.
- Reset `adw_harness: nil` in the `assign/2` that clears the builder after launch (line
  ~2441).

### 5. Write the LiveView integration test (`test_adw_builder_custom_adw_test.exs`)
- Create `test/repo_builder_web/live/test_adw_builder_custom_adw_test.exs` using
  `use RepoBuilderWeb.ConnCase, async: false`.
- Tests:
  a. **Harness picker renders and sets harness**: mount `~p"/"`, open builder, assert `<select
     name="harness">` exists with at least one harness option, `render_change` it, confirm
     `view` assigns contain `adw_harness` matching the selected value.
  b. **Expanding a step shows editable textarea**: add a `plan` step, expand it, assert the
     expanded panel contains `<textarea name="prompt-1">` (empty / no custom prompt yet).
  c. **Editing step prompt stores override**: `render_change` the textarea with a custom value,
     collapse + re-expand, assert the textarea retains the custom value.
  d. **Custom prompt reaches launched step**: `render_change` spec + prompt + step textarea,
     `render_click("run_adw_builder")`, assert the created step's `prompt_template` equals
     the custom value (inspect via `Workflows.list_steps/1` or the step's persisted state).
  e. (Phase 2 in a later step) combo save round-trips custom prompts.

### 6. Extend `RepoBuilder.Adw.Combo` to carry harness + per-step custom prompts
- In `combo.ex`, change the `steps` field:
  ```elixir
  # Before:
  field :steps, [Scaffold.step()], enforce: true
  # After:
  field :steps, [{atom(), String.t() | nil}], enforce: true
  ```
  A tuple `{:plan, nil}` means use the catalog default; `{:build, "Custom build prompt"}` uses
  the override.
- Add `field :harness, String.t(), enforce: false` (may be nil = "use whatever the builder falls
  back to").
- Update `to_json/1`: encode steps as a list of `%{"name" => name, "prompt" => prompt}` objects
  (JSON-safe; backward-compatible with old sidecars that stored plain strings — handle both
  shapes in `from_json/1`).
- Update `from_json/1`: accept both the old `["plan", "build"]` list format AND the new
  `[{"name": "plan", "prompt": null}]` format (backward compatibility).
- Update `validate/1`: step names must still be in `Scaffold.valid_steps()`.
- Update `slugify_name/1` if needed (no change expected).

### 7. Update `Scaffold.generate/1` request type for the richer steps
- In `scaffold.ex`, update `@type request()` so `steps` is `[{step(), String.t() | nil}]`.
- In `render/1` for both `_iso` and `_local_iso` templates, extract the step name via
  `elem(step, 0)` (tuple unpacking). Custom prompts are NOT embedded in the generated Python
  script — the script is a runner; the combo sidecar is the prompt source.
- Update `valid_steps/0` usage: still just checks the step name atom.
- Ensure `Combos.save/2` passes the step tuples (with prompts) through to `Scaffold.generate/1`.

### 8. Update `Combos.save/2` and `adw_save_combo` handler to include new fields
- In `console_live.ex` `handle_event("adw_save_combo", …)`:
  ```elixir
  steps: Enum.map(steps, fn s -> {String.to_existing_atom(s.name), s.prompt} end),
  harness: nilify_blank(socket.assigns.adw_harness)
  ```
- In `combos.ex` `save/2`, pass the enriched combo attrs (including `harness` and step tuples)
  through `Combo.validate/1` and then `Scaffold.generate/1`.

### 9. Update `adw_load_combo` to restore harness + per-step prompts
- In `console_live.ex` `handle_event("adw_load_combo", …)`, after `Combos.fetch/1`:
  - Rebuild `adw_steps` from `combo.steps` as step maps with `prompt` set to the combo's
    per-step custom prompt (or `nil` if none).
  - Assign `adw_harness: combo.harness || ""`.
- This ensures a loaded combo restores the full custom configuration.

### 10. Update `test_adw_builder_combos_test.exs` Phase-3 test for the new step tuple format
- In the existing Phase-3 test (save → sidecar → load → repopulate), update the expected step
  format: steps should now be stored as tuples/maps with a `prompt` key. Adjust assertions as
  needed without breaking the existing 3 passing tests.

### 11. Extend scaffold and combo unit tests
- In `test/repo_builder/adw/scaffold_test.exs`:
  - Add a test: `render/1` with step tuples `[{:plan, nil}, {:build, "custom build"}]` emits
    the same script as before (custom prompts are NOT in the script; step names are extracted
    from the tuple).
  - Confirm `generate/1` still produces a valid `.py` and `{:error, :invalid_step}` for a
    bad step name in the tuple.
- In `test/repo_builder/adw/combos_test.exs`:
  - Add a test: `save/1` with harness `"pi"` and a step with a custom prompt; `fetch/1`
    returns the combo with `harness: "pi"` and the custom prompt in the step tuple.
  - Test backward compatibility: a sidecar written with the old plain-string steps list is
    decoded without crashing (`from_json/1` handles both formats).

### 12. Run the full Validation Commands

## Acceptance Criteria
- The ADW Builder shows a harness `<select>` in the header; selecting a harness persists it
  for the run and clears on launch/reset.
- Expanding a step row shows an editable textarea pre-filled with the catalog default template
  (as placeholder); typing a custom value stores it per-step.
- Launching a builder ADW with custom step prompts passes the overrides into the step
  `prompt_template` (verified by inspecting the launched step's persisted state).
- Saving a combo with harness + custom prompts writes both into the JSON sidecar; loading that
  combo repopulates harness and per-step prompts in the builder.
- Old combo sidecars (plain step-name lists, no harness field) still load without error
  (backward compatibility in `Combo.from_json/1`).
- All Validation Commands pass with zero regressions.

## Validation Commands
Execute every command to validate the work with zero regressions.

- `mix compile --warnings-as-errors` - Compile clean; gradual checker + warnings-as-errors pass.
- `mix test test/repo_builder_web/live/test_adw_builder_custom_adw_test.exs --warnings-as-errors` - New integration tests pass.
- `mix test test/repo_builder_web/live/test_adw_builder_combos_test.exs --warnings-as-errors` - Existing combo tests still pass.
- `mix test test/repo_builder/adw/ --warnings-as-errors` - All ADW unit tests pass.
- `mix test --warnings-as-errors` - Full ExUnit suite, zero failures.
- `mix format --check-formatted` - Formatting.
- `mix credo --strict` - Lint incl. the `@spec` convention.
- `mix dialyzer` - Contract checking, no new warnings.

## Notes
- **Custom prompts are NOT embedded in generated `.py` scripts.** The generated `_iso` and
  `_local_iso` scripts are runner templates that chain step CLIs; their prompt source is the
  `--prompt` flag / `run.json` at launch time, not a hardcoded string in the script. The combo
  sidecar is the right place to store default prompts.
- **Harness picker uses registered harnesses only.** `Harness.Registry.list/0` returns only
  the harnesses registered at runtime (typically `:claude`, `:pi`, `:fake`). Showing only real
  registered options prevents the operator from entering a typo that would silently fall back.
- **Backward compatibility is a hard requirement.** Existing combo sidecars store steps as plain
  string lists. `Combo.from_json/1` must handle both the old `["plan", "build"]` format and the
  new `[{"name": "plan", "prompt": null}]` format without crashing.
- **The step struct in `@adw_steps` stays a plain map** (not a Combo or WorkflowEngine.Step).
  Adding `prompt: nil` is a minimal extension; no new type is introduced in the LiveView layer.
- **`adw_harness` already exists in mount defaults** (line 273, `adw_harness: nil`). No schema
  migration is needed — the harness picker is purely a UI + assign change.
