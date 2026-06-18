# Feature: Ephemeral "Explain logs" with the Fast agent

## Metadata
issue_number: `Explain logs`
adw_id: `action:select`
issue_json: `select`

## Feature Description
Add an ephemeral, on-demand log-explanation action to the orchestration console
(`/`). An operator ticks a checkbox on one or more center event-stream rows
(`#ev-row-<n>`), presses an **EXPLAIN** button, and a specialized *Fast* agent —
the `fast` tier of the per-category agent-models roster configured behind the
header's `#agent-models-toggle` ("Agents…") — produces a single paragraph that
explains, in enough technical detail for an engineer to troubleshoot, what the
selected log line(s) mean.

The explanation is rendered in a transient modal that can be copied to the
clipboard and dismissed. It is **never persisted**: no `agent_logs` row, no
durable agent, no global console feed pollution, no DB write. Closing the modal
discards it entirely. This is purely a read-time troubleshooting aid layered on
top of the existing canonical event stream — raw logs are often cryptic
(`tool=... input=...`, `reason=error_during_execution`, exit codes), and a
one-paragraph natural-language gloss makes them legible without leaving the
console.

## User Story
As an operator triaging a stuck or failed agent run in the orchestration console
I want to select one or more confusing log/event rows and ask a fast model to explain them in plain English
So that I can understand what happened and troubleshoot quickly, without copy-pasting logs into a separate chat or reading raw harness output line by line.

## Problem Statement
The console center stream renders canonical harness events verbatim
(`console_components.ex:451` `event_row`): tool calls with `inspect(input)`,
usage counters, hook details, error `reason=`/`message=` payloads, raw provider
text. For an engineer mid-incident these are dense and often opaque, and there is
no in-product way to get a quick, contextual interpretation. Reading logs
"sometimes does not make sense," and the alternative — pasting them elsewhere —
breaks flow and loses the surrounding context the console already holds.

### Design note: selection is a reusable primitive
The per-row checkbox is **not** Explain-specific. It introduces a general
multi-select over the event stream that a **selection action bar** acts on.
EXPLAIN is the first action; the same `selected_ids` set will also drive (future,
but designed-for now) **HIDE** (make the selected rows invisible in the view) and
**COPY** (copy the selected rows' raw log message(s) to the clipboard). Build the
selection mechanism, the `selected_ids` assign, the checkbox, and the action bar
as a generic, extensible seam — adding a new bulk action should mean adding one
button + one handler, not reworking selection. Explain is the only action wired
end-to-end in this feature; HIDE and COPY are stubbed/scaffolded per the
extensibility tasks below.

## Solution Statement
1. Make event rows **selectable** via a checkbox; track the selection in a
   transient `selected_ids` assign in `ConsoleLive`. This is a reusable
   multi-select primitive (see design note above), not bound to Explain.
2. Add a **selection action bar** (shown when ≥1 row is selected) hosting bulk
   actions over the selection. Wire the **EXPLAIN** action end-to-end: it gathers
   the selected rows' full bodies from the in-assign `event_buffer`, builds a
   troubleshooting prompt, and dispatches a **one-shot, ephemeral** harness
   invocation using the `fast` roster entry
   (`Orchestrators.agent_models(orchestrator)["fast"]` → harness/provider/model).
   Scaffold **HIDE** (soft-hide selected rows from the view) and **COPY** (copy
   selected raw bodies to the clipboard) as sibling actions over the same
   selection so they slot in without reworking the primitive.
3. Run the invocation through the **existing harness session runtime**
   (`Session.Supervisor.start_session/1`) so it stays harness-agnostic
   (Claude / pi / Fake), but with a new additive `:broadcast_feed?` opt set to
   `false` and **no** `agent_db_id`/`orchestrator_db_id` — so the run neither
   persists to `agent_logs` nor pollutes the global console feed/swimlanes. A
   lightweight `RepoBuilder.Explain.Server` subscribes to the run's private
   per-agent topic, accumulates the finalized assistant text / `Done.final_text`,
   and messages the result back to the requesting LiveView.
4. Render the result in a transient `explain_modal` (spinner while running, the
   paragraph when ready, an error if the run failed or no Fast agent is
   configured), with a **Copy** button (reusing the existing `ClipboardCopy`
   hook) and a **Close** button that discards the assign.

This reuses every existing seam — the agent-models roster, the session runtime,
the modal show/hide JS pattern, and the clipboard hook — and adds exactly one
small, default-preserving knob to the session runtime.

## Relevant Files
Use these files to implement the feature:

- `BUILD_PROMPT.md` — Authoritative architecture: typed style guide §3 (every
  public fn `@spec`, `typedstruct`/`@enforce_keys`, `{:ok,_}|{:error,_}` over
  raising), harness event contract §4, session runtime §6, persistence §8
  (DB only behind `@spec`'d contexts), LiveView dashboard §9, extensibility §10.
- `lib/repo_builder/orchestrator.ex` — `Orchestrators` context. `@agent_categories
  ~w(fast main heavy leader)` (line 22), `agent_models/1` (line 217) returns
  `%{category => %{"harness"/"provider"/"model"}}`. Source of the **Fast** tier
  config that drives the explanation. May add a small read helper here.
- `lib/repo_builder_web/live/console_live.ex` — The console LiveView. Holds
  `event_buffer` (full, untruncated row bodies — `record_event/4` line 1584,
  `log_to_row` backfill line 452), the modal render block (`agent_models_modal`
  call ~line 2139), the event-stream render (`event_row` call line 1985), filter
  bar render (~1969), `toggle_event` handler (line 1025), and mount assigns
  (line 138+). New assigns + handlers + modal wiring land here.
- `lib/repo_builder_web/components/console_components.ex` — Typed function
  components. `event_row/1` (line 451, add an action-agnostic checkbox +
  `selected?`), `filter_bar/1` (line ~360) plus a new `selection_bar/1` hosting
  the bulk actions (EXPLAIN now; HIDE/COPY scaffolded), the modal show/hide JS
  helpers (`show_agent_models`/`hide_agent_models` lines 838-842 — model the
  `show_explain`/`hide_explain` pair on these), and the new `explain_modal/1`
  component (model on `agent_models_modal/1` line 1696 / `settings_modal/1`).
- `lib/repo_builder/session/server.ex` — Session runtime. `dispatch/2` (line 413)
  is the single place that persists (gated on `agent_db_id`/`orchestrator_db_id`,
  lines 419-434) and broadcasts to the global feed + swimlanes (lines 441-442).
  Add a `:broadcast_feed?` opt (default `true`) read in `init` and honored in
  `dispatch/2` to gate those two broadcasts only.
- `lib/repo_builder/session/supervisor.ex` — `start_session/1` (line 23). The
  ephemeral runner starts the harness session here; opts flow straight through to
  `Session.Server`.
- `lib/repo_builder/harness/event.ex` — Canonical events. `TextDelta`
  (`partial?` gate, lines 54-67) and `Done` (`final_text`, line 153) are what the
  ephemeral runner accumulates to produce the paragraph.
- `lib/repo_builder/orchestrator/server.ex` — `Orchestrator.Server` (line 199
  `start_session`, line 228 `Done` handling). The closest existing model for a
  session-driving GenServer; `Explain.Server` mirrors its launch + event loop but
  captures text and replies to a caller instead of persisting/cost-tracking.
- `lib/repo_builder/dashboard.ex` — `broadcast_event/3` (line 79) /
  `subscribe_events/0` (line 64); confirms what `:broadcast_feed?: false`
  suppresses (the global feed the console subscribes to).
- `assets/js/app.js` — `ClipboardCopy` hook (line 56, copies `data-copy` text).
  Reused verbatim by the modal's Copy button — no JS change expected.
- `.claude/commands/conditional_docs.md` — Read to confirm whether any extra docs
  apply (LiveView/typed-Elixir). Pull in any matching docs.

### New Files
- `lib/repo_builder/explain.ex` — `RepoBuilder.Explain` context: resolves the
  Fast tier config, validates it, builds the troubleshooting prompt from selected
  rows, and starts the ephemeral runner. Public, fully `@spec`'d. No `Repo`
  access (pure + delegates to `Orchestrators` and the runner).
- `lib/repo_builder/explain/server.ex` — `RepoBuilder.Explain.Server`: a
  transient `Task`/`GenServer` (started under a `Task.Supervisor` or a
  `DynamicSupervisor`) that runs one ephemeral harness session, subscribes to its
  private per-agent topic, accumulates finalized text + `Done.final_text`, and
  sends `{:explain_result, request_id, {:ok, String.t()} | {:error, term()}}` to
  the requesting LiveView pid. Never writes the DB.
- `lib/repo_builder/explain/request.ex` — `typedstruct` for the explain request
  (`request_id`, `rows`/serialized prompt, `harness`, `provider`, `model`,
  `reply_to` pid). `@enforce_keys` on all required fields.
- `test/repo_builder_web/live/test_explain_logs_test.exs` — `Phoenix.LiveViewTest`
  integration test driving select → EXPLAIN → modal result (Fast tier = Fake
  harness for determinism).
- `test/repo_builder/explain_test.exs` — Unit tests for the context: prompt
  building from rows, Fast-tier resolution, and the `{:error, :no_fast_agent}`
  path when the roster has no `fast` model.

## Implementation Plan
### Phase 1: Foundation
Make the session runtime ephemeral-capable and stand up the explain
domain logic, decoupled from the UI.

- Add a `:broadcast_feed?` opt (default `true`) to `Session.Server` so an
  ephemeral run can suppress the global feed + swimlane broadcasts while keeping
  the private per-agent topic (which the runner subscribes to). Default value
  preserves all current behavior for workers and the orchestrator.
- Build `RepoBuilder.Explain` (+ `Request` struct + `Explain.Server`) to resolve
  the Fast tier, format the prompt, and run the one-shot ephemeral session,
  replying to the caller — all without touching `Repo` or persisting events.
- Register the runner's supervisor in the app supervision tree (§5).

### Phase 2: Core Implementation
Wire selection + the explain trigger + the result modal into `ConsoleLive`
and the typed components.

- Add a selection checkbox to `event_row` and `selected_ids` tracking + the
  `toggle_select`/`clear_selection` handlers in `ConsoleLive`.
- Add the EXPLAIN button to `filter_bar` and the `explain_selected` handler that
  gathers selected rows, resolves the Fast tier, starts `Explain.Server`, and
  flips the modal to its running state.
- Add the `explain_modal` component + `show_explain`/`hide_explain` JS helpers,
  the `{:explain_result, ...}` `handle_info`, and the `close_explain` handler.

### Phase 3: Integration
- Handle the no-Fast-agent and run-failure cases gracefully in the modal
  (actionable message pointing at "Agents…").
- Ensure selection clears on Clear/disconnect/reconnect and that the modal is
  fully ephemeral (nothing survives close or a `backfill_events` re-stream).
- Verify end-to-end against a Fake Fast agent in tests, then validate the suite,
  formatter, Credo, and Dialyzer are green.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Confirm docs + conventions
- Read `.claude/commands/conditional_docs.md`; if any LiveView / typed-Elixir doc
  matches, read it and add it to this plan's Relevant Files mentally before
  coding. Re-read `BUILD_PROMPT.md` §3, §4, §6, §9 to stay aligned with the typed
  style and the canonical event contract.
- Use Tidewave `get_source_location`/`get_docs` to confirm exact signatures of
  `Session.Supervisor.start_session/1`, `Orchestrators.agent_models/1`, and the
  `Event.TextDelta`/`Event.Done` fields before depending on them.

### 2. Add the ephemeral broadcast gate to the session runtime
- In `lib/repo_builder/session/server.ex`, add `broadcast_feed?: opts[:broadcast_feed?] != false`
  (default `true`) to the session `State` (typedstruct field, with `@spec`'d
  default behavior preserved) in `init`.
- In `dispatch/2` (line ~441), wrap the `Dashboard.broadcast_event(...)` and
  `maybe_broadcast_lane(...)` calls so they only fire when
  `state.broadcast_feed?` is `true`. The per-agent topic broadcast
  (`agent:#{agent_id}:events`, line 438) **stays unconditional** so the runner can
  still observe its own run. Persistence is already gated on
  `agent_db_id`/`orchestrator_db_id`, so passing neither already prevents DB
  writes — no change needed there; add a comment noting the ephemeral contract.
- This is the only change to the session runtime and is default-preserving.

### 3. Define the explain request struct
- Create `lib/repo_builder/explain/request.ex` with a `typedstruct`
  (`use TypedStruct`) carrying `@enforce_keys` for: `request_id :: String.t()`,
  `prompt :: String.t()`, `harness :: String.t()`, `model :: String.t()`,
  `reply_to :: pid()`, and optional `provider :: String.t() | nil`. Add precise
  `@type`s — no bare `map()`.

### 4. Build the Explain context
- Create `lib/repo_builder/explain.ex` (`RepoBuilder.Explain`) with `@spec`'d
  public functions:
  - `fast_config/1` — `RepoBuilder.Orchestrator.Orchestrator.t() ->
    {:ok, %{harness: String.t(), provider: String.t() | nil, model: String.t()}}
    | {:error, :no_fast_agent}`. Reads `Orchestrators.agent_models/1`, pulls the
    `"fast"` entry, and returns `:no_fast_agent` when harness or model is blank.
  - `build_prompt/1` — takes the list of selected row maps (`%{log_no, line,
    category, kind, agent, body, time}`) and returns a single `String.t()`
    prompt: a short instruction ("You are explaining console/harness log output
    to a software engineer for troubleshooting. Explain what the following
    event(s) mean in ONE paragraph, with enough technical detail to act on. No
    preamble, no bullet lists.") followed by each event serialized as
    `log-<n> [<category>/<kind>] <agent> @ <time>\n<body>`. Use the **full**
    `body` from `event_buffer` (not the 160-char display truncation).
  - `explain/2` — `(orchestrator, rows) -> {:ok, request_id} | {:error,
    :no_fast_agent | term()}`. Resolves `fast_config/1`, builds the prompt,
    mints a `request_id`, and starts `Explain.Server` under its supervisor with a
    `Request`; returns the `request_id` so the LiveView can correlate the reply.
- No `Repo`/`Ecto.Query` here; delegate roster reads to `Orchestrators`.

### 5. Build the ephemeral runner
- Create `lib/repo_builder/explain/server.ex` (`RepoBuilder.Explain.Server`),
  started under a `Task.Supervisor` (or `DynamicSupervisor`) added to the app
  tree in `application.ex` (§5). It:
  - Generates a private ephemeral `agent_id` (e.g. `"explain-" <> request_id`) and
    `session_id`.
  - `Phoenix.PubSub.subscribe`s to `"agent:#{agent_id}:events"` BEFORE starting
    the session (avoid the race).
  - Calls `Session.Supervisor.start_session/1` with `agent_id`, `session_id`,
    `harness`, `model`, `provider`, `prompt`, `broadcast_feed?: false`, and
    **no** `agent_db_id`/`orchestrator_db_id` (ephemeral, no persistence, no feed).
    Run in a throwaway/isolated cwd (pass `cwd: nil` to get the session's own
    isolated scratch workspace, per `Session.Server` cwd resolution).
  - Accumulates finalized `Event.TextDelta` (`partial?: false`) text; on
    `Event.Done`, prefers `final_text` when present, else the accumulated text;
    sends `{:explain_result, request_id, {:ok, text}}` to `reply_to`. On
    `Event.Error` (or a timeout), sends `{:explain_result, request_id,
    {:error, reason}}`. Then stops. Heed the erlexec runtime gotchas
    (env-replace, no PATH search) — but since this reuses `Session.Supervisor`,
    those are already handled by the runtime.
  - Add a watchdog timeout (e.g. 60s) so a hung provider can't leak the run; on
    timeout, stop the session (`Session.Supervisor.stop_session/1`) and reply
    `{:error, :timeout}`.

### 6. Make event rows selectable (component) — reusable primitive
- In `console_components.ex` `event_row/1` (line 451), add `attr :selected?,
  :boolean, default: false`. Prepend a checkbox `<input type="checkbox">` (or a
  small toggle button) inside the row with its OWN `phx-click="toggle_select"
  phx-value-id={@id}` and `checked={@selected?}`. Because LiveView dispatches to
  the closest element carrying `phx-click`, the checkbox's handler fires WITHOUT
  also triggering the row's `toggle_event` expand — verify this and, if needed,
  stop propagation. Style consistent with the existing `cns-event-row` cells.
- Treat this as a **general multi-select**, not an Explain checkbox: `selected?`
  and `toggle_select` carry no action semantics. Any number of bulk actions
  (EXPLAIN now; HIDE/COPY next) read the same `selected_ids` set. Keep the row
  markup action-agnostic.

### 7. Track selection + EXPLAIN trigger in ConsoleLive
- Add `selected_ids: MapSet.new()` and `explain: %{status: :idle}` to the mount
  assigns (~line 138). Pass `selected?={MapSet.member?(@selected_ids, row.id)}`
  in the `event_row` call (~line 1985).
- Add handlers:
  - `handle_event("toggle_select", %{"id" => id}, socket)` — toggle membership in
    `selected_ids` (parse `id` to integer to match `row.id`).
  - `handle_event("clear_selection", _, socket)` — reset to `MapSet.new()`. Also
    clear `selected_ids` inside the existing `clear_filters`/clear handler and on
    `backfill_events` re-stream so stale selections don't linger.
  - `handle_event("explain_selected", _, socket)` — gather
    `Enum.filter(event_buffer, &(&1.id in selected_ids))` preserving order; if
    empty, no-op; resolve `Explain.explain(orchestrator, rows)`. On `{:ok,
    request_id}` set `explain: %{status: :running, request_id: request_id}` and
    push `show_explain()`. On `{:error, :no_fast_agent}` set `explain:
    %{status: {:error, "No Fast agent configured — pick a harness + model for the
    Fast tier under Agents…"}}` and show the modal.

### 8. Render the explain modal + JS helpers (component)
- Add `show_explain/1` and `hide_explain/1` JS helpers in `console_components.ex`
  modeled on `show_agent_models`/`hide_agent_models` (target `#explain-modal`,
  `display: "flex"`).
- Add an `explain_modal/1` typed component (`@spec explain_modal(map()) ::
  Phoenix.LiveView.Rendered.t()`): stays mounted, `hidden` by default, `id=
  "explain-modal"`. Renders by `@status`:
  - `:running` → a spinner + "Explaining N event(s)…".
  - `{:ready, text}` → the paragraph in a readable prose/`<pre class="whitespace-pre-wrap">`
    block, a **Copy** button (`phx-hook="ClipboardCopy" data-copy={text}`), and a
    **Close** button (`phx-click={JS.push("close_explain") |> hide_explain()}`).
  - `{:error, msg}` → the message + Close.
- Add the `<.explain_modal status={@explain.status} />` call alongside the other
  modals in the `ConsoleLive` render (~line 2139).

### 9. Handle the async result in ConsoleLive
- `handle_info({:explain_result, request_id, result}, socket)` — ignore if it
  doesn't match the current `explain.request_id` (a superseded request). On
  `{:ok, text}` set `explain: %{status: {:ready, text}, request_id: request_id}`.
  On `{:error, reason}` set `explain: %{status: {:error, humanize(reason)}}`.
- `handle_event("close_explain", _, socket)` — set `explain: %{status: :idle}`
  (discards the text; nothing persisted) and optionally `clear_selection`.

### 10. Add the selection action bar (extensible) + wire EXPLAIN
- Add a `selection_bar/1` typed component that renders only when
  `@selected_count > 0`: shows the count ("N selected"), a **Clear selection**
  button (`phx-click="clear_selection"`), and a row of bulk-action buttons. Place
  it in the logs view (e.g. just above `#event-stream` or in `filter_bar/1` via a
  new `attr :selected_count, :integer, default: 0`). Pass
  `selected_count={MapSet.size(@selected_ids)}`.
- Wire **EXPLAIN ✦** end-to-end: `phx-click="explain_selected"`, label with the
  count (e.g. `EXPLAIN (3)`), styled like `clear-workflows`.
- Scaffold the sibling actions over the SAME selection so they slot in later
  without reworking the primitive:
  - **HIDE** — `phx-click="hide_selected"`. Add a `handle_event("hide_selected",
    …)` that soft-hides the selected rows from the view (reuse the existing
    soft-hide / stream_delete + hidden-flag pattern the clear/CLEAR path uses
    around `console_live.ex:987`, scoped to `selected_ids` instead of all rows),
    then clears the selection. This is genuinely useful now (declutter noisy
    streams) and exercises the reusable seam.
  - **COPY** — `phx-click` driving a clipboard copy of the selected rows' raw
    bodies joined by newlines. Prefer the existing `ClipboardCopy` hook
    (`assets/js/app.js:56`): render the button with `data-copy={joined_bodies}`
    computed from `selected_ids` (recompute on selection change), so the copy is
    client-side with no round trip. If the payload must be assembled server-side,
    add a `copy_selected` handler that pushes the text to a `ClipboardCopy`-style
    hook via `push_event`.
- Keep each action to "one button + one handler" — the action bar must not bake
  in Explain-specific assumptions.

### 11. Create the LiveView integration test
- Create `test/repo_builder_web/live/test_explain_logs_test.exs` using
  `Phoenix.LiveViewTest`. Setup: an orchestrator whose `agent_models["fast"]`
  points at the **Fake** harness (deterministic) with a model; seed a couple of
  events into the stream (drive a Fake session or insert via the same path mount
  uses). Steps: `live/2` mount → `render_click(element/2 for a row checkbox)` to
  select ≥1 row → assert EXPLAIN enabled → `render_click("explain_selected")` →
  assert `#explain-modal` shows the running state, then (after the Fake run
  completes / via `assert_receive` or `render_async`) assert the paragraph text
  is rendered and the Copy button carries `data-copy`. Assert nothing was
  persisted (no new `agent_logs` row for the ephemeral agent — query via the
  `Logs` context or assert the global feed received no ephemeral event).
- Optionally capture a Tidewave Web vision / Playwright screenshot of
  `http://localhost:4000` showing the modal as visual proof.

### 12. Create the context unit tests
- Create `test/repo_builder/explain_test.exs`: assert `build_prompt/1` includes
  every selected row's full body + a single-paragraph instruction; assert
  `fast_config/1` returns the roster's fast entry and `{:error, :no_fast_agent}`
  when blank.

### 13. Validate
- Run every command in **Validation Commands** and fix any failure until all are
  green with zero regressions. Use Tidewave `get_logs` to inspect any runtime
  stacktrace and `project_eval` to sanity-check `Explain.fast_config/1` /
  `build_prompt/1` against the live orchestrator.

## Testing Strategy
### Unit Tests
- `Explain.build_prompt/1`: serializes all selected rows (full body, correct
  `log-<n>`/category/kind/agent/time), and the instruction asks for ONE paragraph
  with no bullets/preamble.
- `Explain.fast_config/1`: returns `{:ok, %{harness, provider, model}}` for a
  populated `fast` roster entry; `{:error, :no_fast_agent}` when harness or model
  is blank/missing.
- `Explain.Server`: given a Fake harness, accumulates finalized text and replies
  `{:explain_result, request_id, {:ok, text}}`; on a Fake error path replies
  `{:error, _}`; on watchdog timeout replies `{:error, :timeout}` and stops the
  session.
- `Session.Server`: with `broadcast_feed?: false` and no `agent_db_id`/
  `orchestrator_db_id`, a run does NOT call `Dashboard.broadcast_event` /
  `maybe_broadcast_lane` and writes no `agent_logs` row, but DOES broadcast to
  `agent:<id>:events`. Default (`broadcast_feed?` unset) is unchanged.

### Edge Cases
- EXPLAIN pressed with nothing selected → button disabled / no-op.
- No `fast` model configured → modal shows the actionable "configure under
  Agents…" error, no session started.
- Fast harness/provider invalid or run errors → modal shows the failure, nothing
  persisted, no leaked session.
- Provider hangs → 60s watchdog stops the session and reports `:timeout`.
- A second EXPLAIN issued while one is running → the stale `request_id` result is
  ignored; only the latest renders.
- Selection survives filtering but is cleared on CLEAR / disconnect-reconnect /
  `backfill_events` re-stream (no dangling ids referencing reset rows).
- Selected rows include large/multiline bodies (full body used, not the 160-char
  display truncation) — prompt still well-formed.
- Checkbox click does not also toggle the row's expand (`toggle_event`).
- Modal copy/close is fully ephemeral: closing discards the text; reconnecting
  does not resurrect it.

## Acceptance Criteria
- Each center event row shows an action-agnostic selection checkbox; ticking rows
  updates a visible selected count and reveals a selection action bar. The
  selection is a reusable primitive: EXPLAIN is wired end-to-end, and HIDE
  (soft-hide selected rows) + COPY (copy selected raw bodies) are present as
  sibling actions over the same `selected_ids` set, each "one button + one
  handler" with no Explain-specific coupling.
- Pressing EXPLAIN with ≥1 row selected opens a modal that, using the configured
  **Fast** roster agent, displays a single-paragraph, engineer-grade explanation
  of the selected log(s).
- The explanation can be copied to the clipboard and the modal dismissed; nothing
  is persisted (no `agent_logs` row, no global-feed event, no durable agent, no DB
  write), and it does not appear in the live console stream or swimlanes.
- With no Fast agent configured, the modal shows an actionable message and starts
  no run.
- The Fast tier used is exactly `Orchestrators.agent_models(orchestrator)["fast"]`
  (the entry configured behind the header `#agent-models-toggle`).
- The LiveViewTest drives select → EXPLAIN → result and passes.
- `mix compile --warnings-as-errors`, `mix test --warnings-as-errors`,
  `mix format --check-formatted`, `mix credo --strict`, and `mix dialyzer` are all
  green with no new warnings.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix test test/repo_builder/explain_test.exs` — Explain context unit tests pass.
- `mix test test/repo_builder_web/live/test_explain_logs_test.exs` — LiveView
  integration test (select → EXPLAIN → ephemeral Fast-agent result modal) passes.
- `mix compile --warnings-as-errors` — Clean compile; gradual set-theoretic type
  checker + `warnings_as_errors` pass.
- `mix test --warnings-as-errors` — Full ExUnit suite (Postgres-backed) green,
  zero failures, no regressions.
- `mix format --check-formatted` — Formatted.
- `mix credo --strict` — Lint clean, including the every-public-fn-`@spec` gate.
- `mix dialyzer` — No new contract warnings, no stale ignore filters.

## Notes
- **Why reuse `Session.Supervisor` instead of a direct provider HTTP call:** the
  platform is deliberately harness-agnostic (Claude CLI / pi CLI / Fake) and the
  Fast tier may be any of them. Routing through the existing runtime gets correct
  spawning, env handling (erlexec gotchas already solved), normalization, and
  model/provider resolution for free. The single additive `:broadcast_feed?` knob
  keeps the run private. A future optimization could add a thin synchronous
  provider-API path for the Fast tier (lower latency, no workspace spin-up) — note
  it but do not build it now.
- **Ephemeral by construction:** persistence is already gated on
  `agent_db_id`/`orchestrator_db_id` in `Session.Server.dispatch/2`; passing
  neither guarantees no `agent_logs` write. `:broadcast_feed?: false` is what
  additionally keeps it out of the global console feed and swimlanes. The
  per-agent topic remains the runner's private channel.
- **No new dependency expected.** The `ClipboardCopy` hook (`assets/js/app.js:56`)
  and the existing modal show/hide JS pattern cover the UI; `TypedStruct` is
  already in use. If a `Task.Supervisor`/`DynamicSupervisor` for the runner is
  added, register it in `application.ex` (§5) — no `mix.exs` change.
- **Streaming the paragraph into the modal** (token-by-token, like the chat
  streaming bubbles) is a natural enhancement but out of scope: the first cut
  shows a spinner then the finalized paragraph. The runner already observes
  `TextDelta` partials, so wiring live streaming later is incremental.
- **Selection UX:** keep the checkbox visually subtle so it doesn't clutter the
  dense stream; consider showing it on row hover + when selected. Confirm with
  Tidewave Web/Playwright that the checkbox click is isolated from row expand.
- Verify the `fast` roster key casing matches `Orchestrators` (`"fast"` string
  key under `metadata["agent_models"]`).
