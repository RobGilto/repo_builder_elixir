# Feature: Suppress native text-selection highlight during the log-number copy gesture

## Metadata
issue_number: `the`
adw_id: `log-number`
issue_json: `drag-to-copy-range`

## Feature Description
The orchestration console event stream renders a fixed-width, durable log-number chip
(`.cns-event-row__ln`, e.g. `log-4…`) that supports click-to-copy (single `log-XXXX`)
and drag-to-copy-range (`log-XXXX to log-YYYYY`) via the `LogCopy` JS hook in
`assets/js/app.js`. The copy/range logic works correctly.

However, while the user drags down across rows to grab a range, the browser also
performs a **native text selection** — the dragged rows light up with the blue
selection highlight (visible in the reported screenshot across the SYS/RESPONSE row
bodies). This highlight is visual noise: it is not the copy affordance (the chip's
own `.cns-event-row__ln--copied` flash is), it competes with the row's own
selected/hover styling, and it leaves a stray selection behind after release.

This feature suppresses that native text-selection highlight for the duration of a
`LogCopy` drag (and on the log chip itself for a plain click), so the gesture reads
cleanly as "copy a log reference" with no leftover highlighted text. It mirrors the
already-established `DragSelect` precedent, which suppresses selection during its
checkbox sweep via a `.cns-dragging` class.

## User Story
As an operator dragging across log rows to copy a `log-` range
I want the rows to NOT show the browser's blue text-selection highlight during the drag
So that the copy gesture stays visually clean and doesn't leave stray selected text behind.

## Problem Statement
The `LogCopy` hook starts a pointer drag on a `.cns-event-row__ln` cell and tracks the
pointer across rows, but it never suppresses the browser's default text selection. So a
press-and-drag selects the intervening row text (the blue highlight), which:
- is unwanted visual noise unrelated to the copy result,
- persists as a live DOM selection after `pointerup`, and
- diverges from `DragSelect`, which already prevents this via `.cns-dragging`
  (`.cns-dragging, .cns-dragging * { user-select: none; }` in `assets/css/app.css`).

A single click on the chip can also begin a tiny text selection of the chip text, which
is equally undesirable since the chip is a copy control, not selectable content.

## Solution Statement
Two small, purely client-side changes (no Elixir/server/DB change — the interaction is a
browser concern, consistent with the existing hook precedent):

1. **Always make the chip itself unselectable (CSS):** add `user-select: none` to
   `.cns-event-row__ln` so a plain click on the chip never starts a text selection of
   its own glyphs. The chip already carries `cursor: pointer` and the copy flash.

2. **Suppress selection across rows for the duration of a drag (JS + CSS):** reuse the
   existing `.cns-dragging` convention. In `LogCopy`, add the `cns-dragging` class to the
   hook host (`#logs-pane`) on a valid `pointerdown` (a `.cns-event-row__ln[data-log]`
   cell), and remove it on `pointerup`/`pointercancel` — exactly mirroring how
   `DragSelect` toggles the same class on `#event-stream-wrap`. Because the existing
   `.cns-dragging, .cns-dragging * { user-select: none; }` rule cascades to all
   descendants, this disables text selection across every row under the host while the
   drag is active, then restores normal selection on release. As a belt-and-suspenders
   measure, also clear any stray selection (`window.getSelection()?.removeAllRanges()`)
   at the end of a drag-range copy so nothing remains highlighted.

This keeps the change consistent with `DragSelect` (same class, same lifecycle), touches
only `assets/js/app.js` and `assets/css/app.css`, and leaves the server-rendered contract
(asserted by `test/repo_builder_web/live/test_log_copy_chip_test.exs`) unchanged.

## Relevant Files
Use these files to implement the feature:

- `assets/js/app.js` — the `LogCopy` hook (added for the log-copy chip). Add the
  `cns-dragging` class toggle: set it on `this.el` in `_onPointerDown` (only when a valid
  log cell anchors the drag), and remove it in `_onPointerUp` (and the `pointercancel`
  path, which already routes to `_onPointerUp`). Optionally clear the live selection at
  the end of a range copy. Model exactly on the `DragSelect` hook in the same file
  (`this.el.classList.add/remove("cns-dragging")`).
- `assets/css/app.css` — the `.cns-event-row__ln` rule (fixed-width chip) and the existing
  `.cns-dragging, .cns-dragging * { user-select: none; }` rule (~line 263, used by
  DragSelect). Add `user-select: none;` to `.cns-event-row__ln`. The `.cns-dragging`
  rule already exists and needs no change — it is reused.
- `lib/repo_builder_web/live/console_live.ex` — hosts the `LogCopy` hook on
  `#logs-pane` (the stable ancestor of `#event-stream-wrap`). No change expected;
  referenced only to confirm the host element the class is toggled on.
- `lib/repo_builder_web/components/console_components.ex` — `event_row/1` renders the
  `.cns-event-row__ln` span. No change expected; referenced for the chip markup.
- `BUILD_PROMPT.md` — §9 (LiveView dashboard + hooks conventions) for the hook/CSS
  expectations.
- `README.md` — local run/validation instructions.

### New Files
- None. (The existing `test/repo_builder_web/live/test_log_copy_chip_test.exs` already
  pins the server-rendered contract; this change is browser-only behavior — see Testing
  Strategy. No new server-observable surface is introduced.)

## Implementation Plan
### Phase 1: Foundation
Confirm the existing `.cns-dragging` suppression rule and the `DragSelect` class-toggle
lifecycle that `LogCopy` will mirror. No new abstractions — reuse the established
convention so both pointer-drag hooks suppress selection identically.

### Phase 2: Core Implementation
Add `user-select: none` to the chip rule (CSS), and toggle `.cns-dragging` on the
`LogCopy` host across the drag lifecycle (JS). Optionally clear any residual selection at
the end of a range copy.

### Phase 3: Integration
Rebuild assets and confirm the change coexists with `DragSelect` (both use `.cns-dragging`
on their respective hosts without conflict) and does not alter the server contract. Run the
existing LiveView test plus the full validation gate.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Re-read conventions and the existing hooks
- Read `BUILD_PROMPT.md` §9 (LiveView/hook conventions).
- Re-read the `DragSelect` and `LogCopy` hooks in `assets/js/app.js`, and the
  `.cns-dragging` + `.cns-event-row__ln` rules in `assets/css/app.css`, to match the exact
  class name and add/remove lifecycle.

### 2. Make the chip unselectable (CSS)
- In `assets/css/app.css`, add `user-select: none;` to the `.cns-event-row__ln` rule (the
  fixed-width chip block). Keep all existing properties (color, text-align, the truncation
  set, `cursor: pointer`, the `:hover` and `--copied` rules) intact.
- Do NOT modify the existing `.cns-dragging, .cns-dragging * { user-select: none; }` rule —
  it is reused as-is.

### 3. Toggle `.cns-dragging` across the LogCopy drag (JS)
- In `assets/js/app.js`, in the `LogCopy` hook:
  - In `_onPointerDown`, after confirming a valid `.cns-event-row__ln[data-log]` cell
    anchors the drag (and before/after setting `this.dragging = true`), call
    `this.el.classList.add("cns-dragging")`.
  - In `_onPointerUp`, when a drag is in progress (the existing early `if (!this.dragging)
    return` guard already gates this), call `this.el.classList.remove("cns-dragging")`
    near where `this.dragging` is cleared, so both the commit path and the
    `pointercancel` path (which is wired to `_onPointerUp`) remove the class.
  - Optionally, at the end of a drag-range copy (the `didDrag` branch), call
    `window.getSelection()?.removeAllRanges()` to clear any selection that began before the
    class took effect.
- Keep the guards intact so `LogCopy` only acts on `.cns-event-row__ln` and never
  co-fires with `DragSelect` (which guards on `.cns-event-row__select`). Both may add
  `cns-dragging` to their own hosts; that is harmless (the CSS rule is idempotent).

### 4. Build assets
- Run `mix assets.build` to bundle the updated JS/CSS without esbuild/tailwind errors.

### 5. Regression-check the server contract
- Run `mix test test/repo_builder_web/live/test_log_copy_chip_test.exs` — must stay green
  (the change is client-only; the rendered `data-log`/class contract is unchanged).

### 6. Optional visual proof
- With the app running (`scripts/pg.sh start`, `mix phx.server`), use Tidewave Web vision
  mode (or Playwright MCP) against `http://localhost:4000`: drag across several log rows
  and confirm NO blue text-selection highlight appears during the drag, the range still
  copies, and no selection remains after release.

### 7. Run the full validation gate
- Run every command in **Validation Commands** and fix any issue until all are green with
  zero regressions.

## Testing Strategy
### Unit Tests
- **LiveView integration (existing `test_log_copy_chip_test.exs`):** continues to assert the
  server-rendered contract the hook depends on — `data-log="log-<n>"` present, truncating
  class applied, `#event-stream-wrap` host present, `nil` `log_no` omits `data-log`. This
  change adds no new server-observable markup, so the existing test is the regression guard.
- **No new ExUnit test is warranted:** the behavior added (suppressing `user-select` and
  toggling a CSS class on the client during a pointer drag) is not observable through
  `Phoenix.LiveViewTest` — it is pure browser rendering/selection state. Note this gap
  explicitly so it is not mistaken for missing coverage.

### Edge Cases
- **Plain click (no drag) on the chip:** `user-select: none` on `.cns-event-row__ln`
  prevents selecting the chip glyphs; single copy still fires and the `--copied` flash
  shows.
- **Drag then release:** `.cns-dragging` is added on `pointerdown` and removed on
  `pointerup`; normal text selection elsewhere on the page is restored afterward.
- **`pointercancel` mid-drag:** routed to the same `_onPointerUp`, so the class is still
  removed (no stuck `cns-dragging` disabling selection permanently).
- **Drag started on a non-log target:** `_onPointerDown` returns early (guarded on
  `.cns-event-row__ln[data-log]`), so `.cns-dragging` is never added and normal text
  selection over row bodies still works when the user is NOT copying a log range.
- **Coexistence with `DragSelect`:** a checkbox drag toggles `.cns-dragging` on
  `#event-stream-wrap`; a log drag toggles it on `#logs-pane`. Both yield the same
  `user-select: none` cascade; neither leaves the other stuck because each removes its own
  class on release.
- **Stray pre-existing selection:** clearing the selection at the end of a range copy
  ensures nothing remains highlighted even if a selection began in the first
  pre-class frame.

## Acceptance Criteria
- Dragging across N log rows to copy a range shows **no** native blue text-selection
  highlight on the rows during the drag, and leaves no selection highlighted after release.
- A single click on a log chip does not select the chip text; it still copies `log-XXXX`
  and shows the brief copied state.
- The drag-range copy result is unchanged (`log-FIRST to log-LAST`, DOM-ordered).
- Normal text selection still works on row bodies when the user is not performing a
  log-copy drag.
- `DragSelect` checkbox multi-select behavior is unaffected.
- `mix compile --warnings-as-errors`, `mix test --warnings-as-errors`,
  `mix format --check-formatted`, `mix credo --strict`, and `mix dialyzer` all pass; the
  existing `test_log_copy_chip_test.exs` still passes.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix assets.build` — bundle the updated hook + CSS without esbuild/tailwind errors.
- `mix test test/repo_builder_web/live/test_log_copy_chip_test.exs` — the log-copy chip
  server-contract integration test still passes.
- `mix compile --warnings-as-errors` — clean compile; set-theoretic type checker +
  `warnings_as_errors` pass.
- `mix test --warnings-as-errors` — full ExUnit suite, zero failures.
- `mix format --check-formatted` — formatting.
- `mix credo --strict` — lint, including the `@spec`-on-every-public-function rule.
- `mix dialyzer` — contract checking, no new warnings, no stale ignore filters.

## Notes
- **No new dependencies, no Elixir domain/DB changes.** This is a presentation +
  client-hook refinement of the existing log-copy chip feature; the server contract and
  typed/`@spec`/Dialyzer surface are untouched. The full gate is still run to guarantee
  zero regressions.
- **Why reuse `.cns-dragging`:** the class and its `user-select: none` rule already exist
  for `DragSelect`. Reusing it keeps both pointer-drag hooks visually consistent and
  avoids a second near-identical CSS rule. If a future design wants log-drag to look
  distinct from checkbox-drag, a dedicated `.cns-log-dragging` class could be introduced —
  out of scope here.
- **Future:** could add a faint range outline (e.g. a left rule on the in-range rows)
  during a log drag as positive feedback replacing the removed native highlight — out of
  scope.
