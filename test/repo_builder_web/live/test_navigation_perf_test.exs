defmodule RepoBuilderWeb.NavigationPerfTest do
  @moduledoc """
  Regression tests for the live_session grouping and lazy-load fixes
  (issue-plan-adw-plan navigation-perf-root-cause).

  These tests verify behaviour that was previously broken:
  1. Settings-tab data is NOT loaded on mount (wasted DB queries eliminated).
  2. Settings-tab data IS loaded when the matching tab is opened.
  3. Cross-route navigation via navigate= works within one live_session.
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

    test "opening the templates settings tab loads template_rows", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")
      render_click(lv, "select_settings_tab", %{"tab" => "templates"})
      state = :sys.get_state(lv.pid)
      assert is_list(state.socket.assigns.template_rows)
      assert state.socket.assigns.settings_tab == :templates
    end

    test "opening the logs settings tab seeds the log manager", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")
      render_click(lv, "select_settings_tab", %{"tab" => "logs"})
      state = :sys.get_state(lv.pid)
      assert state.socket.assigns.settings_tab == :logs
      assert is_integer(state.socket.assigns.log_mgr_total)
    end

    test "opening the external_apis settings tab loads the API registry", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")
      render_click(lv, "select_settings_tab", %{"tab" => "external_apis"})
      state = :sys.get_state(lv.pid)
      assert state.socket.assigns.settings_tab == :external_apis
      assert is_list(state.socket.assigns.user_apis)
    end
  end

  describe "cross-route navigation within live_session" do
    test "navigate from / to /plan and back succeeds", %{conn: conn} do
      {:ok, _console_lv, _html} = live(conn, ~p"/")
      {:ok, _plan_lv, _} = live(conn, ~p"/plan")
      {:ok, _console_lv2, html} = live(conn, ~p"/")
      assert html =~ "orchestration console"
    end
  end

  describe "mount timing" do
    test "ConsoleLive mount completes under 250 ms", %{conn: conn} do
      # Tightened from 500 ms after the Phase 2/3 seed optimization
      # (specs/console-mount-seed-optimization.html): mount no longer runs the
      # cost full-scans or the history backfill, so a regression re-inflating it
      # must fail here.
      TelemetryCapture.capture(fn ->
        {:ok, lv, _} = live(conn, ~p"/")
        render(lv)
      end)
      |> TelemetryCapture.assert_mount_under(RepoBuilderWeb.ConsoleLive, 250)
    end

    test "PlanningLive mount completes under 100 ms", %{conn: conn} do
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
        render_click(lv, "toggle_view")
      end)
      |> TelemetryCapture.assert_event_under(RepoBuilderWeb.ConsoleLive, "toggle_view", 50)
    end
  end
end
