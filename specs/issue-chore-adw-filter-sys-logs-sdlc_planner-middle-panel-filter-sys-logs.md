# Chore: Filter system logs out of the center event stream (UI-only toggle)

## Metadata
issue_number: `chore`
adw_id: `filter-sys-logs`
issue_json: `null`

## Chore Description
The center event stream of the orchestration console (the "middle panel" between
the left agent rail and the right chat/command panel — rendered by
`<div id="event-stream" phx-update="stream">` in
`lib/repo_builder_web/live/console_live.ex:1895-1933`) is fed by the bounded
`event_buffer` (`@buffer_limit = 500`, `lib/repo_builder_web/live/console_live.ex:78`).
Today that buffer is interleaved with **system-category** rows
(`category: :system`) — the lifecycle events `session_started`, `usage`, `done`,
and `error` — which are useful for the orchestrator's own audit and for the
durable `log-<n>` reference surface, but visually noisy in the center panel.

The user wants the **center event stream** (the LOGS view) to hide the
`:system` category by default. The rows must **continue to exist** in three places:

1. The bounded `event_buffer` in `ConsoleLive` (in-memory; never dropped) — so a
   future toggle back ON reveals them without a DB round-trip.
2. The persistent `agent_logs` table (`lib/repo_builder/logs.ex` — the only
   `Repo` caller for the table) — `:system` rows are not soft-hidden, not purged.
3. The Log Database manager (issue-log-db-manager, the All/Visible/Hidden
   paginated browser — `lib/repo_builder_web/live/console_live/shared.ex:760-787`,
   `lib/repo_builder_web/components/console/logs_components.ex`) — the manager
   reads `agent_logs` directly via `Logs.query_agent_logs/3` and is unaffected
   by the center-panel toggle.

The Log Database manager is the **canonical surface** for sys-log browsing when
the operator needs them; the center stream is for "what is the agent doing right
now". Hiding them by default from the center stream is a pure **view-layer**
change. A toggle (chip in the existing filter bar, parity with the four
RESPONSE/TOOL/THINKING/HOOK chips) flips them back on for debugging.

### What the two log sources are (for the implementer)

The platform has TWO distinct log sources that surface in the UI, and they must
not be conflated by this chore:

1. **`agent_logs` rows rendered in the center event stream** — the
   `event_buffer` rows. Their `category` is derived from the canonical event's
   type by `lib/repo_builder_web/live/console_live/shared.ex:category_for_type/1`
   (lines ~518-525) and the live `record_event/4` clauses in
   `lib/repo_builder_web/live/console_live.ex:975-1190` (`category: :system` for
   `SessionStarted`/`Usage`/`Done`/`Error`, `:response`/`tool`/`thinking`/`hook`
   for the others). These are the rows this chore filters **out of the
   stream view**. They are still persisted to `agent_logs` and are still
   queryable through the Log Database manager.

2. **`system_logs` rows** — the `RepoBuilder.Logs.SystemLog` audit table,
   written by `RepoBuilder.Logs.create_system_log/1` and surfaced by
   `RepoBuilderWeb.SystemLogsLive` (a separate, dedicated page at `/system_logs`).
   This chore does NOT touch that table or that page; the user's "sys logs"
   colloquially means the `:system`-category rows in the event stream, not the
   `system_logs` audit table. Confirm this interpretation in implementation
   notes; do not modify `system_logs` paths.

### Why the current behavior leaks them through

`lib/repo_builder_web/live/console_live/shared.ex:694-696` is the single line
that hard-codes the bypass:

```elixir
@spec category_pass?(map(), MapSet.t()) :: boolean()
def category_pass?(%{category: :system}, _active), do: true
def category_pass?(%{category: category}, active), do: MapSet.member?(active, category)
```

`:system` rows ignore the `active_categories` filter entirely — there is no
user affordance to hide them. The chore replaces that hard-coded `true` with a
new boolean assign (`show_system?`, default `false` for "hidden by default")
gated by a new filter-bar chip, and propagates the toggle through the existing
`restream/1` + `passes?/2` + `maybe_stream_insert/2` chain so live and backfilled
rows both honor the toggle.

### Scope of the change

- **No DB schema change.** No migration. `agent_logs` is untouched.
- **No context API change.** `RepoBuilder.Logs` is untouched — the toggle is
  a view-layer concern.
- **No harness or session runtime change.** §6 of `BUILD_PROMPT.md` is
  unaffected; canonical events still persist as today.
- **No chat-pane change.** `@show_thinking?` (chat reasoning) and the new
  `@show_system?` (center event stream) are independent toggles with distinct
  scopes.
- **No Log Database manager change.** The manager reads `agent_logs` directly;
  it is the operator's escape hatch when sys logs need to be browsed.

## Relevant Files
Use these files to resolve the chore:

- `lib/repo_builder_web/live/console_live.ex` — the orchestrator LiveView. Add
  the new `show_system?: false` assign to the initial `assign(...)` call
  (currently line 197, alongside `active_categories: MapSet.new(@categories)`).
  Pass the new flag to the `<.filter_bar>` invocation (currently line 1886) and
  to the `<.adw_card step_squares=...>` invocation (currently line 1996) so the
  toggle reaches the visible filter bar. The `passes?/2` chain (via
  `Shared.passes?/2`) is reached from the live `record_event/4` →
  `maybe_stream_insert/2` path (currently lines 1388, 1417-1422) so a new
  `show_system?` field is automatically respected on every live insert.
- `lib/repo_builder_web/live/console_live/shared.ex` — the cross-panel
  helpers. **This is the load-bearing change.** Modify
  `category_pass?/2` (lines 694-696) to honor a third argument
  `show_system?`. Update its `@spec` to
  `category_pass?(map(), MapSet.t(), boolean()) :: boolean()`. Update its
  single caller `passes?/2` (lines 648-655) to thread `assigns.show_system?`
  through. The `:underspecs` Dialyzer flag (in `mix.exs` `:dialyzer` config
  per `BUILD_PROMPT.md` §3) will catch any missed call site — the function is
  exported (not `defp`), so there is no implicit caller.
- `lib/repo_builder_web/live/console_live/logs_panel.ex` — the Logs panel
  extracted module. Add the new event name `"toggle_system"` to the `@events`
  list (currently lines 19-23). Add a `handle_event("toggle_system", ...)`
  clause that flips `socket.assigns.show_system?` and calls
  `Shared.restream(socket)` — parity with `toggle_project_scope` (lines 64-69)
  and `toggle_regex` (lines 56-58). The `Shared.restream/1` re-filter
  (line 641-644) automatically re-applies the new `:system` predicate so
  buffered rows become visible / hidden in one round-trip.
- `lib/repo_builder_web/components/console/logs_components.ex` — the
  filter-bar component (lines 33-115). Add a new `<.filter_chip cat={:system}
  label="SYS" active?={...} />` between the `HOOK` chip and the active-agent
  name-pill `for` loop (after line 54). The `:system` atom is already in the
  module's `@categories` list (line 17) and the `category_label/1` private
  helper (line 702) already maps `:system → "SYS"`, so the chip reuses
  `<.filter_chip>` verbatim and renders the `cns-chip--system` modifier class
  for the existing CSS rule `.cns-chip--active` (assets/css/app.css:212) plus
  a new `.cns-chip--system` color rule (CSS, see Step 5). Add a new attr
  `show_system?` (default `false`) to the `filter_bar/1` function head and
  pass it to the chip. Add a new `phx-click="toggle_system"` route on the chip
  — the existing `toggle_category` handler is for the four user-togglable
  categories, and the `:system` chip must use the dedicated event because the
  default is OFF (we don't want the chip to "auto-add" to `active_categories`
  on first click — that would conflate "system row visibility" with
  "category filter membership"). Mirror the `:system` chip on the
  `adw-controls` header in `lib/repo_builder_web/live/console_live.ex:1943-1967`
  so the ADWS view exposes the same toggle (the swimlane `step_squares` are
  derived from `@event_buffer` via the same `passes?/2` filter — see
  `Shared.passes?/2`).
- `assets/css/app.css` — add a `.cns-chip--system.cns-chip--active` color
  rule. Mirror lines 221-224 (one per category) — pick a muted gray to keep
  the system chip visually subordinate to the four content chips
  (e.g. `var(--cns-text-2)` background or a new `--cns-system` token reusing
  the existing gray used by `.cns-cat--system` at line 343). The styling
  must be visible but de-emphasized — sys rows are intentionally background.
- `test/repo_builder_web/live/test_orchestration_console_ui_test.exs` — the
  existing console-UI integration test. Add two new tests at the end of the
  module (which currently ends at line 214) that mirror the existing
  `category chip toggles its active class` test (lines 104-110):
  (a) **default-hidden assertion**: after broadcasting a `Usage` event (which
  lands in the center stream as `category: :system`), assert the row is NOT
  visible (`refute has_element?(view, ".cns-cat--system")`).
  (b) **toggle assertion**: click the new `#filter-system` chip, re-render,
  assert the row IS visible (`assert has_element?(view, ".cns-cat--system")`).
  (c) **persistence-untouched assertion**: query `agent_logs` via
  `RepoBuilder.Logs.query_agent_logs(:all, 50, 0)` and assert the `:usage`
  row is still present — the toggle is view-only, the DB row was never
  soft-hidden.
- `lib/repo_builder/logs.ex` — **read-only reference**, no edits. The chore
  must NOT call any `Logs.hide_*` function (which would soft-hide rows in
  `agent_logs`). The toggle is a LiveView assign; rows remain in `event_buffer`
  and `agent_logs` forever, just not rendered.
- `lib/repo_builder_web/live/console_live/shared.ex:passes?/2` — **read-only
  reference** to understand the existing filter chain (`category_pass?` →
  `agent_pass?` → `project_pass?` → `search_pass?`). The new
  `show_system?` flag slots in as the FIRST conjunct of `passes?/2` for the
  cleanest "fail-fast" semantics on system rows (so an off-toggle never
  re-surfaces them via the search or agent filters — system rows are
  unconditionally hidden when off, regardless of other predicates).
- `BUILD_PROMPT.md` §3 (typed style), §6 (session runtime — do not change),
  §8 (`RepoBuilder.Logs` is the only `Repo` caller for `agent_logs` — keep it
  that way), §9 (LiveView dashboard — the center stream + filter bar live
  here), §13 (ExUnit testing — the integration test pattern in
  `test_orchestration_console_ui_test.exs` is the template).
- `ai_docs/typed-elixir-standard.md` — the typed coding standard. The new
  `show_system?` assign and the modified `category_pass?/3` must keep
  precise types (no `any()`), `@spec` on every public function, and
  build clean under `--warnings-as-errors`.

### New Files

None. The chore touches existing modules only.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Add the `show_system?` LiveView assign (default OFF) in `console_live.ex`
- In the initial `assign(...)` call at `lib/repo_builder_web/live/console_live.ex:197`,
  add a new key `show_system?: false` to the assigns block — adjacent to
  `active_categories: MapSet.new(@categories)` (line 197). Default `false`
  (hidden) per the user's request that the center stream should not clutter
  with sys logs by default; the user can flip it on via the new chip.
- The flag is a transient LiveView assign (not a `Settings` key, not a
  `Settings.put_*` call) — parity with `@auto_follow?` (line 144) and
  `@show_thinking?` (line 149) which are likewise per-session view toggles.
  The user did not ask for cross-session persistence and `Settings` is the
  wrong place for a UI noise filter.
- Verify the disconnected mount's assign block is identical (it must be, since
  this is a default value, not a per-connection seed).

### 2. Update `Shared.category_pass?/2` → `Shared.category_pass?/3` in `shared.ex`
- Modify `lib/repo_builder_web/live/console_live/shared.ex:694-696`. The
  current code is:
  ```elixir
  @spec category_pass?(map(), MapSet.t()) :: boolean()
  def category_pass?(%{category: :system}, _active), do: true
  def category_pass?(%{category: category}, active), do: MapSet.member?(active, category)
  ```
- Replace with:
  ```elixir
  @spec category_pass?(map(), MapSet.t(), boolean()) :: boolean()
  def category_pass?(%{category: :system}, _active, false), do: false
  def category_pass?(%{category: :system}, _active, true), do: true
  def category_pass?(%{category: category}, active, _show_system?),
    do: MapSet.member?(active, category)
  ```
  This is the single change to the system-row policy. Order of clauses matters:
  the `:system` first-match wins; only the four user-togglable categories
  fall through to the `MapSet.member?` predicate.
- Update the single caller `passes?/2` at `shared.ex:648-655` to thread
  `assigns.show_system?` as the third argument:
  ```elixir
  def passes?(row, assigns) do
    category_pass?(row, assigns.active_categories, assigns.show_system?) and
      agent_pass?(row, assigns.active_agents) and
      project_pass?(row, assigns) and
      search_pass?(row.body, assigns.search, assigns.regex?)
  end
  ```
- Run `mix compile --warnings-as-errors` to confirm no other call sites
  break (the function is exported but the project has only one caller, and
  the `:underspecs` Dialyzer flag will catch any drift). If a stray caller
  exists (e.g. a test), update it to pass `true` for back-compat (the
  previous "always pass" behavior).

### 3. Add the `toggle_system` event handler in `logs_panel.ex`
- In `lib/repo_builder_web/live/console_live/logs_panel.ex`:
  (a) Add `"toggle_system"` to the `@events` list at lines 19-23 (sorted
  alphabetically to match the existing list). The `@events` list is the
  dispatch guard `ConsoleLive` uses to route events to this panel module
  (see `console_live.ex:728-732`).
  (b) Add a new `handle_event("toggle_system", _params, socket)` clause
  after the `toggle_show_hidden` clause (currently line 78-82). The clause
  is mirror-symmetric with `toggle_project_scope` (lines 64-69):
  ```elixir
  def handle_event("toggle_system", _params, socket),
    do:
      {:noreply,
       socket
       |> assign(:show_system?, not socket.assigns.show_system?)
       |> Shared.restream()}
  ```
  The `Shared.restream/1` re-filters the bounded `event_buffer` through
  the new `passes?/2` chain so already-buffered `:system` rows become
  visible (or hidden) without a DB round-trip — a single round-trip covers
  the entire buffered history.

### 4. Add the `SYS` filter chip in `logs_components.ex`
- In `lib/repo_builder_web/components/console/logs_components.ex`:
  (a) Add a new `attr :show_system?, :boolean, default: false` to the
  `filter_bar/1` function head (after the existing `attr :project_active?`
  at line 31-33). The `default: false` keeps the disconnected render
  self-consistent.
  (b) Insert a new `<.filter_chip>` invocation between the `HOOK` chip
  (line 54) and the `<span :for={id <- @active_agents}>` block (line 56):
  ```heex
  <.filter_chip
    cat={:system}
    label="SYS"
    active?={@show_system?}
    phx-click="toggle_system"
  />
  ```
  The existing `<.filter_chip>` component (lines 124-138) supports
  overriding `phx-click` via the default attr on the function head —
  verify and adjust if the component hard-codes `toggle_category`. If the
  override is not supported, the simplest fix is to render a plain
  `<button>` for the SYS chip with the same `cns-chip cns-chip--system`
  classes (matching the visual rhythm of the four user-togglable chips)
  and `phx-click="toggle_system"`.
  (c) Add a new attr `phx_click` (default `"toggle_category"`) to the
  `filter_chip/1` component definition (lines 124-138) so the new
  override is first-class and any future chip that needs a different
  event (e.g. a "HIDE ALL" chip in a future chore) can reuse the
  component.
- The existing `<.filter_chip>` `cat={:system}` will render with the
  modifier class `cns-chip--system`. Add the corresponding color rule
  to `assets/css/app.css` (Step 5) so the active state has a visible
  (but muted) color.

### 5. Add a muted color for `.cns-chip--system.cns-chip--active`
- In `assets/css/app.css:221-224`, add a new color rule for the system
  chip's active state. The rule must:
  - Use a muted gray (intentionally background, never the operator's
    primary focus). Reuse the same gray as `.cns-cat--system` at
    `app.css:343` for visual consistency with the existing `:system`
    category badge. Suggested: `background-color: var(--cns-text-3, #6b7280);`.
  - Sit in the existing chip-active block. Suggested addition:
    ```css
    .cns-chip--system.cns-chip--active { background-color: var(--cns-text-3, #6b7280); }
    ```
  - Not introduce a new CSS variable unless the existing `--cns-text-3`
    is not present in the file's `:root` block — verify by reading the
    top of `app.css` and add the token if missing. If a new token is
    added, define it in the same `:root` block as the other `--cns-*`
    colors and reuse the muted-gray semantic.

### 6. Mirror the SYS chip on the ADWS view (swimlanes) header
- In `lib/repo_builder_web/live/console_live.ex:1943-1967`, the
  `adw-controls` header has a parallel set of four category chips
  (`#adw-cat-response`, `#adw-cat-tool`, `#adw-cat-thinking`,
  `#adw-cat-hook`). Add a fifth chip mirroring the filter-bar SYS
  chip:
  ```heex
  <button
    id="adw-cat-system"
    type="button"
    phx-click="toggle_system"
    class={[
      "cns-chip",
      "cns-chip--system",
      @show_system? && "cns-chip--active"
    ]}
  >
    SYS
  </button>
  ```
  Place it AFTER the `HOOK` chip and BEFORE the `running` count span
  (the existing `ml-auto` on the span means everything before the
  span is left-aligned; the new chip goes in the same left-aligned
  group as the four content chips).
- The ADWS `step_squares` are derived from `@event_buffer` via
  `workflow_step_squares/3` which is called at `console_live.ex:1996`
  — that helper already calls `passes?/2` (or its equivalent) so
  flipping `@show_system?` will automatically re-filter the squares
  when the user clicks the chip and `Shared.restream/1` fires.
  Verify by reading `lib/repo_builder_web/live/console_live/shared.ex`
  for the `workflow_step_squares` definition and confirming the
  filter chain. If it does NOT use `passes?/2`, thread the flag
  explicitly in the helper. Document any deviation in the
  implementation PR.

### 7. Add a "show system" log-No reference test (the durable escape hatch)
- Append a new test to
  `test/repo_builder_web/live/test_orchestration_console_ui_test.exs`
  (currently ends at line 214). The new test must verify:
  (a) **default-hidden**: after broadcasting a canonical `:usage` event
  (which persists to `agent_logs` AND renders in the center stream as
  `category: :system`), the row is NOT in the rendered DOM
  (`refute has_element?(view, ".cns-cat--system")`).
  (b) **toggle reveals**: clicking `#filter-system` (the new chip
  rendered in the filter bar) flips the toggle; the row IS now in
  the rendered DOM (`assert has_element?(view, ".cns-cat--system")`).
  (c) **persistence is untouched**: the `agent_logs` row is still
  present after the toggle — query
  `RepoBuilder.Logs.query_agent_logs(:all, 50, 0)` and assert at
  least one row has `event_type: :usage`. The toggle is a view-layer
  concern, not a soft-hide.
  (d) **log-No label intact**: the rendered row carries a
  `data-log-no` (or the test reads it from the DOM via
  `LazyHTML`/`Phoenix.LiveViewTest`'s `element/2`) and
  `RepoBuilder.Logs.log_label/1` formats it as `log-<n>` per
  `AGENTS.md`'s "troubleshooting: finding a log by its number" —
  confirm the label is still recoverable for the orchestrator's
  `get_logs` tool to resolve. (This sub-test is the durability
  guarantee the user asked for: "not that they don't exist".)
- The test follows the existing pattern in
  `test_orchestration_console_ui_test.exs:65-99` ("canonical events
  render rows...") — broadcast via
  `Dashboard.broadcast_event(agent_id, event)`, then `render(view)`
  to drain the mailbox, then `has_element?` / `refute has_element?`
  to assert DOM presence.

### 8. Run the validation commands (zero regressions)
- See `Validation Commands` below. Every command must exit 0. The
  chore is a typed + compile + test + lint + dialyzer check
  per `BUILD_PROMPT.md` §3.

## Validation Commands
Execute every command to validate the chore is complete with zero regressions.

- `mix compile --warnings-as-errors` - Compile clean; the gradual set-theoretic type checker and `warnings_as_errors` must pass. Confirms the new `category_pass?/3` signature and the new `show_system?` assign typecheck against every caller.
- `mix test --warnings-as-errors` - Run the full ExUnit suite with zero failures. Includes the new toggle-system test in `test/repo_builder_web/live/test_orchestration_console_ui_test.exs` and the existing tests that depend on `:system` rows being rendered (e.g. `test_log_number_test.exs` and `test_release_hidden_logs_test.exs` if they read from the center stream — verify before relying on green).
- `mix format --check-formatted` - Ensure code is formatted.
- `mix credo --strict` - Lint, including the "every public function has an `@spec`" convention. The new `category_pass?/3` has its `@spec` updated in Step 2; the new `handle_event/3` clause is private to the panel module but adds no public surface that needs an `@spec`. The new `attr :show_system?, :boolean, default: false` in the `filter_bar/1` component head is a `Phoenix.Component.attr` declaration, not a public function, and does not require an `@spec`.
- `mix dialyzer` - `@spec`/contract checking with no new warnings. The `category_pass?/3` `@spec` change is the most likely place for a stray-call warning; the `:underspecs` and `:no_opaque` flags in `mix.exs` `:dialyzer` config will catch any missed call site.

## Notes
- **The two log sources are distinct.** The platform has (a) `agent_logs` rows that flow into the center event stream and (b) the `system_logs` audit table surfaced by `RepoBuilderWeb.SystemLogsLive` at `/system_logs`. The user's "sys logs" refers to the `:system`-category rows in the center event stream, not the `system_logs` audit table. This chore does NOT touch the audit table or its dedicated page. Confirm with the requester if unsure.
- **Why this is a UI-only change.** The user explicitly said "not that they dont exist, just that the human does not see them cluttering up in the middle panel". The Log Database manager (issue-log-db-manager) is the operator's escape hatch for the durable view; the center stream is the noisy live view. Hiding in one and not the other is the right separation of concerns.
- **Why default OFF.** The user said they want sys logs hidden by default. A user who has not yet opened the console today sees a clean center stream; the SYS chip in the filter bar is the explicit opt-in to see them (e.g. for a usage / cost / error spike investigation). The chip's color is intentionally muted gray to keep it visually subordinate to the four content chips — sys rows are noise, never the operator's primary focus.
- **Why a new toggle, not a 5th entry in `active_categories`.** The current `active_categories` MapSet is the user-togglable set of `:response | :tool | :thinking | :hook` categories. Adding `:system` to it would conflate "system row visibility" with "category filter membership": clearing all four categories (a valid operation) would leave `:system` ON, which contradicts the user's intent. The dedicated `@show_system?` boolean is the cleanest model.
- **Why no DB / context change.** `RepoBuilder.Logs` is the only `Repo` caller for `agent_logs` (`BUILD_PROMPT.md` §8). The chore keeps the durable store untouched; the toggle is a LiveView-only assign. No migration, no context API, no soft-hide — view-only.
- **Why mirror the chip on the ADWS view header.** The swimlane `step_squares` are derived from `@event_buffer` via the same `passes?/2` filter, so the toggle would have an inconsistent effect (hidden in LOGS, visible in ADWS squares) without a parallel chip. The mirrored chip keeps the two views consistent.
- **Back-compat for the existing `test_log_number_test.exs`.** The test renders a `:system` row (a `:usage` event) and asserts the `log-<n>` label is present. With the default-OFF behavior, this test will need to click the SYS chip before asserting — read the test first, update it as part of this chore, and add a brief comment in the test explaining the new precondition.
- **Back-compat for `clear_filters`.** The `clear_filters` handler in `logs_panel.ex:106-123` resets `active_categories` to `MapSet.new(@categories)` (re-enables all four) and clears `event_buffer` / `selected_ids` / `expanded_ids` / `log_count`. It does NOT touch `@show_system?` — by design, the SYS toggle is independent of the four-category reset (a user who toggled SYS ON wants it to stay ON across a CLEAR). If the implementer wants symmetry, add an explicit comment in the handler documenting the intentional asymmetry.
- **Tidewave verification.** The platform exposes Tidewave MCP at `http://localhost:4000/tidewave/mcp`. Before declaring the chore complete, run `project_eval` to load the new `show_system?` assign into a connected socket and `execute_sql_query` to confirm the `:usage` row is still in `agent_logs` after the toggle:
  ```elixir
  RepoBuilder.Logs.query_agent_logs(:all, 5, 0) |> Enum.map(&{&1.log_no, &1.event_type})
  # => [{1, :usage}, {2, :text_delta}, ...]
  ```
  Then `get_docs` on `RepoBuilder.Logs.query_agent_logs/3` to confirm the public API did not drift.
- **Plan files cited in this chore.** `lib/repo_builder_web/components/console/logs_components.ex` already has `@categories [:response, :tool, :thinking, :hook, :system]` (line 17) — the `:system` chip atom is pre-declared, and `category_label(:system)` already returns `"SYS"` (line 702). The chore reuses these declarations; no new atoms are introduced.