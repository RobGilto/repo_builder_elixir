defmodule RepoBuilderWeb.TestAdwBuilderSpecArgThreadedToCwdTest do
  @moduledoc """
  Integration regression for the ADW Builder target-repo launch bug
  (issue-adw-builder-target-repo-launch): when an operator assembles a custom ADW in the
  ⌘K ADW Builder with a typed SPEC path AND has an active target project selected, the
  launched workflow run MUST be scoped to that project — `workflow_runs.project_id` is
  the project's id, the step session runs IN the project's `root_path`, and the typed
  `specs/…` path resolves for the agent. A `nil` active project preserves the existing
  no-cwd / managed-scratch behaviour (back-compat for every pre-existing caller).

  Case 1 (`:direct`): the run's `worktree_path` / `worktree_branch` are `nil` (no
  worktree provisioned; the session runs on `:cwd` itself).

  Case 2 (`:worktree`): the run's `worktree_branch` is `adw/<run_id>` and survives in
  the project's repo (observable proof the cwd reached the session), and the
  `worktree_path` is under the configured `:worktree, :scratch_base` — NOT under
  `priv/workspaces/`.

  `async: false` (shared sandbox reaches the spawned Runner + Session).
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Projects, Repo, Settings, Workflows}
  alias RepoBuilder.WorkflowEngine.Catalog
  alias RepoBuilder.Workflows.{Workflow, WorkflowRun}

  import Ecto.Query

  @spec_text "specs/issue-essay-features-adw-featuregap-sdlc_planner-essay-app-feature-parity.html"
  @initial_prompt "Add the writer-app feature parity task"

  # Back the real-named "claude" harness with the safe canned-event Fake adapter so a
  # launch on a real harness never spawns an external CLI (registry injection seam, §13).
  setup do
    original = Application.fetch_env!(:repo_builder, :harnesses)
    Application.put_env(:repo_builder, :harnesses, Map.put(original, "claude", original["fake"]))
    on_exit(fn -> Application.put_env(:repo_builder, :harnesses, original) end)
    :ok
  end

  # Spin up a git-backed project (writes a real `.git` dir so `:worktree` mode has
  # something to provision against). Point `:worktree, :scratch_base` at a tmp sibling
  # dir so the worktree lands alongside the project — NOT under `priv/workspaces/`.
  defp git_project(attrs) do
    base = Path.join(System.tmp_dir!(), "rb_adwrepo_#{System.unique_integer([:positive])}")
    repo = Path.join(base, "repo")
    File.mkdir_p!(Path.join(repo, "specs"))

    File.write!(Path.join(repo, "mix.exs"), "defmodule X.MixProject do end")

    File.write!(
      Path.join([
        repo,
        "specs",
        "issue-essay-features-adw-featuregap-sdlc_planner-essay-app-feature-parity.html"
      ]),
      "<html>spec</html>"
    )

    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main"], cd: repo)
    {_, 0} = System.cmd("git", ["config", "user.email", "t@example.com"], cd: repo)
    {_, 0} = System.cmd("git", ["config", "user.name", "t"], cd: repo)
    {_, 0} = System.cmd("git", ["add", "."], cd: repo)
    {_, 0} = System.cmd("git", ["commit", "-q", "-m", "init"], cd: repo)
    on_exit(fn -> File.rm_rf(base) end)

    Application.put_env(:repo_builder, :worktree, scratch_base: Path.join(base, "scratch"))
    on_exit(fn -> Application.delete_env(:repo_builder, :worktree) end)

    base_attrs = %{"name" => "adwrepo-#{System.unique_integer([:positive])}", "root_path" => repo}
    {:ok, project} = Projects.create_and_profile(Map.merge(base_attrs, attrs))
    project
  end

  # Persist `project_id` as the operator's active project, so `ConsoleLive`'s mount-time
  # `assign_default_project/1` picks it up. Restore the previous setting on exit so the
  # sandbox never bleeds state into the next test.
  defp set_active_project(project_id) do
    {:ok, previous} = Settings.put_active_project_id(project_id)
    on_exit(fn -> _ = Settings.put_active_project_id(previous) end)
    :ok
  end

  # Drive the ⌘K ADW Builder: open it, type spec + prompt, add plan→build steps, launch.
  # Mirrors the click sequence used in the existing ADW Builder tests.
  defp launch_via_builder(view, spec, prompt) do
    render_click(view, "toggle_adw_builder")
    render_change(view, "adw_set_spec", %{"spec" => spec})
    render_change(view, "adw_set_prompt", %{"prompt" => prompt})
    render_click(view, "adw_add_step", %{"step" => "plan"})
    render_click(view, "adw_add_step", %{"step" => "build"})
    render_click(view, "run_adw_builder")
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

  # Find the freshly-launched run for `wf`. There may be older runs in the DB from
  # earlier tests; `list_recent_for_project/2` is unreliable when `project_id IS NULL`,
  # so query directly by `workflow_id`.
  defp run_for_workflow(%Workflow{id: workflow_id}) do
    from(r in WorkflowRun, where: r.workflow_id == ^workflow_id, order_by: [desc: r.inserted_at])
    |> Repo.all()
    |> List.first()
  end

  describe "active project ⇒ workflow_runs.project_id == project.id" do
    test "the ADW Builder launches a run scoped to the active project (direct isolation)", %{
      conn: conn
    } do
      project =
        git_project(%{"default_harness" => "claude", "isolation_mode" => "direct"})

      :ok = set_active_project(project.id)

      {:ok, view, _html} = live(conn, ~p"/")

      workflows_before = Workflows.list_workflows()
      launch_via_builder(view, @spec_text, @initial_prompt)

      wf =
        Workflows.list_workflows()
        |> Enum.reject(fn w -> w in workflows_before end)
        |> List.last()

      assert wf, "expected a new workflow to be created on launch"
      assert wf.type == "custom"

      [first_step | _] = wf.steps
      assert first_step["prompt_template"] == Catalog.default_prompt_template("plan")

      # Wait for the run to finalize so its `artifacts` are persisted onto the row.
      # The Runner accumulates `artifacts` in `state.artifacts` and only flushes them
      # to `workflow_runs.artifacts` in `finalize/2` (BUILD_PROMPT §7).
      run = run_for_workflow(wf)
      assert run, "expected a run for the launched workflow"

      terminated = await_run_terminal(run.id)

      # The freshly-created run is scoped to the project (regression: was `nil` before
      # the fix because `launch_adw_builder/4` did not thread `project_id:`).
      assert terminated.project_id == project.id
      assert terminated.artifacts["spec"] == @spec_text
      assert terminated.artifacts["input"] == @initial_prompt

      # Direct isolation ⇒ no worktree columns populated.
      assert terminated.worktree_path == nil
      assert terminated.worktree_branch == nil
    end

    test "the ADW Builder launches a run that provisions a worktree IN the target project (worktree isolation)",
         %{conn: conn} do
      project =
        git_project(%{"default_harness" => "claude", "isolation_mode" => "worktree"})

      :ok = set_active_project(project.id)

      {:ok, view, _html} = live(conn, ~p"/")

      workflows_before = Workflows.list_workflows()
      launch_via_builder(view, @spec_text, @initial_prompt)

      wf =
        Workflows.list_workflows()
        |> Enum.reject(fn w -> w in workflows_before end)
        |> List.last()

      assert wf, "expected a new workflow to be created on launch"

      run = run_for_workflow(wf)
      assert run, "expected a run for the launched workflow"

      # Worktree isolation ⇒ the run records the reviewable branch + path under the
      # configured `:worktree, :scratch_base` (NOT `priv/workspaces/...`).
      terminated = await_run_terminal(run.id)

      assert terminated.project_id == project.id
      assert terminated.worktree_branch == "adw/#{run.id}"

      # Observable proof the cwd reached the session: the worktree branch survives in
      # the project's repo (`git worktree add` ran against `<project.root_path>`).
      {branches, 0} =
        System.cmd("git", ["branch", "--list", "adw/#{run.id}"], cd: project.root_path)

      assert branches =~ "adw/#{run.id}"

      assert terminated.worktree_path != nil
      refute String.contains?(terminated.worktree_path, "priv/workspaces/")

      scratch_base = Application.get_env(:repo_builder, :worktree)[:scratch_base]
      assert String.starts_with?(terminated.worktree_path, scratch_base)
    end
  end

  describe "no active project ⇒ existing no-cwd / managed-scratch behaviour (back-compat)" do
    test "a project-less console still launches a run (nil project_id, no worktree)", %{
      conn: conn
    } do
      # Explicitly clear any persisted active project so the console mounts with
      # `active_project_id: nil` (the back-compat path the fix preserves).
      :ok = set_active_project(nil)

      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "toggle_adw_builder")
      render_change(view, "adw_set_spec", %{"spec" => @spec_text})
      render_change(view, "adw_set_prompt", %{"prompt" => @initial_prompt})
      render_click(view, "adw_add_step", %{"step" => "plan"})

      workflows_before = Workflows.list_workflows()
      render_click(view, "run_adw_builder")

      wf =
        Workflows.list_workflows()
        |> Enum.reject(fn w -> w in workflows_before end)
        |> List.last()

      assert wf, "expected a new workflow to be created on launch"

      # Wait for the run to finalize so `artifacts` are persisted onto the row.
      run = run_for_workflow(wf)
      assert run, "expected a run for the launched workflow"

      terminated = await_run_terminal(run.id)

      # The freshly-launched run is NOT scoped to any project (back-compat default
      # when no active project is selected — every pre-existing caller is unchanged).
      assert terminated.project_id == nil
      assert terminated.artifacts["spec"] == @spec_text
    end
  end
end
