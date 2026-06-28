defmodule RepoBuilder.Orchestrator.ToolsReflectionTest do
  @moduledoc """
  Self-healing Phase 5 (Reflexion) write gap: the orchestrator can BANK a verbal lesson
  mid-run via `record_reflection` through `Tools.call/3` (the harness-blind entry point),
  not just at the automatic completion/escalation moments. The lesson persists, is scoped
  to the orchestrator's bound project, and back-fills its goal from the active ledger.
  """
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.Orchestrator.{Reflections, Tools}
  alias RepoBuilder.Orchestrators
  alias RepoBuilder.Projects

  defp uniq, do: System.unique_integer([:positive])

  defp project do
    {:ok, project} =
      Projects.create_project(%{
        "name" => "refl-tool-#{uniq()}",
        "root_path" => "/tmp/refl-tool-#{uniq()}"
      })

    project
  end

  defp orchestrator(attrs \\ %{}) do
    {:ok, orch} =
      Orchestrators.create(
        Map.merge(%{name: "orch-#{uniq()}", harness: "fake", model: "fake-model"}, attrs)
      )

    orch
  end

  describe "record_reflection tool" do
    test "banks a lesson scoped to the orchestrator's bound project" do
      project = project()
      orch = orchestrator(%{project_id: project.id})

      assert {:ok, %{"status" => "recorded", "reflection_id" => id}} =
               Tools.call("record_reflection", orch.id, %{
                 "lesson" => "check disk before re-dispatching a retired worker"
               })

      assert is_binary(id)

      scoped = Reflections.list_recent(project.id, 5)

      assert [%{lesson: "check disk before re-dispatching a retired worker"} = reflection] =
               scoped

      assert reflection.project_id == project.id
      assert reflection.orchestrator_id == orch.id
    end

    test "an unscoped (platform) orchestrator records an unscoped lesson" do
      orch = orchestrator()

      assert {:ok, %{"status" => "recorded"}} =
               Tools.call("record_reflection", orch.id, %{"lesson" => "an unscoped lesson"})

      assert Enum.any?(Reflections.list_recent(nil, 5), &(&1.lesson == "an unscoped lesson"))
    end

    test "a blank lesson is rejected and writes no row" do
      orch = orchestrator()
      before = length(Reflections.list_recent(nil, 50))

      assert {:error, _reason} = Tools.call("record_reflection", orch.id, %{"lesson" => "  "})
      assert {:error, _reason} = Tools.call("record_reflection", orch.id, %{})

      assert length(Reflections.list_recent(nil, 50)) == before
    end

    test "the goal is back-filled from the active ledger when omitted" do
      project = project()
      orch = orchestrator(%{project_id: project.id})

      {:ok, %{"status" => "goal_set"}} =
        Tools.call("set_goal", orch.id, %{
          "goal" => "ship the sprite pipeline",
          "definition_of_done" => "32 facings on disk"
        })

      assert {:ok, %{"status" => "recorded"}} =
               Tools.call("record_reflection", orch.id, %{"lesson" => "slice with an alpha bbox"})

      assert [reflection] = Reflections.list_recent(project.id, 5)
      assert reflection.goal == "ship the sprite pipeline"
    end

    test "an explicit goal overrides the active ledger goal" do
      orch = orchestrator()

      assert {:ok, %{"status" => "recorded"}} =
               Tools.call("record_reflection", orch.id, %{
                 "lesson" => "prefer sheet mode",
                 "goal" => "an explicit goal"
               })

      assert Enum.any?(
               Reflections.list_recent(nil, 5),
               &(&1.lesson == "prefer sheet mode" and &1.goal == "an explicit goal")
             )
    end
  end
end
