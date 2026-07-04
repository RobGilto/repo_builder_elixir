defmodule RepoBuilder.Orchestrator.ReflectionsTest do
  @moduledoc """
  Self-healing Phase 5 parity gap: verbal self-improving memory (Reflexion) — reflections
  persist scoped to a project and the SystemPrompt injects the last N for the next run, plus the
  shared leadership playbook is present in every prompt.
  """
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.Orchestrator.{Reflections, SystemPrompt}
  alias RepoBuilder.Orchestrators
  alias RepoBuilder.Projects

  test "record/1 persists and list_recent/2 returns newest first (unscoped)" do
    {:ok, _} = Reflections.record(%{lesson: "lesson one"})
    {:ok, _} = Reflections.record(%{lesson: "lesson two"})

    lessons = Reflections.list_recent(nil, 5) |> Enum.map(& &1.lesson)
    assert lessons == ["lesson two", "lesson one"]
  end

  test "list_recent/2 is scoped to a project" do
    {:ok, project} =
      Projects.create_project(%{
        "name" => "refl-#{System.unique_integer([:positive])}",
        "root_path" => "/tmp/refl-#{System.unique_integer([:positive])}"
      })

    {:ok, _} = Reflections.record(%{lesson: "scoped lesson", project_id: project.id})
    {:ok, _} = Reflections.record(%{lesson: "other lesson"})

    scoped = Reflections.list_recent(project.id, 5) |> Enum.map(& &1.lesson)
    assert scoped == ["scoped lesson"]
  end

  test "SystemPrompt injects recent reflections for the bound project" do
    {:ok, project} =
      Projects.create_project(%{
        "name" => "refl-#{System.unique_integer([:positive])}",
        "root_path" => "/tmp/refl-#{System.unique_integer([:positive])}"
      })

    {:ok, orch} =
      Orchestrators.create(%{
        name: "orch-#{System.unique_integer([:positive])}",
        harness: "fake",
        model: "fake-model",
        project_id: project.id
      })

    {:ok, _} =
      Reflections.record(%{lesson: "always run the migrations first", project_id: project.id})

    prompt = SystemPrompt.build(orch)
    assert prompt =~ "Lessons from past runs"
    assert prompt =~ "always run the migrations first"
  end

  test "the leadership playbook is present in every orchestrator prompt" do
    {:ok, orch} =
      Orchestrators.create(%{
        name: "orch-#{System.unique_integer([:positive])}",
        harness: "fake",
        model: "fake-model"
      })

    prompt = SystemPrompt.build(orch)
    assert prompt =~ "Autonomous leadership"
    assert prompt =~ "Available subagent templates & worker roles"
    assert SystemPrompt.leader_expertise_block() =~ "record_progress"
  end
end
