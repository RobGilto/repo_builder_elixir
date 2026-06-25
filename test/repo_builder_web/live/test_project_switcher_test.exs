defmodule RepoBuilderWeb.TestProjectSwitcherTest do
  @moduledoc """
  The console's global project switcher (agentic-layer adaptor, Phase 5): selecting a
  project scopes the rail roster to that project's agents. The console opens scoped to the
  platform/home project (`Projects.default_project/0`, the earliest project in the
  sandbox); there is no blank "all / platform" option.

  `async: false` so the shared Ecto sandbox reaches the LiveView process.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Agents, Projects}

  test "selecting a project re-scopes the rail roster to that project's agents", %{conn: conn} do
    # The earliest project is the mount default (`Projects.default_project/0`).
    {:ok, home} = Projects.create_project(%{"name" => "home-proj", "root_path" => "/tmp/home"})
    {:ok, other} = Projects.create_project(%{"name" => "other-proj", "root_path" => "/tmp/other"})

    {:ok, _home_agent} =
      Agents.create_agent(%{
        "name" => "home-agent",
        "harness" => "claude",
        "provider" => "anthropic",
        "project_id" => home.id
      })

    {:ok, _other_agent} =
      Agents.create_agent(%{
        "name" => "other-agent",
        "harness" => "claude",
        "provider" => "anthropic",
        "project_id" => other.id
      })

    {:ok, view, _html} = live(conn, ~p"/")

    # Mount defaults to the home project: only its agent is in the roster.
    html = render(view)
    assert html =~ "home-agent"
    refute html =~ "other-agent"

    # Scope to the other project: only its agent remains.
    render_change(view, "select_project", %{"project_id" => other.id})
    html = render(view)
    assert html =~ "other-agent"
    refute html =~ "home-agent"

    # Back to the home project (by id).
    render_change(view, "select_project", %{"project_id" => home.id})
    html = render(view)
    assert html =~ "home-agent"
    refute html =~ "other-agent"
  end
end
