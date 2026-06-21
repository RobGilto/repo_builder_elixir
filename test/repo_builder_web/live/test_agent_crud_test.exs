defmodule RepoBuilderWeb.TestAgentCrudTest do
  @moduledoc """
  Run-guard coverage for archived orchestrator workers. The console's operator-facing
  agent CRUD affordances (New/Edit/Archive rail controls) were deprecated and removed;
  this remaining test guards the command path: a run against an agent that was archived
  out from under the selection flashes an error and starts no session.

  `async: false` so the shared Ecto sandbox reaches the LiveView process.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Agents, Orchestrators}

  defp uniq, do: System.unique_integer([:positive])

  defp orchestrator do
    {:ok, orch} = Orchestrators.get_or_create_default("fake")
    orch
  end

  defp worker(name) do
    {:ok, agent} =
      Agents.create_worker(orchestrator().id, %{"name" => name, "harness" => "fake"})

    agent
  end

  test "running against an archived agent flashes an error and starts no session", %{conn: conn} do
    agent = worker("guard-#{uniq()}")

    {:ok, view, _html} = live(conn, ~p"/")
    send(view.pid, {:agent_created, agent})
    _ = render(view)

    # Select the agent (single active filter ⇒ single-agent run routing)...
    view |> element("#agent-#{agent.id}") |> render_click()
    # ...then it gets archived out from under the selection (another tab/session).
    {:ok, _archived} = Agents.archive_agent(agent)

    html =
      view
      |> form("#command-form", command: "do the thing")
      |> render_submit()

    assert html =~ "archived" or html =~ "no longer available"
    # The agent never transitions to running (no session was started).
    refute Agents.get_agent(agent.id).status == :running
  end
end
