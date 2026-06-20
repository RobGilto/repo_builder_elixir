defmodule RepoBuilderWeb.TestAgentCardStreamFilterTest do
  @moduledoc """
  Integration test for the agent-card-as-stream-filter feature (see
  specs/issue-NA-adw-NA-sdlc_planner-agent-card-stream-filter.md).

  Clicking an agent card toggles an *id-based* agent filter: the agent appears as a
  removable pill in the center filter bar (next to the category chips) and the center
  event stream narrows to that agent's rows. Clicking the card again, the pill's `×`,
  or `CLEAR FILTERS` removes the filter. The active-filter set also drives prompt
  routing — exactly one active filter routes a manual run to that agent; zero or
  multiple route to the orchestrator.

  `async: false` so the shared Ecto sandbox reaches the LiveView process and the
  spawned `fake` session (registered in `config/test.exs`).
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Agents, Dashboard}
  alias RepoBuilder.Harness.Event

  defp uniq_name, do: "filter-agent-#{System.unique_integer([:positive])}"

  # Seed an agent the way the orchestrator will at runtime: persist it, then announce
  # it on the console's `agent_created` seam so the LiveView adds it to the rail live.
  defp create_agent(view, name) do
    {:ok, agent} = Agents.create_agent(%{name: name, harness: "fake", provider: "anthropic"})
    send(view.pid, {:agent_created, agent})
    _ = render(view)
    agent
  end

  # Finalized (non-partial) reasoning lands in the center event stream under the
  # THINKING category, keyed by the agent's id — a deterministic way to seed rows.
  defp seed_row(agent_id, text) do
    Dashboard.broadcast_event(agent_id, %Event.TextDelta{
      harness: :fake,
      text: text,
      thinking?: true
    })
  end

  test "clicking an agent card adds a filter pill and narrows the event stream", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    a = create_agent(view, uniq_name())
    b = create_agent(view, uniq_name())

    seed_row(a.id, "alpha-row")
    seed_row(b.id, "bravo-row")
    _ = render(view)

    # Default: no filter, both agents' rows are present.
    assert has_element?(view, "#event-stream", "alpha-row")
    assert has_element?(view, "#event-stream", "bravo-row")

    # Click agent A's card → a removable pill appears in the filter bar and the stream
    # narrows to A's rows only.
    view |> element("#agent-#{a.id}") |> render_click()

    assert has_element?(view, "#filter-bar", a.name)
    assert has_element?(view, ~s(#filter-bar button[aria-label="Remove #{a.name} filter"]))
    assert has_element?(view, "#event-stream", "alpha-row")
    refute has_element?(view, "#event-stream", "bravo-row")

    # The card reflects its "active filter" highlight only while filtered.
    assert has_element?(view, "#agent-row-#{a.id}.cns-agent-card--selected")
    refute has_element?(view, "#agent-row-#{b.id}.cns-agent-card--selected")
  end

  test "clicking the card again removes the filter and restores all rows", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    a = create_agent(view, uniq_name())
    b = create_agent(view, uniq_name())

    seed_row(a.id, "alpha-row")
    seed_row(b.id, "bravo-row")
    _ = render(view)

    view |> element("#agent-#{a.id}") |> render_click()
    refute has_element?(view, "#event-stream", "bravo-row")

    # Toggle off via the card click.
    view |> element("#agent-#{a.id}") |> render_click()

    refute has_element?(view, "#filter-bar", a.name)
    assert has_element?(view, "#event-stream", "alpha-row")
    assert has_element?(view, "#event-stream", "bravo-row")
    refute has_element?(view, "#agent-row-#{a.id}.cns-agent-card--selected")
  end

  test "the pill's × removes exactly that agent's filter", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    a = create_agent(view, uniq_name())
    b = create_agent(view, uniq_name())

    seed_row(a.id, "alpha-row")
    seed_row(b.id, "bravo-row")
    _ = render(view)

    view |> element("#agent-#{a.id}") |> render_click()
    assert has_element?(view, "#filter-bar", a.name)

    view
    |> element(~s(#filter-bar button[aria-label="Remove #{a.name} filter"]))
    |> render_click()

    refute has_element?(view, "#filter-bar", a.name)
    assert has_element?(view, "#event-stream", "bravo-row")
  end

  test "CLEAR removes an active agent filter and clears the log view", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    a = create_agent(view, uniq_name())
    b = create_agent(view, uniq_name())

    seed_row(a.id, "alpha-row")
    seed_row(b.id, "bravo-row")
    _ = render(view)

    view |> element("#agent-#{a.id}") |> render_click()
    assert has_element?(view, "#filter-bar", a.name)

    view |> element("#clear-filters") |> render_click()

    # CLEAR resets filters AND clears the log view from the UI (no DB delete).
    refute has_element?(view, "#filter-bar", a.name)
    refute has_element?(view, "#event-stream", "alpha-row")
    refute has_element?(view, "#event-stream", "bravo-row")
  end

  test "exactly one agent filter routes a manual run to that agent", %{conn: conn} do
    :ok = Dashboard.subscribe_events()

    {:ok, view, _html} = live(conn, ~p"/")
    a = create_agent(view, uniq_name())

    # A single active filter = the routing selection: the prompt starts a session for
    # that agent, which streams the canonical `fake` sequence ending in Done.
    view |> element("#agent-#{a.id}") |> render_click()

    view
    |> form("#command-form", command: "ship it")
    |> render_submit()

    assert_receive {:agent_event, _id, %Event.SessionStarted{}, _log_no}, 2_000
    assert_receive {:agent_event, _id, %Event.Done{ok: true}, _log_no}, 2_000
  end

  test "no agent filter routes a manual run to the orchestrator (no spawn, no error)", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/")

    # Zero active filters ⇒ orchestrator routing. The prompt is echoed into the chat as
    # the operator's message and no "select an agent" gate fires.
    html =
      view
      |> form("#command-form", command: "hello orchestrator")
      |> render_submit()

    refute html =~ "Select an agent before running"
    assert html =~ "YOU"
  end
end
