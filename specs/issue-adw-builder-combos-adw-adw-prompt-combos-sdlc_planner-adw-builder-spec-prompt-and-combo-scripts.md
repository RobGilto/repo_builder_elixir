# Feature: ADW Builder — spec + initial-prompt inputs, saved "combos", and generated ADW scripts

## Metadata
issue_number: `adw-builder-combos`
adw_id: `adw-prompt-combos`
issue_json: `null` (freeform operator request captured from the ⌘K ADW Builder in ConsoleLive)

## Feature Description
The ⌘K command modal's **ADW Builder** mode (`console_components.ex` → `global_command_input/1`,
the `@adw_builder?` branch) lets an operator assemble an ordered chain of steps
(`plan patch build test review document ship`), name the workflow, and toggle a `local`
flavor. It has **no place to type the spec or the initial prompt** that the ADW should act
on. Worse, on launch (`ConsoleLive.launch_adw_builder/4`) every step is created with **no
`prompt_template`** (it defaults to `""` in `WorkflowEngine.Step.from_map/1`) and the only
run input is the workflow *name* (`inputs: %{"input" => name}`), which no template references —
so a hand-built ADW today runs each step against an **empty prompt**.

This feature does three things:

1. **Adds a Spec textarea and an Initial-prompt textarea** to the ADW Builder, and wires them
   into the launch so steps receive real, rendered prompts (fixing the empty-prompt gap).
2. **Lets the operator save the current build as a named "combo"** — the ordered steps, the
   `local`/GitHub flavor, and the default spec + initial prompt.
3. **Materializes each saved combo as a real portable Python ADW script** in `adws/`
   (`adw_<name>_iso.py` or `adw_<name>_local_iso.py`), byte-for-byte in the style of the
   existing hand-written composites (e.g. `adws/adw_plan_build_iso.py`), so the combo becomes
   a first-class, discoverable, runnable ADW.

Because `RepoBuilder.Definitions` already watches `adws/adw_*.py` and broadcasts
`{:definitions_changed, :adw, list}`, a generated script **automatically appears** in the
ADWs palette (BASE for the platform repo, PROJECT for the active working dir) — that palette,
plus a dedicated "Load combo" `<select>` that repopulates the builder, is the "select them via
dropdown next time" the operator asked for.

## User Story
As an **operator driving AI Developer Workflows from the console**
I want to **type the spec and the initial prompt when I build an ADW, save a named step-combo,
and have it saved as a real ADW script I can pick next time**
So that **launched ADWs actually receive my task context, and I can reuse a proven
plan→build→test→review recipe without rebuilding it or hand-writing a Python script.**

## Problem Statement
The ADW Builder cannot express *what work the ADW should do*: there is no spec/prompt input,
launched steps run with empty `prompt_template`s, and the run's only input is the workflow name.
A built configuration is also ephemeral — closing the modal loses it, and there is no way to
persist a step-combination as a reusable, named artifact the way the repo's `adws/adw_*.py`
scripts are.

## Solution Statement
Extend the ADW Builder with **Spec** and **Initial prompt** textareas and a **combo name**, and:

- **Launch (must-have fix):** thread the spec + initial prompt into the run as artifacts
  (`%{"input" => initial_prompt, "spec" => spec}`) and give each builder step a real
  `prompt_template` derived from a canonical per-step map (so `plan` renders
  `Plan the work for: {{input}} …{{spec}}`, `build` renders `Build from the plan: {{plan}}`, etc.).
  This alone resolves the operator's primary complaint and the latent empty-prompt bug.
- **Save combo:** a new typed context `RepoBuilder.Adw.Combos` persists the combo as a JSON
  sidecar (file-based, mirroring the `Orchestrator.Templates` "context owns all I/O" doctrine),
  and a new deterministic generator `RepoBuilder.Adw.Scaffold` renders + writes the Python ADW
  script into the target `adws/` dir, then calls `Definitions.refresh/1`.
- **Reuse:** a "Load combo" `<select>` repopulates the builder from a saved combo; the generated
  `.py` shows up in the existing ADWs palette and runs through the portable `start_adw` adapter
  (which already threads `--prompt`) or the in-app engine.

The generator is **Elixir-native and deterministic** (no `uv` needed → covered by the green
gate), with `adws/adw_new.py` as the reference twin: the `_iso` template reproduces
`adw_new.py`'s subprocess-chaining output exactly (matching `adw_plan_build_iso.py`); the
`_local_iso` template emits a thin monolithic script that delegates step-threading to one new
shared helper `adw_modules/workflow_ops.py:run_local_workflow/…` (generalized from the existing
`adw_plan_build_local_iso.py` body), so local composites stay correct against the single-`<adw-id>`
+ `run.json` local launch contract. (The AI-driven `RepoBuilder.Forge` subsystem was evaluated and
rejected here: forging drives a live harness session and is non-deterministic; combo scaffolding
must be a pure, testable string render.)

## Relevant Files
Use these files to implement the feature:

- `lib/repo_builder_web/components/console_components.ex` — `global_command_input/1` (the ⌘K
  modal). The `@adw_builder?` branch (approx. lines 4118–4240) is where the Spec/Initial-prompt
  textareas, combo-name input, "Save combo" button, and "Load combo" `<select>` are added. New
  `attr`s must be declared on the component (approx. lines 3878–3894). `adw_step_hint/1`
  (approx. lines 4437–4458) holds the per-step human descriptions to reuse for the canonical
  `prompt_template` map.
- `lib/repo_builder_web/live/console_live.ex` — mount defaults for ADW Builder assigns
  (approx. lines 267–272); `launch_adw_builder/4` (approx. lines 2275–2303) is rewritten to pass
  spec/prompt inputs + real per-step `prompt_template`s; the ADW event handlers
  (`adw_add_step`/`adw_set_name`/`adw_toggle_local`/`run_adw_builder`, approx. lines 1572–1632)
  are joined by new `adw_set_spec`, `adw_set_prompt`, `adw_save_combo`, `adw_load_combo`,
  `adw_delete_combo` handlers. Seed combo assigns near where `@adws` is assigned
  (`assign_definitions`, approx. line 666).
- `lib/repo_builder/workflow_engine/catalog.ex` — canonical per-step `prompt_template`s
  (`steps/2`, the `step/4` helper, approx. lines 109–188). Reuse/extend a single source for the
  per-step default templates the builder assigns, so builder-built and catalog-built workflows
  agree.
- `lib/repo_builder/workflow_engine/step.ex` — `Step` typedstruct; `prompt_template` default
  `""` confirms the current empty-prompt behavior the fix removes.
- `lib/repo_builder/workflow_engine/runner.ex` — `render/2` (`{{key}}` substitution over
  artifacts, approx. lines 286–291) and `handle_continue(:run_step, …)` show exactly how
  `inputs` + step `prompt_template`s become the agent prompt; the launch fix must produce
  templates + inputs this renderer can resolve.
- `lib/repo_builder/definitions.ex` — file-watch + `refresh/1` + `{:definitions_changed, :adw, …}`
  broadcast; `Adw.scan/2` discovers `adws/adw_*.py`. `app_root/0` resolves the platform repo root
  (the BASE `adws/` write target). The generator calls `Definitions.refresh/1` after writing.
- `lib/repo_builder/definitions/adw.ex` — `Definitions.Adw` struct + `scan/2` (globs
  `adws/adw_*.py` and `adws/adw_workflows/adw_*.py`). Confirms the generated filename convention
  a combo must satisfy to be discovered.
- `lib/repo_builder/orchestrator/templates.ex` + `lib/repo_builder/orchestrator/template.ex` —
  the file-based, `@spec`'d, tagged-tuple, never-raises **context doctrine** to mirror for
  `RepoBuilder.Adw.Combos` (list/fetch/save/delete over a writable root; app-env override as a
  test seam).
- `lib/repo_builder/orchestrator/tools.ex` — `start_adw/2` → `start_adw_via_adapter/4` (approx.
  lines 1426–1505): the portable path that runs a discovered `adws/adw_*.py` and, via
  `harness/adw.ex`, passes `--prompt <input>`. Confirms a generated combo runs unchanged once
  discovered.
- `lib/repo_builder/harness/adw.ex` — `command/1` builds
  `uv run <script.py> --prompt <input> --working-dir <cwd> --adw-id <id> … --emit json`.
  Confirms how the initial prompt reaches a launched ADW.
- `adws/adw_new.py` — the **reference generator** (subprocess-chaining scaffolder). The `_iso`
  Elixir template must reproduce its `make_script/3` output for the same inputs; `VALID_STEPS`
  is the step allowlist to mirror.
- `adws/adw_plan_build_iso.py` — ground-truth **GitHub** composite (subprocess-chaining;
  `<issue-number> [adw-id]`). Golden reference for the `_iso` template.
- `adws/adw_plan_build_local_iso.py` — ground-truth **local** composite (monolithic;
  single `<adw-id>`; prompt from `run.json`; one worktree; steps threaded inline). Golden
  reference for the `_local_iso` template + the body to extract into `run_local_workflow`.
- `adws/adw_modules/workflow_ops.py`, `adws/adw_modules/local_ops.py` — where the shared
  `run_local_workflow(adw_id, steps, logger)` helper is added (generalized from the local
  composite body) and where `build_plan`/`implement_plan`/`create_commit`/`load_run` already live.
- `adws/README.md` — the `uv` single-file-script conventions any generated/edited script obeys.
- `test/repo_builder_web/live/test_prompt_palette_test.exs` — the closest LiveView test model
  (mount `~p"/"`, assert palette chips, drive a `{:definitions_changed, …}` re-render; `async: false`
  so the sandbox reaches the LiveView).

### New Files
- `lib/repo_builder/adw/scaffold.ex` — `RepoBuilder.Adw.Scaffold`: deterministic Python-ADW
  script generator. `@spec render(request()) :: {:ok, String.t()} | {:error, reason()}` (pure)
  and `@spec generate(request()) :: {:ok, %{path, name, script}} | {:error, reason()}` (writes to
  disk, chmod 0755, refuses overwrite unless asked). `_iso` (chaining) + `_local_iso` (monolithic)
  templates; step allowlist parity with `adw_new.py`.
- `lib/repo_builder/adw/combos.ex` — `RepoBuilder.Adw.Combos`: file-based context that owns combo
  I/O. `list/0..1`, `fetch/1`, `save/1` (writes JSON sidecar **and** calls `Scaffold.generate/1`
  + `Definitions.refresh/1`), `delete/1`. Writable root via app-env (test seam).
- `lib/repo_builder/adw/combo.ex` — `RepoBuilder.Adw.Combo`: typedstruct
  (`name`, `steps :: [Scaffold.step()]`, `flavor :: :iso | :local_iso`, `spec :: String.t() | nil`,
  `initial_prompt :: String.t() | nil`, `script_path`, `updated_at`) + `@spec`'d validate/encode/decode.
- `test/repo_builder/adw/scaffold_test.exs` — golden-file parity + validation unit tests for the
  generator (no `uv` required).
- `test/repo_builder/adw/combos_test.exs` — save/list/fetch/delete + sidecar + script-materialization
  unit tests (app-env-overridden tmp roots).
- `test/repo_builder_web/live/test_adw_builder_combos_test.exs` — `Phoenix.LiveViewTest`
  integration test driving the builder UI end-to-end.
- `test/support/fixtures/adw/` (if needed) — golden expected-script fixtures for the parity test.

### Conditional docs consulted (per `.claude/commands/conditional_docs.md`)
- **(always)** `ai_docs/typed-elixir-standard.md` — the enforced typed standard (`@spec`, typedstruct,
  tagged tuples, wire-vs-domain, no `map()`/`any()`).
- `BUILD_PROMPT.md` §9 + `AGENTS.md` — LiveView dashboard + Phoenix 1.8/LiveView guidelines (the modal/UI work).
- `BUILD_PROMPT.md` §7 + `ai_docs/adw-orchestration.md` — the workflow/ADW engine, step state machine, `inputs`/artifacts.
- `BUILD_PROMPT.md` §6 + `ai_docs/adw-primitives.md` — session runtime + the portable ADW/`start_adw` adapter contract.
- `adws/README.md` — the Astral `uv` single-file Python conventions for generated/edited scripts.
- `ai_docs/meta-artifacts.md` — reviewed to confirm Forge is AI-driven generation and therefore the
  wrong (non-deterministic) tool for deterministic combo scaffolding.

## Implementation Plan
### Phase 1: Foundation — spec + initial-prompt inputs and a non-empty launch
Deliver the operator's primary need independently of any persistence/generation. Add the Spec and
Initial-prompt textareas (+ keep the existing name field) to the ADW Builder, hold them as assigns,
and rewrite `launch_adw_builder/4` so (a) the run carries `%{"input" => initial_prompt, "spec" => spec}`
and (b) each builder step gets a real `prompt_template` from a single canonical per-step map (shared
with / derived from `Catalog`). After this phase a hand-built ADW runs with real prompts.

### Phase 2: Core Implementation — combos + deterministic script generation
Add the `RepoBuilder.Adw.Combo` struct, the `RepoBuilder.Adw.Scaffold` generator (`_iso` parity with
`adw_new.py`; `_local_iso` monolithic), and the `RepoBuilder.Adw.Combos` context (JSON sidecar +
`Scaffold.generate/1` + `Definitions.refresh/1`). Add the "Save combo" button + name/flavor wiring in
the UI. Unit-test the generator against golden fixtures and the context against tmp roots.

### Phase 3: Integration — reuse, discovery, and correct local execution
Add the "Load combo" `<select>` that repopulates the builder (steps + flavor + spec + prompt); confirm
generated scripts surface in the ADWs palette via the `{:definitions_changed, :adw, …}` broadcast; add
the shared `adw_modules/workflow_ops.py:run_local_workflow(adw_id, steps, logger)` helper so generated
`_local_iso` scripts run correctly; write the end-to-end LiveView test (build → save → assert script on
disk + combo listed + palette chip → load → launch).

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Canonicalize the per-step prompt templates (shared source of truth)
- In `lib/repo_builder/workflow_engine/catalog.ex`, expose a single `@spec`'d function returning the
  default `prompt_template` for a step name, e.g. `default_prompt_template(step :: String.t()) :: String.t()`,
  covering `plan patch build test review document ship`. Reuse the existing `step/4` templates
  (`"Plan the work for: {{input}}"`, `"Build from the plan: {{plan}}"`, `"Review the build: {{build}}"`, …)
  and add the missing names (`patch`, `document`, `ship`) consistent with `adw_step_hint/1`.
- Templates must reference `{{input}}` (the initial prompt) and `{{spec}}` where relevant, plus prior
  step outputs (`{{plan}}`, `{{build}}`, `{{test}}` …) so `Runner.render/2` resolves them.
- Keep it typed; no `map()`/`any()`.

### 2. Add the LiveView integration test first (drives Phases 1–3)
- Create `test/repo_builder_web/live/test_adw_builder_combos_test.exs` using `Phoenix.LiveViewTest`
  (`use RepoBuilderWeb.ConnCase, async: false`).
- Assert the initial failing/target behavior incrementally (write assertions for Phase 1 now; extend
  as later phases land):
  - mount `~p"/"`, open the builder (`render_click(view, "toggle_adw_builder")`), assert the Spec and
    Initial-prompt textareas render (`element/2` on their ids/names).
  - `render_change` the spec + prompt, add steps, `render_click(view, "run_adw_builder")`, and assert a
    workflow run was created whose first step's rendered prompt contains the typed initial prompt
    (assert via `Workflows`/`WorkflowEngine` state or a broadcast, not internals).
- This file is the required `test/repo_builder_web/live/test_<descriptive_name>_test.exs` deliverable.

### 3. ADW Builder UI — Spec + Initial-prompt inputs
- In `console_components.ex` `global_command_input/1`, declare new `attr`s: `adw_spec :: :string`,
  `adw_prompt :: :string`, `adw_combos :: :list` (default `[]`), `adw_selected_combo :: :string`.
- In the `@adw_builder?` branch, add a **Spec** `<textarea name="spec" phx-change="adw_set_spec">` and
  an **Initial prompt** `<textarea name="prompt" phx-change="adw_set_prompt">`, styled with the existing
  `cns-cmd-textarea` classes and placeholders that explain each (spec = optional pre-written spec;
  prompt = the feature/task description that drives `/feature`).
- Pass the new assigns down from `console_live.ex` at the `<.global_command_input …>` call site.

### 4. Wire inputs through mount + event handlers (Phase 1)
- In `console_live.ex` mount defaults, add `adw_spec: ""`, `adw_prompt: ""`, `adw_combos: []`,
  `adw_selected_combo: ""`.
- Add `handle_event("adw_set_spec", %{"spec" => v}, socket)` and
  `handle_event("adw_set_prompt", %{"prompt" => v}, socket)` assigning the values.
- Rewrite `launch_adw_builder/4`:
  - Build `step_list` with a real `"prompt_template"` per step from
    `Catalog.default_prompt_template/1` (Step 1), keeping the existing `on_success`/`on_failure` chaining.
  - Start the workflow with `inputs: %{"input" => initial_prompt, "spec" => spec}` (fall back to the
    name only when both are blank, preserving today's behavior for empty launches).
  - Keep the Fast-tier `TitleHumanizer` call and the assign reset; also reset `adw_spec`/`adw_prompt`.
- Verify the Phase-1 slice of the Step-2 test passes.

### 5. `RepoBuilder.Adw.Combo` struct
- Create `lib/repo_builder/adw/combo.ex` with a `typedstruct enforce: true`:
  `name`, `steps :: [Scaffold.step()]`, `flavor :: :iso | :local_iso`, `spec :: String.t() | nil`,
  `initial_prompt :: String.t() | nil`, `script_path :: String.t()`, `updated_at :: DateTime.t()`.
- Add `@spec`'d `validate/1`, `to_json/1`, `from_json/1` (string-keyed wire map ↔ struct; blank→nil),
  and a `slugify_name/1` that maps a display name to the `adw_<name>` filename stem (dashes/spaces →
  underscores; reject empty/invalid). Follow `ai_docs/typed-elixir-standard.md` (rule 6 wire vs domain).

### 6. `RepoBuilder.Adw.Scaffold` generator
- Create `lib/repo_builder/adw/scaffold.ex`:
  - `@type step :: :plan | :patch | :build | :test | :review | :document | :ship`,
    `@type flavor :: :iso | :local_iso`, `@type request :: %{…}` (name, steps, flavor, root, overwrite?).
  - `@spec render(request()) :: {:ok, String.t()} | {:error, reason()}` — pure text render. Two private
    templates (EEx or heredoc builders):
    - **`_iso`**: reproduce `adw_new.py make_script(name, steps, local=false)` exactly (PEP-723 header
      split, docstring step list, `subprocess.run([... adw_<step>_iso.py, issue_number, adw_id])` blocks,
      the `ensure_adw_id` import). Assert byte-parity in tests.
    - **`_local_iso`**: a thin monolithic `main()` that `load_dotenv()`, reads `<adw-id>` from argv,
      loads `run.json` via `local_ops`, and calls
      `workflow_ops.run_local_workflow(adw_id, ["plan","build",…], logger)` — matching the single-arg +
      `run.json` local contract (Step 11 adds the helper).
  - `@spec generate(request()) :: {:ok, %{path: String.t(), name: String.t(), script: String.t()}} | {:error, reason()}`
    — validate steps against the allowlist (parity with `adw_new.py VALID_STEPS`), compute
    `adw_<name>_iso.py` / `adw_<name>_local_iso.py` under `<root>/adws/`, refuse overwrite unless
    `overwrite: true` (`{:error, :exists}`), write + `File.chmod(path, 0o755)`, return the path. Never raise.

### 7. `RepoBuilder.Adw.Combos` context
- Create `lib/repo_builder/adw/combos.ex` mirroring the `Orchestrator.Templates` doctrine (the only
  module touching the combos filesystem; every fn `@spec`'d; tagged tuples; never raises on expected paths):
  - `@spec list(root :: String.t() | nil) :: [Combo.t()]` and `list/0`.
  - `@spec fetch(String.t()) :: {:ok, Combo.t()} | {:error, reason()}`.
  - `@spec save(map()) :: {:ok, Combo.t()} | {:error, reason()}` — validate via `Combo`, write the JSON
    sidecar to the writable combos dir (`adws/.combos/<name>.json` under the resolved root — the `.combos/`
    subdir is not matched by the `adws/adw_*.py` glob, so it never masquerades as an ADW), call
    `Scaffold.generate/1` for the `.py`, then `Definitions.refresh(working_dir)` so the palette updates.
  - `@spec delete(String.t()) :: :ok | {:error, reason()}` — remove sidecar (and optionally the generated
    `.py`; default: leave the `.py`, since it is now a normal discovered ADW — document the choice).
  - Writable/target root via `Application.get_env(:repo_builder, RepoBuilder.Adw.Combos)[:root]` with a
    sane default (the active working dir when set, else `Definitions` app root), overridable in tests.

### 8. Save-combo UI + handlers
- In the builder, add a **combo name** input (reuse the existing `adw_name`) and a **"Save combo"** button
  (`phx-click="adw_save_combo"`), plus a small flavor hint (uses the existing `local` toggle for
  `:local_iso` vs `:iso`).
- Add `handle_event("adw_save_combo", _params, socket)`:
  - Assemble attrs from `adw_name` (required; flash on blank), `adw_steps`, `adw_local?` → flavor,
    `adw_spec`, `adw_prompt`.
  - Call `Combos.save/1`; on `{:ok, combo}` re-assign `adw_combos` from `Combos.list/…`, flash
    "Saved combo + generated <script>"; on `{:error, reason}` flash a specific message
    (`:exists` → suggest a new name / overwrite).
- Re-seed `adw_combos` in `assign_definitions` (or on mount/connect) so the dropdown is populated on load
  and after `{:definitions_changed, :adw, …}`.

### 9. Load-combo dropdown + handler (Phase 3 reuse)
- Add a **"Load combo"** `<select name="combo" phx-change="adw_load_combo">` listing `@adw_combos`
  (label = display name; value = name), with a blank first option.
- Add `handle_event("adw_load_combo", %{"combo" => name}, socket)`: `Combos.fetch/1`, then repopulate
  `adw_steps` (rebuild the step rows with fresh ids/`expanded: false`), `adw_local?` (from flavor),
  `adw_spec`, `adw_prompt`, and `adw_name`. Flash on `{:error, :not_found}`.
- Optionally add `handle_event("adw_delete_combo", %{"combo" => name}, socket)` → `Combos.delete/1`.

### 10. Generator + context tests
- `test/repo_builder/adw/scaffold_test.exs`:
  - `render/1` for `:iso` equals the committed golden fixture AND (when `System.find_executable("uv")`)
    equals `uv run adws/adw_new.py <name> --steps … --dry-run` output — tag the `uv` case
    `@tag :external` so the green gate passes without `uv`.
  - `render/1` for `:local_iso` contains the single-`<adw-id>` contract + the `run_local_workflow` call
    and does NOT contain the `issue_number` positional-chaining pattern.
  - `generate/1` writes to a tmp `adws/`, chmods 0755, and returns `{:error, :exists}` without `overwrite`.
  - Invalid step / blank name → `{:error, …}`, never raises.
- `test/repo_builder/adw/combos_test.exs`:
  - `save/1` writes the sidecar, materializes the `.py`, and the combo round-trips through `fetch/1`;
    `list/…` returns it; `delete/1` removes the sidecar. Use an app-env tmp root; `on_exit` cleanup.

### 11. Shared Python local-workflow runner (make generated `_local_iso` runnable)
- In `adws/adw_modules/workflow_ops.py`, add `run_local_workflow(adw_id: str, steps: list[str], logger)`
  generalized from `adws/adw_plan_build_local_iso.py`'s body: load+validate `run.json`, synthesize the
  local issue, set up the worktree/ports/branch **once**, then iterate `steps` running the correct inline
  op per step (`plan`→`build_plan`, `build`→`implement_plan`, `test`/`review`/`document` via their
  existing `workflow_ops` entry points, `ship` = commit/PR path), threading `spec_file`/state, committing
  in the worktree, and narrating via `emit_event`. Keep it faithful to the existing local composites so
  behavior is unchanged for the recipes that already ship.
- Obey `adws/README.md` conventions; do not add new third-party deps.
- Note: this Python helper is outside the Elixir green gate — validate it by launching a generated
  `_local_iso` combo (Validation, Tidewave/live acceptance).

### 12. Palette-discovery integration + end-to-end LiveView assertions
- Extend `test/repo_builder_web/live/test_adw_builder_combos_test.exs`:
  - Override the `Combos` + `Definitions` roots to a tmp `adws/` (app-env), mount `~p"/"`, open the
    builder, type name + steps + spec + prompt, `render_click("adw_save_combo")`.
  - Assert: the sidecar + generated `.py` exist on disk; `Combos.list/…` includes it; after
    `Definitions.refresh/1` (or the broadcast) the ADWs palette re-renders a chip for the new slug;
    `render_change("adw_load_combo")` repopulates the step rows and textareas.
- Optionally capture a Playwright screenshot of `http://localhost:4000` (⌘K → ADW Builder) as visual proof.

### 13. Runtime verification via Tidewave
- With the app running, use Tidewave `project_eval` to exercise the pure paths without the browser:
  `RepoBuilder.Adw.Scaffold.render(%{name: "demo_pbr", steps: [:plan,:build,:review], flavor: :iso, …})`
  and `RepoBuilder.Adw.Combos.save(%{…})`; confirm `{:ok, …}`, the file on disk, and that
  `RepoBuilder.Definitions.list(:adw, nil)` now includes `demo_pbr_iso`.
- Use Tidewave `get_logs` if any launch path errors; use `get_docs`/`get_source_location` for exact-version
  Phoenix/LiveView APIs while implementing.

### 14. Run the full Validation Commands
- Execute every command in **Validation Commands** and fix any failure or regression until all are green.

## Testing Strategy
### Unit Tests
- **Scaffold (`scaffold_test.exs`):** `_iso` golden-parity with `adw_new.py`; `_local_iso` uses the
  single-`<adw-id>` + `run_local_workflow` contract; step allowlist enforcement; overwrite refusal;
  0755 mode; blank/invalid inputs return `{:error, …}` and never raise.
- **Combo (`combo.ex` covered via combos_test):** validate/slugify/JSON round-trip; blank→nil; invalid
  name/steps rejected.
- **Combos context (`combos_test.exs`):** save materializes sidecar + `.py` + refreshes; list/fetch/delete;
  tmp-root isolation.
- **Catalog:** `default_prompt_template/1` returns the expected template for every builder step name.

### Edge Cases
- Blank initial prompt **and** blank spec → launch still succeeds (falls back to name-only input; no crash).
- Combo name collides with an existing generated script → `{:error, :exists}` surfaced as an actionable flash
  (not a raise); with `overwrite: true` it replaces.
- Combo name that slugifies to empty / contains path separators → rejected before any write (no traversal).
- `local` flavor generates the **monolithic** `_local_iso` (not the chaining form); GitHub flavor generates
  the chaining `_iso`.
- Steps reordered/removed after typing a spec → launch/save use the current ordered `adw_steps`.
- Loading a combo whose sidecar references a since-deleted `.py` → repopulates the builder anyway (sidecar is
  source of truth for defaults); saving regenerates the `.py`.
- Empty `adw_steps` on save → blocked with a flash (mirrors the existing launch guard).
- PROJECT vs BASE: with a working dir set, the script + sidecar land under `<working_dir>/adws/` and appear
  on the PROJECT palette tab; unset → platform `adws/` + BASE tab.
- Definitions watcher disabled in tests → an explicit `Definitions.refresh/1` still surfaces the new chip.

## Acceptance Criteria
- The ⌘K ADW Builder shows a **Spec** textarea and an **Initial prompt** textarea; both persist across
  re-renders while the modal is open.
- Launching a built ADW passes the typed initial prompt (and spec) into the run; the first step's rendered
  prompt contains the initial prompt (no more empty `prompt_template`).
- Clicking **Save combo** with a name writes `adws/.combos/<name>.json` **and** generates
  `adws/adw_<name>_iso.py` (or `adw_<name>_local_iso.py`), sets it executable, and the script matches the
  style of the existing composites (`_iso` byte-parity with `adw_new.py` output).
- The generated script appears in the ADWs palette (BASE or PROJECT per working dir) without a page reload,
  via the `{:definitions_changed, :adw, …}` broadcast.
- A **Load combo** dropdown lists saved combos; selecting one repopulates steps, flavor, spec, and prompt.
- A generated `_local_iso` combo runs the intended steps against the `run.json` prompt through the portable
  `start_adw` adapter (validated live).
- All Validation Commands pass with zero regressions.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix test test/repo_builder/adw/scaffold_test.exs` — generator parity/validation unit tests.
- `mix test test/repo_builder/adw/combos_test.exs` — combo context (sidecar + materialization) tests.
- `mix test test/repo_builder_web/live/test_adw_builder_combos_test.exs` — the LiveView integration test
  (build → launch with prompt → save combo → script on disk + palette chip → load combo).
- `mix compile --warnings-as-errors` — clean compile; the gradual set-theoretic type checker and
  `warnings_as_errors` must pass.
- `mix test --warnings-as-errors` — full ExUnit suite (Postgres-backed) with zero failures.
- `mix format --check-formatted` — formatting.
- `mix credo --strict` — lint, including the "every public function has an `@spec`" gate.
- `mix dialyzer` — contract checking with no new warnings and no stale ignore filters.
- (Live acceptance, outside the gate) With the app running: `uv run adws/adw_<name>_local_iso.py <adw-id>`
  against a prepared `agents/<adw-id>/run.json`, or launch the generated combo from the console, and confirm
  it plans/builds against the typed prompt.

## Notes
- **No new mix deps.** The generator is pure Elixir; the one Python addition (`run_local_workflow`) reuses
  existing `adw_modules` helpers and the `uv` PEP-723 header already standard in `adws/`.
- **Why Elixir-native generation (not shelling out to `adw_new.py`):** determinism + green-gate coverage
  (`mix test` has no `uv`), tagged-tuple error handling, and clean BASE/PROJECT root scoping. `adw_new.py`
  stays the CLI twin and the golden reference for the `_iso` template; a `@tag :external` test asserts parity
  when `uv` is present so the two cannot silently drift.
- **Why not Forge:** `RepoBuilder.Forge.Workflow` drives a live, non-deterministic harness session to author
  artifacts (`ai_docs/meta-artifacts.md`). Combo scaffolding is a fixed string render — it must be pure and
  reproducible, so it lives in a dedicated deterministic module, not Forge.
- **`_local_iso` correctness is the main risk.** Real local composites are monolithic (single `<adw-id>`,
  prompt from `run.json`, one worktree); `adw_new.py --local` would emit a broken chaining form. Concentrating
  the logic in one shared `run_local_workflow` helper keeps generated local scripts thin and correct, and lets
  the existing hand-written local composites be refactored onto it later (out of scope here).
- **Combo defaults vs run inputs are distinct.** The combo's saved spec/initial-prompt are *defaults* that
  prefill the builder; the actual run input is whatever is in the textareas at launch (or `--prompt`/`run.json`
  for a portable launch). This keeps one recipe reusable across many different tasks.
- **Future:** an "overwrite" affordance on the Save button; committing/gitignoring `adws/.combos/` per repo
  policy; exposing combo save/generate as an orchestrator tool so the brain can mint reusable ADWs; and
  migrating the shipped hand-written local composites onto `run_local_workflow` to delete duplication.
```