defmodule RepoBuilder.Orchestrator.DesignContractTest do
  @moduledoc """
  The worker-facing design contract (design-system-plugins): a UI project renders a
  compact block naming its component vocabulary + rules + the MCP-tool pointer; a non-UI
  project (generic base) and a nil project render `""` (back-compatible). DB-backed since
  the contract resolves the bound project.
  """
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.Orchestrator.DesignContract
  alias RepoBuilder.Projects

  defp project(stack) do
    {:ok, project} =
      Projects.create_project(%{
        "name" => "ds-#{System.unique_integer([:positive])}",
        "root_path" => "/tmp/ds-#{System.unique_integer([:positive])}",
        "stack" => stack
      })

    project
  end

  test "a Phoenix project renders a design block naming a core component + the tool pointer" do
    p = project(%{"language" => "elixir", "surface" => "web", "framework" => "phoenix"})
    block = DesignContract.render(p.id)

    assert block =~ "Design system"
    assert block =~ "web/phoenix"
    assert block =~ "<.input>"
    assert block =~ "resolve_design_system"
  end

  test "a TUI project surfaces its paradigm" do
    p = project(%{"language" => "go", "surface" => "tui", "framework" => "bubbletea"})
    block = DesignContract.render(p.id)

    assert block =~ "tui/bubbletea"
    assert block =~ "Paradigm: mvu"
    assert block =~ "Model/Init/Update/View" or block =~ "Cmd"
  end

  test "a non-UI project (generic base) renders an empty contract" do
    p = project(%{"language" => "elixir", "surface" => "none", "framework" => "none"})
    assert DesignContract.render(p.id) == ""
  end

  test "a nil project id renders an empty contract without raising" do
    assert DesignContract.render(nil) == ""
  end
end
