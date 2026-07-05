defmodule RepoBuilderWeb.TestWorktreePanelTest do
  @moduledoc """
  LiveView coverage for the Worktrees management panel on `/projects/:id`
  (worktree-panel-and-gc plan): async inventory render with badges, on-demand merge
  (chip + persisted sha), remove / remove+branch, GC, and the isolation-mode toggle.

  `async: false` — shared Ecto sandbox must reach the LiveView + its start_async
  task, and the worktree scratch base is process-global app env.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias RepoBuilder.Projects
  alias RepoBuilder.Projects.Worktree
  alias RepoBuilder.Repo
  alias RepoBuilder.Workflows

  defp uniq, do: System.unique_integer([:positive])

  defp git!(repo, args) do
    {out, code} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    if code != 0, do: flunk("git #{Enum.join(args, " ")} failed: #{out}")
    out
  end

  setup do
    base = Path.join(System.tmp_dir!(), "rb_wtpanel_#{uniq()}")
    repo = Path.join(base, "repo")
    scratch = Path.join(base, "scratch")
    File.mkdir_p!(repo)
    File.mkdir_p!(scratch)

    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["config", "user.email", "t@example.com"])
    git!(repo, ["config", "user.name", "t"])
    File.write!(Path.join(repo, "README.md"), "hello\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-q", "-m", "init"])

    previous = Application.get_env(:repo_builder, :worktree, [])
    Application.put_env(:repo_builder, :worktree, Keyword.put(previous, :scratch_base, scratch))

    on_exit(fn ->
      Application.put_env(:repo_builder, :worktree, previous)
      File.rm_rf(base)
    end)

    {:ok, project} = Projects.create_project(%{name: "wt-#{uniq()}", root_path: repo})
    {:ok, project: project, repo: repo, scratch: scratch}
  end

  defp seed_worktree_run(project, run_id) do
    {:ok, info} = Worktree.checkout(project.root_path, run_id: run_id)

    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "wf-#{uniq()}",
        type: "plan_build",
        steps: [%{"name" => "plan", "harness" => "fake", "on_success" => "done"}]
      })

    {:ok, run} =
      Workflows.create_run(%{
        workflow_id: wf.id,
        status: :succeeded,
        project_id: project.id,
        worktree_path: info.path,
        worktree_branch: info.branch
      })

    {run, info}
  end

  defp commit_in!(path, file) do
    File.write!(Path.join(path, file), "work\n")
    git!(path, ["add", "."])
    git!(path, ["commit", "-q", "-m", "wt work"])
  end

  test "renders the panel with a run-backed row and an orphan badge", %{
    conn: conn,
    project: project
  } do
    {_run, info} = seed_worktree_run(project, "seen")
    {:ok, _orphan} = Worktree.checkout(project.root_path, run_id: "ghost")

    {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")
    html = render_async(view)

    assert html =~ "Worktrees"
    assert html =~ info.branch
    assert html =~ "adw/ghost"
    assert html =~ "orphaned"
    assert html =~ "unmerged"
  end

  test "merge lands the branch, persists the sha, and flips the chip", %{
    conn: conn,
    project: project
  } do
    {run, info} = seed_worktree_run(project, "land")
    commit_in!(info.path, "feature.txt")

    {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")
    render_async(view)

    view
    |> element("#wt-adw-land button", "Merge")
    |> render_click()

    html = render_async(view)
    assert html =~ "merged @"

    reloaded = Repo.reload!(run)
    assert reloaded.merge_status == :merged
    assert is_binary(reloaded.merged_sha)

    log = git!(project.root_path, ["log", "--oneline", "-3"])
    assert log =~ "merge #{info.branch}"
  end

  test "remove + branch deletes the worktree dir and the branch", %{
    conn: conn,
    project: project
  } do
    {_run, info} = seed_worktree_run(project, "gone")

    {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")
    render_async(view)

    view
    |> element("#wt-adw-gone button", "Remove + branch")
    |> render_click()

    render_async(view)
    refute File.dir?(info.path)
    branches = git!(project.root_path, ["branch", "--list", info.branch])
    assert String.trim(branches) == ""
  end

  test "GC reclaims merged worktrees older than the cutoff", %{conn: conn, project: project} do
    {run, info} = seed_worktree_run(project, "oldmerged")
    {:ok, _} = Workflows.record_merge(run, %{merge_status: :merged, merged_sha: "abc"})

    old = DateTime.add(DateTime.utc_now(), -30 * 86_400, :second)

    {1, _} =
      Repo.update_all(
        from(r in RepoBuilder.Workflows.WorkflowRun, where: r.id == ^run.id),
        set: [inserted_at: old]
      )

    {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")
    render_async(view)

    view |> element("button", "GC merged") |> render_click()

    render_async(view)
    refute File.dir?(info.path)
  end

  test "the isolation toggle flips the project's mode", %{conn: conn, project: project} do
    # Mode-agnostic: the schema default flips to :worktree in the same plan, so this
    # asserts the toggle inverts whatever the starting mode is — twice (round trip).
    start_mode = Repo.reload!(project).isolation_mode
    other = if start_mode == :worktree, do: :direct, else: :worktree

    {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")
    render_async(view)

    html = view |> element("#isolation-toggle") |> render_click()
    assert html =~ "isolation: #{other}"
    assert Repo.reload!(project).isolation_mode == other

    html = view |> element("#isolation-toggle") |> render_click()
    assert html =~ "isolation: #{start_mode}"
    assert Repo.reload!(project).isolation_mode == start_mode
  end
end
