defmodule RepoBuilderWeb.TestAgentArchiveTest do
  @moduledoc """
  LiveView test for the rail Archive affordance (re-integrated from the db130314
  agent-CRUD branch, BUILD_PROMPT.md §9): the expanded agent card carries an Archive
  control; clicking it soft-archives the agent, removes its rail item live, and the
  agent is excluded from the default list but reachable with `include_archived: true`.

  `async: false` so the shared Ecto sandbox reaches the LiveView process.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Agents

  defp uniq, do: System.unique_integer([:positive])

  defp create_agent do
    {:ok, agent} =
      Agents.create_agent(%{name: "agent-#{uniq()}", harness: "fake", provider: :anthropic})

    agent
  end

  test "archive removes the rail item and excludes it from the default list", %{conn: conn} do
    agent = create_agent()

    {:ok, view, _html} = live(conn, ~p"/")

    # The expanded rail (default, not collapsed) renders the agent card + Archive control.
    assert has_element?(view, "#agent-#{agent.id}")
    assert has_element?(view, "#archive-agent-#{agent.id}")

    view |> element("#archive-agent-#{agent.id}") |> render_click()

    # The rail item is gone live...
    refute has_element?(view, "#agent-#{agent.id}")
    # ...excluded from the default list, but preserved (reachable include_archived).
    refute Enum.any?(Agents.list_agents(), &(&1.id == agent.id))
    assert Enum.any?(Agents.list_agents(include_archived: true), &(&1.id == agent.id))
  end
end
