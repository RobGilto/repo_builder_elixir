# Feature: Per-Step Provider/Model Selection + Complete ADW Load Discovery

## Metadata
issue_number: `adw-builder-ux`
adw_id: `perstep-model`
issue_json: `{"title":"Per-step provider/model selection in the ADW Builder + Load-combo should surface all platform/local ADWs","body":"I cannot pick a provider/model per step (e.g. a heavy model for the plan/feature step). Review the ADW Builder UI + functionality. Also, Load combo does not include all ADWs available in the platform or local repo.","adw_id":"perstep-model"}`

## Feature Description
The console's **ADW Builder** (`⌘K` → **ADW**) lets an operator assemble an ordered ADW
(plan/patch/build/test/review/document/ship), optionally give each step a custom prompt, pick a
single **harness** for the whole build, choose a **script flavor** (Iso / Local iso / Direct),
save it as a reusable **combo** (materializing a portable `adws/adw_<name>_*.py` script), and/or
**Launch** it into the DB-backed workflow engine.

This feature closes two concrete gaps the operator hit:

1. **No per-step provider/model.** The whole build shares one harness and no model choice, so you
   cannot say "run the **plan** step on a heavy model (`opus`) and the rest on the default." The
   `RepoBuilder.WorkflowEngine.Step` struct already carries `provider`/`model` fields and the
   session runtime already honors `:provider`/`:model` opts — but the **Runner never forwards
   them** (`runner.ex` passes only `harness: step.harness`), the **Builder UI never collects
   them**, and the **saved combo / generated Python never persists them**. So per-step model is
   plumbed at the type level yet dead end-to-end.

2. **Load combo is incomplete.** The **LOAD COMBO** dropdown only lists sidecar-backed combos from
   a *single* root (`Combos.list(working_dir)` — the working dir when set, else the platform repo).
   It ignores every discovered `adws/adw_*.py` script (`@adws`, scanned from BOTH the platform repo
   `:app` and the operator's `:working_dir` project) and never merges platform + local combos. The
   operator expects to load/select from **all** ADWs available across the platform and the local
   repo.

The feature (a) makes per-step `harness`/`provider`/`model` a first-class, optional per-step
override in the Builder, threaded to the live workflow engine AND persisted in the combo sidecar +
generated script; and (b) rebuilds the Load control into a grouped picker that surfaces **saved
combos (platform + local)** and **discovered ADWs (platform + local)**, reconstructing editable
steps from composite ADW filenames where possible.

## User Story
As an operator building an ADW in the console
I want to choose the provider/model per step (e.g. a heavy model for the plan step, default for the rest) and load from every ADW available in the platform or my local repo
So that I can tune cost/quality per phase and reuse any existing workflow without hand-recreating it.

## Problem Statement
- Per-step model/provider is impossible from the UI, and even a programmatically-built step's
  `provider`/`model` is silently dropped by the Runner, so it has zero runtime effect. Operators
  cannot allocate a heavy model to the step that benefits most (planning) while keeping cheaper
  models elsewhere.
- The Load control shows only single-root sidecar combos, hiding the platform's shipped `adw_*.py`
  workflows and the local repo's project ADWs, so operators can't discover or reuse them from the
  Builder.

## Solution Statement
Two coordinated tracks over a shared domain change.

**Track A — per-step harness/provider/model (end-to-end):**
1. **Runner fix (highest leverage, smallest change):** forward `step.provider`/`step.model`
   (and keep `step.harness`) into `Session.Supervisor.start_session/1`, which already flows to
   `Session.Server`. This alone makes per-step model real for any DB-backed workflow.
2. **Canonical per-step domain shape:** introduce `RepoBuilder.Adw.StepSpec` (a `typedstruct` with
   `name`, `prompt`, `harness`, `provider`, `model`, all optional except `name`) as the single
   in-memory + JSON-wire representation of a combo step, replacing the ad-hoc `{atom, prompt}`
   tuple across `Combo` and `Scaffold`. `from_json/1` stays backward-compatible with old
   string/`{"name","prompt"}` shapes (new fields default `nil`).
3. **Builder UI:** in each expanded step row add optional **harness / provider / model** selectors
   (registry-driven option lists, blank = inherit the build-level harness / orchestrator default),
   with cascade semantics (harness change clears provider+model; provider change clears model),
   mirroring the existing `projects_live` `model_rows/1` + console header dropdowns.
4. **Launch + persist:** `launch_adw_builder/4` emits `harness`/`provider`/`model` per step into the
   workflow step maps (consumed by `Step.from_map/1`); `Combos.save/2` persists the `StepSpec`
   fields to the sidecar; `Scaffold` embeds a per-step model into the generated Python `STEPS` and
   `run_local_workflow` honors it per step.

**Track B — complete Load discovery:**
5. **Loadable-ADW index:** a new context function assembles a merged, de-duplicated, grouped list
   of loadable entries — **saved combos** (platform root ∪ working_dir) and **discovered ADWs**
   (`@adws`, already platform ∪ working_dir) — tagged by source. Selecting a combo repopulates the
   Builder as today; selecting a discovered composite script reconstructs its steps from the
   filename stem (`adw_plan_build_review_iso` → `plan, build, review`, allowlist-validated) and its
   flavor from the `_iso`/`_local_iso`/`_direct` suffix; a stem that doesn't map to steps prefills
   only the name (no crash).
6. **UI:** replace the single combo `<select>` with an `<optgroup>`-grouped picker (Saved combos /
   Platform ADWs / Project ADWs).

All changes keep the typed-tagged-tuple / "context owns all I/O" / byte-parity-drift doctrines
intact and add no new dependency.

## Relevant Files
Use these files to implement the feature:

- `lib/repo_builder/workflow_engine/step.ex` — Step struct already has `provider`/`model`; confirm
  `from_map/1` reads per-step `harness` too (it does via `Map.fetch!("harness")`). No structural
  change; reference for the wire keys the Builder must emit.
- `lib/repo_builder/workflow_engine/runner.ex` — **Core fix:** `start_step_session/5` (≈ line 138)
  must add `provider: step.provider, model: step.model` to the `Session.Supervisor.start_session/1`
  keyword list (today only `harness:` is passed).
- `lib/repo_builder/session/supervisor.ex` / `lib/repo_builder/session/server.ex` — Confirm
  `start_session/1` forwards opts and `Server` reads `opts[:model]`/`opts[:provider]` (it does,
  server.ex:193–194). No change; validation reference.
- `lib/repo_builder/harness/registry.ex` — `orchestrator_models/2`, `orchestrator_defaults/1`
  (`:providers`) are the option-list source of truth for the per-step selectors. Reuse; no change.
- `lib/repo_builder/adw/combo.ex` — Domain value + JSON parse/serialize. Replace the `steps ::
  [{atom, prompt}]` field with `steps :: [StepSpec.t()]`; keep `from_json/1` back-compat for
  string/`{"name","prompt"}` steps; extend `to_json/1`, `parse_steps/1`, `validate/1`.
- `lib/repo_builder/adw/scaffold.ex` — Generator. `steps()` extraction and both templates must
  accept `StepSpec` (extract `.name` for the chain/`STEPS` list) and embed per-step model into the
  monolithic (`:local_iso`/`:direct`) template's `STEPS`.
- `lib/repo_builder/adw/combos.ex` — Context that calls `Scaffold.generate/1`. Thread `StepSpec`
  through `save/2`; add the merged **loadable index** function (combos platform ∪ working_dir).
- `lib/repo_builder/definitions.ex` + `lib/repo_builder/definitions/adw.ex` — Discovered `adw_*.py`
  (platform ∪ working_dir) via `Definitions.list(:adw, working_dir)` / `@adws`. Source for Track B;
  reference the `name`/`path`/`source` fields. Add a pure `steps_from_stem/1` + `flavor_from_stem/1`
  helper (either here or in `Combo`) for filename→steps reconstruction.
- `lib/repo_builder_web/components/console/adw_builder_components.ex` — The `global_command_input`
  component: add per-step harness/provider/model selectors in the expanded step row (≈ line 490);
  replace the LOAD COMBO `<select>` (≈ line 352) with the grouped `<optgroup>` picker. New attrs for
  the option lists + loadable index.
- `lib/repo_builder_web/live/console_live/adw_builder_panel.ex` — Event handlers. Add
  `adw_set_step_harness`/`adw_set_step_provider`/`adw_set_step_model` (with cascade); update
  `adw_add_step` default step map to include `harness/provider/model: nil`; update
  `resolve_steps/1` + `launch_adw_builder/4` to carry the trio; rebuild `adw_load_combo` to accept
  either a saved-combo name or a discovered-ADW path and reconstruct steps.
- `lib/repo_builder_web/live/console_live.ex` — Mount defaults (`adw_steps` shape, new
  `adw_loadable` assign) and the `<.global_command_input>` invocation (≈ line 2112) — pass the new
  loadable index + registry option lists.
- `lib/repo_builder_web/live/console_live/shared.ex` — `Combos.list(working_dir)` seeding (line 413)
  → switch to the merged loadable index.
- `adws/adw_modules/workflow_ops.py` — `run_local_workflow/…` `STEPS` normalization: accept either
  a plain `"plan"` string (back-compat) or a `{"step": "...", "model": "..."}` dict and pass the
  per-step model into the step op (`build_plan`/`implement_plan`/… `model=` / state `model_set`).
- `adws/README.md` — Per `conditional_docs.md` (row: "Anything touching the existing Python ADW
  scripts"): read before editing the Python; note the `STEPS` shape extension.

### New Files
- `lib/repo_builder/adw/step_spec.ex` — `RepoBuilder.Adw.StepSpec` typedstruct + `from_json/1`
  (back-compat) / `to_json/1` / `from_builder_map/1` (LiveView step map → StepSpec), all `@spec`'d,
  total, never raising.
- `test/repo_builder/adw/step_spec_test.exs` — Unit tests: JSON round-trip incl. per-step model,
  back-compat parse of legacy string/`{"name","prompt"}` steps, blank normalization.
- `test/repo_builder_web/live/test_adw_builder_per_step_model_test.exs` — `Phoenix.LiveViewTest`:
  add a step, set its model to a heavy model, Launch → assert the workflow's persisted step carries
  the model (and/or the started session opts); Save → assert the sidecar + generated script embed
  it. Uses the `Combos` tmp-root + a fake/Mock harness.
- `test/repo_builder_web/live/test_adw_load_discovery_test.exs` — `Phoenix.LiveViewTest`: seed a
  tmp platform root + working_dir each with an `adw_*.py`, open the Builder, assert the LOAD picker
  lists both saved combos and discovered ADWs (grouped), select a discovered composite, assert the
  steps + flavor are reconstructed.

## Implementation Plan
### Phase 1: Foundation
Land the two lowest-risk, highest-leverage changes and the shared domain type:
- The **Runner** provider/model forward (makes per-step model real for existing DB-backed runs).
- The **`StepSpec`** domain type + `Combo`/`Scaffold` migration to it, with backward-compatible JSON
  and a passing `GeneratedDriftTest` (renders from `combo.steps`). No UI yet.

### Phase 2: Core Implementation
Per-step harness/provider/model in the Builder UI, threaded into `launch_adw_builder/4` (live
engine) and persisted through `Combos.save/2` → sidecar + generated Python (`STEPS` with per-step
model, honored by `run_local_workflow`). Registry-driven option lists + cascade.

### Phase 3: Integration
Rebuild the Load control into the grouped, all-sources picker (saved combos platform ∪ local +
discovered ADWs platform ∪ local) with filename→steps reconstruction; wire the merged index through
mount/shared/component; add the LiveView tests; run the full gate.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Read the required docs
- Read `BUILD_PROMPT.md` §7 (workflow/step engine), §10 (add/swap a harness/provider), and
  `ai_docs/adw-orchestration.md` (workflow/ADW engine) and `adws/README.md` (Python `uv` scripts)
  per `.claude/commands/conditional_docs.md`.

### 2. Fix the Runner to forward per-step provider/model
- In `lib/repo_builder/workflow_engine/runner.ex`, `start_step_session/5`, add
  `provider: step.provider, model: step.model` to the `Session.Supervisor.start_session/1` keyword
  list (keep `harness: step.harness`). Blank/`nil` values are inert (Server defaults already handle
  `nil`).
- Add/extend a runner unit test asserting a step with `model`/`provider` set starts the session
  with those opts (assert via the injected Mock/Fake harness or the session start args).

### 3. Create the `RepoBuilder.Adw.StepSpec` domain type
- New `lib/repo_builder/adw/step_spec.ex`: `typedstruct enforce: true` with
  `name :: atom()`, `prompt :: String.t() | nil` (`enforce: false`),
  `harness :: String.t() | nil` (`enforce: false`),
  `provider :: String.t() | nil` (`enforce: false`),
  `model :: String.t() | nil` (`enforce: false`).
- `@spec from_json(term()) :: {:ok, t()} | {:error, reason()}` accepting: a plain `"plan"` string or
  `:plan` atom (→ name only), `{"name","prompt"}` legacy map, and the new
  `{"name","prompt","harness","provider","model"}` map. Name resolved via the fixed
  `@step_atoms` allowlist (never `String.to_atom/1`); blanks → `nil`.
- `to_json/1` → string-keyed map (omit/`null` the blank fields).
- `from_builder_map/1` → maps a LiveView builder step map (`%{name: "plan", prompt: ..., harness:
  ..., provider: ..., model: ...}`) into a `StepSpec`.
- Write `test/repo_builder/adw/step_spec_test.exs` covering round-trip, all three input shapes,
  blank normalization, and unknown-step rejection.

### 4. Migrate `Combo` to `StepSpec`
- Change `field :steps, [{atom(), String.t() | nil}]` → `field :steps, [StepSpec.t()]`.
- `parse_steps/1` delegates each element to `StepSpec.from_json/1` (keeps back-compat).
- `to_json/1` serializes each step via `StepSpec.to_json/1`.
- `from_json/1`/`validate/1` route through the new parse. Keep the `flavor()` handling untouched.
- Update `test/repo_builder/adw/combo_test.exs`/`combos_test.exs` for the new step shape + a
  per-step-model round-trip; assert legacy sidecars (string steps) still load.

### 5. Migrate `Scaffold` to accept `StepSpec` + embed per-step model
- `steps/1` extraction: accept `StepSpec` (use `.name`), plus the existing atom/tuple forms, for the
  chain list and validation.
- `:iso` template: unchanged output shape (chains `adw_<name>_iso.py`; per-step model is not
  expressible in the chaining GitHub form — document that per-step model applies to the monolithic
  flavors + the live engine, not the chained `:iso` script).
- `:local_iso` / `:direct` templates: change `STEPS = [...]` to a list where a step with a model
  renders as `{"step": "plan", "model": "opus"}` and a plain step stays `"plan"` (byte-stable when
  no model set, so `GeneratedDriftTest` and existing golden stay green for model-less combos).
- Extend `scaffold_test.exs`: a combo with a per-step model renders the dict form; a model-less
  combo is byte-identical to today.

### 6. Thread `StepSpec` through `Combos.save/2`
- `flavor_of/1` unchanged; ensure the `attrs.steps` handed to `Scaffold.generate/1` and the persisted
  `Combo` carry `StepSpec` (provider/model included). Verify `GeneratedDriftTest` stays green.

### 7. Extend the Python runner for per-step model
- In `adws/adw_modules/workflow_ops.py`, normalize each `STEPS` entry: a string → `(step, None)`; a
  dict `{"step","model"}` → `(step, model)`. Before running each step op, if a per-step model is
  present, set the state `model_set` (`"heavy" if model in ("heavy","opus") else "base"`) or pass
  `model=` where the op accepts it, restoring the prior/global model after the step. Default path
  (all plain strings) is byte-behavior-unchanged. Note the change in `adws/README.md`.

### 8. Add per-step harness/provider/model selectors to the Builder UI
- In `adw_builder_components.ex`, inside the expanded step row (after the prompt textarea, ≈ line
  503), add three `<select>`s: **harness** (`Registry.known()`, blank = inherit),
  **provider** (registry providers for the chosen harness, blank = default),
  **model** (`Registry.orchestrator_models(harness, provider)`, blank = default). Each fires
  `phx-change` with `phx-value-id={step.id}` (`adw_set_step_harness`/`_provider`/`_model`). Show the
  effective inherited value as the blank option's label (e.g. "inherit (claude)").
- Add component attrs for the per-step option lists (computed in the LiveView and passed down, or a
  small pure helper the component calls with the registry).

### 9. Wire per-step selector events + launch/persist in the panel
- In `adw_builder_panel.ex`: extend `@events` with the three new events; `adw_add_step` seeds
  `%{id, name, expanded: false, prompt: nil, harness: nil, provider: nil, model: nil}`.
- Add handlers for `adw_set_step_harness` (clears provider+model on change),
  `adw_set_step_provider` (clears model on change), `adw_set_step_model`, each updating the matching
  step in `adw_steps` (map, no `String.to_atom/1`).
- `resolve_steps/1` → build `StepSpec`s (via `StepSpec.from_builder_map/1`) instead of `{atom,
  prompt}`; `adw_save_combo` passes them to `Combos.save/2`.
- `launch_adw_builder/4`: each workflow step map gains `"harness"` (step override else the build
  harness), `"provider"`, `"model"` so `Step.from_map/1` carries them into the engine.

### 10. Build the merged loadable-ADW index (Track B foundation)
- In `RepoBuilder.Adw.Combos`, add `@spec loadable(working_dir :: String.t() | nil) :: [entry]`
  returning a typed, grouped, de-duplicated list of `%{kind: :combo | :adw, name, source: :platform
  | :project, ref, steps, flavor}` merging: `list(platform_root)` ∪ `list(working_dir)` (combos) and
  the discovered `Definitions.list(:adw, working_dir)` (ADWs). For discovered scripts, compute
  `steps` via a pure `steps_from_stem/1` (allowlist-parse the `adw_<...>_<suffix>` stem) and `flavor`
  via `flavor_from_stem/1`; an unmappable stem yields `steps: []` (name-only load).
- Unit-test `loadable/1`, `steps_from_stem/1`, `flavor_from_stem/1` (composite, single-phase, and
  unmappable stems; platform+local merge + de-dup).

### 11. Replace the Load control with the grouped picker
- In `adw_builder_components.ex`, swap the single combo `<select>` for an `<optgroup>`-grouped
  `<select>` over the loadable index (groups: Saved combos / Platform ADWs / Project ADWs). The
  option `value` encodes `kind:ref` (e.g. `combo:my_thing` / `adw:/abs/path.py`); `phx-change`
  stays `adw_load_combo`.
- `adw_load_combo` in the panel: parse the encoded value; for `combo:` load via `Combos.fetch/2`
  (as today, now StepSpec-aware, repopulating per-step harness/provider/model); for `adw:` build the
  steps from the loadable entry's reconstructed `steps` + `flavor`, prefill the name from the stem.
- Update mount default + `<.global_command_input>` invocation + `shared.ex` seeding to use
  `adw_loadable` (the merged index) instead of `adw_combos`; keep the delete (`✕`) scoped to
  `:combo` entries only.

### 12. Create the LiveView integration tests
- `test/repo_builder_web/live/test_adw_builder_per_step_model_test.exs`: mount console, open Builder,
  add a `plan` step, set its model select to a heavy model, **Launch** → assert the created
  workflow's persisted `plan` step has `model` set (query via `Workflows`/`WorkflowEngine`), and/or
  the started session opts include the model (Mock/Fake harness). Then **Save** with a tmp `Combos`
  root → assert the sidecar JSON + generated `_local_iso.py`/`_direct.py` embed the per-step model.
- `test/repo_builder_web/live/test_adw_load_discovery_test.exs`: seed a tmp platform root +
  working_dir each with an `adw_*.py` and a saved combo, open the Builder, assert the LOAD picker
  contains grouped combos + discovered ADWs from both sources, select a discovered composite (e.g.
  `adw_plan_build_review_iso.py`) → assert steps `[plan, build, review]` + flavor `:iso` populate.
- Optionally capture a Tidewave/Playwright screenshot of `http://localhost:4000` as visual proof.

### 13. Run the full validation gate
- Execute every command in **Validation Commands**; fix any failure until green with zero
  regressions. Use Tidewave `project_eval` to spot-check `Combos.loadable/1` and
  `StepSpec.from_json/1` against the live app, and `get_logs` if a LiveView test raises.

## Testing Strategy
### Unit Tests
- **Runner**: a step with `provider`/`model` starts the session with those opts; a step without is
  unchanged (regression guard).
- **StepSpec**: round-trip incl. per-step model; back-compat parse of `"plan"` / `{"name","prompt"}`;
  blank → `nil`; unknown step → `{:error, _}` (no raise).
- **Combo/Combos**: sidecar round-trips per-step model; legacy string-step sidecars still load;
  `save/2` materializes a script embedding the per-step model; `loadable/1` merges + de-dups
  platform ∪ local combos and discovered ADWs; `steps_from_stem/1`/`flavor_from_stem/1` correctness.
- **Scaffold**: model-less combo byte-identical to today (drift/golden stay green); per-step-model
  combo renders the `{"step","model"}` dict `STEPS`.
- **GeneratedDrift**: stays green (renders from `combo.steps`).
- **LiveView**: per-step model select drives Launch + Save; grouped Load picker lists and loads all
  sources.

### Edge Cases
- Per-step `harness` changed → provider+model cleared; provider changed → model cleared (cascade).
- Blank per-step harness/provider/model → step inherits the build-level harness / orchestrator
  default at launch; nothing persisted for that field.
- Tampered/unknown `phx-value` step id, provider, or model string → handler is a total no-op-ish
  update (fixed-map lookups; never `String.to_atom/1`), LiveView stays alive.
- `:iso` (chained) script + a per-step model → model applies to the live engine and the monolithic
  flavors; the chained `:iso` script documents that per-step model is not embedded (chained
  sub-scripts own their model). No silent data loss in the sidecar.
- Load a discovered script whose stem doesn't map to the step allowlist → name-only prefill, empty
  steps, no crash; delete (`✕`) is hidden for non-combo entries.
- Duplicate names across platform + local → de-duplicated deterministically (platform before
  project), consistent with `Definitions.Adw.scan/2` de-dup.
- Legacy combos with the old two-field step shape load and re-save into the new shape without loss.

## Acceptance Criteria
- Each ADW Builder step exposes optional **harness / provider / model** selectors with
  registry-driven options and cascade; blank means inherit.
- **Launch** runs each step on its selected model/provider: a step with `model: "opus"` starts its
  session with that model (verified via the workflow's persisted step and/or session opts).
- **Save combo** persists per-step provider/model to the sidecar and embeds per-step model into the
  generated `_local_iso.py`/`_direct.py` (`STEPS` dict form); a model-less combo's generated script
  is byte-identical to before.
- The **Runner** forwards `step.provider`/`step.model` to the session (regression-tested).
- The **LOAD** picker lists, grouped, every saved combo (platform ∪ local) and every discovered
  `adw_*.py` (platform ∪ local); selecting a saved combo repopulates steps incl. per-step
  model/provider; selecting a discovered composite reconstructs steps + flavor from its filename.
- `mix compile --warnings-as-errors`, `mix test --warnings-as-errors`, `mix format --check-formatted`,
  `mix credo --strict`, and `mix dialyzer` all pass with zero new warnings.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix test test/repo_builder_web/live/test_adw_builder_per_step_model_test.exs` — per-step model
  drives Launch + Save.
- `mix test test/repo_builder_web/live/test_adw_load_discovery_test.exs` — grouped all-sources Load
  picker + filename→steps reconstruction.
- `mix test test/repo_builder/adw/step_spec_test.exs test/repo_builder/adw/combos_test.exs test/repo_builder/adw/scaffold_test.exs test/repo_builder/adw/generated_drift_test.exs` —
  domain/generator/drift coverage.
- `mix test test/repo_builder/workflow_engine/runner_test.exs` — Runner forwards provider/model
  (adjust path to the actual runner test file; add the assertion there).
- `mix compile --warnings-as-errors` — clean compile; gradual type checker + `warnings_as_errors`.
- `mix test --warnings-as-errors` — full ExUnit suite (Postgres-backed) with zero failures.
- `mix format --check-formatted` — formatting.
- `mix credo --strict` — lint incl. the `@spec` gate.
- `mix dialyzer` — contract checking; no new warnings, no stale ignores.
- (Optional, `uv` present) `uv run adws/adw_<name>_local_iso.py <adw-id>` against a scratch
  `agents/<adw-id>/run.json` whose combo carries a per-step model — manual `:external` smoke that the
  generated script honors the per-step model; NOT part of the `mix` gate.

## Notes
- **No new dependency** required.
- **Why the Runner fix is separate and first:** `Step` already has `provider`/`model` and
  `Session.Server` already reads them — the only missing link at runtime is the two keyword entries
  in `runner.ex`. Shipping that first delivers per-step model for the live engine even before the UI
  lands, and de-risks the rest.
- **`:iso` (chained) flavor limitation:** the GitHub chaining form spawns `adw_<step>_iso.py`
  sub-scripts that each own their model; a single composite `STEPS`-embedded model doesn't apply
  there. Per-step model is therefore embedded only in the monolithic `:local_iso`/`:direct`
  templates and honored fully by the live workflow engine; the sidecar always retains the per-step
  model regardless of flavor, so re-generating to a monolithic flavor preserves it.
- **StepSpec migration is back-compat by construction:** `from_json/1` accepts the legacy string /
  `{"name","prompt"}` shapes, so existing `.combos/*.json` sidecars load unchanged and re-save into
  the richer shape. `GeneratedDriftTest` renders from `combo.steps`, so model-less combos stay
  byte-stable.
- **Filename→steps reconstruction** relies on the composite naming convention
  (`adw_<step>[_<step>...]_<suffix>.py`) shared with `Scaffold`/`adw_new.py`; it is best-effort and
  purely additive (unmappable stems degrade to name-only), never blocking a load.
- **Future considerations:** (a) a build-level "apply this model to all steps" shortcut; (b)
  surfacing per-step estimated cost using `RepoBuilder.Harness.Pricing`; (c) letting the chained
  `:iso` sub-scripts accept a `--model` passthrough so per-step model reaches that flavor too.
