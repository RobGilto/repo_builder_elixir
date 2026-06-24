defmodule RepoBuilderWeb.TestPlanningWizardTargetRepoTest do
  @moduledoc """
  Integration regression for the planning-wizard target-repo launch bug: walking the
  wizard must launch a run that executes IN the target project's `root_path`, on a REAL
  harness — not a silent no-op in an ephemeral scratch workspace on the `fake` adapter.

  Case 1: a worktree-isolated git project — the launched run's step session provisions
  the `adw/<run_id>` branch in the project's repo (observable proof the cwd reached the
  session), and the run records that worktree handoff.

  Case 2: a project with no real harness (`default_harness` blank/`fake`) is REFUSED at
  launch with an actionable error, and NO run/plan is created.

  `async: false` (shared sandbox reaches the spawned Runner + session).
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Plans, Projects, Workflows}

  # Back the real-named "claude" harness with the safe canned-event Fake adapter so a
  # launch on a real harness never spawns an external CLI (registry injection seam, §13).
  setup do
    original = Application.fetch_env!(:repo_builder, :harnesses)
    Application.put_env(:repo_builder, :harnesses, Map.put(original, "claude", original["fake"]))
    on_exit(fn -> Application.put_env(:repo_builder, :harnesses, original) end)
    :ok
  end

  defp git_project(attrs) do
    base = Path.join(System.tmp_dir!(), "rb_wizrepo_#{System.unique_integer([:positive])}")
    repo = Path.join(base, "repo")
    File.mkdir_p!(Path.join(repo, ".claude/commands"))
    File.write!(Path.join(repo, "mix.exs"), "defmodule X.MixProject do end")
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main"], cd: repo)
    {_, 0} = System.cmd("git", ["config", "user.email", "t@example.com"], cd: repo)
    {_, 0} = System.cmd("git", ["config", "user.name", "t"], cd: repo)
    {_, 0} = System.cmd("git", ["add", "."], cd: repo)
    {_, 0} = System.cmd("git", ["commit", "-q", "-m", "init"], cd: repo)
    on_exit(fn -> File.rm_rf(base) end)

    Application.put_env(:repo_builder, :worktree, scratch_base: Path.join(base, "scratch"))
    on_exit(fn -> Application.delete_env(:repo_builder, :worktree) end)

    base_attrs = %{"name" => "wizrepo-#{System.unique_integer([:positive])}", "root_path" => repo}
    {:ok, project} = Projects.create_and_profile(Map.merge(base_attrs, attrs))
    project
  end

  defp walk_to_preview(view, project, goal) do
    render_submit(element(view, "#wizard-project"), %{"project_id" => project.id})
    render_submit(element(view, "#wizard-goal"), %{"goal" => goal})

    render_submit(element(view, "#wizard-workflow"), %{
      "workflow_type" => "plan_build",
      "harness" => "fake",
      "model" => "",
      "budget_cap" => ""
    })
  end

  # The run executes on the async Runner; wait for it to reach a terminal state before
  # asserting (and before the test ends, so the Runner never outlives the sandbox).
  defp await_run_terminal(run_id, attempts \\ 400) do
    case Workflows.get_run(run_id) do
      %{status: status} = run when status in [:succeeded, :failed] -> run
      _ when attempts > 0 -> Process.sleep(20) && await_run_terminal(run_id, attempts - 1)
      run -> run
    end
  end

  test "launches a run that executes in the target repo on a real harness", %{conn: conn} do
    project = git_project(%{"default_harness" => "claude", "isolation_mode" => "worktree"})
    {:ok, view, _html} = live(conn, ~p"/plan")

    walk_to_preview(view, project, "add a feature")
    render_click(view, "launch", %{})

    # A run + plan scoped to the project, launched on the real (non-fake) harness.
    assert [plan] = Plans.list_plans_for_project(project.id)
    assert plan.status == :launched
    assert plan.workflow_run_id != nil

    run = await_run_terminal(plan.workflow_run_id)
    assert run.project_id == project.id

    # Observable proof the run executed in the target repo: the worktree branch survives
    # in the project's repo, and the run records the worktree handoff for the UI.
    {branches, 0} =
      System.cmd("git", ["branch", "--list", "adw/#{run.id}"], cd: project.root_path)

    assert branches =~ "adw/#{run.id}"
    assert run.worktree_branch == "adw/#{run.id}"
  end

  test "a project with no real harness is refused at launch with an actionable error", %{
    conn: conn
  } do
    project = git_project(%{"default_harness" => nil})
    {:ok, view, _html} = live(conn, ~p"/plan")

    walk_to_preview(view, project, "add a feature")
    html = render_click(view, "launch", %{})

    assert html =~ "no real harness configured"
    # No silent no-op: nothing was persisted or launched.
    assert Plans.list_plans_for_project(project.id) == []
  end
end
