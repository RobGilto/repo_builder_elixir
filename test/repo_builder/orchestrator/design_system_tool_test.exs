defmodule RepoBuilder.Orchestrator.DesignSystemToolTest do
  @moduledoc """
  The `resolve_design_system` tool (design-system-plugins) round-trips through
  `Tools.call/3`: it is catalogued + advertised in the derived MCP manifest, resolves the
  bound project's design system (web + TUI), honours the `section`/`component` filters, and
  reports `:no_project` for a platform orchestrator.
  """
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.Orchestrator.ToolCatalog
  alias RepoBuilder.Orchestrator.Tools
  alias RepoBuilder.Orchestrators
  alias RepoBuilder.Projects

  defp uniq, do: System.unique_integer([:positive])

  defp orch_for(stack) do
    {:ok, project} =
      Projects.create_project(%{
        "name" => "ds-tool-#{uniq()}",
        "root_path" => Path.join(System.tmp_dir!(), "ds_#{uniq()}"),
        "stack" => stack
      })

    {:ok, orch} = Orchestrators.get_or_create_for_project(project.id)
    orch
  end

  describe "catalog + manifest" do
    test "resolve_design_system is advertised by names/0" do
      assert "resolve_design_system" in ToolCatalog.names()
    end

    test "resolve_design_system is present in the derived pi manifest" do
      assert Enum.any?(ToolCatalog.pi_manifest(), &(&1.name == "resolve_design_system"))
    end
  end

  describe "resolution" do
    test "resolves the Phoenix design system for a bound web project" do
      orch = orch_for(%{"language" => "elixir", "surface" => "web", "framework" => "phoenix"})
      assert {:ok, result} = Tools.call("resolve_design_system", orch.id, %{})

      assert result["surface"] == "web"
      assert result["framework"] == "phoenix"
      assert result["name"] == "web-phoenix"
      assert result["source"] == "builtin"
      assert Enum.any?(result["components"], &(&1["name"] == "input"))
      assert result["rules"] != []
    end

    test "resolves the Bubble Tea design system (with paradigm) for a bound TUI project" do
      orch = orch_for(%{"language" => "go", "surface" => "tui", "framework" => "bubbletea"})
      assert {:ok, result} = Tools.call("resolve_design_system", orch.id, %{})

      assert result["name"] == "tui-bubbletea"
      assert result["paradigm"] == "mvu"
    end

    test "the section filter narrows to one slice" do
      orch = orch_for(%{"language" => "elixir", "surface" => "web", "framework" => "phoenix"})
      assert {:ok, result} = Tools.call("resolve_design_system", orch.id, %{"section" => "rules"})

      assert Map.has_key?(result, "rules")
      refute Map.has_key?(result, "components")
      refute Map.has_key?(result, "tokens")
    end

    test "the component filter narrows the inventory" do
      orch = orch_for(%{"language" => "elixir", "surface" => "web", "framework" => "phoenix"})

      assert {:ok, result} =
               Tools.call("resolve_design_system", orch.id, %{"component" => "input"})

      names = Enum.map(result["components"], & &1["name"])
      assert "input" in names
      refute "table" in names
    end

    test "a platform orchestrator with no project reports :no_project" do
      {:ok, orch} = Orchestrators.get_or_create_default()
      assert {:error, :no_project} = Tools.call("resolve_design_system", orch.id, %{})
    end
  end
end
