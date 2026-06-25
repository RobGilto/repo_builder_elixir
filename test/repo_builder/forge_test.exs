defmodule RepoBuilder.ForgeTest do
  @moduledoc "The Forge context contract (forge-meta-artifact-generation, Phase 2)."
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.Forge
  alias RepoBuilder.Forge.Artifact

  test "request/1 inserts a :requested artifact and get/fetch round-trip it" do
    assert {:ok, %Artifact{} = artifact} =
             Forge.request(%{kind: "command", spec: "a /smoke-test command"})

    assert artifact.status == :requested
    assert artifact.project_id == nil
    assert %Artifact{} = Forge.get(artifact.id)
    assert {:ok, ^artifact} = Forge.fetch(artifact.id)
  end

  test "request/1 rejects an unknown kind at the changeset boundary (no raw DB error)" do
    assert {:error, changeset} = Forge.request(%{kind: "wat", spec: "x"})
    assert %{kind: [_ | _]} = errors_on(changeset)
  end

  test "request/1 requires kind and spec" do
    assert {:error, changeset} = Forge.request(%{kind: "command"})
    assert %{spec: [_ | _]} = errors_on(changeset)
  end

  test "list_for_project/1 scopes by project_id, nil = platform" do
    project_id = Ecto.UUID.generate()
    {:ok, _platform} = Forge.request(%{kind: "skill", spec: "platform skill"})
    {:ok, scoped} = Forge.request(%{kind: "agent", spec: "scoped agent", project_id: project_id})

    assert Enum.map(Forge.list_for_project(project_id), & &1.id) == [scoped.id]
    platform_ids = Enum.map(Forge.list_for_project(nil), & &1.id)
    assert scoped.id not in platform_ids
  end

  test "mark_status/3 transitions through the lifecycle and merges columns" do
    {:ok, artifact} = Forge.request(%{kind: "workflow", spec: "ship workflow"})

    assert {:ok, generating} = Forge.mark_status(artifact, :generating)
    assert generating.status == :generating

    assert {:ok, packaged} =
             Forge.mark_status(generating, :packaged, %{
               output_path: "plugin_library/ship-workflow",
               plugin_id: "ship-workflow"
             })

    assert packaged.status == :packaged
    assert packaged.plugin_id == "ship-workflow"
    assert packaged.output_path == "plugin_library/ship-workflow"
  end
end
