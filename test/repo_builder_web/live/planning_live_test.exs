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
  alias RepoBuilder.Workflows

  # Wait for the async Runner to reach a terminal state so it never outlives the sandbox.
  defp await_run_terminal(run_id, attempts \\ 400) do
    case Workflows.get_run(run_id) do
      %{status: status} = run when status in [:succeeded, :failed] -> run
      _ when attempts > 0 -> Process.sleep(20) && await_run_terminal(run_id, attempts - 1)
      run -> run
    end
  end

  # Back the real-named "claude" harness with the safe canned-event Fake adapter so a
  # launch on a *real* (non-`fake`) harness never spawns an external CLI in tests
  # (registry is the single injection seam, BUILD_PROMPT.md §13).
  setup do
    original = Application.fetch_env!(:repo_builder, :harnesses)
    Application.put_env(:repo_builder, :harnesses, Map.put(original, "claude", original["fake"]))
    on_exit(fn -> Application.put_env(:repo_builder, :harnesses, original) end)
    :ok
  end

  defp fixture_project(attrs \\ %{}) do
    root = Path.join(System.tmp_dir!(), "rb_wiz_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, ".claude/commands"))
    File.write!(Path.join(root, "mix.exs"), "defmodule X.MixProject do end")
    on_exit(fn -> File.rm_rf(root) end)
    # A real `default_harness` so the wizard launches a run that actually runs (the
    # launch path refuses the no-op `fake` harness).
    base = %{
      "name" => "wiz-#{System.unique_integer([:positive])}",
      "root_path" => root,
      "default_harness" => "claude"
    }

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

    # Drain the launched Runner before teardown.
    _ = await_run_terminal(plan.workflow_run_id)
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
