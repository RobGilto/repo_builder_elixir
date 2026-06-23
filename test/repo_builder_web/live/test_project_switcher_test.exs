defmodule RepoBuilderWeb.TestProjectSwitcherTest do
  @moduledoc """
  The console's global project switcher (agentic-layer adaptor, Phase 5): selecting a
  project scopes the rail roster to that project's agents; the "all / platform" option
  remains selectable and shows the unscoped roster.

  `async: false` so the shared Ecto sandbox reaches the LiveView process.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Agents, Projects}

  test "selecting a project scopes the rail roster; platform shows all", %{conn: conn} do
    {:ok, project} = Projects.create_project(%{"name" => "scoped-proj", "root_path" => "/tmp/sp"})

    {:ok, _scoped} =
      Agents.create_agent(%{
        "name" => "scoped-agent",
        "harness" => "claude",
        "provider" => "anthropic",
        "project_id" => project.id
      })

    {:ok, _unscoped} =
      Agents.create_agent(%{
        "name" => "platform-agent",
        "harness" => "claude",
        "provider" => "anthropic"
      })

    {:ok, view, _html} = live(conn, ~p"/")

    # Unscoped (default): both agents are in the roster.
    assert render(view) =~ "platform-agent"

    # Scope to the project: only its agent remains.
    render_change(view, "select_project", %{"project_id" => project.id})
    html = render(view)
    assert html =~ "scoped-agent"
    refute html =~ "platform-agent"

    # Back to platform/all.
    render_change(view, "select_project", %{"project_id" => ""})
    assert render(view) =~ "platform-agent"
  end
end
