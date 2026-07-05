# Worker report: scout-adw-save-input (idle)

Now I have a complete picture. Here is the scout report:

---

## Code-Scout Report: ADW Builder Name Field

### 1. The name input DOES EXIST — but it IS easy to miss

**File:** `lib/repo_builder_web/components/console/adw_builder_components.ex`

**Exact location — lines 275–283:**

```html
<%!-- Workflow name + local toggle + harness picker --%>
<div class="flex items-center gap-2">
  <input
    id="adw-combo-name"
    type="text"
    placeholder="Workflow name (optional)"
    value={@adw_name}
    phx-change="adw_set_name"
    name="name"
    class="cns-cmd-textarea"
    style="padding: 0.25rem 0.5rem; height: auto"
  />
```

**`phx-change` binding:** `"adw_set_name"` → handled by `RepoBuilderWeb.ConsoleLive.AdwBuilderPanel.handle_event/3` (lines 28–30 in `adw_builder_panel.ex`):

```elixir
def handle_event("adw_set_name", %{"name" => name}, socket) do
  {:noreply, assign(socket, :adw_name, name)}
end
```

The input is a **bare `<input>`** (raw HTML, not `Phoenix.Component.input`), so it sends params as `%{"name" => "..."}`.

---

### 2. The "Save combo" button — line 477

**Exact location — lines 476–484:**

```html
<div class="flex items-center justify-end gap-2">
  <button
    type="button"
    phx-click="adw_save_combo"
    class="cns-chip"
    style="color: var(--cns-green, #4ade80)"
    disabled={@adw_steps == []}
    title="Save this build as a named combo + generate its ADW script"
  >
    ⭑ Save combo
  </button>
```

---

### 3. NO visible label for the name input

There is **no `<label>` element** near the `adw-combo-name` input. The closest section header is the HTML comment `Workflow name + local toggle + harness picker` (line 275) — but that is a **server-side comment**, invisible to the user in the browser.

The "LOAD COMBO" section does have a proper `<label>` (lines 312–313), but that is for the dropdown, not the name field:

```html
<label class="text-[0.625rem] font-semibold" style="color: var(--cns-text-2)">
  LOAD COMBO
</label>
```

---

### 4. Visibility conditions

The entire ADW Builder section is gated by a single `<div :if={@adw_builder?}>` at line **263** — which itself is inside the `global_command_input` component rendered at line **2104–2131** in `console_live.ex`:

```elixir
<.global_command_input
  ... (lots of assigns including adw_builder?: @adw_builder?)
/>
```

The `global_command_input` outer panel has `style="display:none"` (line 55), but opens via `hide_command()` JS (keyboard) or clicking the ⌘K trigger. The `:if` guard on line 263 is purely `@adw_builder?` — **no other hidden conditions** on the name input. Once the modal is open and ADW Builder mode is active, the input renders.

---

### 5. The placeholder is misleading

The input's `placeholder` reads:

```
placeholder="Workflow name (optional)"
```

This says **"optional"**, but the `adw_save_combo` handler (line 103 in `adw_builder_panel.ex`) treats it as **required**:

```elixir
def handle_event("adw_save_combo", _params, socket) do
  %{adw_name: name, adw_steps: steps, adw_local?: local?} = socket.assigns

  cond do
    String.trim(name) == "" ->
      {:noreply, put_flash(socket, :error, "Name the combo before saving")}
    ...
  end
end
```

---

### 6. The `<.input>` component is NOT used

This is a raw `<input>` tag, not a `Phoenix.Component.input` from `core_components.ex`. No `field={@form[:name]}` binding — it uses plain HTML `name="name"` and `phx-change`.

---

### 7. Close-equivalent inputs for comparison (the spec/prompt fields)

These ARE inside the same `<div :if={@adw_builder?}>` block and work correctly:

**SPEC textarea — lines 305–313:**
```html
<label class="text-[0.625rem] font-semibold" style="color: var(--cns-text-2)">
  SPEC (optional)
</label>
<textarea
  name="spec"
  phx-change="adw_set_spec"
  rows="2"
  placeholder="Optional pre-written spec the ADW should act on ({{spec}})."
  class="cns-cmd-textarea"
>{@adw_spec}</textarea>
```

**INITIAL PROMPT textarea — lines 315–323:**
```html
<label class="text-[0.625rem] font-semibold" style="color: var(--cns-text-2)">
  INITIAL PROMPT
</label>
<textarea
  name="prompt"
  phx-change="adw_set_prompt"
  rows="2"
  placeholder="The feature/task description that drives /feature ({{input}})."
  class="cns-cmd-textarea"
>{@adw_prompt}</textarea>
```

Note: SPEC and INITIAL PROMPT **both have visible `<label>` elements** above them. The name input does NOT.

---

### 8. What the test expects

The test at line 115 of `test_adw_builder_save_combo_test.exs` confirms the input works via `render_change`:

```elixir
render_change(view, "adw_set_name", %{"name" => "test_review"})
```

The `id="adw-combo-name"` and `name="name"` on the input mean this event fires correctly when the user types.

---

## Summary

| Item | Value |
|---|---|
| **Name input `id`** | `adw-combo-name` |
| **Name input `name`** | `name` |
| **Name input `phx-change`** | `adw_set_name` |
| **Name input line** | 278 (component) |
| **Save combo button line** | 477 (component) |
| **Visible `<label>` for name?** | **NO** — only a server-side HTML comment |
| **Hidden/conditional?** | No — only gated by `@adw_builder? == true` |
| **Raw `<input>` vs `<.input>`?** | Raw `<input>` (no `core_components.ex` form) |

**Root cause of the UX complaint:** The name input has no visible `<label>` element, its placeholder says "Workflow name **(optional)**", and it sits between a comment (`<!-- Workflow name -->`) and two other controls without any visual separation. The user is not blind to it — it's rendered — but it is **undistinguishable from a layout spacer** at a glance. Adding a visible `<label class="text-[0.625rem] font-semibold">WORKFLOW NAME</label>` above the input (matching the SPEC/INITIAL PROMPT pattern) would fix the UX.
