defmodule RepoBuilder.Orchestrator.SystemPromptProjectTest do
  @moduledoc """
  Orchestrator↔project binding, Phase 2: the system prompt resolves its project from the
  explicit `orchestrator.project_id` first — naming the bound project (name + root) and
  embedding its stored `context_primer` — and falls back to today's working-dir lookup
  for the unbound/platform case (back-compat).
  """
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.Orchestrator.{Orchestrator, SystemPrompt}
  alias RepoBuilder.Projects

  defp project_fixture do
    n = System.unique_integer([:positive])

    {:ok, project} =
      Projects.create_project(%{
        "name" => "primed-#{n}",
        "root_path" => "/tmp/primed-#{n}",
        "context_primer" => "Target project: primed-#{n}\nStack: elixir (mix)"
      })

    project
  end

  defp orchestrator(attrs) do
    Map.merge(
      %Orchestrator{name: "default", harness: "fake", provider: nil, model: nil, metadata: %{}},
      attrs
    )
  end

  test "a project-bound orchestrator names the project + root and includes its primer" do
    project = project_fixture()
    prompt = SystemPrompt.build(orchestrator(%{project_id: project.id}))

    assert prompt =~ "You are working on project #{project.name} at `#{project.root_path}`"
    assert prompt =~ "Target project: #{project.name}"
    assert prompt =~ "Stack: elixir (mix)"
  end

  test "the explicit project_id wins over a mismatched working_dir" do
    project = project_fixture()

    prompt =
      SystemPrompt.build(
        orchestrator(%{project_id: project.id, working_dir: "/tmp/some/other/path"})
      )

    assert prompt =~ "You are working on project #{project.name} at `#{project.root_path}`"
  end

  test "an unbound orchestrator with no project resolves to the no-working-dir copy" do
    prompt = SystemPrompt.build(orchestrator(%{project_id: nil, working_dir: nil}))

    assert prompt =~ "No working directory is set"
    refute prompt =~ "You are working on project"
  end

  test "back-compat: a working_dir mapping to a registered project still resolves it" do
    project = project_fixture()
    prompt = SystemPrompt.build(orchestrator(%{project_id: nil, working_dir: project.root_path}))

    assert prompt =~ "You are working on project #{project.name}"
    assert prompt =~ "Target project: #{project.name}"
  end

  test "back-compat: an unregistered working_dir keeps the plain working-dir copy" do
    prompt =
      SystemPrompt.build(orchestrator(%{project_id: nil, working_dir: "/tmp/unregistered/path"}))

    assert prompt =~ "You and every worker you command run in `/tmp/unregistered/path`"
    refute prompt =~ "You are working on project"
  end
end
