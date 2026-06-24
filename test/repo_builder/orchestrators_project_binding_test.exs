defmodule RepoBuilder.OrchestratorsProjectBindingTest do
  @moduledoc """
  Orchestrator↔project binding (Phase 1): `get_or_create_for_project/1` lazily creates
  exactly one orchestrator per project (idempotent, working_dir = root_path, distinct
  from the platform default), and `set_project/2` rebinds + clears the session. A deleted
  project nilifies the FK (the row downgrades to a platform orchestrator).
  """
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.Orchestrator.Orchestrator
  alias RepoBuilder.Orchestrators
  alias RepoBuilder.Projects
  alias RepoBuilder.Repo

  defp uniq, do: System.unique_integer([:positive])

  defp project_fixture(attrs \\ %{}) do
    n = uniq()

    {:ok, project} =
      Projects.create_project(
        Map.merge(%{"name" => "proj-#{n}", "root_path" => "/tmp/proj-#{n}"}, attrs)
      )

    project
  end

  describe "get_or_create_for_project/1" do
    test "creates and binds an orchestrator to the project on the first call" do
      project = project_fixture()

      assert {:ok, orchestrator} = Orchestrators.get_or_create_for_project(project.id)
      assert orchestrator.project_id == project.id
      assert orchestrator.working_dir == project.root_path
      assert orchestrator.name == "orch:" <> project.name
    end

    test "is idempotent — a second call returns the same row" do
      project = project_fixture()

      assert {:ok, first} = Orchestrators.get_or_create_for_project(project.id)
      assert {:ok, second} = Orchestrators.get_or_create_for_project(project.id)
      assert first.id == second.id

      assert Repo.aggregate(from(o in Orchestrator, where: o.project_id == ^project.id), :count) ==
               1
    end

    test "the per-project orchestrator is distinct from the platform default" do
      project = project_fixture()

      assert {:ok, default} = Orchestrators.get_or_create_default()
      assert {:ok, bound} = Orchestrators.get_or_create_for_project(project.id)

      assert default.id != bound.id
      assert default.project_id == nil
      assert bound.project_id == project.id
    end

    test "a nil project id falls back to the platform default" do
      assert {:ok, default} = Orchestrators.get_or_create_default()
      assert {:ok, resolved} = Orchestrators.get_or_create_for_project(nil)
      assert resolved.id == default.id
    end

    test "an unknown project id falls back to the platform default (no crash)" do
      assert {:ok, default} = Orchestrators.get_or_create_default()
      assert {:ok, resolved} = Orchestrators.get_or_create_for_project(Ecto.UUID.generate())
      assert resolved.id == default.id
    end

    test "two projects get two independent orchestrators (separate context windows)" do
      a = project_fixture()
      b = project_fixture()

      assert {:ok, orch_a} = Orchestrators.get_or_create_for_project(a.id)
      assert {:ok, orch_b} = Orchestrators.get_or_create_for_project(b.id)
      assert orch_a.id != orch_b.id
    end
  end

  describe "set_project/2" do
    test "binds working_dir and clears the resumable session id" do
      project = project_fixture()

      {:ok, orch} =
        Orchestrators.create(%{name: "orch-#{uniq()}", harness: "fake", session_id: "s"})

      assert {:ok, updated} = Orchestrators.set_project(orch.id, project.id)
      assert updated.project_id == project.id
      assert updated.working_dir == project.root_path
      # A new project ⇒ a fresh CLI session + context window.
      assert updated.session_id == nil
    end

    test "a nil project id unbinds back to a platform orchestrator" do
      project = project_fixture()
      {:ok, orch} = Orchestrators.get_or_create_for_project(project.id)

      assert {:ok, updated} = Orchestrators.set_project(orch.id, nil)
      assert updated.project_id == nil
      assert updated.working_dir == nil
    end

    test "an unknown project id is {:error, :not_found}" do
      {:ok, orch} = Orchestrators.create(%{name: "orch-#{uniq()}", harness: "fake"})
      assert {:error, :not_found} = Orchestrators.set_project(orch.id, Ecto.UUID.generate())
    end
  end

  describe "project deletion" do
    test "nilify_all downgrades the orchestrator to a platform orchestrator" do
      project = project_fixture()
      {:ok, orch} = Orchestrators.get_or_create_for_project(project.id)
      assert orch.project_id == project.id

      assert {:ok, _} = Projects.delete_project(project)

      reloaded = Repo.get(Orchestrator, orch.id)
      assert reloaded.project_id == nil
    end
  end
end
