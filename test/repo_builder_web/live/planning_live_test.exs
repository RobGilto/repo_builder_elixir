defmodule RepoBuilderWeb.PlanningLiveTest do
  @moduledoc """
  The Planning-Mode Wizard end-to-end (Phase 6): walk project → goal → workflow →
  preview → launch against the Fake adapter, asserting a launched run + a persisted Plan
  artifact; and that the budget cap blocks a plan whose estimate exceeds it.

  `async: false` so the shared Ecto sandbox reaches the LiveView (and the spawned Runner).
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Plans
  alias RepoBuilder.Projects

  defp fixture_project(attrs \\ %{}) do
    root = Path.join(System.tmp_dir!(), "rb_wiz_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, ".claude/commands"))
    File.write!(Path.join(root, "mix.exs"), "defmodule X.MixProject do end")
    on_exit(fn -> File.rm_rf(root) end)
    base = %{"name" => "wiz-#{System.unique_integer([:positive])}", "root_path" => root}
    {:ok, project} = Projects.create_and_profile(Map.merge(base, attrs))
    project
  end

  test "walks the wizard to a launched run + persisted plan", %{conn: conn} do
    project = fixture_project()
    {:ok, view, _html} = live(conn, ~p"/plan")

    render_submit(element(view, "#wizard-project"), %{"project_id" => project.id})
    render_submit(element(view, "#wizard-goal"), %{"goal" => "add a feature"})

    render_submit(element(view, "#wizard-workflow"), %{
      "workflow_type" => "plan_build",
      "harness" => "fake",
      "model" => "",
      "budget_cap" => ""
    })

    assert render(view) =~ "Preview &amp; launch" or render(view) =~ "Preview & launch"

    render_click(view, "launch", %{})

    plans = Plans.list_plans_for_project(project.id)
    assert [plan] = plans
    assert plan.status == :launched
    assert plan.workflow_run_id != nil
    assert plan.resolved_steps["steps"] != []
  end

  test "the budget cap blocks a plan whose estimate exceeds it", %{conn: conn} do
    project = fixture_project()
    {:ok, view, _html} = live(conn, ~p"/plan")

    render_submit(element(view, "#wizard-project"), %{"project_id" => project.id})
    render_submit(element(view, "#wizard-goal"), %{"goal" => "add a feature"})

    # A microscopic cap is guaranteed below any non-zero estimate.
    render_submit(element(view, "#wizard-workflow"), %{
      "workflow_type" => "plan_build",
      "harness" => "fake",
      "model" => "",
      "budget_cap" => "0.0000001"
    })

    render_click(view, "launch", %{})

    assert render(view) =~ "exceeds the budget cap"
    assert Plans.list_plans_for_project(project.id) == []
  end
end
