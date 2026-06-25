defmodule RepoBuilder.Session.ProjectSecretsInjectionTest do
  @moduledoc """
  `Session.Server.resolve_secrets/2` folds the per-project encrypted vault in as the
  lowest-precedence env layer (issue-per-project-encrypted-secrets-vault): a worker
  bound to the project gets `name => value`, an explicit/tool secret of the same name
  still wins, and the orchestrator BRAIN is gated out (its env never carries project
  secrets).

  `async: false` — exercises the shared Ecto sandbox via the Secrets context.
  """
  use RepoBuilder.DataCase, async: false

  alias RepoBuilder.Projects
  alias RepoBuilder.Secrets
  alias RepoBuilder.Session.Server

  setup do
    {:ok, project} =
      Projects.create_project(%{
        "name" => "inj-#{System.unique_integer([:positive])}",
        "root_path" => "/tmp/inj-#{System.unique_integer([:positive])}"
      })

    {:ok, _} = Secrets.put_secret(project.id, "STRIPE_API_KEY", "sk_live_value")
    %{project: project}
  end

  test "a worker bound to the project gets the decrypted name => value", %{project: project} do
    secrets = Server.resolve_secrets([project_id: project.id, config: %{}], "claude")
    assert secrets["STRIPE_API_KEY"] == "sk_live_value"
  end

  test "an explicit per-session secret of the same name still wins", %{project: project} do
    secrets =
      Server.resolve_secrets(
        [project_id: project.id, config: %{}, secrets: %{"STRIPE_API_KEY" => "override"}],
        "claude"
      )

    assert secrets["STRIPE_API_KEY"] == "override"
  end

  test "the orchestrator brain is gated out of project secrets", %{project: project} do
    secrets =
      Server.resolve_secrets([project_id: project.id, config: %{orchestrator: true}], "claude")

    refute Map.has_key?(secrets, "STRIPE_API_KEY")
  end

  test "no project_id ⇒ no project layer", _context do
    secrets = Server.resolve_secrets([config: %{}], "claude")
    refute Map.has_key?(secrets, "STRIPE_API_KEY")
  end
end
