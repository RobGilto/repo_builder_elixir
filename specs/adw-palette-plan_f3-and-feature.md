---
title: "ADW Builder palette — surface `plan_f3` and `feature` as first-class distinct steps"
status: complete
owner: spec-writer
date: 2026-07-04
workstream_id: fd07b677-b53f-4923-b09b-14dcdbe330db
completed: 2026-07-05
impl_commits:
  - 5c5daac perf(console): mount seed optimization — 480ms → 81ms first paint
  - adw-palette-plan_f3-and-feature implementation (see Definition of Done)
---

# Goal

The ADW Builder palette (the LiveView chip row that composes ADW step pipelines) currently
folds two semantically distinct slash commands into one chip via a display-label indirection:
`adw_step_command("plan") → "feature"`, so the user sees `+ feature`, clicks, and
`phx-value-step="plan"` is sent. By happy accident the runtime then classifies the issue
and runs `/feature` — but the user has no way to surface `/plan_f3` at all, and the
mapping from chip to slash command is opaque. We add `:plan_f3` and `:feature` as
distinct first-class step atoms, drop the `plan → feature` display alias so each chip's
label matches its step, and plumb each atom through to its own slash command in the
Python ADW runtime so no chip relies on classification to pick its command.

# Definition of Done

- [x] `lib/repo_builder/adw/step_spec.ex` `@step_atoms` map includes `"plan_f3" => :plan_f3` and `"feature" => :feature`. ✅ (lines 26-27)
- [x] `lib/repo_builder/adw/scaffold.ex` `@valid_steps` list includes `:plan_f3` and `:feature`. ✅ (line 40)
- [x] `lib/repo_builder_web/live/console_live/adw_builder_panel.ex` `@type step_atom` union includes `:plan_f3` and `:feature`. ✅ (lines 326-327)
- [x] `lib/repo_builder_web/components/console/adw_builder_components.ex` chip row literal lists `plan_f3` and `feature` alongside `plan` (both `plan` and `plan_f3` are present as separate entries — not relabelled). ✅ (line 467)
- [x] `adw_step_command/1` no longer maps `"plan" → "feature"`. The mapper drops that clause; `adw_step_command("plan")` returns `"plan"`, `adw_step_command("plan_f3")` returns `"plan_f3"`, `adw_step_command("feature")` returns `"feature"`. ✅ (lines 841-844)
- [x] `adws/adw_new.py` `VALID_STEPS` includes `"plan_f3"` and `"feature"`, with a step block per atom that directly invokes the named slash command (no `classify_issue` indirection for either). ✅ (lines 28, 48-62, 90-95)
- [x] `mix compile --warnings-as-errors` and `mix dialyzer` pass. ✅
- [x] New unit + LiveView tests under `test/repo_builder_web/live/test_adw_builder_palette_plan_f3_test.exs` (modelled on `test_adw_builder_save_combo_test.exs`) cover the chip row, dispatch, persistence, and Python mapping. ✅
- [x] A migration note exists for any persisted combo JSON on disk that contained `"name": "plan"` under the old alias scheme (see Risks §8). ✅ `:plan` kept as first-class atom — no migration needed, legacy combos load unchanged.

# Current State (as-is)

## `lib/repo_builder/adw/step_spec.ex` — lines 22-30

Step allowlist — the only place wire strings are resolved to atoms. Missing `:plan_f3` and `:feature`.

```elixir
# Step allowlist — parity with `adws/adw_new.py:VALID_STEPS` and `Scaffold.valid_steps/0`.
# Fixed string→atom map so untrusted wire strings never reach `String.to_atom/1`.
@step_atoms %{
  "plan" => :plan,
  "patch" => :patch,
  "build" => :build,
  "test" => :test,
  "review" => :review,
  "document" => :document,
  "ship" => :ship
}
```

## `lib/repo_builder/adw/scaffold.ex` — line 39

```elixir
# Step allowlist parity with `adws/adw_new.py:VALID_STEPS`.
@valid_steps [:plan, :patch, :build, :test, :review, :document, :ship]
```

## `lib/repo_builder_web/live/console_live/adw_builder_panel.ex` — line 326

```elixir
@type step_atom :: :build | :document | :patch | :plan | :review | :ship | :test
```

## `lib/repo_builder_web/components/console/adw_builder_components.ex`

**Lines 472-476 — chip row literal** (the `~w(...)` list passed to render):

```elixir
~w(plan patch build test review document ship)
```

**Lines 842-870 — `adw_step_command/1` display mapper** — the indirection the user is calling out. The doc comment above the head explicitly admits the label "is NOT the canonical step name":

```elixir
# adws/adw_modules/workflow_ops.py). Chip + step-row labels show THIS — the md that
# runs — so what the operator clicks names the real prompt. The canonical step id
# (plan/build/…) stays the pipeline vocabulary the Python dispatch and adw_new.py
# VALID_STEPS allowlist match on, so only the DISPLAY label changes here.
@spec adw_step_command(String.t()) :: String.t()
defp adw_step_command("plan"), do: "feature"
defp adw_step_command("build"), do: "implement"
defp adw_step_command("ship"), do: "commit + pr"
defp adw_step_command(other), do: other
```

## `adws/adw_modules/workflow_ops.py` — line 170

```python
PLAN_CAPABLE_COMMANDS = ("/plan_f3", "/feature", "/bug", "/chore")
```

`resolve_plan_command(issue_class)` (lines 173-185) reads `ADW_PLAN_COMMAND` env;
if unset it returns `issue_class` (which is `/feature|/bug|/chore`), so today
**`/plan_f3` is reachable only via env override, never by step name**. `build_plan(command, ...)`
threads the resolved command through `AgentTemplateRequest` (line 207).

The plan iso scripts (`adw_plan_iso.py:142`, `adw_plan_local_iso.py:170`) **always**
classify the issue (`classify_issue(...)`) and pass the classified command into
`build_plan`. The classic `ISSUE_CLASS = "/feature"` constant (`adw_plan_local_iso.py:67`,
`adw_plan_build_local_iso.py:65`, etc.) is hard-coded for prompt-driven local runs;
**none of them invoke `/plan_f3` by step name today**.

## `adws/adw_modules/data_types.py` — line 73

```python
SlashCommand = Literal[
    "/chore", "/bug", "/feature",
    "/plan_f3",  # HTML-first planner (repo-vendored planf3; plan-step alternative to the class commands)
    "/classify_issue", "/classify_adw", "/generate_branch_name",
    "/commit", "/pull_request", "/implement",
    …
]
```

`/plan_f3` is already a first-class `SlashCommand` and already maps to `{base: "main", heavy: "heavy"}` in `adws/adw_modules/agent.py:53`. Both the type system and the model-tier config already know about it. The wiring gap is purely in the builder palette and the per-step-atom slash-command mapping.

## `.claude/commands/plan_f3.md`

Exists — the slash command body for `/plan_f3` (HTML-first planning into `specs/`, planf3 format). Already discoverable by the Python runtime.

# Desired State (to-be)

## Decision summary

1. **Two new step atoms**, `:plan_f3` and `:feature`. `:plan` stays as a first-class atom — it represents the legacy "classify then build-plan" flow.
2. **Drop the `plan → feature` display alias.** Keep `build → implement` and `ship → commit + pr` (operator-friendly labels for non-planning steps). Every planning atom displays its canonical name.
3. **Each plan-flavoured atom maps to its own slash command at scaffold time.** No `classify_issue` indirection in the composite script for `:plan_f3` or `:feature`.
4. **Persisted `plan` combos keep working as-is** (Decision: keep `:plan` for backwards-compat — see §8).

## `lib/repo_builder/adw/step_spec.ex` — lines 22-30

```diff
 @step_atoms %{
   "plan"      => :plan,
+  "plan_f3"   => :plan_f3,
+  "feature"   => :feature,
   "patch"     => :patch,
   "build"     => :build,
   "test"      => :test,
   "review"    => :review,
   "document"  => :document,
   "ship"      => :ship
 }
```

## `lib/repo_builder/adw/scaffold.ex` — line 39

```diff
-@valid_steps [:plan, :patch, :build, :test, :review, :document, :ship]
+@valid_steps [:plan, :plan_f3, :feature, :patch, :build, :test, :review, :document, :ship]
```

## `lib/repo_builder_web/live/console_live/adw_builder_panel.ex` — line 326

```diff
-@type step_atom :: :build | :document | :patch | :plan | :review | :ship | :test
+@type step_atom ::
+         :build | :document | :feature | :patch | :plan | :plan_f3 | :review | :ship | :test
```

The `step_resolution/0` typedef below it does not need to change — it already returns `[StepSpec.t()]` whose `name` is `atom()`.

## `lib/repo_builder_web/components/console/adw_builder_components.ex` — line 472 + lines 842-846

```diff
-~w(plan patch build test review document ship)
+~w(plan plan_f3 feature patch build test review document ship)
```

```diff
 @spec adw_step_command(String.t()) :: String.t()
-defp adw_step_command("plan"), do: "feature"
 defp adw_step_command("build"), do: "implement"
 defp adw_step_command("ship"), do: "commit + pr"
 defp adw_step_command(other), do: other
```

With the alias dropped, `adw_step_command("plan")` returns `"plan"` (passthrough), `adw_step_command("plan_f3")` returns `"plan_f3"`, `adw_step_command("feature")` returns `"feature"`. Add an updated doc comment that no longer claims the label is the slash command — it's the step display name:

```diff
-# Chip + step-row labels show THIS — the md that runs — so what the operator clicks
-# names the real prompt. The canonical step id (plan/build/…) stays the pipeline
-# vocabulary the Python dispatch and adw_new.py VALID_STEPS allowlist match on, so
-# only the DISPLAY label changes here.
+# Step display label. The chip and step-row both render this. The canonical step id
+# (the atom in @step_atoms) is what gets sent on phx-value-step and what Python
+# VALID_STEPS allowlists. The only optional aliases left are operator-friendly
+# shortenings for non-planning steps (build→implement, ship→commit + pr).
```

The `adw_step_hint/1` function (lines 848-862) does NOT need to change — its `plan`/`build`/`ship` clauses still describe the legacy plan/build/ship flows. The new `:feature` chip will fall through to `adw_step_hint(other) -> "/#{other} — custom step."` — that's fine for v1; the next iteration can add explicit hints (out of scope here).

## `adws/adw_new.py` — line 99 + a new step block

```diff
-VALID_STEPS = ["plan", "patch", "build", "test", "review", "document", "ship"]
+VALID_STEPS = ["plan", "plan_f3", "feature", "patch", "build", "test", "review", "document", "ship"]
```

Add two new step blocks in the scaffold generator. `plan_f3` and `feature` both
invoke `adw_plan_iso.py` (or a thin variant) directly with a hard-coded slash
command, skipping `classify_issue`:

```python
# plan_f3: HTML-first planning into specs/ — always runs /plan_f3
plan_f3_block = """    # Plan_f3: HTML-first planning into specs/ via /plan_f3 (no classify_issue).
    print(f"\\\\n=== PLAN_F3 PHASE ===")
    from adw_modules.workflow_ops import build_plan
    plan_resp, plan_err = build_plan(issue, "/plan_f3", adw_id, logger, working_dir=script_dir)
    if plan_err:
        sys.exit(f"plan_f3 step failed: {plan_err}")"""

# feature: direct /feature planning (no classify_issue, no /bug-/chore rerouting)
feature_block = """    # Feature: direct /feature planning (no classify_issue, no /bug-/chore rerouting).
    print(f"\\\\n=== FEATURE PHASE ===")
    from adw_modules.workflow_ops import build_plan
    plan_resp, plan_err = build_plan(issue, "/feature", adw_id, logger, working_dir=script_dir)
    if plan_err:
        sys.exit(f"feature step failed: {plan_err}")"""
```

Wire them into the loop right above the existing `if step == "ship" and local` branch:

```diff
 for step in steps:
     if step == "ship" and local:
         step_blocks.append(local_ship_block)
         continue
+    if step == "plan_f3":
+        step_blocks.append(plan_f3_block)
+        continue
+    if step == "feature":
+        step_blocks.append(feature_block)
+        continue
     var = step.replace("-", "_")
     …
```

This guarantees a `[plan_f3, build, test]` combo produces a script whose first phase
unconditionally calls `build_plan(issue, "/plan_f3", ...)`, with no possibility of the
classifier rerouting to `/bug` or `/chore`. Likewise `[feature, build, test]` calls
`build_plan(issue, "/feature", ...)` directly.

`adws/adw_modules/agent.py:53` and `adws/adw_modules/data_types.py:73` already model
`/plan_f3` correctly — no Python type/tier changes needed.

`adws/adw_modules/workflow_ops.py:170` `PLAN_CAPABLE_COMMANDS` already includes
`/plan_f3` — no change needed there either.

# Files to change

- **lib/repo_builder/adw/step_spec.ex** — add two entries to `@step_atoms`. Rationale: this is the single string→atom map; missing entries cause `to_step_atom/1` to return `{:error, {:unknown_step, _}}` and would block combo saves.
- **lib/repo_builder/adw/scaffold.ex** — extend `@valid_steps`. Rationale: scaffold validation runs the list before generating the composite Python script; missing entries raise.
- **lib/repo_builder_web/live/console_live/adw_builder_panel.ex** — extend the `@type step_atom` union. Rationale: this typedef drives dialyzer; adding the atoms here keeps the LiveView compile-clean and exposes them as a closed vocabulary to `resolve_steps/1`.
- **lib/repo_builder_web/components/console/adw_builder_components.ex** — extend the chip-row literal to `~w(plan plan_f3 feature patch build test review document ship)`; drop the `plan → feature` display alias clause in `adw_step_command/1`. Rationale: these two edits are exactly the user-visible change ("feature and plan_f3 are two different beasts — visibly distinct").
- **adws/adw_new.py** — add `"plan_f3"` and `"feature"` to `VALID_STEPS`; add a `plan_f3_block` and `feature_block` scaffold snippet and dispatch them in the step loop. Rationale: `VALID_STEPS` is the Python allowlist for `adw_new.py --steps`; the new step blocks define what the composite script does for each atom.
- **specs/adw-palette-plan_f3-and-feature.md** — this file. (Self-reference for traceability; the spec is the deliverable.)
- **test/repo_builder_web/live/test_adw_builder_palette_plan_f3_test.exs** — new test file. Rationale: regression coverage for the chip row, persistence, and Python scaffolding is missing; without it the alias regression can silently come back.

# Tests

New file: `test/repo_builder_web/live/test_adw_builder_palette_plan_f3_test.exs`.
Model on `test/repo_builder_web/live/test_adw_builder_save_combo_test.exs` (stub
`Combos` + `Definitions` at a tmp dir, observe generated `adws/*.py`).

```elixir
defmodule RepoBuilderWeb.TestAdwBuilderPalettePlanF3Test do
  @moduledoc """
  Regression tests for the ADW Builder palette: `plan_f3` and `feature` are
  first-class steps with distinct chips and slash commands, and no chip relies
  on display-label aliasing to decide what slash command runs.
  """
  use RepoBuilderWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias RepoBuilder.Adw.Combos
  alias RepoBuilder.Definitions
  alias RepoBuilderWeb.ConsoleLive.AdwBuilderPanel

  # mirror the same tmp-dir seam as test_adw_builder_save_combo_test.exs

  describe "to_step_atom/1 — palette entries" do
    test "plan_f3 resolves" do
      assert {:ok, :plan_f3} = AdwBuilderPanel.to_step_atom("plan_f3")
    end

    test "feature resolves" do
      assert {:ok, :feature} = AdwBuilderPanel.to_step_atom("feature")
    end

    test "plan still resolves (backwards-compat)" do
      assert {:ok, :plan} = AdwBuilderPanel.to_step_atom("plan")
    end

    test "unknown steps still return tagged error, never raise" do
      assert {:error, {:unknown_step, "PLAN_F3"}} = AdwBuilderPanel.to_step_atom("PLAN_F3")
      assert {:error, {:unknown_step, "Feature"}} = AdwBuilderPanel.to_step_atom("Feature")
    end
  end

  describe "chip row + dispatch (LiveView integration)" do
    # … tmp-dir setup identical to save_combo test …

    test "the chip row renders plan, plan_f3 and feature as separate buttons" do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "toggle_adw_builder")

      assert has_element?(view, "button[phx-click=\"adw_add_step\"][phx-value-step=\"plan\"]")
      assert has_element?(view, "button[phx-click=\"adw_add_step\"][phx-value-step=\"plan_f3\"]")
      assert has_element?(view, "button[phx-click=\"adw_add_step\"][phx-value-step=\"feature\"]")
    end

    test "chip labels match step atoms — no plan→feature aliasing" do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "toggle_adw_builder")
      html = render(view)
      # The display label on every chip is its canonical step name.
      assert html =~ ~s(>+ plan<)
      assert html =~ ~s(>+ plan_f3<)
      assert html =~ ~s(>+ feature<)
      refute html =~ ~s(>feature<) |> negate_for_step_button  # negative grep below

      # Specifically: no button has phx-value-step="plan" while displaying "+ feature".
      refute has_element?(
               view,
               ~s(button[phx-value-step="plan"]:contains("+ feature"))
             )
    end

    test "clicking plan_f3 adds the step with name=\"plan_f3\" on the row", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "toggle_adw_builder")
      render_click(view, "adw_add_step", %{"step" => "plan_f3"})
      html = render(view)
      assert has_element?(view, "button[phx-click=\"adw_add_step\"][phx-value-step=\"plan_f3\"]")
      # the step-row badge reflects the canonical step name
      assert html =~ "plan_f3"
      refute html =~ "+ feature"  # no alias leakage
    end

    test "clicking feature adds the step with name=\"feature\" on the row", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "toggle_adw_builder")
      render_click(view, "adw_add_step", %{"step" => "feature"})
      assert has_element?(view, "button[phx-click=\"adw_add_step\"][phx-value-step=\"feature\"]")
      assert render(view) =~ "feature"
    end
  end

  describe "scaffold (Python composite script generation)" do
    test "[plan_f3, build, test] generates a script whose first phase calls build_plan(... /plan_f3 ...)" do
      assert {:ok, %RepoBuilder.Adw.Scaffold.Generated{path: path, script: script}} =
               RepoBuilder.Adw.Scaffold.run("plan_f3-build-test", [:plan_f3, :build, :test], flavor: :iso)

      assert File.exists?(path)
      assert script =~ ~s(/plan_f3)
      # and does NOT mention /bug or /chore classification rerouting
      refute script =~ "classify_issue"
    end

    test "[feature, build, test] generates a script whose first phase calls build_plan(... /feature ...)" do
      assert {:ok, %RepoBuilder.Adw.Scaffold.Generated{path: path, script: script}} =
               RepoBuilder.Adw.Scaffold.run("feature-build-test", [:feature, :build, :test], flavor: :iso)

      assert File.exists?(path)
      assert script =~ ~s(/feature)
      refute script =~ "classify_issue"
    end

    test "legacy [plan, build, test] still classifies (backwards-compat)" do
      assert {:ok, %RepoBuilder.Adw.Scaffold.Generated{script: script}} =
               RepoBuilder.Adw.Scaffold.run("plan-build-test", [:plan, :build, :test], flavor: :iso)
      # The legacy plan block still classifies — this guard prevents an accidental
      # rewrite of the legacy semantics in the same diff.
      assert script =~ "classify_issue"
    end

    test "Scaffold refuses unknown atoms with {:error, _} (never raises)" do
      assert {:error, _} = RepoBuilder.Adw.Scaffold.run("bad", [:bogus], flavor: :iso)
    end
  end

  describe "persisted combos on disk (backwards-compat)" do
    test "a legacy combo JSON with name:\"plan\" round-trips unchanged via Combos.list" do
      legacy = %{
        "name" => "plan-build-test",
        "steps" => [
          %{"name" => "plan", "prompt" => nil},
          %{"name" => "build", "prompt" => nil},
          %{"name" => "test", "prompt" => nil}
        ]
      }

      sidecar = Path.join([tmp, "adws", ".combos", "plan-build-test.json"])
      File.mkdir_p!(Path.dirname(sidecar))
      File.write!(sidecar, Jason.encode!(legacy))

      assert [%{name: "plan-build-test"} = combo] = Combos.list(nil)
      assert Enum.map(combo.steps, & &1.name) == [:plan, :build, :test]
    end
  end
end
```

**Test names at a glance**
1. `to_step_atom/1` — `plan_f3 resolves`, `feature resolves`, `plan still resolves (backwards-compat)`, `unknown steps still return tagged error, never raise`.
2. Chip-row LiveView — `renders plan, plan_f3, feature as separate buttons`, `chip labels match step atoms — no plan→feature aliasing`, `clicking plan_f3 adds the step with name="plan_f3"`, `clicking feature adds the step with name="feature"`.
3. Scaffold (Python composite) — `[plan_f3, build, test] generates a script ... /plan_f3 ...`, `[feature, build, test] generates a script ... /feature ...`, `legacy [plan, build, test] still classifies (backwards-compat)`, `Scaffold refuses unknown atoms with {:error, _}`.
4. Persisted combos — `a legacy combo JSON with name:"plan" round-trips unchanged via Combos.list`.

# Edge cases / risks

## Backwards-compat for persisted combos

**Decision: option (a) — keep `:plan` as a first-class step.** The atom stays in `@step_atoms`, `@valid_steps`, the type union, and Python `VALID_STEPS`. Any combo JSON on disk with `"name": "plan"` steps loads unchanged via `Combos.list/1`, resolves through `to_step_atom("plan")` to `:plan`, and scaffolds a script that still classifies. **No one-shot migration is required.**

The risk we are deliberately carrying: an operator who clicks the new `+ feature` chip from this point forward is opting into "always `/feature`" semantics, which is a behavioral change vs. the legacy `+ plan` chip (which used to run `/feature|/bug|/chore` depending on classification). That is intentional — the user is right that the two are different beasts. The legacy chip stays available so old workflows keep running; new ones pick deliberately.

If a user complaints lands about a combo that used to silently include bugs/chores, the
fallback is to add an `:auto` step in a follow-up that re-exposes classification under
its own canonical name — out of scope here.

## Dialyzer

- `step_atom/0` union MUST be extended before any code that pattern-matches on it
  (e.g. `case Atom.to_string(step)` inside the panel). New atoms without union
  membership would surface as `no_return` or `no_match` warnings. `mix dialyzer`
  gates this.
- `to_step_atom/1`'s `@spec` returns `{:ok, step_atom()} | {:error, ...}` —
  extending the union keeps the spec honest.

## `String.to_atom/1` rule

All new atoms enter exclusively through the `@step_atoms` map in `step_spec.ex`;
wire strings (phx-value-step, combo JSON) are looked up there with no fallthrough
to `String.to_existing_atom/1`. The regression in `test_adw_builder_save_combo_test.exs`
already proves this contract — the new tests extend, not weaken, it.

## Python display contract

`/plan_f3` is wired into both `data_types.SlashCommand` and `agent.py` model-tier
config today; we are not adding a new Python type. The risk is purely in
`adw_new.py`: if the new step blocks reference a module path that the composite
script's `sys.path.insert(0, ...)` does not provide, the import fails at runtime.
Mitigation: keep the new blocks importing from `adw_modules.workflow_ops` (same
import the existing scaffold already performs indirectly via the iso-script
subprocess), and run `mix precommit` plus a manual `uv run adw_<combo>_iso.py --dry-run`
on a generated fixture before merging.

## UI density

Three planning-flavoured chips in a row is denser than before. If the team
objects, the next iteration can move them into a `<select>` overflow — out of scope here.

## Out of scope

- Adding explicit `adw_step_hint/1` clauses for `plan_f3` and `feature`. The plan-hint text for `:feature` already happens to describe `/feature` correctly via the catch-all `adw_step_hint(other) -> "/#{other} — custom step."`; tightening this is a content-only follow-up.
- Adding a `:auto` (classify-then-dispatch) step. Would only land if a user explicitly asks for the legacy-classification behaviour under its own canonical name.
- Updating the local-flavor iso scripts (`adw_plan_*_local_iso.py`) whose `ISSUE_CLASS = "/feature"` constant hard-codes the prompt-driven default. Those scripts never appear in the LiveView palette; they are CLI-prompted. Leave them alone.
- Updating the `adw_step_hint/1` doc comment block — only the mapper doc and chip-row literal change in this diff.
- HTML rendering / flash messages for the new steps beyond the existing `to_form/2` plumbing.
- A `mc_version` or schema bump of saved combo sidecar JSON — the new atoms are
  additive; old JSONs without them still parse.