defmodule RepoBuilderWeb.TestReleaseHiddenLogsTest do
  @moduledoc """
  Integration test for the "Release hidden logs & workflows" settings action
  (specs/issue-logs-adw-visable-sdlc_planner-release-hidden-logs-and-workflows.md).

  Unlike the troubleshooting "peek" toggle (which only flips an in-memory view flag),
  Release is a DURABLE reveal: it un-hides every row soft-hidden by CLEAR so they
  return to the DEFAULT view (and stay visible across reconnects). This test seeds a
  cleared (hidden) worker log, mounts the console, confirms the log is absent from the
  default view, then clicks Release and asserts the log reappears in the event stream,
  the DB row is genuinely un-hidden (visible without the troubleshooting flag), and the
  "Released N rows" confirmation renders.

  `async: false` so the shared Ecto sandbox reaches the LiveView process.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Agents, Logs}
  alias RepoBuilder.Harness.Event

  defp uniq, do: System.unique_integer([:positive])

  test "Release un-hides cleared logs into the default view and confirms the count",
       %{conn: conn} do
    {:ok, agent} =
      Agents.create_agent(%{name: "rel-agent-#{uniq()}", harness: "fake", provider: "anthropic"})

    marker = "cleared-marker-#{uniq()}"

    {:ok, _log} =
      Logs.persist_event(%Event.TextDelta{harness: :fake, text: marker}, %{
        agent_id: agent.id,
        session_id: "s-#{uniq()}"
      })

    # Simulate the console CLEAR action: the row is soft-hidden, not deleted.
    assert Logs.hide_all_logs() == 1

    {:ok, view, _html} = live(conn, ~p"/")

    # Default view (no troubleshooting flag) does NOT show the cleared row.
    refute has_element?(view, "#event-stream", marker)

    # The Release control now lives in the dedicated "Log Database" settings tab
    # (issue-log-db-manager) — select it before acting.
    render_click(view, "select_settings_tab", %{"tab" => "logs"})

    # Release: the durable reveal.
    view |> element("#settings-release-hidden") |> render_click()

    # The previously-hidden row is back in the default event stream...
    assert has_element?(view, "#event-stream", marker)
    # ...the confirmation reports the released count...
    assert has_element?(view, "#settings-release-notice", "Released 1 row")
    # ...and the DB row is genuinely un-hidden (visible WITHOUT the include_hidden flag).
    assert marker in Enum.map(Logs.list_recent_global(500), & &1.payload["text"])
  end
end
