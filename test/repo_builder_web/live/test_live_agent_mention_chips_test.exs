defmodule RepoBuilderWeb.TestLiveAgentMentionChipsTest do
  @moduledoc """
  Integration test for the LIVE AGENTS prompt-palette row
  (issue-the-adw-prompt clickable live-agent mention chips): the ⌘K command modal
  renders a clickable chip per **active** (`:idle`/`:running`) worker shown in the
  left rail; each chip's `phx-click` encodes an `rb:insert-token` dispatch carrying
  the worker's **exact name** (the string `Agents.get_by_name_for_orchestrator/2`
  matches); non-active workers (succeeded/failed/error) are excluded; and an empty
  row renders its actionable hint.

  `async: false` so the shared Ecto sandbox reaches the connected LiveView process.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Agents
  alias RepoBuilder.Agents.Agent
  alias RepoBuilder.Harness.Event

  defp uniq, do: System.unique_integer([:positive])

  defp create_live_agent(view, name) do
    orchestrator_id = :sys.get_state(view.pid).socket.assigns.orchestrator_id

    {:ok, agent} =
      Agents.create_worker(orchestrator_id, %{"name" => name, "harness" => "fake"})

    # Drive the same live seam the orchestrator uses so @agents/@statuses include it.
    send(view.pid, {:agent_created, agent})
    _ = render(view)
    agent
  end

  test "an idle worker renders a LIVE AGENTS chip with an exact-name rb:insert-token dispatch",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    name = "career-scout-#{uniq()}"
    create_live_agent(view, name)

    html = render(view)

    assert html =~ "LIVE AGENTS"
    assert html =~ name
    # The chip dispatches rb:insert-token carrying the exact name (no server round-trip).
    assert html =~ "rb:insert-token"

    assert has_element?(
             view,
             "#palette-live button[phx-click*=\"rb:insert-token\"]",
             name
           )
  end

  test "non-active workers (succeeded/failed/error) are excluded from the row", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    active = "active-#{uniq()}"
    inactive = "done-#{uniq()}"

    create_live_agent(view, active)
    %Agent{id: inactive_id} = create_live_agent(view, inactive)

    # Force the second worker into a terminal (non-active) status via the canonical
    # Done event the console maps to :succeeded.
    done = %Event.Done{harness: :fake, ok: true, reason: :success}
    send(view.pid, {:agent_event, inactive_id, done, 1})
    _ = render(view)

    assert has_element?(view, "#palette-live button[phx-click*=\"rb:insert-token\"]", active)
    refute has_element?(view, "#palette-live button[phx-click*=\"rb:insert-token\"]", inactive)
  end

  test "the LIVE AGENTS row shows its empty-state hint when there are no active agents", %{
    conn: conn
  } do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "LIVE AGENTS (0)"
    assert html =~ "no live agents — create one, then click to reference it"
  end
end
