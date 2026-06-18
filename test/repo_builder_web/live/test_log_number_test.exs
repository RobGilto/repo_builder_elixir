defmodule RepoBuilderWeb.TestLogNumberTest do
  @moduledoc """
  Integration test for the human-readable log number (`log-<n>`) feature (see
  specs/issue-just-adw-need-sdlc_planner-human-readable-log-number.md).

  Every persisted `agent_logs` row carries a durable, best-effort-chronological
  `seq_no` (a Postgres sequence). The console surfaces it as `log-<n>` in the center
  event stream's leading column (the durable log number) and in the event-detail
  drilldown panel. This test drives both paths that fill the drilldown:

    * reconnect-backfill — `Logs.list_recent_global/2` → `log_to_row/4`, and
    * live — the tagged `Dashboard.broadcast_event/3` global feed.

  `async: false` so the shared Ecto sandbox reaches the connected LiveView process.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Agents, Dashboard, Logs}
  alias RepoBuilder.Harness.Event

  defp seed_log(agent_id, text) do
    event = %Event.TextDelta{harness: :fake, text: text, raw: %{"type" => "t", "text" => text}}
    {:ok, log} = Logs.persist_event(event, %{agent_id: agent_id, session_id: "s"})
    log
  end

  test "the detail panel and the center stream both render log-<seq_no> on the backfill path",
       %{conn: conn} do
    {:ok, agent} =
      Agents.create_agent(%{
        name: "w-#{System.unique_integer([:positive])}",
        harness: "fake",
        provider: "anthropic"
      })

    _first = seed_log(agent.id, "alpha-row")
    newest = seed_log(agent.id, "bravo-row")

    # Connected mount backfills the two rows in chronological order → stream ids 1..2.
    {:ok, view, _html} = live(conn, ~p"/")

    # Open the most-recent row (id == 2) via the drilldown seam.
    render_click(view, "open_event", %{"id" => "2"})

    label = Logs.log_label(newest.seq_no)
    assert is_integer(newest.seq_no) and newest.seq_no > 0

    # The durable log number shows in the detail panel...
    assert has_element?(view, "#event-detail-panel", label)
    # ...and in the center event stream's leading "durable log number" column.
    assert has_element?(view, "#event-stream", label)
  end

  test "the detail panel renders log-<n> on the live broadcast path", %{conn: conn} do
    # Empty backfill → the first live row gets stream id 1.
    {:ok, view, _html} = live(conn, ~p"/")

    event = %Event.ToolCall{harness: :fake, name: "read_file", input: %{"path" => "x"}}
    Dashboard.broadcast_event("worker-live", event, 4242)
    _ = render(view)

    render_click(view, "open_event", %{"id" => "1"})

    assert has_element?(view, "#event-detail-panel", "log-4242")
  end
end
