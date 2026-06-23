defmodule RepoBuilderWeb.ProjectsLiveTest do
  @moduledoc """
  LiveView coverage for the agentic-layer adaptor project UI (Phase 5): registering a
  target repo (with profiling), the project dashboard render (repo health, resolved
  command set with provenance), and the command-pack picker.

  `async: false` so the shared Ecto sandbox reaches the LiveView process.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Projects

  defp fixture_repo do
    root = Path.join(System.tmp_dir!(), "rb_plive_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, ".claude/commands"))
    File.write!(Path.join(root, "mix.exs"), "defmodule X.MixProject do end")
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  test "registers a target repo and lands on its dashboard with detected stack", %{conn: conn} do
    root = fixture_repo()
    {:ok, view, _html} = live(conn, ~p"/projects")

    view
    |> form("form[phx-submit=register]", %{"name" => "acme", "root_path" => root})
    |> render_submit()

    assert_redirect(view, ~p"/projects/#{Projects.get_by_root_path(root).id}")

    project = Projects.get_by_root_path(root)
    assert project.stack["language"] == "elixir"
    assert project.capabilities["test_command"] == "mix test"
  end

  test "the dashboard renders repo health and the resolved command set with provenance", %{
    conn: conn
  } do
    root = fixture_repo()
    {:ok, project} = Projects.create_and_profile(%{"name" => "dash", "root_path" => root})

    {:ok, _view, html} = live(conn, ~p"/projects/#{project.id}")

    assert html =~ "Repo health"
    assert html =~ "elixir (mix)"
    assert html =~ "Capability map"
    # The build command resolves from the elixir stack pack — provenance is shown.
    assert html =~ "/build"
    assert html =~ "elixir@1.0.0"
  end

  test "the command-pack picker pins a pack and re-resolves", %{conn: conn} do
    root = fixture_repo()
    {:ok, project} = Projects.create_and_profile(%{"name" => "pin", "root_path" => root})
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")

    view
    |> form("form[phx-change=set_pack]", %{
      "command_pack" => "generic",
      "command_pack_version" => "latest"
    })
    |> render_change()

    assert Projects.get_project!(project.id).command_pack == "generic"
  end

  test "lists registered projects", %{conn: conn} do
    {:ok, _} = Projects.create_project(%{"name" => "listed", "root_path" => "/tmp/listed"})
    {:ok, _view, html} = live(conn, ~p"/projects")
    assert html =~ "listed"
  end
end
