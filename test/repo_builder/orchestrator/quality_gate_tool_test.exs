defmodule RepoBuilder.Orchestrator.QualityGateToolTest do
  @moduledoc """
  The `run_quality_gate` tool (quality-gate-plugins) round-trips through `Tools.call/3`:
  it is catalogued + advertised in the derived MCP manifest, returns the ordered command
  PLAN with no outputs, and EVALUATES a GateResult from worker-captured outputs.
  """
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.Orchestrator.ToolCatalog
  alias RepoBuilder.Orchestrator.Tools
  alias RepoBuilder.Orchestrators
  alias RepoBuilder.Projects
  alias RepoBuilder.Projects.Capabilities

  defp uniq, do: System.unique_integer([:positive])

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "rb_gate_#{uniq()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp python_orch do
    {:ok, project} =
      Projects.create_project(%{
        "name" => "gate-proj-#{uniq()}",
        "root_path" => tmp_dir(),
        "stack" => %{"language" => "python"},
        "capabilities" =>
          %{"language" => "python"}
          |> Capabilities.detect()
          |> Map.put(:typed_enforcement, :standard)
          |> Capabilities.to_map()
      })

    {:ok, orch} = Orchestrators.get_or_create_for_project(project.id)
    orch
  end

  describe "catalog + manifest" do
    test "run_quality_gate is advertised by names/0" do
      assert "run_quality_gate" in ToolCatalog.names()
    end

    test "run_quality_gate is present in the derived pi manifest" do
      assert Enum.any?(ToolCatalog.pi_manifest(), &(&1.name == "run_quality_gate"))
    end
  end

  describe "run_quality_gate/plan mode" do
    test "returns the ordered per_phase command plan", %{} do
      orch = python_orch()
      assert {:ok, result} = Tools.call("run_quality_gate", orch.id, %{})
      assert result["mode"] == "plan"
      assert result["stack"] == "python"
      commands = Enum.map(result["commands"], & &1["stage_id"])
      assert "format" in commands
      assert "test" in commands
      # mutation is pre_merge — not in the per_phase plan.
      refute "mutation" in commands
    end

    test "pre_merge cadence surfaces the mutation stage" do
      orch = python_orch()

      assert {:ok, result} =
               Tools.call("run_quality_gate", orch.id, %{"cadence" => "pre_merge"})

      assert "mutation" in Enum.map(result["commands"], & &1["stage_id"])
    end
  end

  describe "run_quality_gate/result mode" do
    test "evaluates worker outputs into a GateResult", %{} do
      orch = python_orch()

      outputs = [
        %{"stage_id" => "format", "exit_code" => 0, "output" => ""},
        %{
          "stage_id" => "lint",
          "exit_code" => 1,
          "output" => "src/app.py:7:1 F821 undefined name"
        },
        %{"stage_id" => "test", "exit_code" => 0, "output" => ""}
      ]

      assert {:ok, result} =
               Tools.call("run_quality_gate", orch.id, %{"outputs" => outputs})

      assert result["mode"] == "result"
      assert result["green"] == false
      assert result["failed_stage"] == "lint"

      lint = Enum.find(result["stages"], &(&1["stage_id"] == "lint"))
      assert [%{"file" => "src/app.py", "line" => 7}] = lint["diagnostics"]
    end

    test "a platform orchestrator with no project reports :no_project" do
      {:ok, orch} = Orchestrators.get_or_create_default()
      assert {:error, :no_project} = Tools.call("run_quality_gate", orch.id, %{})
    end
  end
end
