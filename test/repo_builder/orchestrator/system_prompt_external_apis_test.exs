defmodule RepoBuilder.Orchestrator.SystemPromptExternalApisTest do
  @moduledoc """
  The "Registered APIs you may delegate" block (issue-external-api-mcp-provisioning): the
  orchestrator system prompt lists in-scope registrations as name + description, with the
  delegation-only instruction, and never any secret. The block is omitted when nothing is
  registered in scope.
  """
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.ExternalApis
  alias RepoBuilder.Orchestrator.{Orchestrator, SystemPrompt}
  alias RepoBuilder.Projects

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

  test "lists registered APIs by name + description, never a secret" do
    {:ok, _} =
      ExternalApis.create(%{
        "name" => "pixellab",
        "transport" => "http",
        "url" => "https://api.pixellab.ai/mcp",
        "auth_scheme" => "bearer",
        "secret_name" => "PIXELLAB_API_KEY",
        "description" => "Image generation MCP"
      })

    prompt = SystemPrompt.build(orchestrator(nil))

    assert prompt =~ "Registered APIs you may delegate to workers:"
    assert prompt =~ "pixellab — Image generation MCP"
    assert prompt =~ "CANNOT call these tools yourself"
    # Never leak the secret reference value into the prompt.
    refute prompt =~ "PIXELLAB_API_KEY"
  end

  test "omits the block when nothing is registered in scope" do
    project = project()
    prompt = SystemPrompt.build(orchestrator(project.id))
    refute prompt =~ "Registered APIs you may delegate"
  end
end
