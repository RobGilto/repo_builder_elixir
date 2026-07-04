defmodule RepoBuilder.Session.Planf3EnvTest do
  @moduledoc """
  `Session.Server.resolve_secrets/2` carries the planf3 plan-image policy into the
  OS-child env (spec planf3-html-plans-for-heavy-adw-planner, Phase 5): placeholders ON
  (the default) ⇒ `PLANF3_IMAGES=placeholders` and no key exposure; OFF ⇒
  `PLANF3_IMAGES=generate` plus the vault `OPENAI_API_KEY` (project shadows platform),
  workers only — the orchestrator brain never receives the key.

  `async: false` — exercises the shared Ecto sandbox via Settings + Secrets.
  """
  use RepoBuilder.DataCase, async: false

  alias RepoBuilder.Projects
  alias RepoBuilder.Secrets
  alias RepoBuilder.Session.Server
  alias RepoBuilder.Settings

  setup do
    {:ok, project} =
      Projects.create_project(%{
        "name" => "pf3-#{System.unique_integer([:positive])}",
        "root_path" => "/tmp/pf3-#{System.unique_integer([:positive])}"
      })

    %{project: project}
  end

  test "default (no row) ships PLANF3_IMAGES=placeholders", %{project: project} do
    secrets = Server.resolve_secrets([project_id: project.id, config: %{}], "claude")
    assert secrets["PLANF3_IMAGES"] == "placeholders"
  end

  test "toggled off ships generate + the project-vault key", %{project: project} do
    {:ok, false} = Settings.put_planf3_image_placeholders(false)
    {:ok, _} = Secrets.put_secret(project.id, "OPENAI_API_KEY", "sk-proj-value")

    secrets = Server.resolve_secrets([project_id: project.id, config: %{}], "claude")
    assert secrets["PLANF3_IMAGES"] == "generate"
    assert secrets["OPENAI_API_KEY"] == "sk-proj-value"
  end

  test "project key shadows the platform key", %{project: project} do
    {:ok, false} = Settings.put_planf3_image_placeholders(false)
    {:ok, _} = Secrets.put_secret(nil, "OPENAI_API_KEY", "sk-platform")
    {:ok, _} = Secrets.put_secret(project.id, "OPENAI_API_KEY", "sk-project")

    secrets = Server.resolve_secrets([project_id: project.id, config: %{}], "claude")
    assert secrets["OPENAI_API_KEY"] == "sk-project"
  end

  test "toggled off with no key ships generate alone (command degrades downstream)",
       %{project: project} do
    {:ok, false} = Settings.put_planf3_image_placeholders(false)

    secrets = Server.resolve_secrets([project_id: project.id, config: %{}], "claude")
    assert secrets["PLANF3_IMAGES"] == "generate"
    refute Map.has_key?(secrets, "OPENAI_API_KEY")
  end

  test "orchestrator brain never receives the key even when toggled off",
       %{project: project} do
    {:ok, false} = Settings.put_planf3_image_placeholders(false)
    {:ok, _} = Secrets.put_secret(project.id, "OPENAI_API_KEY", "sk-proj-value")

    secrets =
      Server.resolve_secrets(
        [project_id: project.id, config: %{orchestrator: true}],
        "claude"
      )

    assert secrets["PLANF3_IMAGES"] == "generate"
    refute Map.has_key?(secrets, "OPENAI_API_KEY")
  end

  test "re-ticking the toggle returns to placeholders", %{project: project} do
    {:ok, false} = Settings.put_planf3_image_placeholders(false)
    {:ok, true} = Settings.put_planf3_image_placeholders(true)

    secrets = Server.resolve_secrets([project_id: project.id, config: %{}], "claude")
    assert secrets["PLANF3_IMAGES"] == "placeholders"
  end
end
