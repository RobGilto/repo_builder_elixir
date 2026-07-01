defmodule RepoBuilder.Orchestrator.GateResolverTest do
  @moduledoc """
  Precedence, capability-token fill, empty-token skip, and typed_enforcement variant
  selection for the quality-gate resolver (quality-gate-plugins). Pure (in-memory
  `Project` structs against the shipped `priv/quality_gates/` builtins), so async.
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.Orchestrator.GateResolver
  alias RepoBuilder.Projects.Capabilities
  alias RepoBuilder.Projects.Project

  defp project(caps_attrs) do
    language = to_string(caps_attrs[:language] || "generic")
    caps = struct(Capabilities.detect(%{"language" => language}), caps_attrs)

    %Project{
      id: nil,
      name: "p",
      root_path: nil,
      stack: %{"language" => caps.language},
      capabilities: Capabilities.to_map(caps),
      command_pack: "auto",
      command_pack_version: "latest",
      isolation_mode: :direct,
      status: :active
    }
  end

  defp commands(stages), do: Enum.map(stages, & &1.command)
  defp ids(stages), do: Enum.map(stages, & &1.id)

  describe "precedence + stack selection" do
    test "resolves the builtin for the detected stack" do
      p = project(%{language: "python", typed_enforcement: :standard})
      assert {:ok, gate} = GateResolver.resolve(p)
      assert gate.stack == "python"
      assert gate.source == :builtin
    end

    test "an unknown stack falls back to generic" do
      p = project(%{language: "haskell", format_command: "fourmolu", test_command: "cabal test"})
      assert {:ok, gate} = GateResolver.resolve(p)
      assert gate.stack == "generic"
    end
  end

  describe "capability-token fill + empty-token skip" do
    test "fills stage commands from the project capabilities" do
      p = project(%{language: "python", typed_enforcement: :standard})
      assert {:ok, gate} = GateResolver.resolve(p)
      assert "uv run ruff format --check" in commands(gate.stages)
      assert "uv run pytest" in commands(gate.stages)
    end

    test "drops a stage whose required token is empty" do
      # No lint_command → the lint stage is dropped rather than emitting a broken command.
      p =
        project(%{
          language: "generic",
          format_command: "fmt",
          test_command: "t",
          typecheck_command: "tc",
          lint_command: nil,
          typed_enforcement: :standard
        })

      assert {:ok, gate} = GateResolver.resolve(p)
      refute "lint" in ids(gate.stages)
      assert "format" in ids(gate.stages)
    end
  end

  describe "typed_enforcement variant selection" do
    defp type_commands(gate) do
      gate.stages |> Enum.filter(&(&1.id in ["type", "type-coverage"])) |> commands()
    end

    test ":off drops the type stage entirely" do
      p = project(%{language: "python", typed_enforcement: :off})
      assert {:ok, gate} = GateResolver.resolve(p)
      assert type_commands(gate) == []
      refute gate.degraded
    end

    test ":standard keeps the plain checker" do
      p = project(%{language: "python", typed_enforcement: :standard})
      assert {:ok, gate} = GateResolver.resolve(p)
      assert type_commands(gate) == ["uv run pyright"]
      refute gate.degraded
    end

    test ":strict swaps in the strict command + coverage sub-stage" do
      p = project(%{language: "python", typed_enforcement: :strict})
      assert {:ok, gate} = GateResolver.resolve(p)

      assert type_commands(gate) == [
               "uv run pyright --strict",
               "uv run mypy --disallow-untyped-defs"
             ]

      refute gate.degraded
    end

    test "an empty strict token degrades :strict to :standard" do
      # A python descriptor but with the strict/coverage tokens blanked out: the resolver
      # must degrade to the plain checker rather than emit a broken command.
      p =
        project(%{
          language: "python",
          typed_enforcement: :strict,
          typecheck_strict_command: nil,
          type_coverage_command: nil
        })

      assert {:ok, gate} = GateResolver.resolve(p)
      assert type_commands(gate) == ["uv run pyright"]
      assert gate.degraded
    end
  end
end
