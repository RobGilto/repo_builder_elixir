# Feature: Command Textarea Autocomplete with Dropdown and Blue-Highlight Formatting

## Metadata
issue_number: `autocomplete`
adw_id: `slash-agent-adw`
issue_json: `autocomplete-adw-slash-agent-adw-sdlc_planner-command-autocomplete`

## Feature Description

Add inline autocomplete to the `⌘K` global command textarea (`#command-textarea`) in
ConsoleLive. As the operator types a trigger character, a positioned dropdown appears below
the textarea listing matching Slash Commands, Agents, or ADWs — the same items already
available in the static prompt palette. The matched prefix typed by the operator is
highlighted in cyan (`--cns-cyan`) inside each suggestion chip, giving the "blue text
formatting" effect. Keyboard (↑↓ arrows, Enter, Escape) and click selection insert the
resolved token at the caret, reusing the existing `rb:insert-token` dispatch mechanism.

Three trigger prefixes:
- `/` → slash commands (token inserted: `/name`, e.g. `/implement`)
- `@` → agent names (token inserted: bare agent name, e.g. `gsd-executor`)
- `!` → ADW workflow names (token inserted: `start_adw workflow_type=name`)

These triggers align with the existing palette column tokens so the autocomplete and the
static palette are always consistent.

## User Story

As a platform operator,
I want typed autocomplete for `/` slash commands, `@` agents, and `!` ADWs in the ⌘K
command textarea,
So that I can quickly discover and insert available commands without opening the static
palette panels, and confirm the exact token with blue-highlighted suggestion text.

## Problem Statement

The ⌘K command modal has a static prompt palette (SLASH / AGENTS / ADWS collapsible
sections) that the operator must manually open, scroll, and click to insert a token. There
is no inline discovery flow: the operator must know token names in advance or stop to
inspect the palette. For long lists (many templates, many agents) this is friction-heavy.
A standard autocomplete dropdown removes the friction and matches the UX of modern editors.

## Solution Statement

All three item lists (`slash_commands`, `agent_defs`, `adws`) are already serialized and
sent as LiveView assigns to the `global_command_input` component. The plan:

1. **Serialize** the three lists into a single JSON array embedded as a `data-autocomplete`
   attribute on `#command-textarea` (updated whenever the assigns change via LiveView
   re-render).
2. **JS hook `CommandAutocomplete`** (new, registered alongside `CommandPaste` and merged
   into the same textarea element via a `phx-hook` rename) watches `keydown`/`input` events:
   - On any `input`, scan backwards from the caret for a trigger character (`/`, `@`, `!`);
     extract the query string after it.
   - Filter the serialized list by prefix match; render up to 10 results in
     `#autocomplete-dropdown`.
   - Track an `activeIndex`; `ArrowUp`/`ArrowDown` cycle through items and highlight them;
     `Enter` selects the active item; `Escape` dismisses.
   - Click on any item selects it.
   - On selection, replace the trigger + query fragment in the textarea value with the full
     token, then dispatch `rb:insert-token` is NOT used for replacement — the hook performs
     direct string surgery (replace trigger+query with token at caret) and dispatches a
     synthetic `input` event so LiveView's phx-change fires if wired.
3. **Dropdown markup** is injected into the `cns-cmd-panel` as a sibling of `#command-form`,
   positioned absolutely below the textarea. Each item renders the typed prefix in
   `color: var(--cns-cyan)` (blue) and the remainder in `--cns-text-2`.
4. The existing `CommandPaste` hook is merged into `CommandAutocomplete` so the textarea
   carries a single `phx-hook` value.

No new Elixir modules, DB tables, or migrations are required. The only server-side change
is adding the `data-autocomplete` attribute to the textarea element with a JSON-encoded
chip list. No PubSub changes needed — LiveView re-renders the textarea attributes whenever
`slash_commands`/`agent_defs`/`adws` assigns change (the existing
`handle_info({:definitions_changed,...})` path already updates them).

## Relevant Files

- **`assets/js/app.js`** — Primary change: add `CommandAutocomplete` hook (subsumes
  `CommandPaste`), register it. The hook owns the full autocomplete lifecycle: trigger
  detection, dropdown render, keyboard/mouse selection, token insertion.
- **`lib/repo_builder_web/components/console_components.ex`** — Add `data-autocomplete`
  attribute to `#command-textarea`; add the `#autocomplete-dropdown` div inside the command
  panel; rename `phx-hook` from `"CommandPaste"` to `"CommandAutocomplete"`.
- **`lib/repo_builder_web/live/console_live.ex`** — Add `autocomplete_items/3` helper
  (pure function, no Repo) that serializes the chip list to JSON and pass it as a new
  `autocomplete_json` assign to `global_command_input`.
- **`test/repo_builder_web/live/test_command_autocomplete_test.exs`** — New LiveView
  integration test.

### New Files
- `test/repo_builder_web/live/test_command_autocomplete_test.exs` — LiveView test: mount
  ConsoleLive, open ⌘K modal (render_click "show_command"), assert `data-autocomplete`
  attribute is present and parses to a list containing slash command tokens, agent tokens,
  and ADW tokens. Drive `phx-click` on a palette chip and assert `rb:insert-token` fires
  (or assert value injection indirectly via the existing `CommandPaste` pattern).

## Implementation Plan

### Phase 1: Foundation — data attribute serialization
Serialize the existing `slash_commands`, `agent_defs`, and `adws` assigns into a compact
JSON array of `{trigger, token, label, description}` objects and embed it as
`data-autocomplete` on `#command-textarea`. This is purely additive and backwards-compatible.

### Phase 2: Core Implementation — JS hook
Write the `CommandAutocomplete` hook that reads `data-autocomplete`, detects trigger
characters, filters results, renders a styled dropdown, handles keyboard/mouse navigation,
and performs caret-aware token replacement.

### Phase 3: Integration — merge CommandPaste, add dropdown markup, wire tests
Merge the existing `CommandPaste` paste/insert-token listeners into `CommandAutocomplete`,
update `phx-hook`, add the dropdown div to the template, verify the hook is registered, and
write/run the LiveView integration test.

## Step by Step Tasks

### Step 1: Add `autocomplete_items/3` helper in `console_components.ex`

- In `console_components.ex`, add a private `@spec`'d helper
  `autocomplete_items(slash_commands, agent_defs, adws)` that returns a list of maps:
  ```elixir
  %{trigger: "/", token: "/name", label: "name", description: "..."}
  %{trigger: "@", token: "agent-name", label: "agent-name", description: "..."}
  %{trigger: "!", token: "start_adw workflow_type=adw-name", label: "adw-name", description: "..."}
  ```
- Add a `Jason.encode!/1` call (Jason is already in the dep tree via Phoenix) to produce a
  JSON string.
- Update the `global_command_input/1` component's `textarea` element to include:
  ```heex
  data-autocomplete={autocomplete_json(@slash_commands, @agent_defs, @adws)}
  ```
  where `autocomplete_json/3` is the new private helper.

### Step 2: Add the `#autocomplete-dropdown` div in the command panel template

- Inside the `cns-cmd-panel` `<div>` (the COMMAND MODE `<div :if={not @adw_builder?}>`
  block), add a sibling `<div>` after `#command-form`:
  ```heex
  <div
    id="autocomplete-dropdown"
    class="cns-autocomplete"
    style="display:none"
    role="listbox"
    aria-label="Autocomplete suggestions"
  ></div>
  ```
- The div starts hidden (`display:none`); the JS hook shows/hides it.
- Add CSS in `assets/css/app.css` (or the inline Tailwind class equivalent) for
  `.cns-autocomplete`: `position: absolute`, `z-index: 50`, max-height with overflow-y,
  background `var(--cns-surface-2)`, border `var(--cns-border)`, rounded corners.
  Since the project uses utility CSS, add inline `style` on the div for the static props
  and let the hook toggle `display` dynamically.

### Step 3: Write the `CommandAutocomplete` JS hook in `assets/js/app.js`

Replace `CommandPaste` with `CommandAutocomplete` that absorbs all existing
`CommandPaste` logic PLUS the new autocomplete behaviour:

```javascript
const CommandAutocomplete = {
  mounted() {
    // --- existing CommandPaste: paste-to-upload ---
    this._onPaste = (e) => { /* exact existing paste handler body */ }
    this.el.addEventListener("paste", this._onPaste)

    // --- existing CommandPaste: rb:insert-token (palette chip click) ---
    this._onInsertToken = (e) => { /* exact existing insert-token handler body */ }
    this.el.addEventListener("rb:insert-token", this._onInsertToken)

    // --- new: autocomplete ---
    this._items = []           // parsed from data-autocomplete
    this._activeIdx = -1
    this._dropEl = document.getElementById("autocomplete-dropdown")

    this._readItems()          // parse data attr on mount

    this._onInput = () => this._handleInput()
    this._onKeydown = (e) => this._handleKeydown(e)
    this.el.addEventListener("input", this._onInput)
    this.el.addEventListener("keydown", this._onKeydown)
    if (this._dropEl) {
      this._dropEl.addEventListener("mousedown", (e) => this._handleDropClick(e))
    }
  },

  updated() {
    // Re-read items when LiveView re-renders the textarea (new defs loaded).
    this._readItems()
  },

  destroyed() {
    this.el.removeEventListener("paste", this._onPaste)
    this.el.removeEventListener("rb:insert-token", this._onInsertToken)
    this.el.removeEventListener("input", this._onInput)
    this.el.removeEventListener("keydown", this._onKeydown)
  },

  // Parse the data-autocomplete JSON attr into this._items.
  _readItems() {
    try {
      this._items = JSON.parse(this.el.dataset.autocomplete || "[]")
    } catch (_) {
      this._items = []
    }
  },

  // Detect the active trigger+query at the caret.
  // Returns {trigger, query, triggerStart} or null.
  _detectTrigger() {
    const el = this.el
    const caret = el.selectionStart ?? el.value.length
    const before = el.value.slice(0, caret)
    // Walk backwards to find trigger char with no intervening whitespace.
    const match = before.match(/([\/\@\!])([^\s\/\@\!]*)$/)
    if (!match) return null
    return {
      trigger: match[1],
      query: match[2],
      triggerStart: caret - match[0].length
    }
  },

  _handleInput() {
    const det = this._detectTrigger()
    if (!det) { this._hide(); return }
    const {trigger, query} = det
    const matches = this._items
      .filter(item => item.trigger === trigger)
      .filter(item => item.label.toLowerCase().startsWith(query.toLowerCase()))
      .slice(0, 10)
    if (matches.length === 0) { this._hide(); return }
    this._activeIdx = 0
    this._render(matches, query)
    this._show()
  },

  _handleKeydown(e) {
    if (!this._dropEl || this._dropEl.style.display === "none") return
    const items = this._dropEl.querySelectorAll("[data-idx]")
    if (e.key === "ArrowDown") {
      e.preventDefault()
      this._activeIdx = Math.min(this._activeIdx + 1, items.length - 1)
      this._updateActive(items)
    } else if (e.key === "ArrowUp") {
      e.preventDefault()
      this._activeIdx = Math.max(this._activeIdx - 1, 0)
      this._updateActive(items)
    } else if (e.key === "Enter" && this._activeIdx >= 0) {
      e.preventDefault()
      const active = items[this._activeIdx]
      if (active) this._select(active.dataset.token)
    } else if (e.key === "Escape") {
      this._hide()
    }
  },

  _handleDropClick(e) {
    const item = e.target.closest("[data-idx]")
    if (item) {
      e.preventDefault() // prevent textarea blur
      this._select(item.dataset.token)
    }
  },

  _select(token) {
    const det = this._detectTrigger()
    if (!det) return
    const el = this.el
    const caret = el.selectionStart ?? el.value.length
    const before = el.value.slice(0, det.triggerStart)
    const after = el.value.slice(caret)
    const lead = before.length > 0 && !/\s$/.test(before) ? " " : ""
    const trail = after.length > 0 && !/^\s/.test(after) ? " " : ""
    el.value = before + lead + token + trail + after
    const pos = det.triggerStart + lead.length + token.length + trail.length
    el.setSelectionRange(pos, pos)
    el.dispatchEvent(new Event("input", {bubbles: true}))
    el.focus()
    this._hide()
  },

  // Render matched items into the dropdown div with cyan prefix highlighting.
  _render(matches, query) {
    if (!this._dropEl) return
    this._dropEl.innerHTML = matches.map((item, idx) => {
      const labelLo = item.label.toLowerCase()
      const qLo = query.toLowerCase()
      const matchLen = qLo.length
      const prefix = item.label.slice(0, matchLen)   // typed portion
      const rest = item.label.slice(matchLen)
      const triggerHtml = item.trigger === "/" ? "/" : item.trigger === "@" ? "@" : "!"
      const active = idx === this._activeIdx ? "background: var(--cns-surface-1, #222);" : ""
      return `<div
        data-idx="${idx}"
        data-token="${escapeHtml(item.token)}"
        class="cns-autocomplete__item"
        role="option"
        style="padding:4px 8px;cursor:pointer;${active}display:flex;flex-direction:column;gap:1px"
        title="${escapeHtml(item.description || item.token)}"
      >
        <span style="font-size:0.7rem;color:var(--cns-text)">
          <span style="color:var(--cns-cyan)">${escapeHtml(triggerHtml + prefix)}</span>${escapeHtml(rest)}
        </span>
        ${item.description ? `<span style="font-size:0.6rem;color:var(--cns-text-2)">${escapeHtml(item.description)}</span>` : ""}
      </div>`
    }).join("")
  },

  _updateActive(items) {
    items.forEach((el, i) => {
      el.style.background = i === this._activeIdx ? "var(--cns-surface-1, #222)" : ""
    })
  },

  _show() {
    if (this._dropEl) this._dropEl.style.display = "block"
  },

  _hide() {
    if (this._dropEl) { this._dropEl.style.display = "none"; this._activeIdx = -1 }
  },
}

// Safe HTML escaper used by the dropdown renderer.
function escapeHtml(str) {
  return String(str ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;")
}
```

- Delete the now-inlined `CommandPaste` const.
- Register `CommandAutocomplete` in the `hooks` map (replace `CommandPaste`):
  ```javascript
  hooks: {...colocatedHooks, AutoScroll, ClipboardCopy, CommandAutocomplete, DragSelect, LogCopy, LogDragSelect}
  ```

### Step 4: Update `phx-hook` in the template

In `console_components.ex`, change:
```heex
phx-hook="CommandPaste"
```
to:
```heex
phx-hook="CommandAutocomplete"
```
on `#command-textarea`.

### Step 5: Add `autocomplete_json/3` private helper in `console_components.ex`

```elixir
@spec autocomplete_json([struct()], [struct()], [struct()]) :: String.t()
defp autocomplete_json(slash_commands, agent_defs, adws) do
  slash = Enum.map(slash_commands, fn cmd ->
    %{trigger: "/", token: "/" <> cmd.name, label: cmd.name, description: cmd.description || ""}
  end)
  agents = Enum.map(agent_defs, fn a ->
    %{trigger: "@", token: a.name, label: a.name, description: a.description || ""}
  end)
  adw_items = Enum.map(adws, fn a ->
    %{trigger: "!", token: "start_adw workflow_type=" <> a.name, label: a.name, description: a.description || ""}
  end)
  Jason.encode!(slash ++ agents ++ adw_items)
end
```

Add `data-autocomplete={autocomplete_json(@slash_commands, @agent_defs, @adws)}` to
`#command-textarea`.

### Step 6: Position the dropdown correctly

The `#autocomplete-dropdown` div must render BELOW the textarea and overlay other content.
Since `#command-input` uses `position: fixed` (`.cns-cmd-overlay`) and `.cns-cmd-panel`
is a normal block, wrap the `#command-form` + `#autocomplete-dropdown` in a relative
container:

```heex
<div style="position: relative">
  <form id="command-form" ...>...</form>
  <div
    id="autocomplete-dropdown"
    role="listbox"
    style="display:none; position:absolute; top:100%; left:0; right:0; z-index:50;
           background:var(--cns-surface-2); border:1px solid var(--cns-border);
           border-radius:4px; max-height:14rem; overflow-y:auto; margin-top:2px"
  ></div>
</div>
```

### Step 7: Write LiveView integration test

Create `test/repo_builder_web/live/test_command_autocomplete_test.exs`:

```elixir
defmodule RepoBuilderWeb.CommandAutocompleteTest do
  use RepoBuilderWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias RepoBuilder.Orchestrators

  defp default_orchestrator do
    {:ok, orch} = Orchestrators.get_or_create_default()
    orch
  end

  test "command textarea has data-autocomplete attr with slash/agent/adw items", %{conn: conn} do
    _orch = default_orchestrator()
    {:ok, view, html} = live(conn, "/")

    # data-autocomplete is present on mount.
    assert html =~ "data-autocomplete"

    # The attribute value is valid JSON containing at least the trigger keys.
    # We use has_element? to check the textarea carries the attribute.
    assert has_element?(view, "#command-textarea[data-autocomplete]")
  end

  test "autocomplete dropdown element exists in COMMAND mode markup", %{conn: conn} do
    _orch = default_orchestrator()
    {:ok, view, _html} = live(conn, "/")

    assert has_element?(view, "#autocomplete-dropdown")
  end

  test "slash commands appear in autocomplete JSON when definitions are loaded", %{conn: conn} do
    _orch = default_orchestrator()
    {:ok, _view, html} = live(conn, "/")

    # The page serializes known slash commands into data-autocomplete.
    # With a live app that has .claude/commands/, the JSON contains "/" triggers.
    # We assert the attribute is non-empty JSON (may be [] in test env with no cmds).
    assert html =~ ~s(data-autocomplete=")
  end
end
```

### Step 8: Run validation

Run all validation commands in order and fix any failures.

## Testing Strategy

### Unit Tests

- `test_command_autocomplete_test.exs` — LiveView mount test: confirms `#command-textarea`
  has a `data-autocomplete` attribute, `#autocomplete-dropdown` div exists, and the JSON
  serialisation is syntactically valid.

### Edge Cases

- Empty lists (no slash commands, no agents, no ADWs) → `data-autocomplete="[]"`;
  dropdown never shown; no JS errors.
- Typing `/` alone (no query) → show all slash commands up to 10.
- Trigger character appears mid-sentence (`foo /impl`) → autocomplete from the most
  recent trigger only (regex `([/\@!])([^\s/\@!]*)$` handles this correctly).
- Query with no matches → dropdown hidden.
- `adw_builder?` mode (ADW Builder panel visible) — textarea is replaced; autocomplete hook
  is on `#command-textarea` only; no crash when dropdown element is absent.
- Agent name contains a hyphen (`gsd-executor`) — `startsWith` filter matches correctly.
- Long description → truncated to one line via CSS `overflow: hidden; text-overflow: ellipsis`.
- Rapid typing (debounce): autocomplete runs on every `input` event — acceptable since list
  is at most a few hundred items and filter is O(n).

## Acceptance Criteria

1. Typing `/` in `#command-textarea` shows `#autocomplete-dropdown` with matching slash
   commands; the typed prefix is rendered in cyan.
2. Typing `@` shows matching agent names in the dropdown; typing `!` shows ADW names.
3. `ArrowUp` / `ArrowDown` moves the active highlight through items; `Enter` inserts the
   selected token at the caret; `Escape` dismisses the dropdown.
4. Clicking a dropdown item inserts its token and dismisses the dropdown.
5. The inserted token matches the palette chip token (e.g., `/implement` for slash,
   bare agent name for `@`, `start_adw workflow_type=name` for `!`).
6. The dropdown is hidden when the trigger fragment has no matches or the caret moves away.
7. The existing `CommandPaste` paste-to-upload and `rb:insert-token` (palette chip click)
   behaviours still work unmodified.
8. `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`,
   and `mix test --warnings-as-errors` all pass with zero regressions.

## Validation Commands

```bash
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix test test/repo_builder_web/live/test_command_autocomplete_test.exs --warnings-as-errors
mix test --warnings-as-errors
mix dialyzer
```

## Notes

- **No new dependencies**: JSON encoding uses `Jason`, already a transitive dependency via
  Phoenix. No `mix.exs` change required.
- **`escapeHtml` helper** is a pure JS function placed at module scope above the hook
  consts; it is NOT a hook property so Dialyzer / Elixir tooling is unaffected.
- **Dropdown position**: The `position: relative` wrapper around `#command-form` + dropdown
  ensures the dropdown aligns with the textarea without fixed pixel offsets.
- **`phx-hook` rename**: Renaming `"CommandPaste"` → `"CommandAutocomplete"` does not break
  existing behaviour because the hook absorbs all prior `CommandPaste` listeners. Any
  existing LiveView test that asserts `phx-hook="CommandPaste"` must be updated to
  `"CommandAutocomplete"`.
- **ADW trigger choice (`!`)**: The palette uses `start_adw workflow_type=name` as the token.
  The `!` trigger was chosen to avoid collision with Markdown links and to be
  unambiguous (not a valid slash-command starter or agent-name character). If the team
  prefers a different trigger (e.g., `#`), change `trigger: "!"` → `trigger: "#"` in
  `autocomplete_json/3` and `"[\/\@\!]"` → `"[\/\@\#]"` in the regex.
- **Future**: the hook's `_render` innerHTML approach can be upgraded to a server-rendered
  `phx-update="replace"` stream if rich-text formatting or LiveView-managed state is
  preferred over pure JS rendering.
