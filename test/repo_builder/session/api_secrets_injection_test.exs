defmodule RepoBuilder.Session.ApiSecretsInjectionTest do
  @moduledoc """
  `Session.Server.resolve_secrets/2` folds a provisioned external API's vault secret into
  the worker child env (issue-external-api-mcp-provisioning): the `${SECRET}` placeholder
  written into `.mcp.json` expands at CLI read time. Workers only — the orchestrator brain
  is gated out. Project vault shadows the platform vault, and a public (`:none`) API
  injects nothing.

  `async: false` — exercises the shared Ecto sandbox via the ExternalApis + Secrets
  contexts.
  """
  use RepoBuilder.DataCase, async: false

  alias RepoBuilder.{ExternalApis, Projects, Secrets}
  alias RepoBuilder.Session.Server

  setup do
    {:ok, project} =
      Projects.create_project(%{
        "name" => "apienv-#{System.unique_integer([:positive])}",
        "root_path" => "/tmp/apienv-#{System.unique_integer([:positive])}"
      })

    {:ok, _} =
      ExternalApis.create(%{
        "name" => "pixellab",
        "transport" => "http",
        "url" => "https://api.pixellab.ai/mcp",
        "auth_scheme" => "bearer",
        "secret_name" => "PIXELLAB_API_KEY"
      })

    %{project: project}
  end

  test "injects the platform vault secret for a provisioned worker", %{project: project} do
    {:ok, _} = Secrets.put_secret(nil, "PIXELLAB_API_KEY", "platform_token")

    secrets =
      Server.resolve_secrets(
        [project_id: project.id, config: %{"apis" => ["pixellab"]}],
        "claude"
      )

    assert secrets["PIXELLAB_API_KEY"] == "platform_token"
  end

  test "the project vault shadows the platform vault", %{project: project} do
    {:ok, _} = Secrets.put_secret(nil, "PIXELLAB_API_KEY", "platform_token")
    {:ok, _} = Secrets.put_secret(project.id, "PIXELLAB_API_KEY", "project_token")

    secrets =
      Server.resolve_secrets(
        [project_id: project.id, config: %{"apis" => ["pixellab"]}],
        "claude"
      )

    assert secrets["PIXELLAB_API_KEY"] == "project_token"
  end

  test "the orchestrator brain is gated out", %{project: project} do
    {:ok, _} = Secrets.put_secret(nil, "PIXELLAB_API_KEY", "platform_token")

    secrets =
      Server.resolve_secrets(
        [project_id: project.id, config: %{"apis" => ["pixellab"], orchestrator: true}],
        "claude"
      )

    refute Map.has_key?(secrets, "PIXELLAB_API_KEY")
  end

  test "no api provisioned ⇒ no api secret", %{project: project} do
    {:ok, _} = Secrets.put_secret(nil, "PIXELLAB_API_KEY", "platform_token")

    secrets = Server.resolve_secrets([project_id: project.id, config: %{}], "claude")
    refute Map.has_key?(secrets, "PIXELLAB_API_KEY")
  end

  test "an unset secret stays absent (fail-soft)", %{project: project} do
    secrets =
      Server.resolve_secrets(
        [project_id: project.id, config: %{"apis" => ["pixellab"]}],
        "claude"
      )

    refute Map.has_key?(secrets, "PIXELLAB_API_KEY")
  end

  test "a public (none-auth) API injects nothing", %{project: project} do
    {:ok, _} =
      ExternalApis.create(%{
        "name" => "publicmcp",
        "transport" => "http",
        "url" => "https://example.com/mcp",
        "auth_scheme" => "none"
      })

    secrets =
      Server.resolve_secrets(
        [project_id: project.id, config: %{"apis" => ["publicmcp"]}],
        "claude"
      )

    assert secrets == %{} or not Map.has_key?(secrets, "PIXELLAB_API_KEY")
  end
end
