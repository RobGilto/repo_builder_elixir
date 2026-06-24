defmodule RepoBuilder.ProjectsTest do
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.Agents
  alias RepoBuilder.Projects
  alias RepoBuilder.Projects.Project
  alias RepoBuilder.Workflows

  @valid %{
    "name" => "acme-web",
    "root_path" => "/tmp/acme-web",
    "default_branch" => "main"
  }

  describe "changeset/2" do
    test "requires name and root_path" do
      changeset = Project.changeset(%Project{}, %{})
      refute changeset.valid?
      assert %{name: ["can't be blank"], root_path: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects an unregistered default_harness" do
      changeset =
        Project.changeset(%Project{}, Map.put(@valid, "default_harness", "not-a-harness"))

      refute changeset.valid?
      assert %{default_harness: ["is not a registered harness"]} = errors_on(changeset)
    end

    test "accepts a nil/blank default_harness" do
      assert Project.changeset(%Project{}, @valid).valid?
      assert Project.changeset(%Project{}, Map.put(@valid, "default_harness", "")).valid?
    end

    test "defaults command_pack/version/isolation/status" do
      {:ok, project} = Projects.create_project(@valid)
      assert project.command_pack == "auto"
      assert project.command_pack_version == "latest"
      assert project.isolation_mode == :direct
      assert project.status == :active
    end

    test "rejects a negative budget cap" do
      changeset =
        Project.changeset(%Project{}, Map.put(@valid, "budget_cap_usd", Decimal.new("-1")))

      refute changeset.valid?
      assert %{budget_cap_usd: _} = errors_on(changeset)
    end
  end

  describe "CRUD" do
    test "create/get/update/delete round-trip" do
      {:ok, project} = Projects.create_project(@valid)
      assert Projects.get_project!(project.id).name == "acme-web"

      {:ok, updated} = Projects.update_project(project, %{"default_branch" => "develop"})
      assert updated.default_branch == "develop"

      {:ok, _} = Projects.delete_project(updated)
      assert Projects.get_project(project.id) == nil
    end

    test "name is unique" do
      {:ok, _} = Projects.create_project(@valid)
      assert {:error, changeset} = Projects.create_project(@valid)
      assert %{name: ["has already been taken"]} = errors_on(changeset)
    end

    test "list_projects/0 is ordered by name" do
      {:ok, _} = Projects.create_project(%{"name" => "zeta", "root_path" => "/z"})
      {:ok, _} = Projects.create_project(%{"name" => "alpha", "root_path" => "/a"})
      assert ["alpha", "zeta"] = Enum.map(Projects.list_projects(), & &1.name)
    end
  end

  describe "create_and_profile/1 folder creation" do
    @tag :tmp_dir
    test "creates the root_path folder when create_dir is opted in", %{tmp_dir: tmp} do
      root = Path.join(tmp, "fresh-repo")
      refute File.dir?(root)

      assert {:ok, project} =
               Projects.create_and_profile(%{
                 "name" => "fresh-repo",
                 "root_path" => root,
                 "create_dir" => "true"
               })

      assert File.dir?(root)
      assert project.root_path == Path.expand(root)
    end

    @tag :tmp_dir
    test "does not create the folder when create_dir is absent/falsey", %{tmp_dir: tmp} do
      root = Path.join(tmp, "absent-repo")

      assert {:ok, _project} =
               Projects.create_and_profile(%{"name" => "absent-repo", "root_path" => root})

      refute File.dir?(root)
    end

    @tag :tmp_dir
    test "leaves an existing folder untouched when opted in", %{tmp_dir: tmp} do
      assert {:ok, _project} =
               Projects.create_and_profile(%{
                 "name" => "existing-repo",
                 "root_path" => tmp,
                 "create_dir" => "true"
               })

      assert File.dir?(tmp)
    end
  end

  describe "active_or_default/1" do
    test "returns the named project when found" do
      {:ok, project} = Projects.create_project(@valid)
      assert Projects.active_or_default(project.id).id == project.id
    end

    test "falls back to the default platform project for an unknown/nil id" do
      {:ok, platform} = Projects.create_project(%{"name" => "p", "root_path" => File.cwd!()})
      assert Projects.active_or_default(nil).id == platform.id
      assert Projects.active_or_default(Ecto.UUID.generate()).id == platform.id
    end

    test "returns nil when no project exists" do
      assert Projects.active_or_default(nil) == nil
    end
  end

  describe "back-compatible scoping" do
    test "an agent with project_id == nil still lists unscoped" do
      {:ok, _agent} =
        Agents.create_agent(%{
          "name" => "legacy",
          "harness" => "claude",
          "provider" => "anthropic"
        })

      assert Enum.any?(Agents.list_for_project(nil), &(&1.name == "legacy"))
    end

    test "list_for_project scopes the roster" do
      {:ok, project} = Projects.create_project(@valid)

      {:ok, scoped} =
        Agents.create_agent(%{
          "name" => "scoped",
          "harness" => "claude",
          "provider" => "anthropic",
          "project_id" => project.id
        })

      {:ok, _other} =
        Agents.create_agent(%{
          "name" => "unscoped",
          "harness" => "claude",
          "provider" => "anthropic"
        })

      names = Enum.map(Agents.list_for_project(project.id), & &1.name)
      assert "scoped" in names
      refute "unscoped" in names
      assert scoped.project_id == project.id
    end

    test "runs scope by project; nil-project runs excluded from a project view" do
      {:ok, project} = Projects.create_project(@valid)
      {:ok, workflow} = Workflows.create_workflow(%{"name" => "wf", "steps" => []})

      {:ok, scoped} =
        Workflows.create_run(%{
          "workflow_id" => workflow.id,
          "status" => "queued",
          "project_id" => project.id
        })

      {:ok, _unscoped} =
        Workflows.create_run(%{"workflow_id" => workflow.id, "status" => "queued"})

      ids = Enum.map(Workflows.list_recent_for_project(project.id), & &1.id)
      assert scoped.id in ids
      assert length(ids) == 1
    end
  end
end
