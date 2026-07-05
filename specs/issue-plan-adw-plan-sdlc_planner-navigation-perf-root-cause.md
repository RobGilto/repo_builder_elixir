# Chore: Fix navigation performance — live_session grouping + batch cost rollup

## Metadata
adw_id: `plan`

## Description

Cross-page navigation (e.g. console → plan a run → back to console) causes a noticeable
0.5–2 s freeze every time you return to `/`. Git bisect and code analysis isolate two root
causes:

1. **No `live_session` grouping in the router** — the primary cause of every cross-LiveView
   navigation paying the full ConsoleLive mount cost (~17 sequential operations, 8+ DB
   queries). Without `live_session`, Phoenix LiveView cannot reuse the WebSocket transport
   between route changes, so clicking "← back to console" after visiting `/plan` forces a
   full HTTP dead-render + new WebSocket connection + cold ConsoleLive mount.

2. **N+1 queries in `seed_agent_costs/1`** — `Logs.cost_rollup!(agent_id)` is called once
   per agent (one full `SELECT * FROM agent_logs WHERE agent_id = $1` per agent). With 10
   agents that is 10 sequential full-table-per-agent scans on every mount.

Both issues pre-date the work done in this session (the session's commits only touched
`planning_live.ex` and the "plan a run" link). They are latent architectural gaps.

## Problem Statement

- `navigate=` between routes that belong to **different `live_session` groups** (or no
  group at all, as is the case here) is equivalent to `href=` from a transport perspective:
  the browser follows the URL, Phoenix renders the dead HTML, and a new WebSocket
  connection is established. The existing session is torn down.
- Every return to `/` therefore pays the full `ConsoleLive.mount/3` cost including:
  `Projects.list_projects`, `load_agents`, `assign_orchestrator` (DB create-or-get),
  `seed_workflow_progress` (50 runs), `seed_budget`, `backfill_events` (200 logs + row
  processing), `seed_log_manager` (2 queries for a closed tab), `assign_template_rows`
  (closed tab), `load_external_apis` (2 queries, closed tab), file I/O for definitions —
  all sequential, all blocking the first render.
- `seed_agent_costs/1` compounds this: it issues N independent `SELECT *` queries against
  `agent_logs`, one per agent, during mount.

## Solution Statement

### Primary fix — `live_session` in the router

Wrap all browser-facing LiveView routes inside a single `live_session` block in
`RepoBuilderWeb.Router`. This tells Phoenix to reuse the existing WebSocket transport when
navigating between routes in the same session. A `navigate=` from `/` to `/plan` and back
becomes a lightweight process swap — the transport layer stays up and the browser never
re-establishes a connection. ConsoleLive's mount is only paid **once** per browser tab, not
once per navigation visit.

No `on_mount` callback is required: the app has no authentication guard and no session-
scoped data to inject. The `live_session` call needs only a name.

### Secondary fix — batch cost rollup

Add `Logs.cost_rollup_for_agents!/1` that fetches agent costs in a **single grouped
query** (`GROUP BY agent_id, SUM`) and returns a map `%{agent_id => Decimal.t()}`. Replace
the `Map.new/2` + `cost_rollup!` loop in `seed_agent_costs/1` with a single call.

### Supporting fix — lazy-load closed-tab seeds (from bug plan)

Remove `seed_log_manager`, `assign_template_rows`, and `load_external_apis` from the
connected mount chain and trigger them lazily on tab open (already analysed in
`issue-perf-adw-console-live-mount-lag-sdlc_planner-console-mount-perf.md`). Combine
both fixes in one PR.

### Telemetry

Add `[:phoenix, :live_view, :mount, :stop]` and `[:phoenix, :live_view, :handle_event,
:stop]` summary metrics to `RepoBuilderWeb.Telemetry.metrics/0` so mount timing is visible
in the Phoenix LiveDashboard. This makes regressions measurable going forward.

## Relevant Files

- `lib/repo_builder_web/router.ex` — **primary change**: wrap all `live` routes in a
  `live_session` block. This is a one-line-plus-indent change with large impact.
- `lib/repo_builder/logs.ex` — add `cost_rollup_for_agents!/1` batch query (one `GROUP
  BY` query instead of N individual scans).
- `lib/repo_builder_web/live/console_live.ex` — update `seed_agent_costs/1` to call the
  new batch function; remove `seed_log_manager`, `assign_template_rows`,
  `load_external_apis` from the connected mount chain.
- `lib/repo_builder_web/live/console_live/shared.ex` — `seed_log_manager/1` and
  `assign_template_rows/1` unchanged but no longer called from mount.
- `lib/repo_builder_web/live/console_live/external_apis_panel.ex` —
  `load_external_apis/1` unchanged but no longer called from mount.
- `lib/repo_builder_web/live/console_live/settings_panel.ex` — extend
  `handle_event("select_settings_tab", ...)` to lazy-load the three removed seeds on tab
  open.
- `lib/repo_builder_web/telemetry.ex` — add LiveView mount/event summary metrics.
- `lib/repo_builder/telemetry/live_view_perf.ex` — **new** telemetry handler that attaches
  to `[:phoenix, :live_view, :mount, :stop]`, `[:phoenix, :live_view, :handle_event, :stop]`,
  and `[:phoenix, :live_view, :handle_params, :stop]` and emits structured `Logger.info`
  timing lines in dev, making mount durations visible in the server log without a separate
  reporter process.
- `test/support/telemetry_capture.ex` — **new** test helper that subscribes to LiveView
  telemetry events during a test, collects measurements, and provides `assert_mount_under/3`
  and `assert_event_under/4` helpers for timing assertions.

### New Files

- `lib/repo_builder/telemetry/live_view_perf.ex` — structured telemetry handler (dev-only
  attachment via `Application.start/2` hook in `config/dev.exs`).
- `test/support/telemetry_capture.ex` — test-time telemetry capture helper.
- `test/repo_builder_web/live/test_navigation_perf_test.exs` — LiveView integration test:
  (a) verifies cross-route navigation stays within the same live_session transport, (b)
  asserts closed-tab assigns are NOT populated on mount, (c) asserts they ARE populated
  after the matching tab is opened, (d) asserts ConsoleLive mount completes under 500 ms,
  (e) asserts `toggle_view` handle_event completes under 50 ms.

## Step by Step Tasks

### 1. Add `live_session` to the router

In `lib/repo_builder_web/router.ex`, wrap the `scope "/", RepoBuilderWeb` block's `live`
routes inside `live_session`:

```elixir
scope "/", RepoBuilderWeb do
  pipe_through :browser

  live_session :app do
    live "/", ConsoleLive
    live "/dashboard", DashboardLive
    live "/agents/:id", AgentLive
    live "/workflows/:id", WorkflowLive
    live "/system-logs", SystemLogsLive
    live "/projects", ProjectsLive, :index
    live "/projects/:id", ProjectsLive, :show
    live "/plan", PlanningLive, :new
    live "/plans/:id", PlanningLive, :show
    live "/plugins", PluginsLive
    live "/forge", ForgeLive
  end
end
```

No `on_mount` is needed. The session name `:app` is arbitrary. After this change,
`navigate=` between any of these routes reuses the same WebSocket transport — ConsoleLive
only remounts when the browser tab is opened fresh, not on every link click.

### 2. Add `Logs.cost_rollup_for_agents!/1` batch query

In `lib/repo_builder/logs.ex`, add after `cost_rollup!/1`:

```elixir
@doc """
Cost rollup for a set of agent ids in a single grouped query.
Returns `%{agent_id_string => Decimal.t()}` for every id in `agent_ids` that has
priced logs; absent ids are not in the map (caller treats them as unpriced/zero).
"""
@spec cost_rollup_for_agents!([Ecto.UUID.t()]) :: %{String.t() => Decimal.t()}
def cost_rollup_for_agents!([]), do: %{}

def cost_rollup_for_agents!(agent_ids) do
  AgentLog
  |> where([l], l.agent_id in ^agent_ids)
  |> group_by([l], l.agent_id)
  |> select([l], {l.agent_id, sum(fragment("COALESCE((usage->>'cost_usd')::numeric, 0)"))})
  |> Repo.all()
  |> Map.new(fn {id, sum} -> {id, Decimal.new(to_string(sum))} end)
end
```

Note: The existing `cost_rollup!/1` loads all rows and sums in Elixir via `add_cost/2` to
handle the `usage` JSONB structure. Replicate the same aggregation in SQL using a
`COALESCE` fragment on `usage->>'cost_usd'`. Verify the fragment produces the same result
as `add_cost/2` by checking `add_cost/2`'s implementation. If the JSONB path differs,
adjust the fragment accordingly.

Also add `@spec` for `cost_rollup!/1` if missing.

### 3. Update `seed_agent_costs/1` to use the batch query

In `lib/repo_builder_web/live/console_live.ex`, replace:

```elixir
defp seed_agent_costs(socket) do
  costs = Map.new(socket.assigns.agents, &{&1.id, nilify_zero(Logs.cost_rollup!(&1.id))})
  assign(socket, :agent_costs, costs)
end
```

With:

```elixir
defp seed_agent_costs(socket) do
  agent_ids = Enum.map(socket.assigns.agents, & &1.id)
  rollups = Logs.cost_rollup_for_agents!(agent_ids)
  costs = Map.new(agent_ids, fn id -> {id, nilify_zero(Map.get(rollups, id, Decimal.new(0)))} end)
  assign(socket, :agent_costs, costs)
end
```

### 4. Remove closed-tab seeds from the connected mount chain

In `lib/repo_builder_web/live/console_live.ex`, remove from the connected mount pipeline
(lines ~334–336):

```elixir
# REMOVE these three lines:
|> Shared.seed_log_manager()
|> Shared.assign_template_rows()
|> ExternalApisPanel.load_external_apis()
```

The mount defaults (`log_mgr_rows: [], log_mgr_total: 0, template_rows: [], user_apis: [],
project_apis: []`) are already set in the disconnected assign block — no change needed
there.

### 5. Lazy-load removed seeds on settings tab open

In `lib/repo_builder_web/live/console_live/settings_panel.ex`, extend
`handle_event("select_settings_tab", ...)`:

```elixir
def handle_event("select_settings_tab", %{"tab" => tab}, socket) do
  selected = settings_tab(tab)
  socket = assign(socket, :settings_tab, selected)

  socket =
    case selected do
      :cost_center  -> Shared.load_cost_center(socket)
      :logs         -> Shared.seed_log_manager(socket)
      :templates    -> Shared.assign_template_rows(socket)
      :external_apis -> ExternalApisPanel.load_external_apis(socket)
      _             -> socket
    end

  {:noreply, socket}
end
```

Ensure `ExternalApisPanel` is already aliased/imported in `settings_panel.ex` — if not,
add the alias.

### 6. Register LiveView telemetry metrics

In `lib/repo_builder_web/telemetry.ex`, add to `metrics/0` after the channel metrics:

```elixir
# LiveView performance — visible in Phoenix LiveDashboard at /dev/dashboard
summary("phoenix.live_view.mount.stop.duration",
  tags: [:view],
  unit: {:native, :millisecond},
  description: "Wall-clock time for a LiveView mount (connected phase) to complete"
),
summary("phoenix.live_view.handle_event.stop.duration",
  tags: [:view, :event],
  unit: {:native, :millisecond},
  description: "Wall-clock time for a LiveView handle_event callback to complete"
),
summary("phoenix.live_view.handle_params.stop.duration",
  tags: [:view],
  unit: {:native, :millisecond},
  description: "Wall-clock time for a LiveView handle_params callback to complete"
),
```

### 7. Create `RepoBuilder.Telemetry.LiveViewPerf` handler module

Create `lib/repo_builder/telemetry/live_view_perf.ex`:

```elixir
defmodule RepoBuilder.Telemetry.LiveViewPerf do
  @moduledoc """
  Attaches structured Logger.info timing lines for LiveView mount,
  handle_event, and handle_params. Active only in `:dev` — attach via
  `config/dev.exs` so test/prod are unaffected.

  Emits lines like:
    [lv_perf] mount ConsoleLive 312 ms
    [lv_perf] event ConsoleLive toggle_view 3 ms
  """

  require Logger

  @events [
    [:phoenix, :live_view, :mount, :stop],
    [:phoenix, :live_view, :handle_event, :stop],
    [:phoenix, :live_view, :handle_params, :stop]
  ]

  @spec attach() :: :ok
  def attach do
    :telemetry.attach_many(
      "repo-builder-lv-perf",
      @events,
      &__MODULE__.handle_event/4,
      nil
    )

    :ok
  end

  @spec detach() :: :ok
  def detach do
    :telemetry.detach("repo-builder-lv-perf")
    :ok
  end

  @spec handle_event(
          [atom()],
          %{duration: non_neg_integer()},
          map(),
          nil
        ) :: :ok
  def handle_event([:phoenix, :live_view, :mount, :stop], %{duration: duration}, meta, _cfg) do
    view = short_name(meta[:socket])
    ms = System.convert_time_unit(duration, :native, :millisecond)
    Logger.info("[lv_perf] mount #{view} #{ms} ms")
  end

  def handle_event(
        [:phoenix, :live_view, :handle_event, :stop],
        %{duration: duration},
        %{event: event} = meta,
        _cfg
      ) do
    view = short_name(meta[:socket])
    ms = System.convert_time_unit(duration, :native, :millisecond)
    Logger.info("[lv_perf] event #{view} #{event} #{ms} ms")
  end

  def handle_event(
        [:phoenix, :live_view, :handle_params, :stop],
        %{duration: duration},
        meta,
        _cfg
      ) do
    view = short_name(meta[:socket])
    ms = System.convert_time_unit(duration, :native, :millisecond)
    Logger.info("[lv_perf] params #{view} #{ms} ms")
  end

  @spec short_name(Phoenix.LiveView.Socket.t() | nil) :: String.t()
  defp short_name(%{view: view}) when is_atom(view) do
    view |> Module.split() |> List.last()
  end

  defp short_name(_), do: "unknown"
end
```

Attach it in `config/dev.exs` by adding to the existing dev-only startup (e.g., after the
`Repo` config):

```elixir
# Attach LiveView perf telemetry handler in dev for timing visibility
config :repo_builder, :lv_perf_handler, attach: true
```

Then in `lib/repo_builder/application.ex`, call `attach` when the config flag is set:

```elixir
if Application.get_env(:repo_builder, :lv_perf_handler)[:attach] do
  RepoBuilder.Telemetry.LiveViewPerf.attach()
end
```

### 8. Create `TelemetryCapture` test support helper

Create `test/support/telemetry_capture.ex`:

```elixir
defmodule RepoBuilderWeb.TelemetryCapture do
  @moduledoc """
  Test helper for capturing LiveView telemetry events and asserting
  timing thresholds. Usage:

      TelemetryCapture.capture(fn ->
        {:ok, lv, _} = live(conn, ~p"/")
        render(lv)
      end)
      |> TelemetryCapture.assert_mount_under(ConsoleLive, 500)
  """

  @lv_events [
    [:phoenix, :live_view, :mount, :stop],
    [:phoenix, :live_view, :handle_event, :stop],
    [:phoenix, :live_view, :handle_params, :stop]
  ]

  @type measurement :: %{
          event: [atom()],
          measurements: map(),
          metadata: map(),
          duration_ms: non_neg_integer()
        }

  @spec capture((() -> any())) :: [measurement()]
  def capture(fun) do
    ref = make_ref()
    test_pid = self()

    handler_id = "telemetry-capture-#{inspect(ref)}"

    :telemetry.attach_many(
      handler_id,
      @lv_events,
      fn event, measurements, metadata, _ ->
        ms = System.convert_time_unit(measurements[:duration], :native, :millisecond)
        send(test_pid, {:tel_event, ref, %{event: event, measurements: measurements, metadata: metadata, duration_ms: ms}})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    collect_events(ref)
  end

  @spec assert_mount_under([measurement()], module(), pos_integer()) :: [measurement()]
  def assert_mount_under(events, view_module, max_ms) do
    mounts =
      Enum.filter(events, fn e ->
        e.event == [:phoenix, :live_view, :mount, :stop] and
          match?(%{socket: %{view: ^view_module}}, e.metadata)
      end)

    assert mounts != [], "No mount event captured for #{inspect(view_module)}"

    Enum.each(mounts, fn e ->
      assert e.duration_ms <= max_ms,
             "#{inspect(view_module)} mount took #{e.duration_ms} ms, expected <= #{max_ms} ms"
    end)

    events
  end

  @spec assert_event_under([measurement()], module(), String.t(), pos_integer()) ::
          [measurement()]
  def assert_event_under(events, view_module, event_name, max_ms) do
    matching =
      Enum.filter(events, fn e ->
        e.event == [:phoenix, :live_view, :handle_event, :stop] and
          e.metadata[:event] == event_name and
          match?(%{socket: %{view: ^view_module}}, e.metadata)
      end)

    assert matching != [],
           "No handle_event '#{event_name}' captured for #{inspect(view_module)}"

    Enum.each(matching, fn e ->
      assert e.duration_ms <= max_ms,
             "#{inspect(view_module)} #{event_name} took #{e.duration_ms} ms, expected <= #{max_ms} ms"
    end)

    events
  end

  # Drain the mailbox of captured events (non-blocking after the fun completes).
  @spec collect_events(reference()) :: [measurement()]
  defp collect_events(ref) do
    collect_events(ref, [])
  end

  defp collect_events(ref, acc) do
    receive do
      {:tel_event, ^ref, event} -> collect_events(ref, [event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
```

### 9. Write the navigation performance integration test

Create `test/repo_builder_web/live/test_navigation_perf_test.exs`:

```elixir
defmodule RepoBuilderWeb.NavigationPerfTest do
  @moduledoc """
  Regression tests for the live_session grouping and lazy-load fixes.

  These tests verify behaviour that was previously broken:
  1. Settings-tab data is NOT loaded on mount (wasted DB queries eliminated).
  2. Settings-tab data IS loaded when the matching tab is opened.
  3. Cross-route navigation via navigate= reuses the same socket process
     (live_session ensures this — if broken, navigate/2 raises or remounts).
  4. ConsoleLive mount duration stays under 500 ms in the test environment.
  5. toggle_view handle_event stays under 50 ms.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilderWeb.TelemetryCapture

  describe "ConsoleLive lazy tab loading" do
    test "log_mgr_rows not populated on mount", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")
      state = :sys.get_state(lv.pid)
      assert state.socket.assigns.log_mgr_rows == []
      assert state.socket.assigns.log_mgr_total == 0
    end

    test "template_rows not populated on mount", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")
      state = :sys.get_state(lv.pid)
      assert state.socket.assigns.template_rows == []
    end

    test "user_apis not populated on mount", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")
      state = :sys.get_state(lv.pid)
      assert state.socket.assigns.user_apis == []
    end
  end

  describe "cross-route navigation within live_session" do
    test "navigate from / to /plan and back succeeds without full remount", %{conn: conn} do
      {:ok, _console_lv, _html} = live(conn, ~p"/")
      {:ok, _plan_lv, _} = live(conn, ~p"/plan")
      {:ok, _console_lv2, html} = live(conn, ~p"/")
      assert html =~ "console"
    end
  end

  describe "mount timing" do
    test "ConsoleLive mount completes under 500 ms", %{conn: conn} do
      TelemetryCapture.capture(fn ->
        {:ok, lv, _} = live(conn, ~p"/")
        render(lv)
      end)
      |> TelemetryCapture.assert_mount_under(RepoBuilderWeb.ConsoleLive, 500)
    end

    test "PlanningLive mount completes under 100 ms (pre-selected project)", %{conn: conn} do
      # Navigate directly with project_id so it skips the project list query
      TelemetryCapture.capture(fn ->
        {:ok, lv, _} = live(conn, ~p"/plan")
        render(lv)
      end)
      |> TelemetryCapture.assert_mount_under(RepoBuilderWeb.PlanningLive, 100)
    end
  end

  describe "handle_event timing" do
    test "toggle_view completes under 50 ms", %{conn: conn} do
      {:ok, lv, _} = live(conn, ~p"/")

      TelemetryCapture.capture(fn ->
        lv |> element("[phx-click='toggle_view']") |> render_click()
      end)
      |> TelemetryCapture.assert_event_under(RepoBuilderWeb.ConsoleLive, "toggle_view", 50)
    end
  end
end
```

### 10. Run validation commands

```sh
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix test test/repo_builder_web/live/test_navigation_perf_test.exs
mix test --warnings-as-errors
mix dialyzer
```

**Manual check:** start `mix phx.server`, open `http://localhost:4000/`, watch the server log — you should see `[lv_perf] mount ConsoleLive N ms` lines and confirm N drops noticeably compared to pre-fix. Navigate to `/plan` and back; confirm no second WebSocket handshake in browser DevTools → Network → WS.

## Acceptance Criteria

- Clicking "plan a run" from the console and returning via "← back to console" no longer
  triggers a full WebSocket reconnection — the browser DevTools Network tab shows no new
  WebSocket handshake.
- ConsoleLive's connected mount no longer calls `seed_log_manager`, `assign_template_rows`,
  or `load_external_apis` (verifiable via the Ecto query log, which should show 5 fewer
  queries on mount).
- `seed_agent_costs` issues exactly 1 DB query regardless of agent count.
- All new tests in `test_navigation_perf_test.exs` pass.
- Full `mix test` suite green.

## Validation Commands

```sh
mix test test/repo_builder_web/live/test_navigation_perf_test.exs
```

- `mix compile --warnings-as-errors` - Compile clean; gradual checker + warnings-as-errors pass.
- `mix test --warnings-as-errors` - Full ExUnit suite, zero failures.
- `mix format --check-formatted` - Formatting.
- `mix credo --strict` - Lint incl. the `@spec` convention.
- `mix dialyzer` - Contract checking, no new warnings.

**Manual verification:** Open browser DevTools → Network → WS tab. Navigate `/` → `/plan`
→ `/`. With `live_session` there should be **one** WebSocket connection entry that stays
open for all three pages. Without it (the current broken state) you see a new WS per
navigation.

## Notes

- The `live_session` fix is a **one-block change** in the router with zero changes to any
  LiveView module — it works by giving Phoenix the information it needs to reuse the
  transport layer it was already capable of reusing.
- The `live_session` name (`:app`) can be anything. If the app later adds authentication,
  add an `on_mount` hook inside the same `live_session` to gate all routes uniformly.
- `Logs.cost_rollup_for_agents!/1` returns an empty map for empty input — the guard
  `do: %{}` avoids a `WHERE agent_id IN ()` SQL error on projects with no agents.
- The JSONB aggregation fragment `(usage->>'cost_usd')::numeric` must match how
  `add_cost/2` extracts the cost from `log.usage`. Verify by grepping `add_cost` and
  the `Usage` struct definition in `lib/repo_builder/logs/usage.ex` (or similar).
- The three removed mount seeds (`seed_log_manager`, `assign_template_rows`,
  `load_external_apis`) were added incrementally as features shipped — there was no
  single "bad" commit. They accumulate silently because each one looks cheap in isolation.
  The `live_session` fix eliminates the repeated cost on navigation; the lazy-load fix
  eliminates it even on cold mounts.
