defmodule RepoBuilderWeb.TestActivityOrbTest do
  @moduledoc """
  Integration test for the Activity Orb — the continuous "processing" indicator
  reused harness-blind across the agent rail, the orchestrator panel, and ADW
  swimlanes (see specs/issue-spec-adw-it-sdlc_planner-activity-orb-indicator.md).

  Drives status transitions through the same `{:agent_event, agent_id, %Event{}}`
  PubSub seam the live `handle_info/2` clauses already handle, then asserts the orb
  markup (`[data-orb][data-active="true"]` / `.cns-orb`) is present for `:running`
  entities and absent for idle/terminal ones.

  `async: false` so the shared Ecto sandbox reaches the LiveView process and the
  `fake` harness (registered in `config/test.exs`).
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Agents, Dashboard}
  alias RepoBuilder.Harness.Event

  defp uniq_name, do: "orb-agent-#{System.unique_integer([:positive])}"

  # Seed an agent the way the orchestrator will at runtime: persist it, then announce
  # it on the console's `agent_created` seam so the LiveView adds it to the rail live.
  defp create_agent(view, name) do
    {:ok, agent} = Agents.create_agent(%{name: name, harness: "fake", provider: "anthropic"})
    send(view.pid, {:agent_created, agent})
    _ = render(view)
    agent
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> true
      attempts > 0 -> Process.sleep(20) && wait_until(fun, attempts - 1)
      true -> false
    end
  end

  test "a freshly created (idle) agent renders no active orb in its card", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    agent = create_agent(view, uniq_name())

    refute has_element?(view, ~s(#agent-#{agent.id} [data-orb][data-active="true"]))
  end

  test "broadcasting SessionStarted flips the agent to :running and shows its orb", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    agent = create_agent(view, uniq_name())

    Dashboard.broadcast_event(agent.id, %Event.SessionStarted{
      harness: :fake,
      session_id: "s-1"
    })

    assert wait_until(fn ->
             has_element?(view, ~s(#agent-#{agent.id} [data-orb][data-active="true"]))
           end)

    assert has_element?(view, "#agent-#{agent.id} .cns-orb--agent")
  end

  test "a terminal (Done) agent shows no active orb", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    agent = create_agent(view, uniq_name())

    Dashboard.broadcast_event(agent.id, %Event.SessionStarted{harness: :fake, session_id: "s-2"})

    assert wait_until(fn ->
             has_element?(view, ~s(#agent-#{agent.id} [data-orb][data-active="true"]))
           end)

    Dashboard.broadcast_event(agent.id, %Event.Done{
      harness: :fake,
      ok: true,
      reason: :success
    })

    assert wait_until(fn ->
             not has_element?(view, ~s(#agent-#{agent.id} [data-orb][data-active="true"]))
           end)
  end

  test "the orchestrator panel shows the orb only while the orchestrator turn is in flight",
       %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")

    # Idle: the orchestrator label is present but no orb beside it.
    assert html =~ "ORCHESTRATOR"
    refute has_element?(view, "#command-panel .cns-orb--orchestrator")

    # The orchestrator runs as an agent over the same canonical event seam; flipping
    # its status to :running gates the panel orb (the `@typing?`-or-running signal).
    orchestrator_id = :sys.get_state(view.pid).socket.assigns.orchestrator_id
    assert orchestrator_id

    Dashboard.broadcast_event(orchestrator_id, %Event.SessionStarted{
      harness: :fake,
      session_id: "orch-1"
    })

    assert wait_until(fn ->
             has_element?(view, "#command-panel .cns-orb--orchestrator")
           end)

    Dashboard.broadcast_event(orchestrator_id, %Event.Done{
      harness: :fake,
      ok: true,
      reason: :success
    })

    assert wait_until(fn ->
             not has_element?(view, "#command-panel .cns-orb--orchestrator")
           end)
  end
end
