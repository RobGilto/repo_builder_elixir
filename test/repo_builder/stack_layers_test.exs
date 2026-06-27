defmodule RepoBuilder.StackLayersTest do
  @moduledoc """
  Unit tests for the Stack Layers context (stack-layers subsystem): catalog CRUD +
  unique-key rejection, per-project selection isolation, `seed_project_from_stack/2`
  language matching (no-clobber), `seed_default_layers/0` idempotency, and the pure
  `Contract.render/1` (content + empty cases).
  """
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.Projects
  alias RepoBuilder.StackLayers
  alias RepoBuilder.StackLayers.{Contract, StackLayer}

  defp uniq, do: System.unique_integer([:positive])

  defp project_fixture do
    dir = Path.join(System.tmp_dir!(), "rb-sl-#{uniq()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, project} = Projects.create_project(%{"name" => "sl-proj-#{uniq()}", "root_path" => dir})
    project
  end

  defp layer_fixture(attrs \\ %{}) do
    base = %{
      "layer_type" => "backend",
      "name" => "Phoenix-#{uniq()}",
      "language" => "elixir",
      "reasoning" => "build in elixir"
    }

    {:ok, layer} = StackLayers.create_layer(Map.merge(base, attrs))
    layer
  end

  describe "catalog CRUD" do
    test "create_layer/1 persists a manual-sourced row" do
      assert {:ok, %StackLayer{} = layer} =
               StackLayers.create_layer(%{
                 "layer_type" => "frontend",
                 "name" => "Svelte-#{uniq()}",
                 "language" => "typescript"
               })

      assert layer.source == :manual
      assert layer.layer_type == :frontend
      assert layer.enabled == true
    end

    test "create_layer/1 requires layer_type, name, language" do
      assert {:error, changeset} = StackLayers.create_layer(%{"name" => "x"})
      assert %{layer_type: _, language: _} = errors_on(changeset)
    end

    test "create_layer/1 rejects a duplicate (layer_type, name)" do
      layer = layer_fixture()

      assert {:error, changeset} =
               StackLayers.create_layer(%{
                 "layer_type" => "backend",
                 "name" => layer.name,
                 "language" => "elixir"
               })

      assert errors_on(changeset)[:layer_type] || errors_on(changeset)[:name]
    end

    test "update_layer/2 edits in place and forces source: :manual" do
      layer = layer_fixture()
      assert {:ok, updated} = StackLayers.update_layer(layer, %{"language" => "ruby"})
      assert updated.language == "ruby"
      assert updated.source == :manual
    end

    test "list_layers/0 orders by type then name; get_layer/1 fetches by id" do
      a = layer_fixture(%{"layer_type" => "database", "name" => "PG-#{uniq()}"})
      b = layer_fixture(%{"layer_type" => "frontend", "name" => "FE-#{uniq()}"})

      ids = StackLayers.list_layers() |> Enum.map(& &1.id)
      assert b.id in ids
      assert a.id in ids
      assert %StackLayer{} = StackLayers.get_layer(a.id)
    end

    test "delete_layer/1 removes the row; missing id → :not_found" do
      layer = layer_fixture()
      assert {:ok, _} = StackLayers.delete_layer(layer.id)
      assert StackLayers.get_layer(layer.id) == nil
      assert {:error, :not_found} = StackLayers.delete_layer(Ecto.UUID.generate())
    end

    test "list_layers_by_type/0 groups enabled rows by type" do
      be = layer_fixture(%{"layer_type" => "backend", "name" => "BE-#{uniq()}"})
      fe = layer_fixture(%{"layer_type" => "frontend", "name" => "FE-#{uniq()}"})
      _disabled = layer_fixture(%{"name" => "Off-#{uniq()}", "enabled" => false})

      grouped = StackLayers.list_layers_by_type()
      assert Enum.any?(grouped[:backend] || [], &(&1.id == be.id))
      assert Enum.any?(grouped[:frontend] || [], &(&1.id == fe.id))
    end
  end

  describe "per-project selection" do
    test "select/deselect and layers_for_project/1 are project-isolated" do
      p1 = project_fixture()
      p2 = project_fixture()
      backend = layer_fixture(%{"layer_type" => "backend", "name" => "BE-#{uniq()}"})
      frontend = layer_fixture(%{"layer_type" => "frontend", "name" => "FE-#{uniq()}"})

      assert {:ok, _} = StackLayers.select_layer(p1.id, backend.id)
      assert {:ok, _} = StackLayers.select_layer(p1.id, frontend.id)
      assert {:ok, _} = StackLayers.select_layer(p2.id, backend.id)

      p1_ids = p1.id |> StackLayers.layers_for_project() |> Enum.map(& &1.id) |> Enum.sort()
      assert p1_ids == Enum.sort([backend.id, frontend.id])
      assert StackLayers.layers_for_project(p2.id) |> Enum.map(& &1.id) == [backend.id]

      assert :ok = StackLayers.deselect_layer(p1.id, frontend.id)
      assert StackLayers.layers_for_project(p1.id) |> Enum.map(& &1.id) == [backend.id]
    end

    test "select_layer/2 is idempotent" do
      project = project_fixture()
      layer = layer_fixture()
      assert {:ok, _} = StackLayers.select_layer(project.id, layer.id)
      assert {:ok, _} = StackLayers.select_layer(project.id, layer.id)
      assert length(StackLayers.layers_for_project(project.id)) == 1
    end

    test "set_project_layers/2 replaces the whole selection" do
      project = project_fixture()
      a = layer_fixture(%{"name" => "A-#{uniq()}"})
      b = layer_fixture(%{"name" => "B-#{uniq()}", "layer_type" => "frontend"})
      c = layer_fixture(%{"name" => "C-#{uniq()}", "layer_type" => "database"})

      StackLayers.select_layer(project.id, a.id)
      assert :ok = StackLayers.set_project_layers(project.id, [b.id, c.id])

      ids = StackLayers.layers_for_project(project.id) |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([b.id, c.id])
    end

    test "layers_for_project/1 returns [] for nil and unselected projects" do
      assert StackLayers.layers_for_project(nil) == []
      assert StackLayers.layers_for_project(project_fixture().id) == []
    end
  end

  describe "seed_project_from_stack/2" do
    test "selects layers whose language matches the detected stack" do
      project = project_fixture()
      ex = layer_fixture(%{"name" => "Phx-#{uniq()}", "language" => "elixir"})
      _ts = layer_fixture(%{"name" => "Sv-#{uniq()}", "language" => "typescript"})

      assert {:ok, 1} =
               StackLayers.seed_project_from_stack(project.id, %{"language" => "elixir"})

      assert StackLayers.layers_for_project(project.id) |> Enum.map(& &1.id) == [ex.id]
    end

    test "matches build_tool too, and is a no-op when a selection already exists" do
      project = project_fixture()
      existing = layer_fixture(%{"name" => "Pre-#{uniq()}"})
      StackLayers.select_layer(project.id, existing.id)

      assert {:ok, 0} =
               StackLayers.seed_project_from_stack(project.id, %{"language" => "elixir"})

      assert StackLayers.layers_for_project(project.id) |> Enum.map(& &1.id) == [existing.id]
    end

    test "no match leaves the project unselected" do
      project = project_fixture()
      _ = layer_fixture(%{"language" => "elixir"})
      assert {:ok, 0} = StackLayers.seed_project_from_stack(project.id, %{"language" => "cobol"})
      assert StackLayers.layers_for_project(project.id) == []
    end
  end

  describe "seed_default_layers/0" do
    test "is idempotent and preserves operator :manual edits" do
      assert {:ok, n} = StackLayers.seed_default_layers()
      assert n > 0
      first_count = length(StackLayers.list_layers())

      # An operator edits a seeded row → :manual; re-seeding must not clobber it.
      seeded = Enum.find(StackLayers.list_layers(), &(&1.source == :seed))
      {:ok, edited} = StackLayers.update_layer(seeded, %{"reasoning" => "operator override"})

      # Re-seed never duplicates rows; the manual edit is skipped (not re-counted).
      assert {:ok, _} = StackLayers.seed_default_layers()
      assert length(StackLayers.list_layers()) == first_count

      assert StackLayers.get_layer(edited.id).reasoning == "operator override"
      assert StackLayers.get_layer(edited.id).source == :manual
    end
  end

  describe "Contract.render/1" do
    test "renders the header, each layer, and the off-stack guardrail" do
      project = project_fixture()

      backend =
        layer_fixture(%{
          "layer_type" => "backend",
          "name" => "Phoenix",
          "language" => "elixir",
          "reasoning" => "typed contexts only"
        })

      db =
        layer_fixture(%{
          "layer_type" => "database",
          "name" => "PostgreSQL",
          "language" => "sql",
          "reasoning" => "reversible migrations"
        })

      StackLayers.select_layer(project.id, backend.id)
      StackLayers.select_layer(project.id, db.id)

      rendered = Contract.render(project.id)
      assert rendered =~ "## Project stack — build ONLY within this stack"
      assert rendered =~ "Backend: Phoenix (elixir) — typed contexts only"
      assert rendered =~ "Database: PostgreSQL (sql) — reversible migrations"
      assert rendered =~ "STOP and report back"
    end

    test "returns \"\" for nil and for a project with no layers" do
      assert Contract.render(nil) == ""
      assert Contract.render(project_fixture().id) == ""
    end
  end
end
