defmodule RepoBuilder.Plugins.DesignSystemPluginsTest do
  @moduledoc """
  The shipped design-system sample plugins (design-system-plugins, Phase 5): every manifest
  validates and declares a `design_system` contribution whose descriptor parses, and once a
  plugin is active the resolver picks its design system over the builtin default via
  `Activation.contributions/2` — proving "add a design system (web OR terminal) = one
  package, zero core change".
  """
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.Orchestrator.DesignResolver
  alias RepoBuilder.Plugins
  alias RepoBuilder.Plugins.{Activation, Contribution, DesignSystem, Manifest}
  alias RepoBuilder.Projects

  @lib Path.expand("plugin_library")
  @plugins ~w(design-system-phoenix design-system-tui-bubbletea)

  defp install(id) do
    dir = Path.join(@lib, id)
    manifest = dir |> Path.join("plugin.json") |> File.read!() |> Jason.decode!()

    {:ok, plugin} =
      Plugins.install_record(%{
        plugin_id: id,
        version: manifest["version"],
        source: "library",
        install_path: dir,
        manifest: manifest,
        status: :installed
      })

    plugin
  end

  defp project(stack) do
    {:ok, project} =
      Projects.create_project(%{
        "name" => "ds-plug-#{System.unique_integer([:positive])}",
        "root_path" => "/tmp/ds-plug-#{System.unique_integer([:positive])}",
        "stack" => stack
      })

    project
  end

  describe "shipped design-system plugins" do
    test "every manifest validates and declares a design_system contribution that parses" do
      for id <- @plugins do
        dir = Path.join(@lib, id)
        assert {:ok, %Manifest{contributions: contributions}} = Manifest.read(dir)

        %Contribution{path: path} = Enum.find(contributions, &(&1.kind == :design_system))
        assert path, "#{id} missing a :design_system contribution"
        assert {:ok, %DesignSystem{}} = DesignSystem.read(Path.join(dir, path))
      end
    end
  end

  describe "activation + resolver precedence" do
    test "an active web plugin's design system wins over the builtin default" do
      p = project(%{"language" => "elixir", "surface" => "web", "framework" => "phoenix"})

      # Builtin default before activation.
      assert {:ok, %{source: :builtin, name: "web-phoenix"}} = DesignResolver.resolve(p)

      install("design-system-phoenix")
      {:ok, _} = Plugins.activate(p.id, "design-system-phoenix")

      assert [%Activation.Resolved{kind: :design_system}] =
               Activation.contributions(p.id, :design_system)

      assert {:ok, resolved} = DesignResolver.resolve(p)
      assert resolved.source == :plugin
      assert resolved.descriptor.tokens["provenance"] =~ "design-system-phoenix"
    end

    test "an active TUI plugin's design system wins for a TUI project" do
      p = project(%{"language" => "go", "surface" => "tui", "framework" => "bubbletea"})
      assert {:ok, %{source: :builtin}} = DesignResolver.resolve(p)

      install("design-system-tui-bubbletea")
      {:ok, _} = Plugins.activate(p.id, "design-system-tui-bubbletea")

      assert {:ok, %{source: :plugin}} = DesignResolver.resolve(p)
    end
  end
end
