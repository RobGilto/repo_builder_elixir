# Worker report: ph3-recon (idle)

Now I have everything. Here's the structured report:

---

## Read-Only Reconnaissance Report

---

### 1. `adws/adw_modules/workflow_ops.py` — `run_local_workflow`

**✅ PRESENT — line 830**

```python
def run_local_workflow(adw_id: str, steps: list, logger) -> None:
    """Run an ordered `steps` list against the single-`<adw-id>` + run.json local
    contract, in ONE isolated worktree, narrating progress via emit_event.

    Generalized from `adw_plan_build_local_iso.py`: it loads + validates the run
    record, synthesizes a local issue, sets up the worktree/branch/ports once,
    then iterates the steps running the correct inline op per step:

        plan     -> build_plan (/feature)      test     -> run_tests (/test)
        build    -> implement_plan (/implement) review   -> run_review (/review)
        patch    -> create_and_implement_patch  document -> generate_documentation
        ship     -> commit + best-effort PR

    The worktree is committed once after the implementing steps (mirroring the
    shipped plan+build composite). Faithful to the existing local composites so
    already-shipping recipes behave identically.
    """
```

Body (lines 849–875+): loads run record via `local_ops.load_run`, validates prompt, normalizes steps, calls `local_ops.update_run`, narrates start, synthesizes issue via `local_ops.synthesize_issue(run)`, then continues iterating steps. **174 more lines** (step dispatch loop).

---

### 2. `lib/repo_builder_web/live/console_live.ex` — Combo handle_events

**✅ ALL THREE PRESENT:**

- `handle_event("adw_set_name", ...)` — **line 1622**
  ```elixir
  def handle_event("adw_set_name", %{"name" => name}, socket) do
    {:noreply, assign(socket, adw_name: name)}
  end
  ```

- `handle_event("adw_load_combo", ...)` — **lines 1700 & 1704** (two clauses: blank + named)
  ```elixir
  # Load-combo reuse: repopulate the builder (steps + flavor + spec + prompt + name)
  # from a saved combo. A blank selection is a no-op that just clears the highlight.
  def handle_event("adw_load_combo", %{"combo" => ""}, socket) do
    {:noreply, assign(socket, adw_selected_combo: "")}
  end

  def handle_event("adw_load_combo", %{"combo" => name}, socket) do
    working_dir = nilify_blank(socket.assigns.orchestrator_working_dir)

    case Combos.fetch(name, working_dir) do
      {:ok, combo} ->
        steps = ...
  ```

- `handle_event("adw_delete_combo", ...)` — **line 1738**
  ```elixir
  # Delete a saved combo's sidecar (the generated .py stays a normal discovered ADW),
  # then re-seed the combo list so the dropdown stays fresh.
  def handle_event("adw_delete_combo", %{"combo" => name}, socket) do
    working_dir = nilify_blank(socket.assigns.orchestrator_working_dir)

    case Combos.delete(name, working_dir) do
      :ok ->
        socket =
          socket
          |> assign(adw_combos: Combos.list(working_dir), adw_selected_combo: "")
  ```

**`seed_definitions/1`** — **line 669** (private `@spec`'d at 669, body at 670):
```elixir
@spec seed_definitions(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
defp seed_definitions(socket) do
  working_dir = nilify_blank(socket.assigns.orchestrator_working_dir)

  %{slash_command: slash, agent: agents, adw: adws} =
    Definitions.all(working_dir)

  assign(socket,
    slash_commands: slash,
    agent_defs: agents,
    adws: adws,
    adw_combos: Combos.list(working_dir)   # ← YES, seeds Combos.list
  )
end
```

---

### 3. `lib/repo_builder_web/components/console_components.ex` — Load-combo select + attrs

**✅ SELECT element — line 4154:**
```html
<select
  name="combo"
  phx-change="adw_load_combo"
  ...
>
```
Note: the `name` attribute is `"combo"` (not `"adw_load_combo"` — the event is driven by `phx-change`, not the name).

**✅ ATTRS declared — lines 3889–3890:**
```elixir
attr :adw_combos, :list, default: []
attr :adw_selected_combo, :string, default: ""
```

**✅ LOAD COMBO block** (with Delete ✕ button) at **lines 4148–4173**:
- `div :if={@adw_combos != []}` wrapper
- `<select name="combo" phx-change="adw_load_combo">`
- blank option + `:for={combo <- @adw_combos}`
- Delete button `phx-click="adw_delete_combo" phx-value-combo={@adw_selected_combo}`

---

### 4. `test/repo_builder_web/live/test_adw_builder_combos_test.exs` — Phase-3 test

**✅ EXISTS.** Four test functions:

| # | Test name |
|---|-----------|
| 1 | `"the builder renders Spec + Initial-prompt textareas and launches with real prompts"` |
| 2 | `"launching with a blank spec and prompt still succeeds (name-only fallback)"` |
| 3 | `"Phase 3: save materializes sidecar + script, palette shows the chip, load repopulates"` |
| — | Helper: `render_template/2` |

**Phase 3 test body** (lines 108–170): uses a temp dir, sets `Combos` + `Definitions` env overrides, builds a `plan → build → review` combo named `"demo_pbr"`, clicks `adw_save_combo`, then asserts:
1. `demo_pbr.json` sidecar exists in `adws/.combos/`
2. `adw_demo_pbr_iso.py` exists in `adws/`
3. `Combos.list(nil)` includes `"demo_pbr"`
4. `Definitions.list(:adw, nil)` includes a `"demo_pbr_iso"` entry
5. After toggling out/in the builder, loading the combo repopulates `plan`, `build`, `review` steps + spec + prompt textareas.

---

### 5. `@adw_builder?` branch — full `global_command_input/1` section

Lines **4148–~4300** (`<div :if={@adw_builder?}>` in `global_command_input/1`):

```elixir
<div :if={@adw_builder?} class="cns-adw-builder">
  <%!-- Header bar with name input + local toggle + Save button --%>
  <%!-- Load combo: select with phx-change="adw_load_combo" + ✕ delete button --%>
  <%!-- Spec textarea (phx-change="adw_set_spec") --%>
  <%!-- Initial prompt textarea (phx-change="adw_set_prompt") --%>
  <%!-- Step palette: +plan +patch +build +test +review +document +ship --%>
  <%!-- Step list: rendered rows with step name, on-success chain --%>
  <%!-- Run button: phx-click="run_adw_builder" --%>
</div>
```

Full section spans **~150 lines** inside `global_command_input/1`.

---

### 6. `ls lib/repo_builder/adw/`

```
combo.ex      ← RepoBuilder.Adw.Combo
combos.ex     ← RepoBuilder.Adw.Combos
scaffold.ex   ← RepoBuilder.Adw.Scaffold
```

---

### 7. `adw_plan_build_local_iso.py` — step-threading approach

**9 local-iso scripts exist:**
```
adw_patch_local_iso.py
adw_plan_build_document_local_iso.py
adw_plan_build_local_iso.py
adw_plan_build_review_local_iso.py
adw_plan_build_test_local_iso.py
adw_plan_build_test_review_local_iso.py
adw_plan_local_iso.py
adw_sdlc_local_iso.py
```

**`adw_plan_build_local_iso.py` (318 lines) does NOT call `run_local_workflow`.** It imports `build_plan`, `implement_plan`, `create_commit`, `AGENT_PLANNER`, `AGENT_IMPLEMENTOR` from `workflow_ops` — but `run_local_workflow` is imported **zero times**.

The step threading is **fully inlined** (lines 212–302):

```python
# --- Plan step ---
local_ops.step_start(adw_id, "plan", summary="planning via /feature")
step_t0 = time.monotonic()

plan_response = build_plan(issue, ISSUE_CLASS, adw_id, logger, working_dir=worktree_path)
if not plan_response.success:
    local_ops.step_end(adw_id, "plan", "failed")
    fail(adw_id, "plan", ...)
...
local_ops.step_end(adw_id, "plan", "completed", duration_ms=..., summary=f"spec: {spec_file}")
narrate(adw_id, f"✅ Plan created: {spec_file}", agent_name=AGENT_PLANNER)

# --- Build step ---
local_ops.step_start(adw_id, "build", summary=f"implementing {spec_file}")
step_t0 = time.monotonic()

build_response = implement_plan(spec_file, adw_id, logger, working_dir=worktree_path)
if not build_response.success:
    ...
local_ops.step_end(adw_id, "build", "completed", ...)
narrate(adw_id, "✅ Implementation complete", agent_name=AGENT_IMPLEMENTOR)

# Commit
create_commit(...); commit_changes(...)
local_ops.update_run(adw_id, status=local_ops.COMPLETED, completed_steps=2, ...)
```

**Summary:** `run_local_workflow` exists in `workflow_ops.py` but is a **generalized generalization** — `adw_plan_build_local_iso.py` does not use it. The 2-step (plan + build) thread is hard-coded/inline.

---

### Summary Table

| # | Item | Status | Location |
|---|------|--------|----------|
| 1 | `run_local_workflow` defined | ✅ Yes | `workflow_ops.py:830` |
| 2 | `adw_set_name` handler | ✅ Yes | `console_live.ex:1622` |
| 2 | `adw_load_combo` handler (2 clauses) | ✅ Yes | `console_live.ex:1700,1704` |
| 2 | `adw_delete_combo` handler | ✅ Yes | `console_live.ex:1738` |
| 2 | `seed_definitions` seeds `adw_combos: Combos.list` | ✅ Yes | `console_live.ex:680` |
| 3 | Load-combo `<select phx-change="adw_load_combo">` | ✅ Yes | `console_components.ex:4154` |
| 3 | `attr :adw_combos` + `attr :adw_selected_combo` | ✅ Yes | `console_components.ex:3889–3890` |
| 4 | Phase-3 end-to-end combo test | ✅ Yes | `test_adw_builder_combos_test.exs:108` |
| 5 | Full `@adw_builder?` branch | ✅ Yes | `console_components.ex:4148–~4300` |
| 6 | `combo.ex` + `combos.ex` + `scaffold.ex` | ✅ All 3 | `lib/repo_builder/adw/` |
| 7 | `adw_plan_build_local_iso.py` step threading | ⛔ NOT via `run_local_workflow` | Inlined, lines 212–302 |
