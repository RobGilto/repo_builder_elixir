defmodule RepoBuilder.Orchestrator.GateRunnerTest do
  @moduledoc """
  Ordered execution, stop-at-first-strict-red, diagnostic parsing, and cadence filtering
  for the quality-gate runner (quality-gate-plugins). Fixture-driven via an injected
  `exec_fun`, so no real toolchains run.
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.Orchestrator.GateResolver
  alias RepoBuilder.Orchestrator.GateRunner
  alias RepoBuilder.Projects.Capabilities
  alias RepoBuilder.Projects.Project

  defp gate(caps_attrs) do
    language = to_string(caps_attrs[:language] || "generic")
    caps = struct(Capabilities.detect(%{"language" => language}), caps_attrs)

    p = %Project{
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

    {:ok, resolved} = GateResolver.resolve(p)
    resolved
  end

  # An exec_fun that fails a given stage id (nonzero exit + output), else passes.
  defp fail_on(stage_id, output) do
    fn stage ->
      if stage.id == stage_id,
        do: %{exit_code: 1, output: output},
        else: %{exit_code: 0, output: ""}
    end
  end

  describe "run/3" do
    test "all-green when every stage passes" do
      g = gate(%{language: "python", typed_enforcement: :standard})
      result = GateRunner.run(g, :per_phase, fn _ -> %{exit_code: 0, output: ""} end)
      assert result.green
      assert result.failed_stage == nil
      assert Enum.all?(result.stages, &(&1.status == :passed))
    end

    test "stops at the first strict red — later stages are skipped" do
      g = gate(%{language: "python", typed_enforcement: :standard})
      result = GateRunner.run(g, :per_phase, fail_on("lint", "src/x.py:3:1 undefined name"))

      refute result.green
      assert result.failed_stage == "lint"

      statuses = Map.new(result.stages, &{&1.stage_id, &1.status})
      assert statuses["format"] == :passed
      assert statuses["lint"] == :failed
      # A stage AFTER the failed strict stage never runs.
      assert statuses["test"] == :skipped
    end

    test "parses file:line diagnostics for a :file_line stage" do
      g = gate(%{language: "python", typed_enforcement: :standard})

      result =
        GateRunner.run(g, :per_phase, fail_on("lint", "src/app.py:42:5 F821 undefined name x"))

      lint = Enum.find(result.stages, &(&1.stage_id == "lint"))
      assert [%{file: "src/app.py", line: 42, message: message}] = lint.diagnostics
      assert message =~ "undefined name"
    end

    test ":pre_merge stages are excluded from a :per_phase run" do
      g = gate(%{language: "python", typed_enforcement: :standard})
      per_phase = GateRunner.plan(g, :per_phase)
      pre_merge = GateRunner.plan(g, :pre_merge)

      refute "mutation" in Enum.map(per_phase, & &1.id)
      assert "mutation" in Enum.map(pre_merge, & &1.id)
    end

    test "to_map/1 serializes a JSON-friendly result" do
      g = gate(%{language: "python", typed_enforcement: :standard})
      result = GateRunner.run(g, :per_phase, fn _ -> %{exit_code: 0, output: ""} end)
      map = GateRunner.to_map(result)
      assert map["green"] == true
      assert is_list(map["stages"])
      assert Enum.all?(map["stages"], &is_map/1)
    end
  end
end
