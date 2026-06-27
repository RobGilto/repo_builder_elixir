defmodule RepoBuilderWeb.ProjectStackLayersTest do
  @moduledoc """
  Integration tests for the per-project stack mix & match (stack-layers subsystem) on
  `/projects/:id`: selecting one layer per type updates `layers_for_project/1` and the
  live contract preview, deselecting ("none") clears it, two projects stay isolated, and
  auto-seed selects a layer matching the registered project's detected stack.

  `async: false` so the shared Ecto sandbox reaches the LiveView process.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Projects
  alias RepoBuilder.StackLayers

  defp uniq, do: System.unique_integer([:positive])

  defp project_fixture do
    n = uniq()

    {:ok, project} =
      Projects.create_project(%{"name" => "proj-#{n}", "root_path" => "/tmp/p-#{n}"})

    project
  end

  defp layer_fixture(attrs) do
    base = %{"layer_type" => "backend", "name" => "L-#{uniq()}", "language" => "elixir"}
    {:ok, layer} = StackLayers.create_layer(Map.merge(base, attrs))
    layer
  end

  test "selecting a layer per type updates the selection and contract preview", %{conn: conn} do
    project = project_fixture()

    backend =
      layer_fixture(%{
        "layer_type" => "backend",
        "name" => "Phoenix",
        "language" => "elixir",
        "reasoning" => "typed contexts only"
      })

    {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")

    # Empty state: preview tells the operator no contract is issued.
    assert has_element?(view, "#project-stack-contract-empty")

    view
    |> element("#project-stack-layer-backend")
    |> render_change(%{"layer_type" => "backend", "stack_layer_id" => backend.id})

    assert StackLayers.layers_for_project(project.id) |> Enum.map(& &1.id) == [backend.id]
    assert has_element?(view, "#project-stack-contract")
    assert render(view) =~ "build ONLY within this stack"
    assert render(view) =~ "Phoenix"

    # Deselect ("none") removes it and the preview returns to empty.
    view
    |> element("#project-stack-layer-backend")
    |> render_change(%{"layer_type" => "backend", "stack_layer_id" => ""})

    assert StackLayers.layers_for_project(project.id) == []
    assert has_element?(view, "#project-stack-contract-empty")
  end

  test "selecting another layer of the same type replaces the prior pick", %{conn: conn} do
    project = project_fixture()
    a = layer_fixture(%{"layer_type" => "backend", "name" => "A-#{uniq()}"})
    b = layer_fixture(%{"layer_type" => "backend", "name" => "B-#{uniq()}"})

    {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")

    el = element(view, "#project-stack-layer-backend")
    render_change(el, %{"layer_type" => "backend", "stack_layer_id" => a.id})
    render_change(el, %{"layer_type" => "backend", "stack_layer_id" => b.id})

    assert StackLayers.layers_for_project(project.id) |> Enum.map(& &1.id) == [b.id]
  end

  test "two projects keep independent selections", %{conn: conn} do
    p1 = project_fixture()
    p2 = project_fixture()

    layer =
      layer_fixture(%{"layer_type" => "database", "name" => "PG-#{uniq()}", "language" => "sql"})

    {:ok, view, _html} = live(conn, ~p"/projects/#{p1.id}")

    view
    |> element("#project-stack-layer-database")
    |> render_change(%{"layer_type" => "database", "stack_layer_id" => layer.id})

    assert StackLayers.layers_for_project(p1.id) |> Enum.map(& &1.id) == [layer.id]
    assert StackLayers.layers_for_project(p2.id) == []
  end

  test "auto-seed selects a catalog layer matching the registered stack" do
    _elixir_layer =
      layer_fixture(%{
        "layer_type" => "backend",
        "name" => "Phx-#{uniq()}",
        "language" => "elixir"
      })

    # Register a project whose root is THIS repo (an Elixir/mix project the Profiler detects).
    {:ok, project} =
      Projects.create_project(%{
        "name" => "seeded-#{uniq()}",
        "root_path" => File.cwd!(),
        "stack" => %{"language" => "elixir"}
      })

    {:ok, _} = StackLayers.seed_project_from_stack(project.id, %{"language" => "elixir"})

    assert project.id
           |> StackLayers.layers_for_project()
           |> Enum.any?(&(&1.language == "elixir"))
  end
end
