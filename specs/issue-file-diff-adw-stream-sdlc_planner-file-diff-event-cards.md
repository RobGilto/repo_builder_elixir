# Feature: Polished file-diff event cards (create/edit) with inline diff + file access

## Metadata
issue_number: `file-diff`
adw_id: `stream`
issue_json: `{"title":"Improve UI for file create/edit events — inline diff + file access","body":"For orchestrator events that create or edit a file (e.g. log-9729, log-9766, log-9781) an engineer needs to see the diff inline (red = removed, green = added, gray = unchanged) and open/access the referenced file from the UI. Make it polished and practical: file path links, status badges, +N/-N line stats, an expandable colored diff. Reference implementation to study: /data/1.Projects/tactical-agentic-coding/tac-14/orchestrator-agent-with-adws/apps/orchestrator_3_stream/ (FileChangesDisplay.vue, fileService.ts)."}`

## Feature Description
Today the console event stream renders a file-writing tool call (Claude `Write`/`Edit`/`MultiEdit`; pi equivalents) as a generic "Using tool: Edit" card whose body is a flat `key: value` dump of the raw tool input (`file_path`, `old_string`, `new_string`, `content`, …). For an engineer reviewing what an orchestrator/worker actually did to the codebase, that is unreadable: there is no diff, no add/remove coloring, and no way to jump to the file.

This feature upgrades file-operation tool events into **polished, practical file-change cards**:

- A **status badge** — `✓ Created` (green) for a `Write` of a new file, `✎ Modified` (amber) for an `Edit`/`MultiEdit`.
- **Line stats** — `+N Added` (green) / `-N Removed` (red), computed from a real line-level diff.
- An **expandable inline diff** with git-style coloring: **green** for added lines, **red** for removed lines, **gray** for unchanged context lines.
- The **file path rendered as a monospace link** plus an **Open** affordance that launches the file in the operator's configured editor (Cursor/VS Code), mirroring the reference app's `/api/open-file` → "open in IDE" flow — implemented here as a typed `RepoBuilder.Editor` context + a LiveView event (no new HTTP route).

It renders in the **center event stream row** (collapsed: badge + stats + path; expanded: full colored diff) and in the **EVENT DETAIL side panel** for the selected event. It works on both the **live path** (clean `Event.ToolCall` structs) and the **reconnect/backfill path** (persisted `agent_logs.payload` raw frame), via the existing shared `EventPresenter` so both render identically.

## User Story
As an engineer supervising an orchestrator and its workers in the console
I want file create/edit events to show an inline red/green/gray diff and let me open the file
So that I can review exactly what changed and jump straight to the source without leaving the dashboard or decoding raw tool JSON.

## Problem Statement
File-operation tool events are the highest-signal events in a coding-agent run, yet they are presented as the lowest-fidelity cards:

- The diff is invisible. `Edit`'s `old_string`/`new_string` are dumped as raw scalars (truncated at 240 chars), so the actual change is unreadable and large `Write` `content` is just elided.
- There is no add/remove/context coloring — nothing an engineer can scan.
- There is no link to the file and no way to open it; the operator must manually copy the path and open it in a terminal/editor.
- `EventPresenter.from_payload(:tool_call, …)` reads top-level `"name"`/`"input"`, which **do not exist** on the persisted Claude raw frame (name/input are nested under `message.content[].{name,input}`), so on reconnect/backfill these cards degrade even further.

## Solution Statement
Introduce a small, pure **line-diff engine** and a **file-change render sub-model**, surfaced through new typed function components and a typed editor-open context:

1. `RepoBuilder.Console.Diff` — a pure, `@spec`'d LCS line-diff that turns `(old_text, new_text)` into an ordered list of `:eq | :ins | :del` line ops plus added/removed counts. No new dependency.
2. Extend `RepoBuilder.Console.EventPresenter` with a typed `file_change` field on the render model, populated for `Write`/`Edit`/`MultiEdit` (and pi `create_file`/`edit_file`) tool calls — extracting `file_path` + before/after text from the clean live input **and** from the persisted raw frame (fixing backfill fidelity), then computing the diff.
3. New `file_change_card/1` component renders the status badge, `+N/-N` stats, the path-as-link with an **Open** button, and an expandable colored diff (`cns-diff__line--add|--del|--ctx`). It is rendered inside `event_row/1` and `event_detail_panel/1` whenever `render.file_change` is present.
4. `RepoBuilder.Editor` context + `open_file` LiveView event shell out to a configured editor command to open the absolute path (guarded: must be an existing absolute file), flashing success/failure — the practical "access the file from the UI" capability.

This reuses the existing single-source-of-truth presenter seam (live `record_event` and backfill `log_to_row` both call `EventPresenter`), so live and reconnect render identically with zero divergence.

## Relevant Files
Use these files to implement the feature:

- `BUILD_PROMPT.md` — authoritative architecture/spec; honor §3 typed style guide, §4 harness event contract (`Event.ToolCall`/`ToolResult`), §8 persistence (contexts own `Repo`), §9 LiveView dashboard conventions. Read first.
- `ai_docs/typed-elixir-standard.md` — **mandatory** (conditional_docs always row): the enforced typed-Elixir coding standard — `@spec` on every public function, `typedstruct`/`@enforce_keys`, precise types, `{:ok, t()} | {:error, reason()}` over raising. This feature adds several new public functions and structs; all must conform.
- `AGENTS.md` — Phoenix v1.8 + LiveView 1.2 guidelines (conditional_docs LiveView row); relevant for component `attr` declarations, `phx-click` event wiring, and LiveView test helpers.
- `README.md` — project overview/run instructions.
- `lib/repo_builder/console/event_presenter.ex` — **the** shared render-model presenter; `from_event/1` (live) and `from_payload/2` (backfill), `tool_call_model/3`, `extract_files/1`. The `render_model()` type and `base/1` helper define the shape extended by this feature. `from_payload(:tool_call, payload)` currently reads top-level `payload["name"]`/`payload["input"]` — the backfill fix must also dig into `payload["message"]["content"]` for Claude raw frames where `name`/`input` are nested in the `tool_use` block.
- `lib/repo_builder_web/components/console_components.ex` — typed function components; `event_row/1` (center row, lines ~501–559), `consumed_files/1` (exact pattern to mirror for `file_change_card/1`, lines ~561–583), `format_bytes/1`. The call-site in `console_live.ex` at line ~2915 passes `row.render.*` fields explicitly — `file_change` must be added here too.
- `lib/repo_builder_web/components/dashboard_components.ex` — `event_detail_panel/1` (~247); render the file-change card here for the selected event above the PAYLOAD block. The selected event row carries a `render` map (set in `log_to_row` at line ~3471).
- `lib/repo_builder_web/live/console_live.ex` — `record_event/4` (~2361) builds `:render` from `EventPresenter.from_event/1`; `event_row` call-site (~2915–2935) maps `row.render.*` to component attrs (add `file_change={row.render.file_change}`); add `open_file` event handler. Note: LiveViews never touch `Repo` — go through `RepoBuilder.Editor`.
- `lib/repo_builder/harness/claude.ex` — `assistant_block/2` (~314) shows how the Claude adapter extracts `name`/`input` from a `"type" => "tool_use"` block nested inside the raw streaming frame; this is the nesting structure that `from_payload(:tool_call, …)` must learn to dig into for backfill.
- `assets/css/app.css` — console design system; existing CSS vars: `--cns-success: #10b981`, `--cns-error: #ef4444`, `--cns-warning: #f59e0b`, `--cns-text-2: #9ca3af`, `--cns-bg-2: #2a2a2a`, `--cns-border: #333333`. Add `cns-diff*` and `cns-file-change*` rules using these tokens for green/red/gray diff lines and status badges.
- `config/config.exs` — add `config :repo_builder, :editor, enabled: true, command: ["cursor"]`.
- `config/test.exs` — add `config :repo_builder, :editor, enabled: false` so CI never shells out to an editor.
- `config/runtime.exs` — add runtime overrides via `RB_EDITOR_CMD` / `RB_EDITOR_ENABLED` env vars.
- `mix.exs` — no new deps expected (diff is self-contained); only touch if a diff lib is chosen instead (see Notes).
- `test/repo_builder/console/event_presenter_test.exs` — existing presenter tests to extend for `file_change` (at `test/repo_builder/console/event_presenter_test.exs`).
- `.claude/commands/conditional_docs.md` — already read; matches: (always) `ai_docs/typed-elixir-standard.md`; (LiveView dashboard) `BUILD_PROMPT.md §9` + `AGENTS.md`.

### New Files
- `lib/repo_builder/console/diff.ex` — `RepoBuilder.Console.Diff`: pure LCS line-diff engine returning a typed result (`%Diff{lines: [line()], added: non_neg_integer(), removed: non_neg_integer(), truncated?: boolean()}`).
- `lib/repo_builder/editor.ex` — `RepoBuilder.Editor`: typed context that opens an absolute file path in the configured editor via `System.cmd/3`; `{:ok, path} | {:error, reason()}`.
- `test/repo_builder/console/diff_test.exs` — unit tests for the diff engine.
- `test/repo_builder/editor_test.exs` — unit tests for the editor-open guard logic.
- `test/repo_builder_web/live/test_file_diff_event_cards_test.exs` — `Phoenix.LiveViewTest` integration test driving a `Write` and an `Edit` tool event through the console and asserting the rendered diff card + Open affordance.

## Implementation Plan
### Phase 1: Foundation
Build the two pure/typed primitives the UI depends on, fully tested in isolation:

1. `RepoBuilder.Console.Diff` — line-level LCS diff (`diff/2` → `Diff.t()`), with an output cap (e.g. 600 emitted lines ⇒ `truncated?: true`) so a huge `Write` can't blow up the DOM. Pure, no `Repo`, never raises.
2. `RepoBuilder.Editor` — `open/1` validating the path is a binary absolute path to an existing regular file, then `System.cmd(editor, [path])` under the configured command; returns `{:ok, path} | {:error, :not_found | :disabled | :invalid_path | {:exit, integer()}}`. Editor command + enable flag read from app config (default disabled-safe / `["cursor"]`), never from user input.

### Phase 2: Core Implementation
1. Extend `EventPresenter`'s `render_model` with `file_change :: file_change() | nil`, add the typed `file_change` typedoc/type, and default it to `nil` in `base/1` and every `*_model` builder.
2. Add `file_change_from_tool/2` (and raw-frame digging) to populate `file_change` for `Write`/`Edit`/`MultiEdit`/pi `create_file`/`edit_file`:
   - `Write` → `status: :created` (best-effort `:modified` only when we can't tell), before-text `""`, after-text = `content`.
   - `Edit` → `status: :modified`, before = `old_string`, after = `new_string`.
   - `MultiEdit` → `status: :modified`, fold the `edits` list into a combined before/after (or one diff per edit, concatenated) — keep it simple and deterministic.
   - Compute `RepoBuilder.Console.Diff.diff(before, after)`; carry `path`, `status`, `added`, `removed`, `diff`, and `absolute?`.
   - Backfill: read the Claude raw frame (`payload["message"]["content"]` → the `%{"type" => "tool_use"}` block's `name`/`input`) so `from_payload(:tool_call, …)` reaches the same data; also fix the existing top-level-key bug as part of this.
3. Add `file_change_card/1` to `console_components.ex` mirroring `consumed_files/1`'s structure: header row (status badge + `+N/-N` + path link + Open button), and an expandable diff body (`<pre>` of per-line `<span>`s classed add/del/ctx). Reuse the row's existing `expanded?` toggle for expand/collapse (no new client JS) — collapsed shows badge+stats+path, expanded shows the colored diff.
4. Render `file_change_card/1` from `event_row/1` when `@file_change` is present (in addition to / in place of the generic preview for that row), and add a `file_change` attr to `event_row/1`.

### Phase 3: Integration
1. Thread `file_change` from `row.render.file_change` into the `event_row` call-site in `console_live.ex`, and into `event_detail_panel/1` for `@selected_event`.
2. Add the `open_file` LiveView event (`phx-click="open_file" phx-value-path={...}`) → `RepoBuilder.Editor.open/1` → `put_flash(:info|:error, …)`. Disabled/guarded gracefully when editor integration is off.
3. Add `cns-diff*` / `cns-file-change*` CSS (green/red/gray lines, status badges, Open button) consistent with the existing `cns-*` design system.
4. Wire `mix assets.build`-free CSS (plain `app.css`), confirm both views (LOGS center stream + EVENT DETAIL panel) render the card, and validate end-to-end with the LiveView test + a Tidewave screenshot.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### Task 1 — Read the spec and reference, confirm tool shapes
- Read `BUILD_PROMPT.md` (§3, §4, §8, §9) and `README.md`.
- Read `.claude/commands/conditional_docs.md` (if present) and pull any mandated docs into this plan's Relevant Files.
- Confirm the live `Event.ToolCall` input shape and the persisted raw-frame nesting using Tidewave `project_eval`/`get_source_location` (e.g. re-inspect log-9729/9766/9781 payloads and the Claude adapter's `ToolCall` normalization). Confirm pi's file-tool names.

### Task 2 — Implement `RepoBuilder.Console.Diff` (pure)
- Create `lib/repo_builder/console/diff.ex` with `@type line :: %{op: :eq | :ins | :del, text: String.t()}`, a `typedstruct`/`@enforce_keys` `Diff.t()` (`lines`, `added`, `removed`, `truncated?`), and `@spec diff(String.t(), String.t()) :: t()`.
- Implement an LCS line diff (split on `"\n"`); empty `old` ⇒ all `:ins`; empty `new` ⇒ all `:del`. Cap emitted lines (`@max_lines 600`) ⇒ `truncated?: true`. Pure, total, never raises.

### Task 3 — Unit-test the diff engine
- Create `test/repo_builder/console/diff_test.exs`: pure creation (all-insert), pure deletion, mixed change (eq/ins/del interleave), identical inputs (all `:eq`, 0/0 counts), trailing-newline handling, and the truncation cap.

### Task 4 — Implement `RepoBuilder.Editor` context + config
- Create `lib/repo_builder/editor.ex` with `@type reason :: :disabled | :invalid_path | :not_found | {:exit, integer()}` and `@spec open(String.t()) :: {:ok, String.t()} | {:error, reason()}`.
- Validate: binary, `Path.type/1 == :absolute`, `File.regular?/1`; respect an `:enabled` config flag; `System.cmd(editor, [path], stderr_to_stdout: true)` and map non-zero exit to `{:error, {:exit, code}}`.
- Add config: `config :repo_builder, :editor, enabled: true, command: ["cursor"]` in `config/config.exs`, overridable in `config/runtime.exs` (env `RB_EDITOR_CMD` / `RB_EDITOR_ENABLED`). Default must be safe in CI/test (`enabled: false` in `config/test.exs`).

### Task 5 — Unit-test the editor context
- Create `test/repo_builder/editor_test.exs`: `{:error, :invalid_path}` for relative/non-binary; `{:error, :not_found}` for a missing absolute path; `{:error, :disabled}` when the flag is off; success path exercised against a tmp file with a stub command (e.g. config command `["true"]`) asserting `{:ok, path}`.

### Task 6 — Extend `EventPresenter` with the `file_change` sub-model
- Add `@type file_change :: %{path: String.t(), status: :created | :modified, added: non_neg_integer(), removed: non_neg_integer(), diff: RepoBuilder.Console.Diff.t(), absolute?: boolean()}` and add `file_change: file_change() | nil` to `render_model()`.
- Default `file_change: nil` in `base/1` and every `*_model` builder.
- Add `file_change_from_tool/2` handling `Write`/`Edit`/`MultiEdit` + pi `create_file`/`edit_file`; wire it into `tool_call_model/3` (live) and a raw-frame extractor used by `from_payload(:tool_call, …)`. Fix `from_payload(:tool_call, …)` to read name/input from the Claude `message.content` `tool_use` block (and keep the existing top-level path as a fallback for already-normalized rows). Keep everything pure/total.

### Task 7 — Extend presenter tests
- Extend `test/repo_builder/console/event_presenter_test.exs`: `from_event(%Event.ToolCall{name: "Write", input: %{"file_path" => ..., "content" => ...}})` ⇒ `file_change.status == :created`, added > 0, removed == 0; `Edit` ⇒ `:modified` with correct added/removed; a non-file tool ⇒ `file_change == nil`; and a **backfill** assertion: `from_payload(:tool_call, <claude raw Edit frame>)` yields the same `file_change` (regression-guards the raw-frame bug).

### Task 8 — `file_change_card/1` component + CSS
- Add `file_change_card/1` to `console_components.ex` (typed `attr`s: `file_change`, `expanded?`, `open_enabled?`), mirroring `consumed_files/1`. Collapsed: status badge + `+N/-N` + path (monospace, selectable) + **Open** button (`phx-click="open_file" phx-value-path={@file_change.path}`, shown only when absolute & enabled). Expanded: a `<pre phx-no-curly-interpolation>` of per-line `<span class={diff_line_class(op)}>`; show a "diff truncated" note when `truncated?`.
- Add `cns-diff`, `cns-diff__line--add|--del|--ctx`, `cns-file-change*`, status-badge, and Open-button styles to `assets/css/app.css` using the `cns-*` token system (green/red/gray).

### Task 9 — Render the card in `event_row/1`
- Add a `file_change` attr to `event_row/1`; when present, render `file_change_card/1` (replacing the generic `preview`/`detail` block for that row, keeping `consumed_files/1` behavior for non-file rows). Preserve the expand toggle (`@expanded?`).

### Task 10 — Render the card in `event_detail_panel/1`
- In `dashboard_components.ex`, render `file_change_card/1` (expanded) for `@event.render.file_change` when present, above the raw PAYLOAD block.

### Task 11 — Wire `console_live.ex` (call-site + handler)
- At the `event_row` call-site (~2915), pass `file_change={row.render.file_change}`.
- Ensure `@selected_event` carries `render` (it already stores the full row) so the detail panel can read `@event.render.file_change`.
- Add `handle_event("open_file", %{"path" => path}, socket)` → `RepoBuilder.Editor.open(path)` → `put_flash(:info, "Opened …")` / `put_flash(:error, reason_msg)`. `@impl`-free public `@spec` not required for `handle_event` clauses, but keep helpers `@spec`'d.

### Task 12 — LiveView integration test
- Create `test/repo_builder_web/live/test_file_diff_event_cards_test.exs` using `Phoenix.LiveViewTest`: mount `live(conn, ~p"/")`, broadcast/send a `Write` tool-call event and an `Edit` tool-call event for the active agent (via the same PubSub/`handle_info({:agent_event, …})` seam other console tests use), then:
  - assert the rendered row shows the status badge (`Created`/`Modified`) and `+N`/`-N` stats;
  - expand the row and assert add/del/ctx diff lines are present (`cns-diff__line--add`/`--del`);
  - assert the **Open** button renders with `phx-value-path` and that clicking it triggers the `open_file` handler (editor disabled in test ⇒ assert the graceful `:error`/disabled flash, no crash).
- Optionally capture a Tidewave Web (vision) or Playwright screenshot of `http://localhost:4000` showing an expanded diff card as visual proof.

### Task 13 — Run the full Validation Commands
- Run every command in `Validation Commands` and fix any compile/type/lint/test/format issue until all are green with zero regressions.

## Testing Strategy
### Unit Tests
- `RepoBuilder.Console.Diff` — creation/deletion/mixed/identical/truncation, counts correct, op ordering stable.
- `RepoBuilder.Editor` — path validation, disabled flag, missing file, success against a stub command.
- `RepoBuilder.Console.EventPresenter` — `file_change` populated for `Write`/`Edit`/`MultiEdit` (live structs) and the matching persisted raw frame (backfill parity); `nil` for non-file tools; counts and `status` correct.

### Edge Cases
- `Write` of a brand-new file (old text empty) ⇒ all-green, `removed == 0`, `status: :created`.
- `Edit` that only deletes lines ⇒ `added == 0`, red lines present.
- `Edit` whose `old_string == new_string` (no-op) ⇒ all-gray, `0/0` stats.
- `replace_all: true` Edit and `MultiEdit` with several edits ⇒ deterministic combined diff.
- Huge `Write` `content` (thousands of lines) ⇒ diff capped, `truncated?` note shown, DOM stays bounded.
- Relative `file_path` or path outside the workspace ⇒ Open button hidden/disabled; path still shown.
- Backfilled (reconnect) Claude `Edit`/`Write` row ⇒ identical card to the live render.
- Editor integration disabled / editor binary missing ⇒ `open_file` flashes a clear error, never crashes the LiveView.
- pi-harness file tools (`create_file`/`edit_file`) ⇒ recognized; unknown file tool ⇒ falls back to the existing generic tool card.

## Acceptance Criteria
- File create/edit tool events (Claude `Write`/`Edit`/`MultiEdit`, pi `create_file`/`edit_file`) render a file-change card with a status badge (`✓ Created` green / `✎ Modified` amber) and `+N Added` (green) / `-N Removed` (red) stats.
- Expanding the row (or viewing it in EVENT DETAIL) shows an inline diff with **green added / red removed / gray unchanged** lines.
- The file path is shown as a monospace, selectable link, and an **Open** button opens the file in the configured editor (or flashes a clear, non-crashing error when disabled/unavailable).
- Live and backfill/reconnect paths render the identical card (shared `EventPresenter`); the prior `from_payload(:tool_call, …)` raw-frame gap is fixed.
- The center stream stays bounded for very large writes (diff truncation honored).
- `mix compile --warnings-as-errors`, `mix test --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, and `mix dialyzer` all pass with zero new warnings; every new public function has an `@spec` and new structs use `@enforce_keys`/`typedstruct`.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix test test/repo_builder/console/diff_test.exs` — diff engine correctness.
- `mix test test/repo_builder/editor_test.exs` — editor-open guard logic.
- `mix test test/repo_builder/console/event_presenter_test.exs` — presenter `file_change` (live + backfill parity).
- `mix test test/repo_builder_web/live/test_file_diff_event_cards_test.exs` — LiveView: diff card renders (badge, +/- stats, colored lines) and the Open affordance works end-to-end.
- `mix compile --warnings-as-errors` — clean compile; gradual set-theoretic type checker + `warnings_as_errors` pass.
- `mix test --warnings-as-errors` — full ExUnit suite, zero failures.
- `mix format --check-formatted` — formatting.
- `mix credo --strict` — lint incl. the every-public-function-has-an-`@spec` gate.
- `mix dialyzer` — contract checking, no new warnings, no stale ignores.

## Notes
- **No new dependency is required**: the diff is a self-contained LCS line-diff in `RepoBuilder.Console.Diff`. If a richer hunk/word diff is later wanted, a pinned library could be added per `BUILD_PROMPT.md` §2 and reported here — but the self-contained approach keeps the build (`--warnings-as-errors` + Dialyzer + set-theoretic checker) simplest and dependency-free.
- **File access design** follows the reference app (`fileService.ts` → `POST /api/open-file` → "open in IDE") but is implemented idiomatically for this stack as a typed `RepoBuilder.Editor` context invoked from a LiveView `open_file` event — no new HTTP route, and the editor command is config-driven (never derived from user/tool input) so it cannot become a command-injection sink. The app already shells out safely via `System.cmd`/muontrap/erlexec, so this is consistent with existing practice.
- **Security**: `Editor.open/1` only ever passes a validated, existing, absolute file path as a single argv to a fixed editor command — no shell interpolation. Disabled by default in `config/test.exs` so CI never launches an editor.
- **Single-source-of-truth**: all rendering data flows through `EventPresenter` so the live `record_event` path and the `log_to_row` backfill path stay identical — the same invariant already used for `context_size/1` and the counter derivation. The `file_change` extraction also fixes the latent `from_payload(:tool_call, …)` raw-frame bug as a side benefit.
- **Backfill raw-frame shapes** (confirmed from harness adapters): Claude raw frames have the tool `name`/`input` nested inside `payload["message"]["content"]` as a `%{"type" => "tool_use", "name" => ..., "input" => ...}` block (`claude.ex:assistant_block/2`, line ~314). Pi raw frames (`"type" => "tool_execution_start"`) have `toolName` and `args` at the top level (`pi.ex:normalize/2`, line ~265) — `from_payload` currently reads top-level `"name"` which matches pi (after normalizer coerces) but not Claude. The fix must: (1) try top-level `"name"`/`"input"` (matches normalized/fake/pi rows), then (2) fall through to digging `message → content → first tool_use block` (matches Claude raw frames).
- **Pi tool names**: pi worker agents use pi's built-in coding tools (`read`, `write`, `edit`, `bash` — per `--no-builtin-tools` disabling these for the orchestrator only). The actual string names surfaced in `Event.ToolCall.name` for pi workers are `"write"` and `"edit"` (same strings as Claude) based on the harness doc. The spec says `create_file`/`edit_file` as a reference app artifact; confirm actual pi tool names via Tidewave `project_eval` in Task 1 before implementing the name-match list.
- **CSS tokens** (confirmed from `assets/css/app.css`): `--cns-success: #10b981` (green), `--cns-error: #ef4444` (red), `--cns-warning: #f59e0b` (amber), `--cns-text-2: #9ca3af` (gray/context), `--cns-bg-2: #2a2a2a` (diff-line background tint). Use these directly; do not introduce new hex literals.
- **Validation via Tidewave**: use `project_eval` to confirm `EventPresenter.from_payload(:tool_call, payload)` against the real persisted payloads of log-9729/9766/9781, and (optionally) Tidewave Web vision mode for a screenshot of an expanded diff card at `http://localhost:4000`.
- **Reference coloring** (`FileChangesDisplay.vue`): added `#4ade80`/green bg `rgba(16,185,129,.2)`, removed `#fca5a5`/red bg `rgba(239,68,68,.2)`, context muted gray, status badges green/amber/red — map these onto the existing `cns-*` token palette (above).
