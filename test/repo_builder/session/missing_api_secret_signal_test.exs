defmodule RepoBuilder.Session.MissingApiSecretSignalTest do
  @moduledoc """
  Unit test of the detection helper `Session.Server.missing_api_secrets/3`
  (issue-provisioned-api-secret-missing-silent): given a provisioned API whose `secret_name`
  did NOT resolve into the merged child env (the fail-soft drop), it returns that
  `{api, secret_name}` pair; given the secret present, an orchestrator session, or a
  `:none`-auth (public) API, it returns `[]`. Asserts the fail-soft drop is unchanged AND the
  missing secret is now detected.

  `async: false` — exercises the shared Ecto sandbox via the ExternalApis + Secrets contexts.
  """
  use RepoBuilder.DataCase, async: false

  alias RepoBuilder.{ExternalApis, Projects, Secrets}
  alias RepoBuilder.Session.Server

  setup do
    {:ok, project} =
      Projects.create_project(%{
        "name" => "missing-#{System.unique_integer([:positive])}",
        "root_path" => "/tmp/missing-#{System.unique_integer([:positive])}"
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

  test "a provisioned API whose secret is absent is detected (fail-soft drop unchanged)", %{
    project: project
  } do
    config = %{"apis" => ["pixellab"]}

    # The fail-soft drop is preserved: the merged env carries NO PIXELLAB_API_KEY.
    secrets = Server.resolve_secrets([project_id: project.id, config: config], "pi")
    refute Map.has_key?(secrets, "PIXELLAB_API_KEY")

    # …but the absence is now detected.
    assert Server.missing_api_secrets(config, secrets, project.id) ==
             [{"pixellab", "PIXELLAB_API_KEY"}]
  end

  test "a provisioned API whose secret IS deposited is not flagged", %{project: project} do
    {:ok, _} = Secrets.put_secret(project.id, "PIXELLAB_API_KEY", "project_token")

    config = %{"apis" => ["pixellab"]}
    secrets = Server.resolve_secrets([project_id: project.id, config: config], "pi")

    assert secrets["PIXELLAB_API_KEY"] == "project_token"
    assert Server.missing_api_secrets(config, secrets, project.id) == []
  end

  test "the platform vault secret also satisfies detection", %{project: project} do
    {:ok, _} = Secrets.put_secret(nil, "PIXELLAB_API_KEY", "platform_token")

    config = %{"apis" => ["pixellab"]}
    secrets = Server.resolve_secrets([project_id: project.id, config: config], "pi")

    assert secrets["PIXELLAB_API_KEY"] == "platform_token"
    assert Server.missing_api_secrets(config, secrets, project.id) == []
  end

  test "an orchestrator session is never flagged", %{project: project} do
    config = %{"apis" => ["pixellab"], orchestrator: true}
    secrets = Server.resolve_secrets([project_id: project.id, config: config], "pi")

    assert Server.missing_api_secrets(config, secrets, project.id) == []
  end

  test "a public (none-auth) API contributes no pair and is never flagged", %{project: project} do
    {:ok, _} =
      ExternalApis.create(%{
        "name" => "publicmcp",
        "transport" => "http",
        "url" => "https://example.com/mcp",
        "auth_scheme" => "none"
      })

    config = %{"apis" => ["publicmcp"]}
    secrets = Server.resolve_secrets([project_id: project.id, config: config], "pi")

    assert Server.missing_api_secrets(config, secrets, project.id) == []
  end

  test "no APIs provisioned ⇒ nothing flagged", %{project: project} do
    config = %{}
    secrets = Server.resolve_secrets([project_id: project.id, config: config], "pi")

    assert Server.missing_api_secrets(config, secrets, project.id) == []
  end
end
