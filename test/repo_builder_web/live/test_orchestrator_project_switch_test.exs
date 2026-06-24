defmodule RepoBuilderWeb.TestOrchestratorProjectSwitchTest do
  @moduledoc """
  Orchestrator↔project binding, Phase 3: selecting a project in the console switches the
  ACTIVE orchestrator (not just the rail roster) — a different brain with its own
  working_dir and context window — and selecting "All / platform" returns to the
  `project_id: nil` default. References stable DOM ids, not raw HTML.

  `async: false` so the shared Ecto sandbox reaches the LiveView process.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Agents, Orchestrators, Projects}

  defp uniq, do: System.unique_integer([:positive])

  defp project_fixture do
    n = uniq()

    {:ok, project} =
      Projects.create_project(%{"name" => "switch-#{n}", "root_path" => "/tmp/switch-#{n}"})

    project
  end

  test "selecting a project swaps the active orchestrator; blank restores the default", %{
    conn: conn
  } do
    project = project_fixture()

    {:ok, _scoped} =
      Agents.create_agent(%{
        "name" => "scoped-#{uniq()}",
        "harness" => "claude",
        "provider" => "anthropic",
        "project_id" => project.id
      })

    {:ok, view, _html} = live(conn, ~p"/")

    # Default brain: the platform "default" orchestrator is live.
    assert {:ok, default} = Orchestrators.get_or_create_default()
    assert has_element?(view, "#active-orchestrator", default.name)

    # Switch to the project: a DIFFERENT orchestrator becomes active (bound to the project,
    # named after it) and the rail re-scopes to the project's agent.
    render_change(view, "select_project", %{"project_id" => project.id})

    assert {:ok, bound} = Orchestrators.get_or_create_for_project(project.id)
    assert bound.id != default.id
    assert bound.project_id == project.id
    assert bound.working_dir == project.root_path
    assert has_element?(view, "#active-orchestrator", bound.name)
    refute has_element?(view, "#active-orchestrator", default.name)

    # Back to platform/all: the default orchestrator is live again.
    render_change(view, "select_project", %{"project_id" => ""})
    assert has_element?(view, "#active-orchestrator", default.name)
  end
end
