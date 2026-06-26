defmodule RepoBuilderWeb.PerProjectAgentModelsTest do
  @moduledoc """
  Integration tests (issue per-project-agent-models): the Settings → Default Models tab
  edits the global default; per-project rosters inherit it; a per-project override on
  `/projects/:id` changes only that project.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Orchestrators
  alias RepoBuilder.Projects
  alias RepoBuilder.Settings

  defp uniq, do: System.unique_integer([:positive])

  defp project_fixture do
    n = uniq()

    {:ok, project} =
      Projects.create_project(%{"name" => "proj-#{n}", "root_path" => "/tmp/p-#{n}"})

    project
  end

  describe "Settings → Default Models tab" do
    test "edits and persists the global default roster", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Open the Default Models tab (server loads the rows).
      view |> element(~s{button[phx-value-tab="default_models"]}) |> render_click()

      view
      |> element("#default-model-main")
      |> render_change(%{
        "category" => "main",
        "harness" => "fake",
        "provider" => "",
        "model" => "set-from-tab",
        "_target" => ["model"]
      })

      assert Settings.default_agent_models()["main"]["model"] == "set-from-tab"
    end
  end

  describe "per-project inheritance" do
    test "an unset tier renders the inherited default with an inherited indicator", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # The default `/` orchestrator inherits the test config default (fake-main, etc.),
      # so its agent-models modal marks the tier inherited.
      view |> element("#agent-models-toggle") |> render_click()
      _ = render(view)

      assert has_element?(view, "#agent-model-main-inherited")
    end
  end

  describe "/projects/:id roster card" do
    test "overriding one project's tier is isolated from another project", %{conn: conn} do
      project_a = project_fixture()
      project_b = project_fixture()

      {:ok, view, _html} = live(conn, ~p"/projects/#{project_a.id}")

      view
      |> element("#project-model-main")
      |> render_change(%{
        "category" => "main",
        "harness" => "fake",
        "provider" => "",
        "model" => "override-a",
        "_target" => ["model"]
      })

      orch_a = elem(Orchestrators.get_or_create_for_project(project_a.id), 1)
      orch_b = elem(Orchestrators.get_or_create_for_project(project_b.id), 1)

      assert {%{"model" => "override-a"}, :project} =
               Orchestrators.effective_agent_model(orch_a, "main")

      # Project B is untouched — it keeps the seeded/inherited default.
      assert Orchestrators.effective_agent_models(orch_b)["main"]["model"] == "fake-main"
      refute Orchestrators.effective_agent_models(orch_b)["main"]["model"] == "override-a"

      # The rendered card reflects the override (no longer "inherited" for main).
      assert has_element?(view, ~s{#project-model-main option[value="override-a"][selected]})
    end

    test "reset re-inherits the global default", %{conn: conn} do
      project = project_fixture()
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")

      view
      |> element("#project-model-heavy")
      |> render_change(%{
        "category" => "heavy",
        "harness" => "fake",
        "provider" => "",
        "model" => "tmp-heavy",
        "_target" => ["model"]
      })

      view |> element("#project-model-heavy button", "Reset") |> render_click()

      orch = elem(Orchestrators.get_or_create_for_project(project.id), 1)
      assert {_entry, :default} = Orchestrators.effective_agent_model(orch, "heavy")
    end
  end
end
