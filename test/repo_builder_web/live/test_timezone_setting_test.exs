defmodule RepoBuilderWeb.TimezoneSettingTest do
  @moduledoc """
  Integration test for the timezone setting (issue-a): the settings select persists
  the chosen zone, the center log stream renders timestamps in that zone (offset
  applied, not bare UTC), and the choice survives a reconnect (re-read on mount).
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query, only: [from: 2]

  alias RepoBuilder.Harness.Event
  alias RepoBuilder.Logs
  alias RepoBuilder.Logs.AgentLog
  alias RepoBuilder.Orchestrators
  alias RepoBuilder.Repo

  # 2026-06-18 00:30:00Z -> Australia/Sydney (UTC+10, no DST in June) -> 10:30:00.
  @utc ~U[2026-06-18 00:30:00Z]
  @utc_str "2026-06-18 00:30:00"
  @sydney_str "2026-06-18 10:30:00"

  defp seed_log!(orchestrator_id) do
    event = %Event.TextDelta{harness: :claude, text: "hello", raw: %{"text" => "hello"}}

    {:ok, log} =
      Logs.persist_orchestrator_event(event, %{orchestrator_id: orchestrator_id, session_id: "s"})

    # Force a known instant so the rendered local time is deterministic.
    {1, _} =
      Repo.update_all(from(l in AgentLog, where: l.id == ^log.id), set: [inserted_at: @utc])

    log
  end

  test "changing the timezone persists it and renders log timestamps in that zone", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    orchestrator_id = :sys.get_state(view.pid).socket.assigns.orchestrator_id

    seed_log!(orchestrator_id)

    # Default zone (UTC) renders the bare UTC datetime once we re-backfill.
    view |> element("#settings-timezone-form") |> render_change(%{"timezone" => "UTC"})
    assert render(view) =~ @utc_str

    # Switch to Sydney: persists + re-renders the seeded row in local time.
    view
    |> element("#settings-timezone-form")
    |> render_change(%{"timezone" => "Australia/Sydney"})

    {:ok, reloaded} = Orchestrators.fetch(orchestrator_id)
    assert Orchestrators.timezone(reloaded) == "Australia/Sydney"

    html = render(view)
    assert html =~ @sydney_str
    refute html =~ @utc_str

    # The select reflects the chosen zone as selected.
    assert has_element?(view, "#settings-timezone option[selected]", "Australia/Sydney")
  end

  test "the persisted timezone survives a reconnect (re-read on mount)", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    orchestrator_id = :sys.get_state(view.pid).socket.assigns.orchestrator_id
    seed_log!(orchestrator_id)

    {:ok, _} = Orchestrators.set_timezone(orchestrator_id, "Australia/Sydney")

    # A fresh mount reads the persisted zone and backfills in local time.
    {:ok, view2, _html} = live(conn, ~p"/")
    assert :sys.get_state(view2.pid).socket.assigns.timezone == "Australia/Sydney"

    html = render(view2)
    assert html =~ @sydney_str
    assert has_element?(view2, "#settings-timezone option[selected]", "Australia/Sydney")
  end
end
