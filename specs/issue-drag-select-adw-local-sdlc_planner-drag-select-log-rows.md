# Feature: Click-and-drag range selection of console log rows

## Metadata
issue_number: ``
adw_id: ``
issue_json: `{"title":"Drag to select log row checkboxes","body":"On the console (/) center event stream, when I click and hold on a log row's checkbox and drag down or up, I want each row I drag over to have its checkbox selected, for a smoother (spreadsheet-like) multi-select instead of clicking each checkbox one at a time."}`

## Feature Description
The console center event stream (`RepoBuilderWeb.ConsoleComponents.event_row/1`, rendered per row in `console_live.ex:2280`) already has a reusable per-row selection checkbox (`.cns-event-row__select`, `console_components.ex:490-497`) that drives the bulk-action `selection_bar` (EXPLAIN / HIDE / COPY) via the `selected_ids` MapSet and the `toggle_select` event. Today selection is strictly one-click-per-row.

This feature adds **click-and-drag range selection**: press the pointer on a row's checkbox, drag up or down, and every row the pointer crosses is toggled to a single target state (spreadsheet "drag-fill" semantics) in one smooth gesture. On release, the whole dragged range is committed to the server's `selected_ids` in a single round-trip. A plain click (no drag) keeps its current single-row toggle behavior unchanged, so the bulk actions and existing tests are untouched.

## User Story
As an operator triaging the console event stream
I want to click-hold on a log row checkbox and drag up or down to select a contiguous range of rows
So that I can build a multi-row selection (for EXPLAIN/HIDE/COPY) quickly and smoothly instead of clicking each checkbox individually.

## Problem Statement
Selecting many adjacent log rows requires one discrete click per row — slow and error-prone when picking a span of related events. There is no gesture to sweep a range. The selection primitive (`selected_ids` + `toggle_select`) is sound, but the interaction is limited to single toggles.

## Solution Statement
Add a small, self-contained LiveView JS hook (`DragSelect`) on the `#event-stream` container that translates a pointer drag into a range selection:

- **Anchor + mode:** on `pointerdown` on a `.cns-event-row__select`, record the anchor row id and the drag **mode** = the OPPOSITE of the anchor checkbox's current state (drag from an unchecked row ⇒ "select"; from a checked row ⇒ "deselect") — standard spreadsheet drag semantics.
- **Optimistic paint during drag:** on `pointermove`, compute the contiguous DOM range between the anchor row and the row under the pointer, and optimistically set each row's checkbox `checked` + `.cns-event-row--selected` class to `mode` — no server round-trip per row, so the sweep is smooth.
- **Single commit on release:** on `pointerup`, if a real drag occurred, push ONE `select_drag` event `%{"ids" => [...], "mode" => "select"|"deselect"}` to the LiveView and suppress the trailing synthetic click so it does not double-toggle.
- **Click compatibility:** if no drag occurred (pointer never left the anchor row), do nothing in the hook and let the existing `phx-click="toggle_select"` handle the single toggle exactly as today.

Server-side, add a `handle_event("select_drag", …)` clause that adds/removes the given ids from `selected_ids` (additive/subtractive relative to the existing selection, honoring `mode`) and re-streams only the affected rows so authoritative `checked`/`--selected` state reconciles the optimistic paint. The existing `selection_bar` count and all bulk actions work unchanged because they read the same `selected_ids`.

## Relevant Files
Use these files to implement the feature:

- `assets/js/app.js` — registers LiveView hooks (`AutoScroll`, `ClipboardCopy`, `CommandPaste` at `:127`). Add the new `DragSelect` hook object and include it in the `hooks: {…}` map. This is the bulk of the feature (client-side pointer handling, optimistic paint, single commit, click suppression).
- `lib/repo_builder_web/components/console_components.ex` — `event_row/1` (`:474-515`) renders the row + checkbox (`:490-497`); `selection_bar/1` (`:530+`) renders the bulk-action bar. The checkbox keeps `phx-click="toggle_select"` (single-click fallback); add only the small `data-*`/class hooks the JS needs to identify rows/checkboxes (see Tasks). The row already carries `id="ev-row-#{@id}"` and the checkbox already carries `phx-value-id`; confirm the JS can read the row id from these without markup churn.
- `lib/repo_builder_web/live/console_live.ex` — the center stream container `#event-stream` (`:2273-2279`) where the `DragSelect` hook attaches (it currently has `phx-hook="AutoScroll"`; a DOM element supports only ONE `phx-hook`, so the new behavior must be folded into a single hook on this element OR attached to a different wrapping element — see Tasks/Notes). The existing selection handlers live at `toggle_select` (`:1171-1180`), `clear_selection` (`:1182-1183`), and the `selected_ids` assign (`:159`). Add the `select_drag` handler beside `toggle_select`, reusing the `toggle_member`/stream-insert pattern.
- `assets/css/app.css` — event-row styles (`.cns-event-row`, `--selected`, `__select` at `:242-260`). Add a `user-select: none` guard applied while a drag is active (e.g. a `.cns-dragging` class on the container) so text isn't selected during the sweep.
- `test/repo_builder_web/live/test_explain_logs_test.exs` — reference for the selection test pattern: seed rows via `Dashboard.broadcast_event/3`, drive selection, assert on `render/1` and the `selection_bar`. Model the new test's server-side assertions on this.
- `BUILD_PROMPT.md` §9 (LiveView dashboard, hooks, reconnect rules) and §3 (typed style: `@spec` on the new public handler) — conventions to honor.
- `.claude/commands/conditional_docs.md` — read it; if it maps LiveView/JS-hook or front-end work to extra docs, fold those into this section.

### New Files
- `test/repo_builder_web/live/test_drag_select_logs_test.exs` — `Phoenix.LiveViewTest` integration test for the SERVER contract of the gesture: drive the `select_drag` event via `render_hook/3` and assert `selected_ids`/`selection_bar` update for both `"select"` and `"deselect"` modes and that rows re-stream with the right `checked` state. (The raw pointer gesture is browser-only and is verified manually / via Tidewave browser eval — see Testing Strategy.)

## Implementation Plan
### Phase 1: Foundation
Establish the server-side batch-selection contract that the gesture commits to, independent of any JS. Add `handle_event("select_drag", …)` to `console_live.ex` (additive/subtractive over `selected_ids`, re-stream affected rows) and its test via `render_hook/3`. This makes the feature testable and correct before wiring the pointer UI.

### Phase 2: Core Implementation
Build the `DragSelect` client hook in `assets/js/app.js`: pointerdown anchor + mode capture, pointermove range computation + optimistic paint, pointerup single commit + click suppression, and document-level pointerup/pointercancel cleanup so a release outside the container still commits/cancels cleanly. Add the `user-select:none` CSS guard.

### Phase 3: Integration
Attach the hook to the stream container without losing `AutoScroll` (single-`phx-hook`-per-element constraint), keep `phx-click="toggle_select"` as the single-click path, verify EXPLAIN/HIDE/COPY still operate on the drag-built selection, and validate end-to-end (tests + manual browser drag).

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Research & confirm conventions
- Read `BUILD_PROMPT.md` §3 and §9, `README.md`, and `.claude/commands/conditional_docs.md`.
- Re-read `event_row/1` (`console_components.ex:474-515`), the `#event-stream` container (`console_live.ex:2273-2294`), the `toggle_select`/`clear_selection` handlers (`console_live.ex:1171-1183`), and the hook registration (`app.js:127`).
- Confirm the per-row `id` is available to JS as the numeric suffix of `#ev-row-<id>` and as the checkbox's `phx-value-id`; decide to read it from a stable `data-row-id` on the checkbox (added in step 3) to avoid string-parsing the DOM id.

### 2. Add the server-side batch selection handler (Phase 1)
- In `console_live.ex`, beside `toggle_select` (`:1171`), add `@impl`-style `handle_event("select_drag", %{"ids" => ids, "mode" => mode}, socket)`:
  - Parse `ids` to integers (guard against non-numeric); normalize `mode` to `:select | :deselect` (default to `:select` on anything unexpected).
  - Compute the new `selected_ids`: `:select` ⇒ `MapSet.union(selected, MapSet.new(ids))`; `:deselect` ⇒ `MapSet.difference(selected, MapSet.new(ids))`.
  - Determine the set of rows whose membership actually CHANGED (symmetric difference of old vs new) and `stream_insert/3` each such row found in `event_buffer` (mirror the `toggle_select` re-stream pattern at `:1176-1178`) so only changed rows re-render.
  - Assign the new `selected_ids` and return `{:noreply, socket}`.
- Keep the existing `toggle_select` clause unchanged (single-click path).
- Add an `@spec`? Note `handle_event/3` is a `@impl true` callback (exempt from the per-function `@spec` rule per `BUILD_PROMPT.md` §3). If a private helper is extracted (e.g. `apply_drag_selection/3`), give it an `@spec`.

### 3. Add minimal markup hooks the JS needs (Phase 1/2 seam)
- In `event_row/1` (`console_components.ex:490-497`), add a stable `data-row-id={@id}` attribute to the `<input type="checkbox">` (keep its existing `phx-click="toggle_select"` and `phx-value-id`). This gives the hook an unambiguous integer id without parsing the DOM id.
- Do NOT remove `phx-click="toggle_select"` — single click stays server-handled; the hook only intervenes on a true drag.

### 4. Resolve the single-`phx-hook` constraint on `#event-stream` (Phase 3 prerequisite)
- The `#event-stream` element already has `phx-hook="AutoScroll"` (`console_live.ex:2276`). An element supports only one `phx-hook`. Choose ONE:
  - **Preferred:** wrap the stream container in (or attach `DragSelect` to) a STABLE parent/sibling element that is NOT the `phx-update="stream"` node, and have the hook query its descendant rows. Attaching the drag hook to the `phx-update="stream"` node is risky (stream DOM churn). Add a thin wrapper `<div id="event-stream-wrap" phx-hook="DragSelect"> … #event-stream … </div>` so `AutoScroll` stays on `#event-stream` and `DragSelect` owns the wrapper.
  - Document the chosen structure in a code comment referencing the one-hook-per-element rule.

### 5. Implement the `DragSelect` JS hook (Phase 2)
- In `assets/js/app.js`, add a `DragSelect` hook object (mirror the structure/cleanup discipline of `CommandPaste`: store bound handlers, remove them in `destroyed()`):
  - State: `dragging`, `mode` (`"select"|"deselect"`), `anchorId`, `didDrag`, `suppressNextClick`.
  - `pointerdown` (delegated, only when `e.target.matches(".cns-event-row__select")`): record `anchorId` = `data-row-id`; `mode` = checkbox.checked ? "deselect" : "select"; set `dragging=true`, `didDrag=false`; add `.cns-dragging` to the container (CSS `user-select:none`); optionally `setPointerCapture`. Do NOT paint yet (so a pure click is untouched).
  - `pointermove` while `dragging`: find the row under the pointer (`document.elementFromPoint` → closest `[id^="ev-row-"]`, or track via `pointerover` on rows). If it differs from the anchor (or any movement crosses a row boundary), set `didDrag=true`. Build the ordered list of row checkboxes in the container (query `.cns-event-row__select` in DOM order), compute the inclusive index range between anchor and current, and set each in-range checkbox's `.checked` and its row's `.cns-event-row--selected` class to match `mode`; reset out-of-range rows that were painted this drag back to their pre-drag state (track the painted set so an up-then-down drag corrects itself).
  - `pointerup` (on document, to catch release outside): if `dragging`:
    - if `didDrag`: collect the in-range `data-row-id`s, `this.pushEvent("select_drag", {ids, mode})`, and set `suppressNextClick=true` so the imminent click on the checkbox/row is swallowed (a capture-phase `click` listener on the container calls `preventDefault()` + `stopImmediatePropagation()` once when `suppressNextClick`).
    - if NOT didDrag: do nothing → the native `phx-click="toggle_select"` fires for the single row.
    - clear `dragging`, remove `.cns-dragging`, release pointer capture.
  - `pointercancel` / blur: treat as cancel — clear `dragging`, remove `.cns-dragging`, repaint nothing new (server state is authoritative; the optimistic paint will be reconciled on the next stream update if needed).
  - Register `DragSelect` in the `hooks: {…}` map at `app.js:127`.
- Keep it dependency-free (pointer events cover mouse + touch); no new libs.

### 6. Add the CSS drag guard (Phase 2)
- In `assets/css/app.css` near `:242-260`, add `.cns-dragging { user-select: none; }` (scoped to the drag container) so the sweep doesn't select page text. Reuse existing `.cns-event-row--selected` / `__select:checked` styles for the painted feedback (no new visual styles required).

### 7. Add the LiveView integration test (Phase 1, write alongside step 2)
- Create `test/repo_builder_web/live/test_drag_select_logs_test.exs` (`use RepoBuilderWeb.ConnCase, async: false`, `import Phoenix.LiveViewTest`), modeled on `test_explain_logs_test.exs`:
  - `live(conn, "/")`; seed ≥3 deterministic rows via `Dashboard.broadcast_event/3` (ids become the per-socket seq `1,2,3`); `wait_render` for them.
  - **Select range:** `render_hook(view, "select_drag", %{"ids" => ["1","2","3"], "mode" => "select"})`; assert `render(view) =~ "3 selected"` and each row's checkbox renders `checked`.
  - **Deselect subset:** `render_hook(view, "select_drag", %{"ids" => ["2"], "mode" => "deselect"})`; assert `"2 selected"` and row 2 is unchecked while 1 and 3 stay checked.
  - **Additivity:** with a prior single `toggle_select` on row 1, a `select_drag` of `["2","3"]` yields `"3 selected"` (drag is additive, not a replace).
  - **Bulk-action interop:** after a drag selection, `render_click(view, "explain_selected", %{})` (or assert the `selection_bar` shows EXPLAIN/HIDE/COPY for the dragged set) to prove the gesture feeds the existing actions.
- Note in the test moduledoc that the raw pointer drag is browser-only and covered by manual/Tidewave verification (step 9).

### 8. Build assets & run the gate
- `mix assets.build` (bundle the new hook) and run the Validation Commands.

### 9. Manual / runtime verification of the gesture
- With the app running (`http://localhost:4000`), use Tidewave Web `browser_eval` (or Playwright MCP) to confirm the wiring: dispatch synthetic `pointerdown`/`pointermove`/`pointerup` across several `.cns-event-row__select` elements and assert the `selection-bar` shows the expected "N selected" and that a single `select_drag` was pushed (not N toggles). Optionally capture a screenshot as visual proof. If the synthetic pointer sequence proves unreliable in the harness, defer to the user for a real click-drag check rather than over-investing in simulation.

### 10. Final validation
- Run every command in `Validation Commands`; fix any compile/format/credo/dialyzer issues; confirm zero regressions in the existing `test_explain_logs_test.exs`.

## Testing Strategy
### Unit Tests
- `select_drag` server handler (via `render_hook/3`): select-mode union, deselect-mode difference, additivity over an existing selection, idempotence (re-selecting already-selected ids keeps the count stable), and that only changed rows re-stream (assert checkbox `checked` state per row).
- `selection_bar` count reflects the drag-built `selected_ids`, and EXPLAIN/HIDE/COPY operate on it (interop with the existing selection primitive).

### Edge Cases
- Pure click (no movement) still single-toggles via `phx-click="toggle_select"` (the hook must not interfere) — covered by the unchanged `test_explain_logs_test.exs`.
- Drag upward vs downward yields the same inclusive range (anchor may be either endpoint).
- Up-then-down within one drag: rows painted then left out-of-range revert to their pre-drag state before commit.
- Release outside the stream container still commits (document-level `pointerup`).
- `pointercancel`/window blur cancels cleanly without a partial commit.
- Rows arriving live (new `broadcast_event`) mid-drag: range recomputed from current DOM each move; server is authoritative on commit.
- Drag across filtered/hidden rows: only DOM-present rows (already filtered) participate.
- Non-numeric / stale `ids` in the `select_drag` payload are ignored server-side (guarded parse).
- Empty `ids` is a no-op.

## Acceptance Criteria
- Pressing on a row checkbox and dragging up or down toggles every crossed row to one consistent target state (select if the anchor was unselected, deselect if it was selected), with smooth visual feedback during the drag.
- Releasing commits the entire range to `selected_ids` in a SINGLE server round-trip (`select_drag`), and the `selection_bar` count + bulk actions reflect it.
- A plain single click still toggles exactly one row (no behavior change; existing tests pass).
- Text is not selected while dragging.
- `mix test test/repo_builder_web/live/test_drag_select_logs_test.exs` passes, and the full gate is green.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix test test/repo_builder_web/live/test_drag_select_logs_test.exs` — the new integration test passes.
- `mix test test/repo_builder_web/live/test_explain_logs_test.exs` — existing single-click selection + bulk-action flow still passes (no regression).
- `mix assets.build` — the JS bundle (with the `DragSelect` hook) builds cleanly.
- `mix compile --warnings-as-errors` — clean compile; gradual set-theoretic type checker and `warnings_as_errors` pass.
- `mix test --warnings-as-errors` — full ExUnit suite, zero failures.
- `mix format --check-formatted` — formatting clean.
- `mix credo --strict` — lint clean, including the every-public-function-has-`@spec` rule (callback clauses exempt).
- `mix dialyzer` — no new contract warnings, no stale ignore filters.

## Notes
- No new dependencies. Pointer Events (`pointerdown`/`pointermove`/`pointerup`/`pointercancel`) cover mouse and touch in one code path; no drag library needed.
- **One `phx-hook` per element:** `#event-stream` already hosts `AutoScroll`, and it is the `phx-update="stream"` node (DOM churn). Attach `DragSelect` to a stable wrapper element (step 4), not the stream node, to avoid the hook being torn down/re-init on every stream patch and to keep `AutoScroll` intact.
- **Keep the server primitive additive:** `select_drag` deliberately ADDS/REMOVES rather than REPLACES, so a drag composes with prior single-click selections — matching spreadsheet expectations and preserving the existing `toggle_select` contract.
- **Optimistic paint is reconciled, not authoritative:** the client paints during the drag for smoothness; the server's `selected_ids` + per-row `stream_insert` on commit is the source of truth. If the socket drops mid-drag, no commit happens and the next render restores authoritative state.
- Future enhancement (out of scope): edge auto-scroll while dragging past the top/bottom of the viewport to extend a selection beyond the visible rows; and Shift-click range-select as a keyboard-only complement to the drag.
- Consider centralizing the `"orch-"`-style string contracts and DOM id conventions if more hooks need the row id; for now a single `data-row-id` on the checkbox is sufficient.
