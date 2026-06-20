# Feature: Paste-a-path directory picker

## Metadata
issue_number: `the`
adw_id: `directory`
issue_json: `picker`

## Feature Description
The console's working-directory picker (`dir_picker_modal`) is currently navigation-only:
the operator can click into child directories (`📁`) or go up (`⬆️ ..`), and the current
path is shown in a **read-only** display div (`#dir-picker-path`). There is no way to jump
directly to a known location — reaching `/data/2.Areas/job-seeking/` means clicking through
every intermediate directory.

This feature turns the path display into an **editable text input**. The operator can paste
or type an absolute path (e.g. `/data/2.Areas/job-seeking/`), press Enter (or click a "Go"
button), and the picker browses straight to that directory — re-listing its child
directories and updating parent/up navigation. The "Use this directory" button then commits
the typed/browsed path as the orchestrator cwd, exactly as today. Navigation by clicking
directory buttons continues to work unchanged and keeps the input in sync with the
currently-browsed path.

## User Story
As a console operator setting the orchestrator's working directory
I want to paste an absolute directory path into the picker and jump straight to it
So that I can select a deeply-nested directory without clicking through every parent

## Problem Statement
The directory picker only supports click-to-navigate. Selecting a known, deeply-nested
working directory is slow and error-prone because every intermediate directory must be
clicked. Operators frequently already know the absolute path (it's on their clipboard) but
have no way to use it directly.

## Solution Statement
Replace the read-only `#dir-picker-path` display with a controlled text input bound to the
existing `@dir_picker_path` assign, plus a small "Go" affordance. Submitting the input
(Enter via a wrapping `<form phx-submit>` or a button `phx-click`) dispatches a new
`dir_picker_goto` event carrying the typed value. The server reuses the existing
`load_dir_picker/2` helper — which already expands the path via `FileBrowser.list/1`,
flashes on an invalid/unreadable path, and keeps the prior view on error — so the only new
server code is one thin event handler. Clicking directories still calls `dir_picker_browse`
and updates `@dir_picker_path`, which the controlled input reflects automatically. No
changes to `FileBrowser`, persistence, or the commit (`dir_picker_select`) path are needed.

## Relevant Files
Use these files to implement the feature:

- `lib/repo_builder_web/components/console_components.ex` — defines `dir_picker_modal/1`
  (lines ~866–960). The `#dir-picker-path` display div (~897–904) becomes an editable input
  wrapped in a `<form>` with a "Go" submit button. This is the primary UI change.
- `lib/repo_builder_web/live/console_live.ex` — owns the picker assigns
  (`dir_picker_open?`, `dir_picker_path`, `dir_picker_parent`, `dir_picker_dirs`; ~112–115),
  the picker event handlers (`open_dir_picker`, `dir_picker_browse`, `close_dir_picker`,
  `dir_picker_select`; ~720–745), the `load_dir_picker/2` helper (~1422–1434), and the
  `<.dir_picker_modal>` render call (~2567–2571). Add the new `dir_picker_goto` handler here
  and reuse `load_dir_picker/2`.
- `lib/repo_builder/file_browser.ex` — `FileBrowser.list/1` already `Path.expand/1`s the
  input and returns `{:ok, listing} | {:error, reason}`. No change required; relied upon as-is
  (it already handles trailing slashes and `~`-free absolute paths via `Path.expand/1`).
- `BUILD_PROMPT.md` — §3 typed style guide (every public function `@spec`'d), §9 LiveView
  dashboard conventions. The new handler/component must honor these.

### New Files
- `test/repo_builder_web/live/test_dir_picker_paste_path_test.exs` — `Phoenix.LiveViewTest`
  integration test that opens the picker, submits a typed absolute path, and asserts the
  picker browses to it (path display + child listing) and commits it as the working dir.

## Implementation Plan
### Phase 1: Foundation
Confirm the data flow already in place: `@dir_picker_path` is the single source of truth for
the browsed path, `load_dir_picker/2` is the one funnel that validates+lists a path and
flashes on error, and `dir_picker_select` commits `@dir_picker_path`. The feature only needs
to add a new *input* edge into `load_dir_picker/2` — no new state, no new validation logic.

### Phase 2: Core Implementation
1. Add a `dir_picker_goto` event handler in `console_live.ex` that takes the submitted path
   string and calls `load_dir_picker/2` (which expands, lists, and flashes on error). Trim
   the input and treat blank as a no-op (or re-list the current path) so an empty submit
   doesn't error.
2. In `console_components.ex`, replace the read-only `#dir-picker-path` div with a
   `<form phx-submit="dir_picker_goto">` containing a text `<input name="path">` (value bound
   to `@path`, `phx-window-keydown="close_dir_picker"` already lives on the overlay) and a
   small "Go" submit button. Keep the monospace styling and the `title={@path}` affordance.
   Ensure the input is not auto-focused on open if that would steal focus from Escape-to-close
   (it is fine to focus it — Escape is a window-keydown handler).

### Phase 3: Integration
Verify the controlled input stays in sync when the operator clicks directory buttons
(`dir_picker_browse` updates `@dir_picker_path`, so the re-rendered input `value` follows).
Confirm `dir_picker_select` still commits `@dir_picker_path` (now possibly a pasted path that
was browsed-to). Confirm an invalid pasted path flashes and leaves the prior view intact.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Add the `dir_picker_goto` LiveView event handler
- In `lib/repo_builder_web/live/console_live.ex`, alongside the other picker handlers
  (~733), add `handle_event("dir_picker_goto", %{"path" => path}, socket)`.
- Trim the path; on blank, return `{:noreply, socket}` (no-op). Otherwise delegate to the
  existing `load_dir_picker(socket, path)` and return `{:noreply, ...}`.
- This handler is a `Phoenix.LiveView` callback implementation (`handle_event/3`) — no `@spec`
  needed per the `@impl`/callback exemption, matching the sibling handlers.

### 2. Make the path field editable in the component
- In `lib/repo_builder_web/components/console_components.ex`, replace the
  `#dir-picker-path` display `<div>` (~897–904) with a `<form>`:
  - `<form phx-submit="dir_picker_goto" class="mb-2 flex items-center gap-2">`
  - A text `<input type="text" name="path" id="dir-picker-path" value={@path} ...>` carrying
    the existing monospace/border styling and `title={@path}`, plus `autocomplete="off"` and
    `spellcheck="false"`.
  - A `<button type="submit" class="cns-chip">Go</button>` to the right.
- Keep the existing attrs (`@path`, `@parent`, `@dirs`, `@open?`) unchanged.
- Preserve the surrounding listing, Cancel, and "Use this directory" markup verbatim.

### 3. Create the LiveView integration test
- Create `test/repo_builder_web/live/test_dir_picker_paste_path_test.exs` using
  `Phoenix.LiveViewTest`.
- Mount `ConsoleLive` at `/`, trigger `open_dir_picker` (render_click on the control that
  opens it, or `render_hook`/`render_click` for `"open_dir_picker"`).
- Submit the path form with a real, existing absolute directory created via
  `System.tmp_dir!()` + a `File.mkdir_p!` fixture (e.g. a tmp dir with a known child
  subdirectory), using `form(view, "#... ")` / `render_submit` or
  `render_submit(element(view, "form[phx-submit=dir_picker_goto]"), %{path: tmp})`.
- Assert the rendered picker now shows the submitted absolute path and the child
  subdirectory name in the listing.
- Submit `dir_picker_select` and assert the working dir is committed (assert the rendered
  working-dir control reflects the tmp path, and/or the relevant PubSub/flash, mirroring how
  the existing working-dir tests assert commits).
- Add a negative case: submit a non-existent path and assert a flash error and that the path
  display is unchanged.

### 4. Run the validation commands
- Run every command in `Validation Commands` and fix any failures until all are green with
  zero regressions.

## Testing Strategy
### Unit Tests
- `FileBrowser.list/1` already has coverage; no new unit tests needed (the feature adds no
  new domain logic — it reuses `list/1` via `load_dir_picker/2`).
- The behavior is exercised through the LiveView integration test (the meaningful surface).

### Edge Cases
- Pasted path with a trailing slash (`/data/2.Areas/job-seeking/`) — `Path.expand/1`
  normalizes it; assert it browses correctly.
- Blank/whitespace-only submit — no-op, no crash, no flash spam.
- Non-existent or unreadable path — flashes "Cannot open directory: …" and keeps the prior
  listing (no broken state).
- Relative path pasted (e.g. `foo/bar`) — `Path.expand/1` resolves it against cwd; it either
  lists (if it exists) or flashes; assert no crash. (Commit-time `validate_working_dir/1`
  still enforces absolute paths on `dir_picker_select`.)
- Clicking a directory after pasting keeps the input value in sync with `@dir_picker_path`.

## Acceptance Criteria
- The picker's path field is an editable text input (id `dir-picker-path`) pre-filled with
  the current browsed path.
- Submitting an existing absolute path (Enter or "Go") re-lists that directory: the path
  display updates and the child directories render.
- Submitting an invalid path flashes an error and leaves the previous listing intact.
- Clicking directory buttons (`📁` / `⬆️ ..`) still works and updates the input value.
- "Use this directory" commits the currently-shown path as the orchestrator cwd, unchanged.
- The new LiveView integration test passes.
- `mix compile --warnings-as-errors`, `mix test --warnings-as-errors`,
  `mix format --check-formatted`, `mix credo --strict`, and `mix dialyzer` are all green.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix test test/repo_builder_web/live/test_dir_picker_paste_path_test.exs` - Run the new
  LiveView integration test for the paste-a-path picker.
- `mix compile --warnings-as-errors` - Compile clean; gradual type checker + warnings-as-errors pass.
- `mix test --warnings-as-errors` - Full ExUnit suite, zero failures.
- `mix format --check-formatted` - Code formatting.
- `mix credo --strict` - Lint, including the `@spec`-on-every-public-function convention.
- `mix dialyzer` - Contract checking, no new warnings.

Optional runtime validation (Tidewave): use `project_eval` to call
`RepoBuilder.FileBrowser.list("/data/2.Areas/job-seeking/")` and confirm it returns the
expected `{:ok, listing}`; optionally capture a screenshot of the open picker at
`http://localhost:4000` via Tidewave Web vision mode (or Playwright MCP) as visual proof.

## Notes
- No new dependencies. No migrations. No `FileBrowser` changes — `Path.expand/1` already
  handles trailing slashes and relative input.
- The server-side validation/flash story is fully reused via `load_dir_picker/2`; the only
  new server code is the thin `dir_picker_goto` callback, keeping the change minimal and
  consistent with the existing picker handlers.
- Focus behavior: the overlay's `phx-window-keydown="close_dir_picker"` (Escape) is a window
  listener, so focusing the input is safe and Escape still closes the modal.
- Future consideration: tab-completion / inline directory suggestions as the operator types,
  and remembering recently-used working directories. Out of scope here.
