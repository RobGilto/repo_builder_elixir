# Feature: Log Database Manager (settings tab + paginated purge/visibility popup)

## Metadata
issue_number: `log-db-manager`
adw_id: `na`
issue_json: `{"title":"Log Database operations: own settings tab + paginated manager popup with drag-select, hide/unhide, purge selected, purge all","body":"Move the hidden-log settings (Release hidden, Temporarily show cleared rows) into their own settings tab. Add log database operations to that tab: a dangerous \"purge ALL log rows\" action, and a pop-up tool to select a few rows and purge them, make visible / make invisible. The popup must support pagination and the same click-and-drag checkbox multi-select used in the main middle column view. The manager must have a horizontal tab of All / Hidden / Visible that the user can select from to filter the rows."}`

## Feature Description
Today, log rows (`agent_logs`) can only be **soft-hidden** in bulk (the console CLEAR action via `Logs.hide_all_logs/0`) or **released** in bulk (`Logs.release_hidden_logs/0`); there is no per-row visibility control and no way to permanently delete rows. The two controls that exist (`Release hidden logs & workflows`, `Temporarily show cleared rows (peek)`) live in the **General** settings tab, mixed in with unrelated settings.

This feature introduces a dedicated **Log Database** settings tab and a **Log Manager popup** — a paginated, drag-selectable table of log rows with a horizontal **All / Hidden / Visible** filter. From it the operator can multi-select rows (click, or the same click-and-drag paint as the main log view) and **Make visible**, **Make invisible**, or **Purge selected**; the tab also exposes a guarded **Purge ALL log rows** action. This gives the operator real database hygiene controls over the log store directly from the console.

## User Story
As an operator running the orchestration console
I want a dedicated log-database tab with a paginated manager that lets me filter by All/Hidden/Visible, multi-select rows (including click-and-drag), and make them visible/invisible or purge them (with a guarded purge-everything option)
So that I can curate and permanently clean up the log store without dropping to SQL, and keep the console focused on the logs that matter.

## Problem Statement
- Log visibility is **all-or-nothing**: there is no per-row hide/unhide, only `hide_all_logs/0` / `release_hidden_logs/0`.
- There is **no hard delete** anywhere in `RepoBuilder.Logs` — rows accumulate forever; the only escape is manual SQL.
- The log/hidden settings are buried in the **General** tab, not grouped as database operations.
- There is **no paginated, filterable inspector** of the persisted log rows; the main center view is a live in-memory stream (`@buffer_limit 500`), not a DB browser.
- The powerful **click-and-drag multi-select** only exists for the live stream and cannot be reused against the DB rows.

## Solution Statement
1. Extend the **`RepoBuilder.Logs`** context (the sole `Repo` caller for `agent_logs`) with `@spec`'d, filter-aware **pagination** (`query_agent_logs/3`, `count_agent_logs/1`), **per-row visibility** (`hide_logs/1`, `unhide_logs/1`), and **hard delete** (`purge_logs/1`, `purge_all_logs/0`).
2. Add a new **`:logs` settings tab** ("Log Database") and **move** the two hidden-log controls (refs #0–#3) out of General into it, alongside a guarded **Purge ALL** action and a **Manage log rows…** launcher.
3. Add a **Log Manager popup** (`log_manager_modal/1`) rendered like the existing `budget_modal` (always in the DOM, shown/hidden client-side). It contains a horizontal **All / Hidden / Visible** filter, a **paginated** table (offset/limit), per-row checkboxes, a selection action bar, and pagination controls.
4. Reuse the drag-select pattern via a **self-contained `LogDragSelect` JS hook** (a focused clone of `DragSelect`) scoped to the modal's own classes/ids/events, so the live main-view hook is untouched. Selection is a `MapSet` of log `id` strings that **persists across pages**, so a purge/visibility action can span pages.
5. Cover everything with context unit tests and a `Phoenix.LiveViewTest` integration test.

No new dependency and **no migration** are required: the `hidden` boolean and the `log_no` sequence already exist on `agent_logs`; hard delete uses the existing primary key.

## Relevant Files
Use these files to implement the feature:

- `BUILD_PROMPT.md` — §3 typed style guide (every public fn `@spec`'d), §8 persistence (web never touches `Repo`; contexts only), §9 LiveView dashboard (streams, modals, reconnect). Authoritative architecture.
- `ai_docs/typed-elixir-standard.md` — enforced typed standard (the **(always)** conditional-docs row): `@spec`, `@type` for the new `log_filter` type, precise types over `map()`/`any()`, `{:ok, t()} | {:error, reason()}` discipline. Also matched the "Ecto schemas/contexts" conditional-docs row.
- `lib/repo_builder/logs.ex` — the **only** `Repo` caller for `agent_logs`. Add the pagination/visibility/purge functions here. Mirror the existing `list_recent_global/2`, `hide_all_logs/0`, `release_hidden_logs/0`, `filter_hidden/2`, and the offset/limit pattern in `query_system_logs/1` (`clamp_limit/1`).
- `lib/repo_builder/logs/agent_log.ex` — the `agent_logs` schema. Fields used: `id` (binary_id PK), `hidden` (bool, indexed), `log_no` (int, unique, DB sequence, `log_label/1`), `event_type` (Ecto.Enum), `harness`, `provider`, `model`, `inserted_at`. No change needed.
- `lib/repo_builder_web/components/console_components.ex` — `settings_modal/1` (tabs nav at ~1059, `settings_tab_button/1`, `settings_field/1`), the General-tab fields to move (lines ~1106–1140), the existing modal helpers (`show_budget/1`, `hide_budget/1`, `budget_modal/1` as the popup template to mirror), and the live-view checkbox/selection-bar markup (lines ~488–600) to mirror for the manager rows.
- `lib/repo_builder_web/live/console_live.ex` — mount assigns (~159 `selected_ids: MapSet.new()`, ~196 budget assigns block), `select_settings_tab` handler (~1094), live-view `toggle_select`/`select_drag`/`apply_drag_selection` (~1300–1317, ~2754) to mirror, modal render site (~2685 budget_modal), and `@buffer_limit`. Add the new manager assigns, events, and modal render.
- `assets/js/app.js` — `DragSelect` hook (lines ~123–238) to clone as `LogDragSelect`; hook registration map (~347). Reuse the `.cns-dragging` selection-suppression convention.
- `assets/css/app.css` — `.cns-dragging` / `.cns-event-row__select` rules (~263, ~278) to reuse/extend for the manager checkboxes.
- `test/repo_builder/logs_test.exs` (if present, else new) — context unit tests for pagination/visibility/purge.
- `test/support/data_case.ex` — `DataCase` (sandbox; `async: false` when a separate process must see inserts) for context tests.

### New Files
- `test/repo_builder_web/live/test_log_database_manager_test.exs` — `Phoenix.LiveViewTest` integration test: open Settings → Log Database tab, launch the manager, switch All/Hidden/Visible filter, paginate, single + drag select, make-visible/invisible, purge selected, and the guarded purge-all.
- `test/repo_builder/logs/log_database_ops_test.exs` — `RepoBuilder.DataCase` unit tests for `query_agent_logs/3`, `count_agent_logs/1`, `hide_logs/1`, `unhide_logs/1`, `purge_logs/1`, `purge_all_logs/0` (filter correctness, offset/limit clamping, counts, idempotency).

## Implementation Plan
### Phase 1: Foundation
Extend `RepoBuilder.Logs` with the filter-aware pagination, per-row visibility, and hard-delete functions, all `@spec`'d and keeping `Repo`/`Ecto.Query` inside the context. Introduce a `@type log_filter :: :all | :visible | :hidden` and a private `apply_filter/2` (mirroring `filter_hidden/2`) plus `clamp_limit/1`/`clamp_offset/1` (mirroring `query_system_logs/1`). Write the context unit tests first and make them pass.

### Phase 2: Core Implementation
Add the `:logs` settings tab and the Log Manager popup component, move the hidden-log controls into the tab, and wire the LiveView assigns + events (filter, pagination, single/drag select, visibility, purge, purge-all). Add the `LogDragSelect` JS hook and the manager CSS. Each destructive action is gated by `data-confirm`.

### Phase 3: Integration
Seed the manager data on connected mount and refresh it whenever the manager is opened or any mutating action runs, so the table, total count, and pagination stay correct. Ensure selection (`MapSet` of `id` strings) survives filter changes and pagination, and that mutations clear the selection and re-query. Confirm the live main-view DragSelect hook and its events are untouched. Run the full validation suite.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Read the authoritative docs
- Read `BUILD_PROMPT.md` §3, §8, §9 and `ai_docs/typed-elixir-standard.md` (the **(always)** + Ecto conditional-docs rows). Confirm: every new public fn gets an `@spec`; the web layer never calls `Repo`; contexts return precise types.

### 2. Extend the `RepoBuilder.Logs` context (TDD: write `test/repo_builder/logs/log_database_ops_test.exs` first)
- Add `@type log_filter :: :all | :visible | :hidden` (and `@typep` for any internal opts).
- `@spec query_agent_logs(log_filter(), pos_integer(), non_neg_integer()) :: [AgentLog.t()]` — newest-first (`order_by: [desc: l.log_no, desc: l.inserted_at]`), `limit`/`offset` clamped; apply `apply_filter/2`.
- `@spec count_agent_logs(log_filter()) :: non_neg_integer()` — `Repo.aggregate(query, :count, :id)` with the same filter (for pagination metadata).
- `@spec hide_logs([Ecto.UUID.t()]) :: non_neg_integer()` and `@spec unhide_logs([Ecto.UUID.t()]) :: non_neg_integer()` — `update_all(set: [hidden: true|false])` on `where: l.id in ^ids`; `[] -> 0` guard. Reuse the `hide_all_logs/0` pattern.
- `@spec purge_logs([Ecto.UUID.t()]) :: non_neg_integer()` — `from(l in AgentLog, where: l.id in ^ids) |> Repo.delete_all()` returns `{count, _}`; `[] -> 0` guard.
- `@spec purge_all_logs() :: non_neg_integer()` — `Repo.delete_all(AgentLog)` returns `{count, _}`.
- Private `apply_filter(query, :all)` (no-op), `apply_filter(query, :visible)` (`hidden == false`), `apply_filter(query, :hidden)` (`hidden == true`); private `clamp_limit/1` (default 50, max 200) and `clamp_offset/1` (>= 0). Keep these `@spec`'d/`@typep`'d.
- Unit tests assert: filter correctness (counts per filter), offset/limit windowing and clamping, `hide_logs`/`unhide_logs` flip only the targeted ids and return the right count, `purge_logs` deletes only targeted ids, `purge_all_logs` empties the table, and empty-id calls are no-ops returning 0.

### 3. Write the LiveView integration test scaffold (`test/repo_builder_web/live/test_log_database_manager_test.exs`)
- `use RepoBuilderWeb.ConnCase, async: false` (a manager that re-queries the DB needs the shared sandbox), `import Phoenix.LiveViewTest`.
- Seed several `agent_logs` rows (mix of `hidden: true/false`) via `RepoBuilder.Logs.persist_event/2` or direct context inserts.
- Drive: open settings, click the **Log Database** tab (`select_settings_tab` → `#settings-tab-logs`), assert the moved controls render there and **not** in General; open the manager (`#open-log-manager`), assert `#log-manager-modal` + rows; click the **Hidden**/**Visible**/**All** filter segments and assert the row set changes; paginate (Next/Prev) and assert the window + "rows X–Y of N"; select a row (`log_toggle_select`) and assert the selection bar count; fire `log_select_drag` with ids+mode and assert the count; `log_make_invisible`/`log_make_visible` and assert DB `hidden` via `RepoBuilder.Logs`; `log_purge_selected` and assert rows gone; `purge_all_logs` and assert empty. (This test is finalized after the UI exists, but author the skeleton now.)

### 4. Add the `:logs` settings tab and move the hidden-log controls
- In `settings_modal/1` nav, add `<.settings_tab_button tab={:logs} active={@settings_tab} label="Log Database" />` (place after Cost Center).
- Add a `<div :if={@settings_tab == :logs} class="flex flex-col gap-4">` panel.
- **Move** the two `settings_field`s — `Release hidden logs & workflows` (refs #0–#1) and `Temporarily show cleared rows (peek)` (refs #2–#3) — from the General panel into the new Logs panel (verbatim markup + their existing events `release_hidden`, `toggle_show_hidden`; assigns `@release_notice`, `@show_hidden?`).
- Add a guarded **Purge ALL log rows** `settings_field`: a `cns-chip` button `id="settings-purge-all-logs"`, `phx-click="purge_all_logs"`, `data-confirm="Permanently DELETE every log row? This cannot be undone and also clears Cost Center history."`, plus a one-line consequence note.
- Add a **Manage log rows…** launcher: `id="open-log-manager"`, `phx-click={JS.push("open_log_manager") |> show_log_manager()}`.
- Add `show_log_manager/1` + `hide_log_manager/1` JS helpers mirroring `show_budget/1`/`hide_budget/1`.

### 5. Build the Log Manager popup component (`log_manager_modal/1` in `console_components.ex`)
- Mirror `budget_modal/1`: `id="log-manager-modal"`, `class="cns-cmd-overlay"`, `style="display:none"`, `phx-window-keydown={hide_log_manager()}` + `phx-key="Escape"`, inner `cns-cmd-panel` (wide, ~56rem, capped height with internal scroll).
- Attrs (all `@spec`'d component): `:filter` (`log_filter`), `:rows` (`[AgentLog.t()]`), `:total` (`non_neg_integer`), `:limit`, `:offset`, `:selected` (`MapSet.t()`).
- **Horizontal filter tab**: a `cns-toggle` with three segments `All` / `Visible` / `Hidden`, each `phx-click="select_log_filter"` + `phx-value-filter`, active styling driven by `@filter`.
- **Selection action bar** (`:if={MapSet.size(@selected) > 0}`): "N selected", `Make visible` (`log_make_visible`), `Make invisible` (`log_make_invisible`), `Purge selected` (`log_purge_selected`, `data-confirm`), `Clear selection` (`clear_log_selection`).
- **Table**, wrapped in a stable host `<div id="log-manager-table-wrap" phx-hook="LogDragSelect" class="contents">`: header (select, log-no, time, harness/model, type, visibility badge); one row per `@rows` entry, `id={"log-mgr-row-#{row.id}"}`, with a checkbox `class="log-mgr-row__select"`, `data-row-id={row.id}`, `phx-click="log_toggle_select"`, `phx-value-id={row.id}`, `checked={MapSet.member?(@selected, row.id)}`. Render `Logs.log_label(row.log_no)`, formatted time, harness/model, `event_type`, and a Hidden/Visible badge.
- **Pagination footer**: `Prev`/`Next` (`log_page_prev`/`log_page_next`, disabled at bounds) and a "rows X–Y of N" label derived from `@offset`, `@limit`, length, `@total`.
- Add helper(s) for the row time/label rendering consistent with existing console formatting (reuse the timezone-aware formatter the center view uses).

### 6. Wire LiveView assigns + events (`console_live.ex`)
- Add mount assigns (disconnected-safe defaults; seed on connected mount): `log_mgr_filter: :all`, `log_mgr_rows: []`, `log_mgr_total: 0`, `log_mgr_limit: 50`, `log_mgr_offset: 0`, `log_mgr_selected: MapSet.new()`.
- Add a private `@spec seed_log_manager(Socket.t()) :: Socket.t()` that sets `log_mgr_rows`/`log_mgr_total` via `Logs.query_agent_logs/3` + `Logs.count_agent_logs/1`, and call it in the connected-mount pipeline and from a `refresh_log_manager/1` helper.
- Events (each `{:noreply, ...}`):
  - `open_log_manager` → `refresh_log_manager` (re-query current filter/page).
  - `select_log_filter %{"filter" => f}` → set filter (guard string→atom into the closed set `~w(all visible hidden)`), reset offset to 0, clear selection, re-query.
  - `log_page_next` / `log_page_prev` → adjust offset by `limit` (clamp to `[0, total)`), re-query.
  - `log_toggle_select %{"id" => id}` → toggle id (string UUID) in `log_mgr_selected`.
  - `log_select_drag %{"ids" => ids, "mode" => mode}` → union/difference into `log_mgr_selected` (mirror `apply_drag_selection/3`, but ids are strings — no `String.to_integer`).
  - `clear_log_selection` → `MapSet.new()`.
  - `log_make_visible` / `log_make_invisible` → `Logs.unhide_logs/1` / `Logs.hide_logs/1` on `MapSet.to_list(selected)`, clear selection, re-query.
  - `log_purge_selected` → `Logs.purge_logs/1` on the selection, clear selection, re-query (clamp offset if the last page shrank).
  - `purge_all_logs` → `Logs.purge_all_logs/0`, clear selection, reset offset, re-query.
- Render `<.log_manager_modal .../>` next to `budget_modal` in `console_live.ex`, threading the new assigns.
- Guard the filter parse with a closed mapping (never `String.to_atom/1` on user input), consistent with `system_prompt_mode/1`.

### 7. Add the `LogDragSelect` JS hook (`assets/js/app.js`) + CSS
- Clone `DragSelect` as `LogDragSelect`, changing: checkbox selector `.log-mgr-row__select`, row matcher `[id^='log-mgr-row-']`, commit event `log_select_drag`, painted-class target (reuse `.cns-event-row--selected` equivalent or a new `.log-mgr-row--selected`). Reuse the `.cns-dragging` user-select suppression on the host (`#log-manager-table-wrap`).
- Register it in the hooks map alongside `DragSelect`, `LogCopy`, etc.
- Add CSS for `.log-mgr-row__select` (mirror `.cns-event-row__select`) and a `.log-mgr-row--selected` highlight; reuse the existing `.cns-dragging, .cns-dragging * { user-select: none; }` rule.

### 8. Finalize the LiveView integration test
- Complete `test/repo_builder_web/live/test_log_database_manager_test.exs` per step 3 against the now-built UI; assert DB effects through `RepoBuilder.Logs` (never `Repo` in the test web layer where avoidable; reading via the context is fine).

### 9. Runtime verification via Tidewave
- Use `project_eval` to call `RepoBuilder.Logs.query_agent_logs(:hidden, 50, 0)` / `count_agent_logs(:all)` and confirm shapes.
- Use `execute_sql_query` (`SELECT hidden, count(*) FROM agent_logs GROUP BY hidden`) before/after a make-invisible and a purge to confirm DB state.
- Optionally drive the live UI with `browser_eval` (open Settings → Log Database → manager, switch filter, paginate, drag-select, purge selected) and confirm rendering; capture a screenshot of `http://localhost:4000` as visual proof.

### 10. Run the Validation Commands
- Run every command in **Validation Commands**; fix any failure; re-run until all green with zero regressions.

## Testing Strategy
### Unit Tests
- **Context (`log_database_ops_test.exs`)**: `query_agent_logs/3` returns the right rows per filter and respects offset/limit + clamping; `count_agent_logs/1` matches per filter; `hide_logs/1`/`unhide_logs/1` flip only targeted ids and return correct counts and are idempotent; `purge_logs/1` deletes only targeted ids; `purge_all_logs/0` empties the table; empty-id calls return 0 without error.
- **LiveView (`test_log_database_manager_test.exs`)**: tab move (controls present in Logs tab, absent in General), manager open, filter switching, pagination window + label, single-click and drag selection (selection persists across a page change), make-visible/invisible reflected in DB, purge selected, purge-all. Assert via `element/2`, `render_*`, `has_element?/2`, and `RepoBuilder.Logs` reads.

### Edge Cases
- Empty store: manager shows an empty state; pagination shows "0 of 0"; Prev/Next disabled.
- Selection spanning multiple pages, then purge/visibility action applies to the full set; offset clamps when the last page shrinks below the current offset.
- Filter change while rows are selected → selection cleared and offset reset to avoid stale, off-page selections.
- `data-confirm` cancel path performs no mutation.
- Drag-select hook does not interfere with the live main-view `DragSelect` (distinct host/classes/events; integer vs UUID id namespaces).
- Purging removes rows that feed Cost Center rollups — counts/cost history change accordingly (intended, surfaced in the confirm copy).
- Disconnected mount renders safe defaults (no `Repo` call before `connected?/1`).

## Acceptance Criteria
- A new **Log Database** settings tab exists; the **Release hidden logs** and **Temporarily show cleared rows (peek)** controls render there and no longer in **General**, with unchanged behavior.
- The Logs tab has a guarded **Purge ALL log rows** action (`data-confirm`) that empties `agent_logs`, and a **Manage log rows…** launcher.
- The **Log Manager popup** opens/closes (button + Escape), shows a paginated table newest-first with per-row select checkboxes and a "rows X–Y of N" label, and Prev/Next paginate correctly.
- A horizontal **All / Visible / Hidden** filter switches the row set and the count; changing it resets to page 1 and clears selection.
- Rows can be selected by click and by **click-and-drag paint** (same UX as the main view); selection **persists across pages**; the action bar shows the count.
- **Make visible** / **Make invisible** flip `hidden` for the selected rows (verified in DB); **Purge selected** hard-deletes them; both re-query and clear selection.
- All new `RepoBuilder.Logs` functions are `@spec`'d and are the only `Repo` callers; the LiveView/components call only the context.
- All **Validation Commands** pass with zero regressions.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix test test/repo_builder/logs/log_database_ops_test.exs` — context pagination/visibility/purge unit tests pass.
- `mix test test/repo_builder_web/live/test_log_database_manager_test.exs` — LiveView integration test (tab move, manager, filter, pagination, drag-select, hide/unhide, purge) passes.
- `mix compile --warnings-as-errors` — clean compile; gradual set-theoretic type checker + `warnings_as_errors` pass.
- `mix test --warnings-as-errors` — full ExUnit suite green (zero failures, zero regressions).
- `mix format --check-formatted` — formatting clean.
- `mix credo --strict` — lint clean, including the "every public function has an `@spec`" rule.
- `mix dialyzer` — no new contract warnings; no stale ignore filters.

## Notes
- **No migration / no new dependency.** The `hidden` boolean (indexed) and `log_no` sequence already exist on `agent_logs`; hard delete uses the primary key. `agent_id`/`orchestrator_id` FKs are `on_delete: :delete_all`, but here we delete the log rows themselves — no cascade concern.
- **Cost Center coupling (intended, surfaced):** `agent_logs` is the source for `CostCenter` spend rollups. Purging rows permanently removes their cost history; the confirm copy states this so it's a deliberate operator action, not a surprise.
- **Hook isolation:** a dedicated `LogDragSelect` (clone of `DragSelect`) keeps the working live-view hook untouched; the small duplication is intentional and lower-risk than parametrizing the shared hook. A future refactor could unify them via `data-*` config if desired.
- **Live-view reflection:** toggling `hidden` in the manager affects future backfills and the "show hidden" peek; it does not retroactively remove rows already painted into the current live stream (that reconciles on reconnect/backfill). This matches the existing CLEAR/Release semantics.
- **Selection model:** the manager selection is a `MapSet` of `agent_logs.id` UUID **strings** (distinct from the live view's integer `selected_ids`), so the two selection systems never collide.
- **Pagination default:** 50 rows/page, max 200 (mirrors `query_system_logs/1` clamping), offset-based for simplicity and stable Prev/Next; cursor pagination is a possible future upgrade for very large tables.
