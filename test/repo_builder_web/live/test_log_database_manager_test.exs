defmodule RepoBuilderWeb.TestLogDatabaseManagerTest do
  @moduledoc """
  LiveView integration for the Log Database manager (issue-log-db-manager): the moved
  hidden-log controls live in their own settings tab; the manager popup paginates and
  filters `agent_logs`, supports single + drag selection that persists across pages, and
  drives make-visible/invisible, purge-selected, and the guarded purge-all — all through
  the `RepoBuilder.Logs` context (the web layer never touches `Repo`).

  The raw pointer drag is browser-only; the committed `log_select_drag` event is driven via
  `render_hook/3`. DB effects are asserted by reading back through `RepoBuilder.Logs`.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Agents
  alias RepoBuilder.Harness.Event
  alias RepoBuilder.Logs

  defp agent_fixture do
    {:ok, agent} =
      Agents.create_agent(%{
        name: "w-#{System.unique_integer([:positive])}",
        harness: "fake",
        provider: "anthropic"
      })

    agent
  end

  # Persist `n` rows for one agent and return the inserted log structs (oldest-first).
  defp seed_logs(agent_id, n) do
    for i <- 1..n do
      {:ok, log} =
        Logs.persist_event(
          %Event.TextDelta{harness: :fake, text: "row-#{i}", thinking?: false},
          %{agent_id: agent_id, session_id: "s"}
        )

      log
    end
  end

  defp open_log_tab(view) do
    render_click(view, "select_settings_tab", %{"tab" => "logs"})
  end

  describe "settings tab move" do
    test "the hidden-log controls render in the Log Database tab, not in General", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # General tab is the default — the moved controls are absent there.
      general = render(view)
      refute general =~ "settings-release-hidden"
      refute general =~ "settings-show-hidden"

      logs_html = open_log_tab(view)
      assert logs_html =~ "settings-release-hidden"
      assert logs_html =~ "settings-show-hidden"
      assert logs_html =~ "open-log-manager"
      assert logs_html =~ "settings-purge-all-logs"
    end
  end

  describe "manager: open, filter, paginate" do
    test "opens with newest-first rows and a rows X–Y of N label", %{conn: conn} do
      agent = agent_fixture()
      seed_logs(agent.id, 3)

      {:ok, view, _html} = live(conn, "/")
      html = render_click(view, "open_log_manager", %{})

      assert html =~ "log-manager-modal"
      assert html =~ "rows 1–3 of 3"
      assert html =~ "log-mgr-row-"
    end

    test "the All/Visible/Hidden filter switches the row set and count", %{conn: conn} do
      agent = agent_fixture()
      logs = seed_logs(agent.id, 4)
      [a, b | _] = logs
      assert Logs.hide_logs([a.id, b.id]) == 2

      {:ok, view, _html} = live(conn, "/")
      render_click(view, "open_log_manager", %{})

      hidden = render_click(view, "select_log_filter", %{"filter" => "hidden"})
      assert hidden =~ "rows 1–2 of 2"
      assert hidden =~ "log-mgr-row-#{a.id}"
      assert hidden =~ "log-mgr-row-#{b.id}"

      visible = render_click(view, "select_log_filter", %{"filter" => "visible"})
      assert visible =~ "rows 1–2 of 2"
      refute visible =~ "log-mgr-row-#{a.id}"

      all = render_click(view, "select_log_filter", %{"filter" => "all"})
      assert all =~ "rows 1–4 of 4"
    end

    test "Prev/Next paginate the window", %{conn: conn} do
      agent = agent_fixture()
      seed_logs(agent.id, 60)

      {:ok, view, _html} = live(conn, "/")
      render_click(view, "open_log_manager", %{})

      first = render(view)
      assert first =~ "rows 1–50 of 60"

      second = render_click(view, "log_page_next", %{})
      assert second =~ "rows 51–60 of 60"

      back = render_click(view, "log_page_prev", %{})
      assert back =~ "rows 1–50 of 60"
    end

    test "empty store shows an empty state and 0 of 0", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      html = render_click(view, "open_log_manager", %{})
      assert html =~ "No log rows for this filter."
      assert html =~ "rows 0–0 of 0"
    end
  end

  describe "manager: selection + mutations" do
    test "single-click selection shows the action bar count", %{conn: conn} do
      agent = agent_fixture()
      [log | _] = seed_logs(agent.id, 2)

      {:ok, view, _html} = live(conn, "/")
      render_click(view, "open_log_manager", %{})

      html = render_click(view, "log_toggle_select", %{"id" => log.id})
      assert html =~ "1 selected"
    end

    test "drag selection unions ids and survives a page change", %{conn: conn} do
      agent = agent_fixture()
      logs = seed_logs(agent.id, 60)
      [first_id | _] = Enum.map(logs, & &1.id)
      page2_id = Enum.at(logs, 5).id

      {:ok, view, _html} = live(conn, "/")
      render_click(view, "open_log_manager", %{})

      # Two ids from across pages, committed as one drag.
      html =
        render_hook(view, "log_select_drag", %{"ids" => [first_id, page2_id], "mode" => "select"})

      assert html =~ "2 selected"

      # Paginating does not lose the selection (MapSet persists across pages).
      paged = render_click(view, "log_page_next", %{})
      assert paged =~ "2 selected"
    end

    test "make-invisible then make-visible flips hidden in the DB", %{conn: conn} do
      agent = agent_fixture()
      [log | _] = seed_logs(agent.id, 2)

      {:ok, view, _html} = live(conn, "/")
      render_click(view, "open_log_manager", %{})
      render_click(view, "log_toggle_select", %{"id" => log.id})

      render_click(view, "log_make_invisible", %{})
      assert Logs.count_agent_logs(:hidden) == 1
      assert log.id in (Logs.query_agent_logs(:hidden, 50, 0) |> Enum.map(& &1.id))

      # Selection cleared after a mutation; re-select to flip back.
      render_click(view, "select_log_filter", %{"filter" => "hidden"})
      render_click(view, "log_toggle_select", %{"id" => log.id})
      render_click(view, "log_make_visible", %{})
      assert Logs.count_agent_logs(:hidden) == 0
    end

    test "purge selected hard-deletes the rows", %{conn: conn} do
      agent = agent_fixture()
      [a, b, _c] = seed_logs(agent.id, 3)

      {:ok, view, _html} = live(conn, "/")
      render_click(view, "open_log_manager", %{})
      render_hook(view, "log_select_drag", %{"ids" => [a.id, b.id], "mode" => "select"})

      html = render_click(view, "log_purge_selected", %{})
      assert Logs.count_agent_logs(:all) == 1
      assert html =~ "rows 1–1 of 1"
      refute html =~ "log-mgr-row-#{a.id}"
    end

    test "purge ALL empties the store", %{conn: conn} do
      agent = agent_fixture()
      seed_logs(agent.id, 5)

      {:ok, view, _html} = live(conn, "/")
      render_click(view, "open_log_manager", %{})

      html = render_click(view, "purge_all_logs", %{})
      assert Logs.count_agent_logs(:all) == 0
      assert html =~ "rows 0–0 of 0"
    end
  end
end
