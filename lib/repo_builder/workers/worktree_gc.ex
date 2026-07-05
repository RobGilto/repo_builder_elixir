defmodule RepoBuilder.Workers.WorktreeGC do
  @moduledoc """
  Nightly worktree garbage collection (worktree-panel-and-gc plan; Oban Cron —
  `30 3 * * *`). Sweeps every registered project, reclaiming MERGED run worktrees
  (and their `adw/*` branches — the commits are already on the trunk) older than the
  configured age via `Projects.WorktreeInventory.gc/2`, then prunes git's registry.

  Idempotent and safe to fire any time: eligibility requires merged + aged + something
  physical left to reclaim, and unmerged trees are never auto-reclaimed. Per-project
  failures are logged and skipped so one broken repo can't starve the sweep. Kill
  switch: `config :repo_builder, :worktree, gc_enabled: false`.
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  require Logger

  alias RepoBuilder.Projects
  alias RepoBuilder.Projects.Worktree
  alias RepoBuilder.Projects.WorktreeInventory

  @impl Oban.Worker
  def perform(_job) do
    if enabled?() do
      _ = sweep()
      :ok
    else
      :ok
    end
  end

  @doc """
  GC every project with a git `root_path`; returns the total worktrees reclaimed.
  Public (mirrors `WorkflowResume.reconcile/0`) so the sweep is operable from IEx and
  testable without Oban.
  """
  @spec sweep() :: non_neg_integer()
  def sweep do
    {total, projects} =
      Projects.list_projects()
      |> Enum.filter(&git_project?/1)
      |> Enum.reduce({0, 0}, fn project, {count, seen} ->
        {count + gc_project(project), seen + 1}
      end)

    Logger.info("worktree gc reclaimed #{total} across #{projects} project(s)")
    total
  end

  @spec gc_project(Projects.Project.t()) :: non_neg_integer()
  defp gc_project(project) do
    {:ok, count} = WorktreeInventory.gc(project)
    count
  rescue
    error ->
      Logger.warning("worktree gc failed for #{project.name}: #{Exception.message(error)}")
      0
  end

  @spec git_project?(Projects.Project.t()) :: boolean()
  defp git_project?(%{root_path: root}) when is_binary(root), do: Worktree.git_repo?(root)
  defp git_project?(_project), do: false

  @spec enabled?() :: boolean()
  defp enabled? do
    Application.get_env(:repo_builder, :worktree, [])[:gc_enabled] != false
  end
end
