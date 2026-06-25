defmodule RepoBuilderWeb.TestProjectPaletteRefreshTest do
  @moduledoc """
  Regression for issue-palette-project-refresh: selecting a project in the global switcher
  must re-seed the ⌘K palette's PROJECT tab from the now-active orchestrator's `working_dir`,
  surfacing that project's `.claude/commands/*.md`. Before the fix `switch_orchestrator/2`
  updated `orchestrator_working_dir` for display but never re-scanned the palette nor
  refreshed the `Definitions` watcher, so the project's overlay commands never appeared.

  `async: false` so the shared Ecto sandbox reaches the LiveView process and because the
  single global `Definitions` watcher is repointed by the switch.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Projects

  defp uniq, do: System.unique_integer([:positive])

  # A temp project root carrying a slash command only present in the project overlay.
  defp project_with_command_fixture do
    n = uniq()
    root = Path.join(System.tmp_dir!(), "rb-projpalette-#{n}")
    File.mkdir_p!(Path.join(root, ".claude/commands"))
    File.write!(Path.join(root, ".claude/commands/projonly.md"), "# Project-only command\n")

    {:ok, project} =
      Projects.create_project(%{"name" => "projpalette-#{n}", "root_path" => root})

    on_exit(fn -> File.rm_rf!(root) end)

    {project, "/projonly"}
  end

  test "selecting a project re-seeds the PROJECT tab with that project's .claude/commands",
       %{conn: conn} do
    # A home project (created first ⇒ the mount default per `Projects.default_project/0`)
    # WITHOUT the overlay command, so the PROJECT tab is empty at mount.
    {:ok, _home} =
      Projects.create_project(%{
        "name" => "home-#{uniq()}",
        "root_path" => Path.join(System.tmp_dir!(), "rb-projpalette-home-#{uniq()}")
      })

    {project, token} = project_with_command_fixture()

    {:ok, view, _html} = live(conn, ~p"/")

    # Default brain: the project overlay is not active, so its command is absent from the
    # PROJECT tab (which only lists :working_dir-sourced artifacts).
    view |> element("#palette-tab-project") |> render_click()
    refute render(view) =~ token

    # Switch to the project — switch_orchestrator/2 must refresh + re-seed the palette.
    render_change(view, "select_project", %{"project_id" => project.id})

    view |> element("#palette-tab-project") |> render_click()
    assert render(view) =~ token
  end
end
