# Feature: Polished structured event-stream rendering

## Metadata
issue_number: `the`
adw_id: `orchestration`
issue_json: `console`

## Feature Description
The center EVENT STREAM of the orchestration console currently renders every
agent/orchestrator event as a single flat line whose body is a raw
`inspect/1` dump of the canonical event's Elixir map (e.g.
`tool_result %{"isError" ⇒ false, "result" ⇒ %{"content" ⇒ [%{"text" ⇒ "{\"id\":\"…`).
The reference UI that inspired this project renders the same underlying events as
**polished, structured cards**: a per-event category badge (TOOL / THINKING /
HOOK / RESPONSE), a colored agent-name pill, a human-readable summary line
(`Using tool: Bash`, `Tool result: Read`), a clean preview of the actual content
(not the wire JSON), an expandable "Show More" affordance, and — for response
events that report file activity — a **"Consumed N files"** card listing each
file with its read/write byte count.

This feature replaces the raw-map body with a typed, per-event-type **presenter**
layer plus richer function components, so the live stream and the reconnect
backfill both render the polished card layout. It is a pure
observability/presentation change: no new persisted data, no harness/adapter
changes, no DB migration. All structured data needed already rides on the
canonical `Event` structs (`%Event.ToolCall{name, input}`,
`%Event.ToolResult{is_error, content}`, `%Event.Status{kind, detail}`,
`%Event.TextDelta{text, thinking?}`, `%Event.Usage{...}`) and on the persisted
`agent_logs.payload`.

## User Story
As an operator watching multiple AI agents orchestrate in real time
I want the console event stream to render each event as a clean, structured card
(readable tool summaries, content previews, consumed-file lists, expandable detail)
So that I can follow what every agent is doing at a glance instead of parsing raw
Elixir map dumps.

## Problem Statement
The event stream is functionally complete but visually raw. Every non-text event
body is produced by interpolating `inspect/1` over the event payload
(`console_live.ex:1872`, `:1887`, `:1922`; `log_body/1` at `:3091`). The result is:

- **Unreadable tool calls/results** — nested wire JSON (`%{"isError" ⇒ false, …}`)
  dominates the row; the operator cannot tell at a glance which tool ran or whether
  it succeeded.
- **No content preview** — a tool result's actual text/output is buried inside the
  inspected `content` term, often escaped twice.
- **No file-activity surfacing** — the reference shows a "Consumed N files" card
  with per-file byte counts; ours has nothing equivalent.
- **Weak category affordances** — there is a category badge, but error/success
  state, tool identity, and thinking are not visually distinguished within a card.

The data to fix all of this is already present on the canonical `Event` structs
and the persisted `payload`; only the **presentation** maps it through `inspect/1`.

## Solution Statement
Introduce a typed **presenter** module, `RepoBuilder.Console.EventPresenter`, that
turns a canonical event (live path) or a persisted `AgentLog`/row payload
(backfill path) into a small, explicit **render model**:

```elixir
@type render_model :: %{
  summary: String.t(),            # "Using tool: Bash", "Tool result: Read", "in=… out=…"
  preview: String.t() | nil,      # clean, de-JSON'd content preview (nil ⇒ no preview block)
  detail: String.t() | nil,       # full pretty body behind "Show More"
  tool_name: String.t() | nil,    # drives the tool pill
  error?: boolean(),              # tool_result error state ⇒ red accent
  files: [file_activity()]        # consumed/written files ⇒ "Consumed N files" card
}
```

The presenter is the single source of truth shared by the live `record_event`
path and the `log_to_row` backfill path, so both render identically (mirroring how
`Logs.context_size/1` and the counter derivation are already shared across live and
backfill). The `event_row/1` component is upgraded to render the structured card
(summary line, optional tool pill, optional preview block, optional consumed-files
card, expandable full detail) while keeping the existing select/log-number/agent/
meta scaffolding, CSS tokens, and `phx-click="toggle_event"` expand behavior intact.

No persisted shape changes: the presenter reads `Event` structs live and the same
`payload` map on backfill, so historical rows render with the new polish too. The
`payload_json` already carried on each row remains the "Show More" full detail.

## Relevant Files
Use these files to implement the feature:

- `lib/repo_builder_web/live/console_live.ex` — owns the live event handlers
  (`handle_info({:agent_event, …})` at `:1864`–`:1965`) that today build `body:`
  via `inspect/1`, the `record_event/4` row builder (`:2103`), the `log_to_row/4` +
  `log_body/1` backfill path (`:3055`, `:3089`), and the stream template that calls
  `<.event_row>` (`:2627`). All three call sites must route through the new presenter
  and pass the richer render model to the component.
- `lib/repo_builder_web/components/console_components.ex` — owns `event_row/1`
  (`:486`) and `category_label/1` (`:3053`). The card layout, tool pill, preview
  block, and consumed-files sub-card live here as typed function components.
- `lib/repo_builder/harness/event.ex` — the canonical `Event` structs the presenter
  pattern-matches on (`ToolCall`, `ToolResult`, `Status`, `TextDelta`, `Usage`,
  `Done`, `Error`). Read-only; defines the structured fields we surface.
- `lib/repo_builder/logs.ex` — `AgentLog` shape + `event_payload/2` (the persisted
  `payload` the backfill presenter reads; note `TextDelta` persists
  `%{"text" => …, "thinking" => …}`, tool events persist the scrubbed `raw`).
- `assets/css/app.css` (or wherever `cns-event-row`, `cns-cat`, `cns-bubble--tool`
  tokens are defined — grep `cns-event-row` to locate) — add the card/pill/preview/
  consumed-files style tokens, reusing existing `--cns-*` color variables and the
  `cns-cat--{category}` palette so the new card matches the established theme.
- `AGENTS.md` — Phoenix 1.8 + LiveView component conventions (typed `attr`,
  `Phoenix.LiveView.Rendered.t()` specs, no raw `Repo` in the web layer).
- `BUILD_PROMPT.md` §9 — the LiveView dashboard contract (streams, reconnect
  backfill rule, chat-vs-events separation) the change must preserve.
- `ai_docs/typed-elixir-standard.md` — the enforced typed standard (`@spec` on every
  public function, `@type` for the render model, precise unions, `typedstruct`).

### New Files
- `lib/repo_builder/console/event_presenter.ex` — `RepoBuilder.Console.EventPresenter`:
  the typed presenter mapping `Event.t()` (live) and persisted `payload`/`AgentLog`
  (backfill) to the `render_model`. Pure, no `Repo`, fully `@spec`'d. Home of the
  `summary`, `preview`, `detail`, `tool_name`, `error?`, and `files` derivation,
  including the byte-count extraction for the consumed-files card.
- `test/repo_builder/console/event_presenter_test.exs` — unit tests for the presenter
  across every event variant and edge case (missing fields, non-binary content,
  empty input, error results, file-activity extraction, thinking flag).
- `test/repo_builder_web/live/test_polished_event_stream_test.exs` — a
  `Phoenix.LiveViewTest` integration test that mounts ConsoleLive, drives a tool
  call + tool result + response-with-files through the live event path (PubSub
  broadcast), and asserts the rendered stream shows the structured card
  (`Using tool: …`, tool pill, preview, "Consumed N files") rather than a raw
  `inspect` dump — and that expanding a row reveals the full detail.

## Implementation Plan
### Phase 1: Foundation — the typed presenter
Build `RepoBuilder.Console.EventPresenter` as a pure module with an explicit
`@type render_model` and `@type file_activity`. Add one `@spec`'d entry point per
input source: `from_event/1` (a canonical `Event.t()`) and `from_payload/2`
(`event_type` atom + persisted `payload` map, for backfill). Both converge on the
same private builders so live and backfill produce identical render models. Cover
every `Event` variant with a dedicated clause; derive `summary`, `preview`,
`detail`, `tool_name`, `error?`, and `files`. Keep all JSON/term flattening here
(never in the component) and never `String.to_atom/1` untrusted payload keys.

### Phase 2: Core Implementation — the card component
Upgrade `event_row/1` in `console_components.ex` to accept the render model fields
as typed `attr`s (`summary`, `preview`, `detail`, `tool_name`, `error?`, `files`)
alongside the existing scaffolding attrs. Render: the category badge + agent pill
(unchanged), a readable summary line, an optional tool-name pill, an optional
preview block (clamped height), an optional **consumed-files** sub-card
(`Consumed N files` + per-file rows with byte counts), and the expandable full
`detail` behind the existing `toggle_event`/`expanded?` mechanism. Add a
`consumed_files/1` sub-component and any `category_label`/badge helpers. Add CSS
tokens reusing the existing `--cns-*` palette.

### Phase 3: Integration — wire live + backfill paths
Route the four tool/usage/status/done/error `handle_info` clauses and the
`log_to_row/4` backfill through the presenter: replace the `body: "#{…} #{inspect …}"`
construction with a `render_model` carried on the row map (keep `body` as the
plain-text `summary` for search/copy/`selected_copy_payload` compatibility). Pass
the render-model fields from the row into `<.event_row>` in the template. Preserve
all existing behavior: category filtering, search (`passes?`), selection/copy,
thinking routing, chat separation (`orchestrator_event?/1`), `payload_json` as the
"Show More" detail, and the reconnect backfill ordering.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Read the standards and confirm the data contract
- Read `ai_docs/typed-elixir-standard.md`, `BUILD_PROMPT.md` §9, and `AGENTS.md`.
- Re-read `lib/repo_builder/harness/event.ex` and `lib/repo_builder/logs.ex`
  `event_payload/2` to confirm exactly which fields each event variant carries live
  vs. what is persisted (notably: `ToolResult.content` is `term()`; tool events
  persist scrubbed `raw`; `TextDelta` persists `%{"text", "thinking"}`).
- Use Tidewave `get_source_location` / `project_eval` to inspect a real
  `%Event.ToolResult{}` and a real persisted `agent_logs.payload` for a `tool_result`
  row, so the `preview`/`files` extraction matches reality rather than assumptions.

### 2. Create the presenter module (`event_presenter.ex`)
- Define `RepoBuilder.Console.EventPresenter` with:
  - `@type file_activity :: %{path: String.t(), action: :read | :write | :edit, bytes: non_neg_integer() | nil}`
  - `@type render_model :: %{summary: String.t(), preview: String.t() | nil,
    detail: String.t() | nil, tool_name: String.t() | nil, error?: boolean(),
    files: [file_activity()]}`
- `@spec from_event(RepoBuilder.Harness.Event.t()) :: render_model()` with one clause
  per variant:
  - `ToolCall` → summary `"Using tool: <name>"`, `tool_name`, preview = compact
    one-line view of key inputs (e.g. command/file_path), detail = pretty input.
  - `ToolResult` → summary `"Tool result: <tool_name-if-known-else 'result'>"`,
    `error?: is_error`, preview = the flattened text content (de-nested from
    `content`), files extracted when the result reports file activity.
  - `TextDelta` → summary = first line of text, preview = text, `thinking?`-aware.
  - `Usage` → summary `"in=<in> out=<out>"`, no preview.
  - `Status` → summary `"<kind>"`, preview = compact `detail`.
  - `Done`/`Error` → summary `"reason=<…>"` / `"<reason>: <message>"`,
    `error?: true` for `Error`.
- `@spec from_payload(atom(), map()) :: render_model()` mirroring the above off the
  persisted `payload` shape so backfill renders identically. Reuse private builders.
- Add private `@spec`'d helpers: `flatten_content/1` (term → readable string, handles
  nested `%{"content" => [%{"text" => …}]}` claude/pi shapes and stringly JSON),
  `extract_files/1` (returns `[file_activity()]`, parsing read/write byte counts when
  present), `compact_inputs/1`. Never raise; degrade to `nil`/`[]` on unexpected shapes.
- Honor the typed standard: `@spec` on every public fn, precise unions, no `map()`
  where a shape is known, `String.to_existing_atom/1` (or a fixed lookup map) for any
  action keys — never `String.to_atom/1` on payload data.

### 3. Unit-test the presenter (`event_presenter_test.exs`)
- One test per `Event` variant via `from_event/1` and the matching `from_payload/2`,
  asserting `summary`/`preview`/`error?`/`tool_name`/`files`.
- Edge cases (see Testing Strategy). Assert live and backfill paths produce equal
  render models for the same logical event (regression guard against drift).

### 4. Upgrade the `event_row/1` component + add `consumed_files/1`
- Add typed `attr`s: `summary` (string, required), `preview` (string, default nil),
  `detail` (string, default nil), `tool_name` (string, default nil), `error?`
  (boolean, default false), `files` (list, default []). Keep existing attrs.
- Render the structured card: summary line, optional tool pill (`tool_name`),
  optional preview block, `consumed_files/1` sub-card when `files != []`, and the
  expandable `detail` behind the existing `expanded?`/`toggle_event` mechanism.
  Apply an error accent when `error?`.
- Add `@spec consumed_files(map()) :: Phoenix.LiveView.Rendered.t()` rendering the
  "Consumed N files" header + per-file rows (path + byte count), styled like the
  reference card.
- Keep `body`-based search/copy working: the row still carries plain-text `body`
  (= `summary` + preview) for `selected_copy_payload`/`passes?`.

### 5. Wire the live event handlers through the presenter
- In `console_live.ex` `handle_info({:agent_event, agent_id, %Event.X{}…})` for
  `ToolCall`, `ToolResult`, `Usage`, `Status`, `Done`, `Error`: replace the
  `body: "… #{inspect …}"` with `render: EventPresenter.from_event(event)` (and keep
  a derived `body: render.summary <> preview` string for search/copy).
- Update `record_event/4` to store the render model on the row map (add a `render`
  key; keep `body`, `payload_json`, etc.). Preserve `bump_counter`, thinking
  routing, and `maybe_chat`.

### 6. Wire the backfill path through the presenter
- Replace `log_body/1` (`:3089`) usage so `log_to_row/4` builds the row's `render`
  via `EventPresenter.from_payload(log.event_type, log.payload)`; keep the
  text-delta fast path (`%{"text" => text}` → response body) consistent with the
  presenter's `TextDelta` output.
- Confirm `chat_for_row/1` still routes finalized orchestrator text to chat (use
  `render.summary`/`body` as the content source).

### 7. Update the stream template to pass render-model fields
- In the `<.event_row>` call (`:2627`), pass `summary`, `preview`, `detail`,
  `tool_name`, `error?`, and `files` from `row.render` (with safe defaults).
- Keep `expanded?`/`selected?`/`log_no`/`agent`/`color`/`time` wiring unchanged.

### 8. Add CSS tokens
- Grep `cns-event-row` / `cns-cat--` to find the stylesheet. Add `.cns-event-card`,
  `.cns-event-card__summary`, `.cns-tool-pill`, `.cns-event-preview`,
  `.cns-consumed`, `.cns-consumed__file`, and an `--error` accent, reusing the
  existing `--cns-*` variables and the `cns-cat--{category}` palette so the card
  matches the theme. Do not validate CSS via `browser_eval` (style-only).

### 9. Write the LiveView integration test
- Create `test/repo_builder_web/live/test_polished_event_stream_test.exs` using
  `Phoenix.LiveViewTest`: `live/2` the console, broadcast (or call the same
  PubSub seam the runtime uses) a `%Event.ToolCall{name: "Bash", …}`, a
  `%Event.ToolResult{is_error: false, content: …with file activity…}`, and a
  response, then assert the rendered HTML contains `Using tool: Bash`, the tool
  pill, the content preview, and `Consumed` (files card) — and assert it does **not**
  contain a raw `%{"isError"` inspect dump. Drive `toggle_event` and assert the full
  detail appears. Reuse existing console test setup/helpers (grep an existing
  `test/repo_builder_web/live/*console*` test for the mount/agent-seed pattern).

### 10. Manual runtime check via Tidewave (optional but recommended)
- With the app running, use Tidewave `get_logs` to confirm no render errors, and
  optionally capture a screenshot of `http://localhost:4000` (Tidewave Web vision
  mode, else Playwright) showing the polished stream for visual parity with the
  reference.

### 11. Run the full validation suite
- Run every command in **Validation Commands** and fix any failure until all are
  green with zero regressions.

## Testing Strategy
### Unit Tests
- `EventPresenter.from_event/1` for each variant: `ToolCall`, `ToolResult` (success
  and error), `TextDelta` (response and thinking), `Usage`, `Status`, `Done`,
  `Error` — assert `summary`, `preview`, `tool_name`, `error?`, `files`.
- `EventPresenter.from_payload/2` parity: for each variant, the persisted payload
  shape produces an equal (or intentionally-degraded) render model vs. the live
  event — guarding against live/backfill drift.
- `flatten_content/1`: claude shape `%{"content" => [%{"text" => "x"}]}`, pi shape,
  bare string, stringly-JSON, and a non-string/non-map term all flatten without
  raising.
- `extract_files/1`: a result reporting N files yields N `file_activity` entries with
  correct byte counts; a result with no file activity yields `[]`.

### Edge Cases
- `ToolResult.content` that is `nil`, an integer, or a deeply nested map → `preview`
  is `nil` or a safe truncated string; never a crash.
- Empty `ToolCall.input` (`%{}`) → preview `nil`, summary still `"Using tool: <name>"`.
- Missing/blank `tool_name` on a result → summary falls back to `"Tool result"`,
  no tool pill rendered.
- Persisted `payload` missing expected keys (older rows) → presenter degrades to a
  minimal render model, never raises (backfill must not crash the mount).
- A `TextDelta` with `thinking? == true` still routes to the thinking lane and is not
  duplicated into chat (existing behavior preserved).
- Very large preview/detail → clamped/truncated for the row; full detail available on
  expand. Worker-report full-fidelity (the 10 KB spill concern in
  `worker_report_full_fidelity_test.exs`) is unaffected — this change is render-only
  and must not touch the persisted `payload`.

## Acceptance Criteria
- Tool-call rows render `Using tool: <name>` with a tool pill instead of
  `name %{"…" ⇒ …}`.
- Tool-result rows render `Tool result: <name>` with a clean content preview (no
  double-escaped wire JSON) and a red accent when `is_error`.
- Response events that report file activity render a "Consumed N files" card listing
  each file path and byte count.
- Expanding a row (existing click) reveals the full pretty detail; collapsed rows show
  the structured summary/preview.
- Live path and reconnect backfill render identically (same presenter).
- No raw `inspect/1` Elixir-map dump appears in the default (collapsed) row body for
  tool/result/status/usage events.
- Search, selection, copy, category filtering, thinking routing, chat separation, and
  cost/counter accumulation all continue to work unchanged.
- No DB migration, no persisted-shape change; historical rows render with the new polish.
- All five validation commands pass with zero failures/warnings.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix test test/repo_builder/console/event_presenter_test.exs` — the presenter unit
  suite passes (all variants + edge cases).
- `mix test test/repo_builder_web/live/test_polished_event_stream_test.exs` — the
  LiveView integration test passes (structured card rendered, no raw inspect dump,
  expand reveals detail).
- `mix compile --warnings-as-errors` — compile clean; gradual set-theoretic checker
  and `warnings_as_errors` pass.
- `mix test --warnings-as-errors` — full ExUnit suite green (no regressions in the
  existing console/logs/worker-report suites).
- `mix format --check-formatted` — formatted.
- `mix credo --strict` — lint clean, including the "@spec on every public function"
  gate (the new presenter and components must each carry specs).
- `mix dialyzer` — no new contract warnings; the `render_model`/`file_activity` types
  check against the component attrs and call sites.

## Notes
- **No new dependencies.** Everything is derivable from existing `Event` structs,
  the persisted `payload`, and existing CSS tokens. Do not add a Markdown/HTML
  sanitizer — previews are plain text (escaped by HEEx), so no new attack surface.
- **Render-only, persistence-untouched.** This deliberately does NOT alter
  `Logs.event_payload/2` or any persisted shape; the worker-report full-fidelity
  spill path (`Orchestrator.Tools.spill_report/4`) and its tests must remain green.
  The "Consumed files" data is *derived at render time* from the result content, not
  newly persisted.
- **Single source of truth.** `EventPresenter` is shared by live and backfill exactly
  as `Logs.context_size/1` and the counter derivation already are — this is the
  established pattern for keeping the two paths from drifting.
- **Future extension.** The `file_activity` action union (`:read | :write | :edit`)
  and the render model leave room for later affordances (diff peek, click-to-open)
  without reworking the presenter contract. A harness adding a novel tool-result
  shape only needs a new `flatten_content/1`/`extract_files/1` clause, not a
  component change.
- **Verification via Tidewave.** Prefer `get_source_location`/`project_eval` to
  confirm the exact live `%Event.ToolResult{}` content shape and a real persisted
  `agent_logs.payload` before finalizing `flatten_content/1`/`extract_files/1`, and
  `get_logs` to confirm no render errors after wiring.
