# Bug: ConsoleLive mount lag + tab-toggle performance

## Metadata
issue_number: `perf`
adw_id: `console-perf`
issue_json: `{"title": "performance is really bad, pages slow to load. we need to run tests and track time across navigation pages, when toggling to next tab there is a lag", "body": "ConsoleLive mount runs 14+ sequential DB queries before first render. Three of those queries load settings tabs (Logs browser, Templates, External APIs) that are never open by default — wasted on every page load. Tab switching lag is caused by the DOM diff for a 2380-line LiveView and, for Cost Center, a synchronous aggregation query on the server side."}`

## Bug Description

Clicking any link that mounts or remounts `ConsoleLive` (including navigating back from `/plan`) causes a noticeable delay before the page becomes interactive. Additionally, toggling the main view (`logs ↔ adws`) and switching to settings tabs (especially Cost Center) exhibits visible lag.

**Expected:** Console page appears in <300ms; tab toggling is instantaneous.
**Actual:** Console page stalls for 0.5–2s; certain settings tabs (Cost Center) trigger a blocking DB aggregation query, freezing the process for the duration.

## Problem Statement

`ConsoleLive.mount/3` (connected path) executes **17 sequential operations** synchronously — including 8+ DB queries, file I/O, and CPU-bound row processing — before the LiveView can send the first diff to the browser. Three of those operations load data for **settings tabs that are not open by default**:

- `Shared.seed_log_manager/1` — 2 queries (`count_agent_logs` + `query_agent_logs 50`) for the **Logs DB browser** (Settings → Logs tab). Not shown until the user opens that tab.
- `Shared.assign_template_rows/1` — 1 query (`Templates.list()`) for the **Templates** settings tab.
- `ExternalApisPanel.load_external_apis/1` — 2 queries (`ExternalApis.list_for_scope × 2`) for the **External APIs** settings tab.

Removing these 5 unnecessary queries from the mount hot path (and lazy-loading them when the relevant tab opens) is the highest-ROI fix. Additionally, there are no LiveView telemetry metrics wired to track mount/handle_event timing, making it impossible to confirm improvements or catch regressions.

## Solution Statement

1. **Remove 3 eager seed calls from mount** — `seed_log_manager`, `assign_template_rows`, and `load_external_apis`. Each is lazily triggered when the user actually opens the matching settings tab.
2. **Wire `[:phoenix, :live_view, :mount, :stop]` and `[:phoenix, :live_view, :handle_event, :stop]` telemetry** — add `summary` metrics to `RepoBuilderWeb.Telemetry.metrics/0` so mount + event timings are surfaced in the Phoenix LiveDashboard and trackable in tests.
3. **Add a `Telemetry.Metrics.ConsoleReporter` in dev** — print live mount/event timing to the dev log so regressions are visible immediately.
4. **Write a LiveView integration test** — asserts that (a) ConsoleLive's connected mount completes without querying the log-manager / templates / external-apis data, and (b) those assigns populate only when the matching settings tab is selected.

## Steps to Reproduce

1. Navigate to `http://localhost:4000/` — observe 0.5–2s blank/spinner before content appears.
2. Click "plan a run" then click "← back to console" — same delay on remount.
3. Open Settings → Cost Center — observe a freeze while `CostCenter.rollup/1` and `CostCenter.period_spend/1` run synchronously.
4. Toggle the main view (Logs ↔ ADWs) repeatedly — observe slight lag as a 2380-line LiveView diffs.

## Root Cause Analysis

`ConsoleLive.mount/3` (connected path, `lib/repo_builder_web/live/console_live.ex:315–342`) runs:

```
Projects.list_projects()          → 1 DB query
load_agents()                     → 1 DB query
seed_agent_costs()                → computation
seed_context_tokens()             → computation
seed_counters()                   → computation
seed_lanes()                      → computation
seed_workflow_progress()          → 1 DB query  (50 recent runs)
seed_budget()                     → Budget.Guard.snapshot + 1 DB query
seed_planf3_image_policy()        → 1 computation
assign_orchestrator()             → 1 DB query  (get_or_create_for_project)
seed_cost()                       → 1 DB query
seed_orchestrator_cost()          → 1 DB query
backfill_events()                 → 1 DB query + 200-row CPU processing
seed_log_manager()  ← WASTED     → 2 DB queries (count + select 50)
assign_template_rows() ← WASTED  → 1 DB query
load_external_apis() ← WASTED    → 2 DB queries
seed_definitions()                → file I/O scan
subscribe_feeds()                 → PubSub setup
```

**5 DB queries are wasted on every mount** loading data for closed settings tabs. These are the highest-value cuts. The remaining queries (backfill 200 logs, orchestrator create, cost seeds) are necessary but run sequentially, compounding mount latency.

For `select_settings_tab` → `cost_center`: `Shared.load_cost_center/1` calls `CostCenter.rollup/1` and `CostCenter.period_spend/1` synchronously (lines 42–60 of `shared.ex`). These are aggregation queries that can be slow on large `agent_logs` tables.

## Relevant Files

- `lib/repo_builder_web/live/console_live.ex` — mount hot path (lines 314–342); the 17-op sequential chain lives here.
- `lib/repo_builder_web/live/console_live/shared.ex` — `seed_log_manager/1` (line 750), `assign_template_rows/1` (line 414), `backfill_events/1` (line 466), `seed_workflow_progress/1` (line 777), `load_cost_center/1` (line 42).
- `lib/repo_builder_web/live/console_live/external_apis_panel.ex` — `load_external_apis/1` (line 119).
- `lib/repo_builder_web/live/console_live/settings_panel.ex` — `handle_event("select_settings_tab", ...)` (line 165); lazy-load hooks go here.
- `lib/repo_builder_web/telemetry.ex` — `metrics/0`; LiveView mount/event metrics added here.
- `mix.exs` — no new dependencies needed.

### New Files

- `test/repo_builder_web/live/test_console_live_perf_test.exs` — LiveView integration test verifying lazy loading + mount does not populate closed-tab assigns.

## Step by Step Tasks

### 1. Remove `seed_log_manager` from the connected mount path

In `lib/repo_builder_web/live/console_live.ex`, delete `|> Shared.seed_log_manager()` from the connected mount pipeline (line ~334). The Logs tab starts with `log_mgr_rows: [], log_mgr_total: 0` (already the mount default) and loads on demand.

### 2. Remove `assign_template_rows` from the connected mount path

Delete `|> Shared.assign_template_rows()` from the connected mount pipeline (line ~335). `template_rows: []` is already the default.

### 3. Remove `load_external_apis` from the connected mount path

Delete `|> ExternalApisPanel.load_external_apis()` from the connected mount pipeline (line ~336). `user_apis: [], project_apis: []` are already the defaults.

### 4. Lazy-load each removed seed when its settings tab opens

In `lib/repo_builder_web/live/console_live/settings_panel.ex`, extend `handle_event("select_settings_tab", ...)` (line 165):

```elixir
def handle_event("select_settings_tab", %{"tab" => tab}, socket) do
  selected = settings_tab(tab)
  socket = assign(socket, :settings_tab, selected)

  socket =
    case selected do
      :cost_center -> Shared.load_cost_center(socket)      # already present
      :logs -> Shared.seed_log_manager(socket)              # NEW
      :templates -> Shared.assign_template_rows(socket)     # NEW
      :external_apis -> ExternalApisPanel.load_external_apis(socket)  # NEW
      _ -> socket
    end

  {:noreply, socket}
end
```

No other changes needed — `refresh_cost_center_on_tz/1` already guards `:cost_center` only.

### 5. Add LiveView mount + handle_event telemetry metrics

In `lib/repo_builder_web/telemetry.ex`, add to the `metrics/0` list after the Phoenix channel metrics:

```elixir
# LiveView performance metrics
summary("phoenix.live_view.mount.stop.duration",
  tags: [:view],
  unit: {:native, :millisecond},
  description: "Time for a LiveView mount to complete"
),
summary("phoenix.live_view.handle_event.stop.duration",
  tags: [:view, :event],
  unit: {:native, :millisecond},
  description: "Time for a LiveView handle_event to complete"
),
summary("phoenix.live_view.handle_params.stop.duration",
  tags: [:view],
  unit: {:native, :millisecond},
  description: "Time for a LiveView handle_params to complete"
),
```

Also uncomment (or add) the `Telemetry.Metrics.ConsoleReporter` as a child in `init/1` — **only in dev** — so mount times print to the server log:

```elixir
# In init/1, inside the children list, add:
if Mix.env() == :dev do
  [{Telemetry.Metrics.ConsoleReporter, metrics: liveview_metrics()}]
end
```

Add a private `liveview_metrics/0` that returns the three new LiveView summaries only (avoid reprinting DB/Oban metrics that are already verbose).

### 6. Write a LiveView integration test

Create `test/repo_builder_web/live/test_console_live_perf_test.exs`:

```elixir
defmodule RepoBuilderWeb.ConsoleLivePerf do
  @moduledoc """
  Verifies that settings-tab data is lazily loaded (not on mount) so the
  mount hot path does not run unnecessary DB queries.
  """
  use RepoBuilderWeb.ConnCase

  import Phoenix.LiveViewTest

  describe "ConsoleLive lazy loading" do
    test "mount does not populate log_mgr_rows (Logs tab is closed)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")
      assert lv |> element("body") |> render() =~ "console"
      # log_mgr_rows starts empty — the DB query has not run
      state = :sys.get_state(lv.pid)
      assert state.socket.assigns.log_mgr_rows == []
      assert state.socket.assigns.log_mgr_total == 0
    end

    test "mount does not populate template_rows (Templates tab is closed)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")
      state = :sys.get_state(lv.pid)
      assert state.socket.assigns.template_rows == []
    end

    test "mount does not populate user_apis (External APIs tab is closed)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")
      state = :sys.get_state(lv.pid)
      assert state.socket.assigns.user_apis == []
    end

    test "opening Logs settings tab populates log_mgr_rows", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")
      # Trigger the settings panel open + tab select
      lv |> element("[phx-click='open_settings']") |> render_click()
      lv |> element("[phx-click='select_settings_tab'][phx-value-tab='logs']") |> render_click()
      state = :sys.get_state(lv.pid)
      # After tab selection, log_mgr_rows may be empty (no logs in test DB) but the query ran
      assert is_list(state.socket.assigns.log_mgr_rows)
      assert is_integer(state.socket.assigns.log_mgr_total)
    end

    test "opening Templates tab populates template_rows", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")
      lv |> element("[phx-click='open_settings']") |> render_click()
      lv |> element("[phx-click='select_settings_tab'][phx-value-tab='templates']") |> render_click()
      state = :sys.get_state(lv.pid)
      assert is_list(state.socket.assigns.template_rows)
    end

    test "opening External APIs tab populates user_apis", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")
      lv |> element("[phx-click='open_settings']") |> render_click()
      lv |> element("[phx-click='select_settings_tab'][phx-value-tab='external_apis']") |> render_click()
      state = :sys.get_state(lv.pid)
      assert is_list(state.socket.assigns.user_apis)
    end
  end
end
```

Adjust the `phx-click` selectors to match the actual button attributes in `console_live.ex` if they differ (check with `grep -n "open_settings\|select_settings_tab" lib/repo_builder_web/live/console_live/settings_panel.ex`).

### 7. Run validation commands

Verify nothing broke and timing improvement is visible in the dev log.

## Validation Commands

```sh
mix test test/repo_builder_web/live/test_console_live_perf_test.exs
```

- `mix compile --warnings-as-errors` - Compile clean; the gradual set-theoretic type checker and `warnings_as_errors` must pass.
- `mix test --warnings-as-errors` - Run the full ExUnit suite (spawns Postgres-backed cases) with zero failures.
- `mix format --check-formatted` - Ensure code is formatted.
- `mix credo --strict` - Lint, including the "every public function has an `@spec`" convention.
- `mix dialyzer` - `@spec`/contract checking with no new warnings and no stale ignore filters.

**Manual verification:** Start the dev server (`mix phx.server`), open `http://localhost:4000/`, and confirm in the server log that mount completes (3 fewer DB queries in the logged SQL). Open Settings → Logs / Templates / External APIs and confirm the queries run at that point instead of on mount. The `ConsoleReporter` should print mount durations to confirm the speedup.

## Notes

- The three removed queries (`seed_log_manager`, `assign_template_rows`, `load_external_apis`) sum to **5 DB round-trips** cut from every page load. On a local dev machine this may save 10–50ms; on a loaded DB it can be much more.
- `Shared.seed_log_manager/1` is already called via `Shared.refresh_log_manager/1` on any log DB browser action — no other callsite needs updating.
- `Shared.assign_template_rows/1` is already referenced in the settings panel refresh path — check all callsites with `grep -rn "assign_template_rows"` to ensure none break.
- `ExternalApisPanel.load_external_apis/1` is already called in `handle_event("save_api", ...)` and `handle_event("delete_api", ...)` for post-action refresh — those stay.
- The `CostCenter.rollup/1` aggregation (triggered by the Cost Center tab) is intentionally left synchronous for now: it is only called on user action, not on mount. A follow-up could wrap it in `start_async` if the aggregation is slow on large datasets.
- LiveView telemetry events (`[:phoenix, :live_view, :mount, :stop]`) are emitted by Phoenix LiveView automatically — no custom instrumentation is needed in ConsoleLive itself, only the metric registration in `RepoBuilderWeb.Telemetry`.
- The `Telemetry.Metrics.ConsoleReporter` in dev is **not** a supervision concern — add it inside a compile-time `if Mix.env() == :dev` guard or in `config/dev.exs` children injection to prevent it loading in prod/test.
