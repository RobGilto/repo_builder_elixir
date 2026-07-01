defmodule RepoBuilder.Orchestrator.QualityGateE2ETest do
  @moduledoc """
  End-to-end phase-with-gate loop (quality-gate-plugins, Phase 5), driven through the
  harness-blind `Tools.call/3` seam (no real toolchains): a phase's `:test` stage runs the
  resolved gate, goes RED on a seeded lint failure, holds the phase on `:test`, then a fix
  makes the gate GREEN and the phase advances to `:review`. A `pre_merge` mutation gate runs
  once at close and its score is recorded.
  """
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.Orchestrator.Tools
  alias RepoBuilder.Orchestrator.Workstreams
  alias RepoBuilder.Orchestrators
  alias RepoBuilder.Projects
  alias RepoBuilder.Projects.Capabilities

  defp uniq, do: System.unique_integer([:positive])

  defp setup_orch do
    dir = Path.join(System.tmp_dir!(), "rb_gate_e2e_#{uniq()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    caps =
      %{"language" => "python"}
      |> Capabilities.detect()
      |> Map.put(:typed_enforcement, :standard)
      |> Capabilities.to_map()

    {:ok, project} =
      Projects.create_project(%{
        "name" => "e2e-#{uniq()}",
        "root_path" => dir,
        "stack" => %{"language" => "python"},
        "capabilities" => caps
      })

    {:ok, orch} = Orchestrators.get_or_create_for_project(project.id)
    orch
  end

  defp current_phase(orch, ws_id) do
    {:ok, record} = Workstreams.get_workstream(orch.id, ws_id)
    Enum.find(record.phases, &(&1.position == record.current_phase_position))
  end

  test "a red gate holds :test, a fix turns it green and advances to :review" do
    orch = setup_orch()

    {:ok, %{"workstream_id" => ws}} =
      Tools.call("create_workstream", orch.id, %{"title" => "Build", "goal" => "ship"})

    {:ok, _} =
      Tools.call("plan_phases", orch.id, %{
        "workstream" => ws,
        "phases" => [%{"title" => "Only phase"}]
      })

    # spec → implement pass.
    {:ok, _} =
      Tools.call("record_stage", orch.id, %{
        "workstream" => ws,
        "stage" => "spec",
        "outcome" => "passed",
        "artifact" => "specs/x.md"
      })

    {:ok, _} =
      Tools.call("record_stage", orch.id, %{
        "workstream" => ws,
        "stage" => "implement",
        "outcome" => "passed"
      })

    assert current_phase(orch, ws).current_stage == :test

    # Run the gate; seed a RED lint output → evaluated GateResult is not green.
    red_outputs = [
      %{"stage_id" => "format", "exit_code" => 0, "output" => ""},
      %{
        "stage_id" => "lint",
        "exit_code" => 1,
        "output" => "src/app.py:3:1 F821 undefined name x"
      }
    ]

    {:ok, red_result} = Tools.call("run_quality_gate", orch.id, %{"outputs" => red_outputs})
    refute red_result["green"]
    assert red_result["failed_stage"] == "lint"

    # Record the red test outcome with the gate evidence → phase stays on :test.
    {:ok, _} =
      Tools.call("record_stage", orch.id, %{
        "workstream" => ws,
        "stage" => "test",
        "outcome" => "failed",
        "gate" => red_result
      })

    assert current_phase(orch, ws).current_stage == :test

    # Fix worker ran; re-run the gate all-green.
    green_outputs = [
      %{"stage_id" => "format", "exit_code" => 0, "output" => ""},
      %{"stage_id" => "lint", "exit_code" => 0, "output" => ""},
      %{"stage_id" => "type", "exit_code" => 0, "output" => ""},
      %{"stage_id" => "test", "exit_code" => 0, "output" => ""}
    ]

    {:ok, green_result} = Tools.call("run_quality_gate", orch.id, %{"outputs" => green_outputs})
    assert green_result["green"]

    {:ok, _} =
      Tools.call("record_stage", orch.id, %{
        "workstream" => ws,
        "stage" => "test",
        "outcome" => "passed",
        "gate" => green_result
      })

    # Green gate advances the phase to :review, and the gate evidence persisted.
    phase = current_phase(orch, ws)
    assert phase.current_stage == :review
    assert get_in(phase.stages, ["test", "gate", "green"]) == true
  end

  test "a pre_merge mutation gate runs once at close and records its score" do
    orch = setup_orch()

    {:ok, %{"workstream_id" => ws}} =
      Tools.call("create_workstream", orch.id, %{"title" => "MutWS", "goal" => "ship"})

    # The pre_merge cadence surfaces exactly the mutation stage.
    {:ok, plan} = Tools.call("run_quality_gate", orch.id, %{"cadence" => "pre_merge"})
    mutation_stages = Enum.filter(plan["commands"], &(&1["stage_id"] == "mutation"))
    assert length(mutation_stages) == 1

    # A passing mutation run → green pre_merge result recorded as workstream evidence.
    {:ok, result} =
      Tools.call("run_quality_gate", orch.id, %{
        "cadence" => "pre_merge",
        "outputs" => [%{"stage_id" => "mutation", "exit_code" => 0, "output" => "score: 0.92"}]
      })

    assert result["green"]
    assert result["cadence"] == "pre_merge"

    {:ok, closed} =
      Tools.call("close_workstream", orch.id, %{"workstream" => ws, "status" => "done"})

    assert closed["status"] == "done"
  end
end
