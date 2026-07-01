defmodule RepoBuilder.Plugins.QualityGatePluginsTest do
  @moduledoc """
  The six shipped stack gate plugins (quality-gate-plugins, Phase 3): every manifest
  validates, every `quality_gate` descriptor parses, and once a stack plugin is active the
  resolver picks its gate over the builtin default via `Activation.contributions/2`.
  """
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.Orchestrator.GateResolver
  alias RepoBuilder.Plugins
  alias RepoBuilder.Plugins.{Activation, Contribution, Manifest, QualityGate}
  alias RepoBuilder.Projects
  alias RepoBuilder.Projects.Capabilities

  @lib Path.expand("plugin_library")
  @stacks ~w(elixir rust go python typescript ruby)

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

  describe "shipped gate plugins" do
    test "every manifest validates and declares a quality_gate + skill contribution" do
      for stack <- @stacks do
        dir = Path.join(@lib, "quality-gates-#{stack}")
        assert {:ok, %Manifest{contributions: contributions}} = Manifest.read(dir)

        kinds = Enum.map(contributions, & &1.kind)
        assert :quality_gate in kinds, "quality-gates-#{stack} missing :quality_gate"
        assert :skill in kinds, "quality-gates-#{stack} missing :skill"

        # The gate descriptor asset exists and parses.
        %Contribution{path: gate_path} = Enum.find(contributions, &(&1.kind == :quality_gate))
        assert {:ok, %QualityGate{stages: [_ | _]}} = QualityGate.read(Path.join(dir, gate_path))
      end
    end
  end

  describe "activation + resolver precedence" do
    test "an active stack plugin's gate wins over the builtin default" do
      caps =
        %{"language" => "python"}
        |> Capabilities.detect()
        |> Map.put(:typed_enforcement, :standard)
        |> Capabilities.to_map()

      {:ok, project} =
        Projects.create_project(%{
          "name" => "gate-plug-#{System.unique_integer([:positive])}",
          "root_path" => "/tmp/gate-plug-#{System.unique_integer([:positive])}",
          "stack" => %{"language" => "python"},
          "capabilities" => caps
        })

      # Builtin default before activation.
      assert {:ok, %{source: :builtin}} = GateResolver.resolve(project)

      install("quality-gates-python")
      {:ok, _} = Plugins.activate(project.id, "quality-gates-python")

      assert [%Activation.Resolved{kind: :quality_gate}] =
               Activation.contributions(project.id, :quality_gate)

      # With the plugin active the resolver now sources the gate from the plugin.
      assert {:ok, %{source: :plugin, stack: "python"}} = GateResolver.resolve(project)
    end
  end
end
