defmodule RepoBuilderWeb.TestOrchestratorProjectSwitchTest do
  @moduledoc """
  Orchestrator↔project binding, Phase 3: selecting a project in the console switches the
  ACTIVE orchestrator (not just the rail roster) — a different brain with its own
  working_dir and context window. The console opens scoped to the platform/home project
  (`Projects.default_project/0`, the earliest project in the sandbox); there is no blank
  "all / platform" option. References stable DOM ids, not raw HTML.

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

  test "selecting a project swaps the active orchestrator; selecting the home project restores it",
       %{conn: conn} do
    # The earliest project is the mount default (`Projects.default_project/0`).
    home = project_fixture()
    project = project_fixture()

    {:ok, _scoped} =
      Agents.create_agent(%{
        "name" => "scoped-#{uniq()}",
        "harness" => "claude",
        "provider" => "anthropic",
        "project_id" => project.id
      })

    {:ok, view, _html} = live(conn, ~p"/")

    # Mount defaults to the home (platform) project's bound orchestrator.
    assert {:ok, home_orch} = Orchestrators.get_or_create_for_project(home.id)
    assert has_element?(view, "#active-orchestrator", home_orch.name)

    # Switch to the other project: a DIFFERENT orchestrator becomes active (bound to the
    # project, named after it) and the rail re-scopes to the project's agent.
    render_change(view, "select_project", %{"project_id" => project.id})

    assert {:ok, bound} = Orchestrators.get_or_create_for_project(project.id)
    assert bound.id != home_orch.id
    assert bound.project_id == project.id
    assert bound.working_dir == project.root_path
    assert has_element?(view, "#active-orchestrator", bound.name)
    refute has_element?(view, "#active-orchestrator", home_orch.name)

    # Back to the home project (by id — there is no blank "all/platform" option anymore).
    render_change(view, "select_project", %{"project_id" => home.id})
    assert has_element?(view, "#active-orchestrator", home_orch.name)
  end
end
