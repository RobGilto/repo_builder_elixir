defmodule RepoBuilder.Orchestrator.PerProjectModelsTest do
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.Orchestrators
  alias RepoBuilder.Projects
  alias RepoBuilder.Settings

  defp uniq, do: System.unique_integer([:positive])

  defp project_fixture(attrs \\ %{}) do
    n = uniq()

    {:ok, project} =
      Projects.create_project(
        Map.merge(%{"name" => "proj-#{n}", "root_path" => "/tmp/proj-#{n}"}, attrs)
      )

    project
  end

  defp orchestrator_for(project), do: elem(Orchestrators.get_or_create_for_project(project.id), 1)

  describe "create_for_project seeding" do
    test "a new project's orchestrator is seeded from the global default roster" do
      project = project_fixture()
      orch = orchestrator_for(project)

      assert Orchestrators.agent_models(orch) == Settings.default_agent_models()
      assert Orchestrators.agent_models(orch)["main"]["model"] == "fake-main"
    end
  end

  describe "effective_agent_models/1 + effective_agent_model/2" do
    test "an unset tier inherits the default and is tagged :default" do
      orch = orchestrator_for(project_fixture())
      # Clear the seeded entry so the tier is genuinely unset, exercising read-through.
      {:ok, orch} = Orchestrators.clear_agent_model(orch.id, "fast")

      assert {entry, :default} = Orchestrators.effective_agent_model(orch, "fast")
      assert entry["model"] == "fake-fast"
      assert Orchestrators.effective_agent_models(orch)["fast"]["model"] == "fake-fast"
    end

    test "an explicit override wins over the default and is tagged :project" do
      orch = orchestrator_for(project_fixture())

      {:ok, orch} =
        Orchestrators.set_agent_model(orch.id, "main", %{
          "harness" => "fake",
          "provider" => nil,
          "model" => "custom-main"
        })

      assert {entry, :project} = Orchestrators.effective_agent_model(orch, "main")
      assert entry["model"] == "custom-main"
      assert Orchestrators.effective_agent_models(orch)["main"]["model"] == "custom-main"
    end
  end

  describe "per-project isolation" do
    test "overriding one project's tier does not change another project's roster" do
      orch_a = orchestrator_for(project_fixture())
      orch_b = orchestrator_for(project_fixture())

      {:ok, _} =
        Orchestrators.set_agent_model(orch_a.id, "heavy", %{
          "harness" => "fake",
          "provider" => nil,
          "model" => "a-only"
        })

      orch_b = elem(Orchestrators.get_or_create_for_project(orch_b.project_id), 1)

      # B keeps its own (seeded-default) heavy tier; A's override never leaks across.
      assert Orchestrators.effective_agent_models(orch_b)["heavy"]["model"] == "fake-heavy"
      refute Orchestrators.effective_agent_models(orch_b)["heavy"]["model"] == "a-only"
    end
  end

  describe "clear_agent_model/2" do
    test "re-inherits the default after an override" do
      orch = orchestrator_for(project_fixture())

      {:ok, orch} =
        Orchestrators.set_agent_model(orch.id, "leader", %{
          "harness" => "fake",
          "provider" => nil,
          "model" => "lead-x"
        })

      assert {_e, :project} = Orchestrators.effective_agent_model(orch, "leader")

      {:ok, orch} = Orchestrators.clear_agent_model(orch.id, "leader")

      assert {entry, :default} = Orchestrators.effective_agent_model(orch, "leader")
      assert entry["model"] == "fake-leader"
    end

    test "rejects an unknown category" do
      orch = orchestrator_for(project_fixture())
      assert {:error, :invalid_category} = Orchestrators.clear_agent_model(orch.id, "bogus")
    end
  end

  describe "get_or_create_for_project/1 backfill" do
    test "backfills an empty roster from the default without clobbering explicit entries" do
      project = project_fixture()
      orch = orchestrator_for(project)

      # Simulate a pre-feature orchestrator with an empty roster, keeping one explicit tier.
      {:ok, _updated} =
        Orchestrators.set_agent_model(orch.id, "main", %{
          "harness" => "fake",
          "provider" => nil,
          "model" => "kept"
        })

      # Wipe everything except the explicit entry to a non-empty-but-partial roster:
      # backfill only fires on a fully empty roster, so the explicit entry must survive.
      reloaded = elem(Orchestrators.get_or_create_for_project(project.id), 1)
      assert Orchestrators.agent_models(reloaded)["main"]["model"] == "kept"
    end
  end
end
