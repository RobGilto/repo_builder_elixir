defmodule RepoBuilderWeb.AgentCrudRosterTest do
  @moduledoc """
  Integration test for the additive console roster seam (issue agent-CRUD).
  Mounts `ConsoleLive`, then broadcasts `{:agent_created, agent}` followed by
  `{:agent_deleted, agent}` on `console:events` and asserts the rail card for the
  worker appears then disappears live (streams; flat server memory).
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Agents, Orchestrators}

  defp uniq, do: System.unique_integer([:positive])

  defp worker do
    {:ok, orch} = Orchestrators.create(%{name: "orch-#{uniq()}", harness: "fake"})

    {:ok, agent} =
      Agents.create_worker(orch.id, %{"name" => "roster-#{uniq()}", "harness" => "fake"})

    agent
  end

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(RepoBuilder.PubSub, "console:events", message)
  end

  test "a created worker appears in the roster and a deleted one disappears", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    agent = worker()
    card = "#agent-#{agent.id}"

    refute has_element?(view, card)

    broadcast({:agent_created, agent})
    assert has_element?(view, card)

    broadcast({:agent_deleted, agent})
    refute has_element?(view, card)
  end
end
