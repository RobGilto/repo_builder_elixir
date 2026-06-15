defmodule RepoBuilderWeb.TestOrchestrationConsoleTest do
  @moduledoc """
  Integration test for the multi-layered orchestration console
  (BUILD_PROMPT.md §9): mount → create agent → select → launch a `fake` session
  → assert streamed canonical events + stat updates → toggle view → launch ADW.

  `async: false` so the shared Ecto sandbox reaches the spawned `Session.Server`
  and workflow `Runner`. The `fake` harness is resolved through the registry seam
  (§13) — it is already registered in `config/test.exs`, no per-test override
  needed.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Agents, Dashboard}
  alias RepoBuilder.Harness.Event

  defp uniq_name, do: "console-agent-#{System.unique_integer([:positive])}"

  # Open the inline "New agent" form, submit it for `name` on the `fake` harness,
  # and return the persisted agent (now also present in the LiveView's rail).
  defp create_agent(view, name) do
    view |> element("#show-new-agent") |> render_click()

    view
    |> form("#new-agent-form", agent: %{name: name, harness: "fake", provider: "anthropic"})
    |> render_submit()

    Enum.find(Agents.list_agents(), &(&1.name == name))
  end

  test "mounts and renders the header, agent rail, and event stream regions", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ ~s(id="console-header")
    assert html =~ ~s(id="agent-rail")
    assert html =~ ~s(id="event-stream")
  end

  test "creating an agent via the inline form adds a selectable rail item", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    name = uniq_name()
    agent = create_agent(view, name)

    assert agent
    assert has_element?(view, "#agent-#{agent.id}")
    assert render(view) =~ name
  end

  test "selecting an agent and running streams the canonical fake sequence + updates pills", %{
    conn: conn
  } do
    # Observe the global feed deterministically (no Process.sleep).
    :ok = Dashboard.subscribe_events()

    {:ok, view, _html} = live(conn, ~p"/")
    agent = create_agent(view, uniq_name())

    view |> element("#agent-#{agent.id}") |> render_click()

    view
    |> form("#launch-form", launch: %{prompt: "ship it", harness: "fake", model: ""})
    |> render_submit()

    assert_receive {:agent_event, _id, %Event.SessionStarted{}}, 2_000
    assert_receive {:agent_event, _id, %Event.Done{ok: true}}, 2_000

    html = render(view)

    # The fake sequence: session_started → text_delta* → tool_call → tool_result → usage → done.
    assert html =~ "Hello"
    assert html =~ "world"
    assert html =~ "bash"
    assert html =~ "done"

    # Stat pills updated live: 7 canned events, 1 active agent.
    assert has_element?(view, "#stat-logs", "7")
    assert has_element?(view, "#stat-active", "1")
  end

  test "Done flips the agent's swimlane to succeeded in ADWS view", %{conn: conn} do
    :ok = Dashboard.subscribe_events()
    :ok = Dashboard.subscribe()

    {:ok, view, _html} = live(conn, ~p"/")
    agent = create_agent(view, uniq_name())

    view |> element("#agent-#{agent.id}") |> render_click()

    view
    |> form("#launch-form", launch: %{prompt: "ship it", harness: "fake", model: ""})
    |> render_submit()

    assert_receive {:agent_event, _id, %Event.Done{ok: true}}, 2_000
    # The session also broadcasts a lane transition; wait for the terminal one so the
    # view has processed it before we render (no Process.sleep).
    assert_receive {:lane, %{id: "agent:" <> _, status: :succeeded}}, 2_000

    # Toggle to swimlanes; the agent lane (stable dom_id) shows the terminal status.
    view |> element("#view-toggle") |> render_click()
    html = render(view)

    assert html =~ ~s(id="swimlanes")
    assert html =~ "lane-agent:#{agent.id}"
    assert html =~ "succeeded"
  end

  test "the LOGS/ADWS toggle switches the center column", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")

    # Both stream containers stay mounted (so stream rows are never dropped); the
    # toggle flips which one is visible, reflected by the toggle button's label.
    assert html =~ ~s(id="event-stream")
    assert html =~ ~s(id="swimlanes")
    assert has_element?(view, "#view-toggle", "LOGS")

    view |> element("#view-toggle") |> render_click()

    assert has_element?(view, "#view-toggle", "ADWS")
  end

  test "launching an ADW starts the example workflow and a workflow lane appears", %{conn: conn} do
    :ok = Dashboard.subscribe()

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("#launch-adw-form", adw: %{harness: "fake"})
    |> render_submit()

    assert_receive {:lane, %{kind: :workflow} = lane}, 5_000

    # launch_adw switches to ADWS view; the workflow lane is in the swimlanes stream.
    html = render(view)
    assert html =~ ~s(id="swimlanes")
    assert html =~ "lane-#{lane.id}"

    # Let the example ADW (plan→build→review) run to completion BEFORE the test ends,
    # so its fake step-sessions don't touch the DB after the sandbox owner is gone.
    assert_receive {:lane, %{kind: :workflow, status: :succeeded}}, 8_000
  end

  test "Run with no agent selected shows a flash error and starts nothing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html =
      view
      |> form("#launch-form", launch: %{prompt: "hi", harness: "fake", model: ""})
      |> render_submit()

    assert html =~ "Select an agent before running"
  end

  test "creating an agent with a harness not in the registry surfaces a changeset error", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#show-new-agent") |> render_click()

    # "nope" is not a registered harness → validate_inclusion error, no insert.
    html =
      view
      |> form("#new-agent-form",
        agent: %{name: uniq_name(), harness: "fake", provider: "anthropic"}
      )
      |> render_change(agent: %{name: "x", harness: "nope", provider: "anthropic"})

    assert html =~ "is not a registered harness"
  end
end
