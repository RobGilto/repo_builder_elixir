defmodule RepoBuilder.Orchestrator.SystemPromptSecretsTest do
  @moduledoc """
  The names-only project-secrets block (issue-per-project-encrypted-secrets-vault): the
  orchestrator system prompt lists secret NAMES (with a masked hint) but NEVER the
  values, and the block is omitted entirely when a project has no secrets.
  """
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.Orchestrator.{Orchestrator, SystemPrompt}
  alias RepoBuilder.Projects
  alias RepoBuilder.Secrets

  defp orchestrator(project_id) do
    %Orchestrator{
      name: "default",
      harness: "fake",
      provider: nil,
      model: nil,
      project_id: project_id,
      working_dir: nil,
      metadata: %{}
    }
  end

  defp project do
    {:ok, project} =
      Projects.create_project(%{
        "name" => "sp-#{System.unique_integer([:positive])}",
        "root_path" => "/tmp/sp-#{System.unique_integer([:positive])}"
      })

    project
  end

  test "lists names and the masked hint, never the value" do
    project = project()
    {:ok, _} = Secrets.put_secret(project.id, "STRIPE_API_KEY", "sk_live_4242")

    prompt = SystemPrompt.build(orchestrator(project.id))

    assert prompt =~ "Project secrets (available to workers as environment variables):"
    assert prompt =~ "$STRIPE_API_KEY (set; ••••4242)"
    assert prompt =~ "CANNOT print them"
    refute prompt =~ "sk_live_4242"
  end

  test "omits the block entirely when the project has no secrets" do
    project = project()
    prompt = SystemPrompt.build(orchestrator(project.id))
    refute prompt =~ "Project secrets (available to workers"
  end
end
