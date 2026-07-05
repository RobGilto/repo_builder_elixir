# Worker report: scout-adw-m3 (idle)

I have everything I need. Let me compile the final recon report.

---

# ADW "Save combo" — read-only recon handoff

## (a) The full click → handler → writer call chain (with file:line refs)

### Step 1 — Button is rendered
**File:** `lib/repo_builder_web/components/console/adw_builder_components.ex`, lines 471–489 (the ⭑ Save combo button), inside the `global_command_input/1` HEEx function.

```heex
471  <%!-- Save + Launch buttons. "Save combo" persists the current build as a
472       named JSON sidecar AND materializes a portable adws/adw_<name>_iso.py
473       (or _local_iso.py) that surfaces in the ADWs palette. --%>
474  <div class="flex items-center justify-end gap-2">
475    <button
476      type="button"
477      phx-click="adw_save_combo"
478      class="cns-chip"
479      style="color: var(--cns-green, #4ade80)"
480      disabled={@adw_steps == [] or @adw_name == ""}   #  ← server-rendered disabled flag
481      title="Save this build as a named combo + generate its ADW script"
482    >
483      ⭑ Save combo
484    </button>
...
```

**Wiring facts:**
- `type="button"` — correct (no accidental form submit).
- `phx-click="adw_save_combo"` — the only event binding on this button.
- **No `phx-hook`** on this button. **No `id`, no `name`, no `value`** attributes.
- `disabled` is server-rendered from `@adw_steps` and `@adw_name` assigns.
- **Critical:** the name input 7 lines above uses only `phx-change="adw_set_name"` (line 281). In LiveView, `phx-change` on a text input only fires on **blur** or **Enter** — not on every keystroke.
- The `.cns-chip` CSS rule (`assets/css/app.css:200–211`) does **not** have a `:disabled` selector — only the UA's default `:disabled` opacity dims it; `cursor: pointer` is still applied, so the button looks clickable while disabled.

### Step 2 — Click routes through `console_live.ex` dispatch guard
**File:** `lib/repo_builder_web/live/console_live.ex`, lines 681–684:
```elixir
681  # ADW Builder panel (extracted: ConsoleLive.AdwBuilderPanel, audit F3 Phase 3): the
682  # builder toggle, palette tab, step editing, launch, and saved-combo handlers.
683  def handle_event(event, params, socket) when event in @adw_builder_events,
684    do: AdwBuilderPanel.handle_event(event, params, socket)
```

`@adw_builder_events` is sourced from `AdwBuilderPanel.events/0` (line 73), and `"adw_save_combo"` is in that allowlist (`adw_builder_panel.ex:19–21`).

### Step 3 — Handler
**File:** `lib/repo_builder_web/live/console_live/adw_builder_panel.ex`, lines 127–165:

```elixir
128  def handle_event("adw_save_combo", _params, socket) do
129    %{adw_name: name, adw_steps: steps, adw_local?: local?} = socket.assigns
...
141      true ->
142        working_dir = Shared.nilify_blank(socket.assigns.orchestrator_working_dir)
143
144        attrs = %{
145          name: name,
146          steps: Enum.map(steps, fn s -> {String.to_existing_atom(s.name), s[:prompt]} end),
147          flavor: if(local?, do: :local_iso, else: :iso),
148          spec: socket.assigns.adw_spec,
149          initial_prompt: socket.assigns.adw_prompt,
150          harness: Shared.nilify_blank(socket.assigns.adw_harness || "")
151        }
152
153        case Combos.save(attrs, working_dir) do
154          {:ok, combo} ->
...
155            |> put_flash(:info, "Saved combo + generated #{Path.basename(combo.script_path)}")
...
```

### Step 4 — Context validates + persists
**File:** `lib/repo_builder/adw/combos.ex`, `save/2` lines 81–107:
- Validates via `Combo.validate/1` → slugifies name → parses steps → calls `Scaffold.generate/1`.
- On success, writes the JSON sidecar via `write_sidecar/3` (line 145–156: `File.mkdir_p` + `Jason.encode` + `File.write`) and refreshes definitions.

### Step 5 — Composite Python writer
**File:** `lib/repo_builder/adw/scaffold.ex`, `generate/1` lines 60–75 + writer at lines 91–103:

```elixir
 67    path = script_path(request, stem, flavor)
 68    overwrite? = Map.get(request, :overwrite, false) == true
 69
 70    if File.exists?(path) and not overwrite? do
 71      {:error, :exists}
 72    else
 73      write(path, script, stem)
 74    end
...
 81  def script_path(request, stem, flavor) do
 82    suffix = if flavor == :local_iso, do: "_local_iso", else: "_iso"
 83    root = Map.get(request, :root) || File.cwd!()
 84    Path.join([root, "adws", "adw_#{stem}#{suffix}.py"])
 85  end
...
 92  defp write(path, script, stem) do
 93    with :ok <- File.mkdir_p(Path.dirname(path)),
 94         :ok <- File.write(path, script),
 95         :ok <- File.chmod(path, 0o755) do
 96      {:ok, %{path: path, name: stem, script: script}}
```

Output path: `<root>/adws/adw_<stem>_iso.py` (or `_local_iso.py`), chmod `0755`. `root` comes from `Scaffold`'s `:root` request key, which `Combos.save/2` sets from `resolve_root(working_dir)` (combos.ex:122–138) → `Application.get_env(:repo_builder, Combos)[:root]`, else `Definitions.app_root`, else `File.cwd!()`.

### Step 6 — Flash + return
Handler returns `{:noreply, socket |> put_flash(:info, "Saved combo + generated #{Path.basename(combo.script_path)}")}` (line 154–157). Flash flows through `ConsoleLive`'s `put_flash` pipe into the standard `Layouts.app` flash group.

---

## (b) Verdict — EXACT root cause(s)

### Primary root cause: **stale server-rendered `disabled` swallows the first click**

The Save combo button's `disabled` attribute (`adw_builder_components.ex:480`) is **server-rendered** from `@adw_steps == [] or @adw_name == ""`. The name input (`adw_builder_components.ex:281`) uses **`phx-change="adw_set_name"`** which LiveView only dispatches on **blur or Enter**, not on every keystroke.

User repro path (the one described):
1. User toggles ADW builder mode (`@adw_name == ""`, `@adw_steps == []` → button disabled in DOM).
2. User types a workflow name into the input. The `<input>` is purely client-controlled; no LiveView event fires yet, so `@adw_name` on the server is still `""`.
3. User clicks **+test**, **+review** under ADD STEP. Each `phx-click="adw_add_step"` round-trips, `@adw_steps` becomes `[test, review]`, **but `@adw_name` is still `""`** because the name input never lost focus.
4. User clicks **⭑ Save combo**. The DOM button is still `disabled` (server's last render had `@adw_name == ""`). Browsers **do not fire click events on disabled buttons**. Nothing happens — no `phx-click`, no `phx-change` on the name input either, no `put_flash`, no `File.write`. The cursor is still `pointer` (the `.cns-chip` rule has no `:disabled` style override), so the click feels like it "did nothing."
5. Even after the user clicks away (blurring the input), `phx-change` finally fires and `@adw_name` becomes `"…"`. But by then the user has given up.

This matches the user's symptom **exactly**: "no toast/flash, and no composite ADW file is created."

### Secondary contributing factors
- **No client-side mirror of `disabled`.** A pure-CSS `:disabled` style (or a JS hook watching the input) would have given users a visual cue. Today `.cns-chip` has no `:disabled` selector (`assets/css/app.css:200–211`), so a disabled Save combo looks identical to an enabled one — only slightly dimmed by the UA default.
- **No `phx-blur` on the name input.** Either `phx-change` plus an explicit `phx-blur` or a LiveView form binding (e.g. `Phoenix.HTML.Form.input/3` with `phx-debounce`) would make `@adw_name` track typing immediately.

### Things that are NOT broken (ruling out other suspects)
- ✅ `handle_event("adw_save_combo", …)` **EXISTS** at `adw_builder_panel.ex:128`. Not missing.
- ✅ Dispatch guard at `console_live.ex:683–684` **correctly routes** `"adw_save_combo"` to the panel.
- ✅ `Combos.save/2` **EXISTS** and is wired (`combos.ex:82`).
- ✅ `Scaffold.generate/1` **EXISTS** and writes the `.py` (`scaffold.ex:60` + `scaffold.ex:92`).
- ✅ `put_flash(:info, "Saved combo + generated …")` **EXISTS** at `adw_builder_panel.ex:155`.
- ✅ No JS hook is intercepting the button (no colocated `Phoenix.LiveView.ColocatedHook` references `adw_save_combo`/`Save combo`/`adw_save_combo`; the only `phx-hook` in this file is `CommandAutocomplete` on the command textarea, unrelated).
- ✅ Button is `type="button"` — it is NOT inside the `<form id="command-form" phx-submit="run_command">` (`adw_builder_components.ex:118–169`); the ADW builder block starts at line 273, outside the form.
- ✅ No `JS.push`, no client-side `hide_command/0` is invoked by the click.
- ✅ The existing test `test/repo_builder_web/live/test_adw_builder_combos_test.exs:140` uses `render_click(view, "adw_save_combo")` and asserts the sidecar + script exist — proving the full call chain works **when the button isn't stale-disabled**.

---

## (c) Files a fix should touch

The fix is UI-only. Three candidate approaches, ranked by surgical impact:

### Recommended — fix in one file
**`lib/repo_builder_web/components/console/adw_builder_components.ex`**
- **Line 281** (the `<input>` for name): add `phx-blur="adw_set_name"` alongside `phx-change`, so blurring by clicking the Save combo button (or anywhere else) commits the name to the socket before the click dispatches. Optional: add a tiny `phx-debounce="blur"` style debounce, or switch to a LiveView form binding.
- **Line 480** (`disabled={@adw_steps == [] or @adw_name == ""}`): drop the `@adw_name == ""` clause **OR** add `aria-disabled` and a JS hook so the button is enabled optimistically when the input has a non-empty value. The strictest minimum: only `@adw_steps == []` should disable, since the handler at `adw_builder_panel.ex:130–133` already guards on `String.trim(name) == ""` and emits `put_flash(:error, "Name the combo before saving")`.
- **Alternative:** add a JS hook `Phoenix.LiveView.ColocatedHook` (colocated, per AGENTS.md) on the name input that calls `this.pushEvent("adw_set_name", {name: this.el.value}, ...)` on every `input` event with a `phx-debounce`. Eliminates the server-render lag entirely.

### Optional polish
**`assets/css/app.css:200–211`** — add a `.cns-chip:disabled` rule (`cursor: default; opacity: 0.5;`) so a disabled Save combo is visually distinct from an enabled one. Helps users notice the bug rather than clicking blindly.

### Do NOT touch
- `lib/repo_builder_web/live/console_live.ex` — dispatch guard is correct.
- `lib/repo_builder_web/live/console_live/adw_builder_panel.ex:127–165` — handler is correct.
- `lib/repo_builder/adw/combos.ex` — context I/O is correct.
- `lib/repo_builder/adw/scaffold.ex` — Python writer is correct.
- `assets/js/app.js` — no hook is needed at the JS level; a colocated hook on the name input is sufficient.

### How to verify the fix
1. After patching, manually reproduce the user's repro: toggle ADW, click `+test` + `+review`, type `"my_combo"` into the name field, **without blurring**, click ⭑ Save combo.
2. Expect: green flash "Saved combo + generated `adw_my_combo_iso.py`" and the file at `<root>/adws/adw_my_combo_iso.py`.
3. Run `mix test test/repo_builder_web/live/test_adw_builder_combos_test.exs test/repo_builder_web/live/test_adw_builder_custom_adw_test.exs` — both should still pass (they use `render_change(view, "adw_set_name", …)` which already blurs).

**TL;DR:** the click → handler → writer chain is fully wired and functional. The bug is that the Save combo button is **server-rendered disabled** until the user explicitly blurs the workflow-name input, and the `.cns-chip` CSS has no `:disabled` style to make this visible. The name input's `phx-change="adw_set_name"` only fires on blur/Enter, so typing-into-then-clicking the disabled button eats the click silently.
