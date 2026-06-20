defmodule RepoBuilderWeb.TestAgentCrudTest do
  @moduledoc """
  LiveView tests for operator-facing agent CRUD (re-integrated from db130314, adapted
  to the current console — issue agent-CRUD, BUILD_PROMPT.md §9). Console-created and
  -edited agents are ORCHESTRATOR-OWNED workers (`create_worker`/`update_worker`) so
  the active orchestrator can list + command them. Also covers the run-guard: a run
  against an archived agent flashes an error and starts no session.

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

  test "New agent form creates an orchestrator-owned worker; rail shows it + model", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    name = "crud-#{uniq()}"

    view |> element("#show-new-agent") |> render_click()
    assert has_element?(view, "#new-agent-form")

    view
    |> form("#new-agent-form",
      agent: %{
        name: name,
        harness: "fake",
        provider: "anthropic",
        model: "claude-opus-4-8",
        system_prompt: "Be terse."
      }
    )
    |> render_submit()

    agent = Enum.find(Agents.list_agents(), &(&1.name == name))
    assert agent
    assert agent.model == "claude-opus-4-8"
    assert agent.system_prompt == "Be terse."
    # Orchestrator-owned (so the orchestrator can manage/command it).
    assert agent.orchestrator_id == orchestrator().id

    html = render(view)
    assert html =~ name
    assert html =~ "claude-opus-4-8"
  end

  test "Edit form updates name + model and the rail reflects it", %{conn: conn} do
    agent = worker("edit-#{uniq()}")

    {:ok, view, _html} = live(conn, ~p"/")
    send(view.pid, {:agent_created, agent})
    _ = render(view)

    view |> element("#edit-agent-#{agent.id}") |> render_click()
    assert has_element?(view, "#edit-agent-form")

    new_name = "edited-#{uniq()}"

    view
    |> form("#edit-agent-form", agent: %{name: new_name, harness: "fake", model: "gpt-5"})
    |> render_submit()

    updated = Agents.get_agent(agent.id)
    assert updated.name == new_name
    assert updated.model == "gpt-5"

    html = render(view)
    assert html =~ new_name
    assert html =~ "gpt-5"
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
