# Feature: Fixed-width log-number chip with click-to-copy and drag-to-copy-range

## Metadata
issue_number: `chip`
adw_id: `with`
issue_json: `fixed-width`

## Feature Description
The event-log rows on the orchestration console render a durable log number (`log-#{log_no}`). As the platform runs over time, that number grows unbounded (`log-588` → `log-1234567`), widening the log-number column and stealing horizontal real estate from the body/agent/meta columns.

This feature makes the log-number **occupy a fixed width regardless of magnitude** — it shows `log-` followed by as many digits as fit, then a dot/ellipsis trail (e.g. `log-123…`) so the column never grows. The full value remains fully usable via copy interactions:

- **Single click** on the log number copies the full `log-XXXX` string to the clipboard.
- **Click-and-drag down** across multiple rows, then release, copies the inclusive range `log-XXXX to log-YYYYY` (first → last row in the drag).
- A brief, subtle "copied" visual state confirms the copy.
- Neither interaction triggers the row's expand toggle (`toggle_event`) or the multi-select checkbox drag (`select_drag`).

## User Story
As an operator triaging the orchestration console
I want the log number to stay a fixed, compact width while still letting me copy a single log id or a range with one gesture
So that long-running sessions don't waste horizontal space and I can quickly grab `log-` references (single or range) to paste into issues, prompts, or chat.

## Problem Statement
The log-number cell (`lib/repo_builder_web/components/console_components.ex:510`, class `.cns-event-row__ln`) renders its full text with no width cap. Large numbers widen the column and compress the more important body column. There is also no affordance to copy a log id — operators must hand-retype it — and no way at all to grab a contiguous range.

## Solution Statement
Two layers, both client-side (no Elixir domain or DB change is required — the log number is already rendered):

1. **Presentation (CSS + markup):** Cap `.cns-event-row__ln` to a fixed width with `overflow: hidden; text-overflow: ellipsis; white-space: nowrap`, so any magnitude renders as `log-NNN…` within a constant column. Stamp the full `log-XXXX` string on a `data-log` attribute (and keep it in the `title`) so the truncated display never loses the real value. Add a transient `.cns-event-row__ln--copied` feedback state.

2. **Interaction (LiveView JS hook):** Add a `LogCopy` hook on the existing event-stream wrapper (`#event-stream-wrap`, which already hosts `DragSelect`). It delegates pointer events from `.cns-event-row__ln` elements:
   - `pointerdown` on a log cell starts a potential drag, recording the anchor row.
   - `pointermove` (on `document`) tracks the row currently under the pointer.
   - `pointerup`: if the pointer never left the anchor cell → **single copy** of that cell's `data-log`; if it swept across rows → **range copy** `"#{first} to #{last}"` computed from DOM order of the anchor and release rows. Either way, write to `navigator.clipboard`, flash the copied state, and `stopPropagation`/swallow the synthetic click so the row never toggles.

This mirrors the established `ClipboardCopy` (data-attr → clipboard) and `DragSelect` (pointer drag + capture-phase click swallow) hooks, so it slots into existing conventions. Clipboard + pointer logic is inherently a browser concern, so it lives entirely in `assets/js/app.js`; the server is not involved.

## Relevant Files
Use these files to implement the feature:

- `lib/repo_builder_web/components/console_components.ex` — `event_row/1` (defined line ~487; the log-number `<span class="cns-event-row__ln">` at line ~510). Add `data-log={"log-#{@log_no}"}`, keep/extend the `title`, and ensure the span is the hook's delegation target. This is the only markup change.
- `lib/repo_builder_web/live/console_live.ex` — renders `event_row` (line ~2403) inside `#event-stream-wrap` (the `phx-hook="DragSelect"` container, line ~2394). The new `LogCopy` hook attaches to this same wrapper; confirm no server-side event handlers are needed (the interaction is client-only).
- `assets/js/app.js` — existing hooks (`AutoScroll`, `ClipboardCopy`, `CommandPaste`, `DragSelect`) and the `hooks: {...}` registration (line ~244). Add the `LogCopy` hook here and register it. Model the drag/click-swallow on `DragSelect` and the clipboard write on `ClipboardCopy`.
- `assets/css/app.css` — `.cns-event-row__ln` rule (currently `color: var(--cns-text-3); text-align: right;`, ~line 266). Add the fixed-width truncation and a `.cns-event-row__ln--copied` feedback state; add `cursor: pointer` and a hover hint so the cell reads as interactive.
- `BUILD_PROMPT.md` — §9 (LiveView dashboard + hooks conventions) and §3 (typed style) for any HEEx/markup expectations.
- `README.md` — run instructions for local validation.

### New Files
- `test/repo_builder_web/live/test_log_copy_chip_test.exs` — `Phoenix.LiveViewTest` integration test asserting the rendered server-side contract the JS hook depends on: each event row's log-number span carries the truncating class and the correct `data-log="log-#{log_no}"` value, and the stream container exposes the `phx-hook` wrapper. (The clipboard/drag behavior itself is browser-only; see Testing Strategy for the optional Playwright proof.)

## Implementation Plan
### Phase 1: Foundation
Establish the server-side contract the hook relies on: the log-number span must expose the full value (`data-log`) independent of its truncated display, and must be uniquely targetable by the hook. No Elixir context, schema, or migration work — the feature adds no persisted state.

### Phase 2: Core Implementation
Implement the fixed-width CSS truncation and the `LogCopy` JS hook (single-click copy, drag-range copy, copied-state flash, propagation suppression).

### Phase 3: Integration
Wire the hook into the existing `#event-stream-wrap` so it coexists with `DragSelect` (checkbox multi-select) and the row's `toggle_event` without cross-triggering. Add the LiveView test for the server contract and run the full validation gate.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Read the spec and confirm conventions
- Read `BUILD_PROMPT.md` §9 (LiveView/hook conventions) and `README.md`.
- Re-read the `DragSelect` and `ClipboardCopy` hooks in `assets/js/app.js` to reuse their pointer-drag, capture-phase click-swallow, and clipboard idioms.

### 2. Add the LiveView integration test first (server contract)
- Create `test/repo_builder_web/live/test_log_copy_chip_test.exs` using `Phoenix.LiveViewTest`.
- Mount `ConsoleLive`, push enough activity (or seed via the existing session/test helpers used by sibling tests like `test_log_number_test.exs`) that at least one event row with a `log_no` renders.
- Assert: the log-number span renders with the `cns-event-row__ln` class, carries `data-log="log-#{log_no}"`, and that `#event-stream-wrap` is present (the hook host). Use `element/2` + `render/1` / `has_element?/2`.
- This test should fail until the markup change in step 3 lands.

### 3. Expose the full log value on the span (markup)
- In `lib/repo_builder_web/components/console_components.ex` `event_row/1` (line ~510), update the log-number span to add `data-log={"log-#{@log_no}"}` when `@log_no` is set, keep `title` showing the full `log-#{@log_no}` (so hover reveals the untruncated value), and leave the visible text as today (`log-#{@log_no}` / fallback `@line`).
- Guard the `nil` `@log_no` case (fallback `@line`): only emit `data-log` when there is a real log number, so the hook ignores non-copyable rows.

### 4. Fixed-width truncation + copied feedback (CSS)
- In `assets/css/app.css`, extend `.cns-event-row__ln`:
  - `display: inline-block; max-width: <fixed, e.g. 7ch>; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; vertical-align: bottom;` so any magnitude shows `log-NNN…` at a constant width (pick a width that always preserves the `log-` prefix plus a couple digits).
  - `cursor: pointer;` and a subtle hover (e.g. `color: var(--cns-text-2)` on `:hover`) to signal interactivity.
  - Add `.cns-event-row__ln--copied { color: var(--cns-cyan); }` (or a brief background flash) for the transient confirmation.
- Keep the existing `text-align: right;` behavior consistent within the fixed box.

### 5. Implement the `LogCopy` hook (interaction)
- In `assets/js/app.js`, add a `LogCopy` hook (mounted on `#event-stream-wrap`) that:
  - On `pointerdown` whose `target.closest(".cns-event-row__ln")` has a `data-log`: record `anchorEl`/`anchorLog`, set a `dragging` flag, mark `didDrag = false`.
  - On document `pointermove` while dragging: resolve the row under the pointer via `document.elementFromPoint(...).closest("[id^='ev-row-']")`; if its `.cns-event-row__ln[data-log]` differs from the anchor, set `didDrag = true` and remember it as the current end; optionally toggle a transient highlight class on the in-range rows for feedback.
  - On document `pointerup` while dragging: compute the copy string — single (`anchorLog`) when `!didDrag`, else range `"${first} to ${last}"` where first/last are ordered by DOM position of the anchor and end spans; `navigator.clipboard.writeText(...)`; flash `.cns-event-row__ln--copied` on the involved cell(s) for ~600ms; set `suppressNextClick = true` and clear drag state.
  - Add a capture-phase `click` listener on the wrapper that, when `suppressNextClick` (or the click originated on a `.cns-event-row__ln`), calls `e.preventDefault(); e.stopImmediatePropagation()` so the row's `toggle_event` never fires.
  - Implement `destroyed()` to remove the document/window listeners (mirror `DragSelect`).
- Register `LogCopy` in the `hooks: {...colocatedHooks, AutoScroll, ClipboardCopy, CommandPaste, DragSelect, LogCopy}` map.
- Ensure no conflict with `DragSelect`: `LogCopy` only acts on `.cns-event-row__ln`, `DragSelect` only on `.cns-event-row__select` — guard each handler by its own target so the two drags never co-fire.

### 6. Build assets and run the server contract test
- `mix assets.build` to bundle the JS/CSS.
- `mix test test/repo_builder_web/live/test_log_copy_chip_test.exs` — expect green.

### 7. Optional visual proof
- With the app running (`scripts/pg.sh start`, `mix phx.server`), optionally use Tidewave Web vision mode (or Playwright MCP) against `http://localhost:4000` to screenshot a long `log-` number rendering truncated (`log-…`) within the fixed column, and confirm hover affordance.

### 8. Run the full validation gate
- Run every command in **Validation Commands** and fix any issue until all are green with zero regressions.

## Testing Strategy
### Unit Tests
- **LiveView integration (`test_log_copy_chip_test.exs`):** asserts the server-rendered contract the hook depends on — `data-log="log-#{log_no}"` present, truncating class applied, `#event-stream-wrap` host present, and the `nil` log_no fallback omits `data-log`.
- **Regression:** existing `test/repo_builder_web/live/test_log_number_test.exs` and the broader `test/repo_builder_web/live/` suite must stay green (the markup change is additive).
- **JS behavior (single-click copy, drag-range copy, propagation suppression):** browser-only; not expressible in `Phoenix.LiveViewTest`. Validate manually or via the optional Playwright screenshot/interaction step. Note this gap explicitly so it isn't mistaken for missing coverage.

### Edge Cases
- `log_no` is `nil` (row shows `@line` fallback): span has no `data-log`; click/drag is a no-op there.
- Drag that starts and ends on the same cell → single copy (not a 1-element range).
- Up-then-down sweep: first/last derive from DOM order of anchor + final end cell, so direction doesn't matter.
- Drag crossing rows that arrive live (stream prepends/appends) during the gesture → recompute order from current DOM at release.
- Very large numbers still preserve the `log-` prefix (width chosen so the prefix never clips).
- `navigator.clipboard` unavailable (insecure context) → fail silently without throwing (mirror `ClipboardCopy`'s guard).
- A log-cell interaction must never toggle row expansion or alter the checkbox multi-selection.

## Acceptance Criteria
- The log-number column is a constant width for any magnitude; overflow renders as `log-NNN…` and never widens the row.
- Single click on a log number copies exactly `log-XXXX` to the clipboard and shows a brief copied state.
- Click-drag down across N rows and release copies `log-XXXX to log-YYYYY` (anchor → release, DOM-ordered).
- Neither interaction toggles the row body nor changes the checkbox selection.
- Hovering a log number signals it is interactive (cursor + subtle color change); the full value is available via `title`.
- `mix compile --warnings-as-errors`, `mix test --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, and `mix dialyzer` all pass; the new LiveView test passes.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix assets.build` — bundle the new hook + CSS without esbuild/tailwind errors.
- `mix test test/repo_builder_web/live/test_log_copy_chip_test.exs` — the new server-contract integration test passes.
- `mix test test/repo_builder_web/live/test_log_number_test.exs` — existing log-number rendering still passes.
- `mix compile --warnings-as-errors` — clean compile; set-theoretic type checker + `warnings_as_errors` pass.
- `mix test --warnings-as-errors` — full ExUnit suite, zero failures.
- `mix format --check-formatted` — formatting.
- `mix credo --strict` — lint, including the `@spec`-on-every-public-function rule.
- `mix dialyzer` — contract checking, no new warnings, no stale ignore filters.

## Notes
- **No new dependencies, no Elixir domain/DB changes.** The feature is presentation + a client-side hook; the log number is already rendered. The only server-side edit is adding the `data-log` attribute (and keeping `title`) on an existing span, so the typed/`@spec`/Dialyzer surface is essentially untouched — but the full gate is still run to guarantee zero regressions.
- **Why a hook, not server round-trips:** clipboard access and pointer-drag geometry are browser-only. Pushing events to the server for a pure copy would add latency and a useless server handler. This matches the existing `ClipboardCopy` hook precedent.
- **Coexistence with `DragSelect`:** both attach to `#event-stream-wrap` and add `document` pointer listeners, but each guards on its own target class (`.cns-event-row__ln` vs `.cns-event-row__select`), so they don't interfere. Keep the capture-phase click-swallow consistent with `DragSelect` to avoid double-handling the synthetic post-drag click.
- **Width tuning:** pick the fixed `max-width` so the `log-` prefix plus ≥2 digits always show before the ellipsis; revisit if the design system later changes the row font size.
- **Future:** could extend the copied feedback to a tiny toast, or support modifier-click to copy just the bare number without the `log-` prefix — out of scope here.
