defmodule RepoBuilder.Projects.WorktreeInventory do
  @moduledoc """
  Reconciling worktree inventory for a project (worktree management panel). Unions
  THREE sources of truth so drift in any one of them is visible instead of silent:

    1. `workflow_runs` rows with a recorded `worktree_branch` (via `Workflows`);
    2. git's own registry (`Worktree.list/1`, filtered to `adw/`-prefixed branches);
    3. the scratch directory's contents (`Worktree.scratch_base/0`).

  This module owns the on-demand operations the panel exposes — `merge/2`,
  `remove/3`, `gc/2` — but is NOT a `Repo` caller: all DB access goes through
  `Workflows`, all git access through `Projects.Worktree` (BUILD_PROMPT.md §8).

  Enrichment (ahead/behind + diff shortstat, ~2 git calls per entry) is capped at the
  `@enrich_cap` newest entries; older entries render un-enriched (nil counts).
  """

  require Logger

  alias RepoBuilder.Projects.Project
  alias RepoBuilder.Projects.Worktree
  alias RepoBuilder.Workflows
  alias RepoBuilder.Workflows.WorkflowRun

  @enrich_cap 30
  @branch_prefix "adw/"

  defmodule Entry do
    @moduledoc "One reconciled worktree: run row ⊕ git registry ⊕ scratch dir."
    use TypedStruct

    typedstruct enforce: true do
      field :branch, String.t()
      field :path, String.t()
      field :run_id, Ecto.UUID.t(), enforce: false
      field :run_status, atom(), enforce: false
      field :merge_status, :merged | :failed, enforce: false
      field :merged_sha, String.t(), enforce: false
      field :on_disk?, boolean(), default: false
      field :in_git?, boolean(), default: false
      field :ahead, non_neg_integer(), enforce: false
      field :behind, non_neg_integer(), enforce: false
      field :shortstat, String.t(), enforce: false
      field :run_inserted_at, DateTime.t(), enforce: false
    end
  end

  @typedoc "Why an entry could not be removed."
  @type remove_error :: :unmerged | term()

  @doc """
  The reconciled inventory for `project`, newest-run first, orphans (present on disk
  or in git with no run row) appended. A non-git `root_path` still lists run-row
  entries (visibility even when the disk side is gone) — it never errors for that.
  """
  @spec list(Project.t()) :: {:ok, [Entry.t()]}
  def list(%Project{} = project) do
    runs = Workflows.list_worktree_runs(project.id)
    git_entries = git_entries(project.root_path)
    scratch_paths = scratch_paths()

    entries =
      runs
      |> Enum.map(&entry_from_run(&1, git_entries, scratch_paths))
      |> append_orphans(git_entries, scratch_paths, project.root_path)
      |> enrich(project.root_path)

    {:ok, entries}
  end

  @doc """
  Land `branch` on the project's trunk via `Worktree.merge/2` and record the outcome
  on the matching run row (when one exists). No matching run still merges — the
  recording is best-effort observability, not a precondition.
  """
  @spec merge(Project.t(), String.t()) ::
          {:ok, %{sha: String.t(), trunk: String.t()}} | {:error, term()}
  def merge(%Project{} = project, branch) when is_binary(branch) do
    case Worktree.merge(project.root_path, branch: branch) do
      {:ok, %{sha: sha} = result} ->
        _ = record_outcome(project, branch, %{merge_status: :merged, merged_sha: sha})
        {:ok, result}

      {:error, reason} ->
        _ =
          record_outcome(project, branch, %{
            merge_status: :failed,
            merge_error: stringify(reason)
          })

        {:error, reason}
    end
  end

  @doc """
  Remove an entry's worktree (idempotent), optionally deleting its branch
  (`delete_branch: true`; `adw/`-prefix guarded by `Worktree.delete_branch/2`).
  REFUSED with `{:error, :unmerged}` when the entry is unmerged AND has commits
  ahead of the trunk, unless `force: true` — losing unlanded agent work must be an
  explicit choice.
  """
  @spec remove(Project.t(), Entry.t(), keyword()) :: :ok | {:error, remove_error()}
  def remove(%Project{} = project, %Entry{} = entry, opts \\ []) do
    if unmerged_with_work?(entry) and not Keyword.get(opts, :force, false) do
      {:error, :unmerged}
    else
      :ok = Worktree.cleanup(%{repo: project.root_path, path: entry.path})

      if Keyword.get(opts, :delete_branch, false) do
        delete_branch_tolerant(project.root_path, entry.branch)
      else
        :ok
      end
    end
  end

  # A branch already gone (hand-deleted) is the desired end state, not a failure.
  @spec delete_branch_tolerant(String.t(), String.t()) :: :ok
  defp delete_branch_tolerant(root_path, branch) do
    case Worktree.delete_branch(root_path, branch) do
      :ok -> :ok
      {:error, reason} -> log_skip("delete_branch", branch, reason)
    end
  end

  @doc """
  Reclaim every MERGED entry whose run is older than `opts[:days]` (default: config
  `:repo_builder, :worktree, :gc_after_days`, default 7), deleting worktree AND
  branch (the commits are already on the trunk), then `git worktree prune`. Unmerged
  entries are never GC'd regardless of age. Per-entry failures are logged and
  skipped. Returns the count removed.
  """
  @spec gc(Project.t(), keyword()) :: {:ok, non_neg_integer()}
  def gc(%Project{} = project, opts \\ []) do
    days = Keyword.get(opts, :days) || config_gc_days()
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)
    {:ok, entries} = list(project)

    count =
      entries
      |> Enum.filter(&gc_eligible?(&1, cutoff))
      |> Enum.reduce(0, fn entry, acc ->
        case remove(project, entry, delete_branch: true, force: true) do
          :ok ->
            acc + 1

          {:error, reason} ->
            _ = log_skip("gc", entry.branch, reason)
            acc
        end
      end)

    :ok = Worktree.prune(project.root_path)
    {:ok, count}
  end

  # --- reconcile internals ---

  @spec git_entries(String.t() | nil) :: [Worktree.listed()]
  defp git_entries(root_path) when is_binary(root_path) do
    case Worktree.list(root_path) do
      {:ok, listed} ->
        Enum.filter(listed, fn %{branch: branch} ->
          is_binary(branch) and String.starts_with?(branch, @branch_prefix)
        end)

      {:error, _reason} ->
        []
    end
  end

  defp git_entries(_root_path), do: []

  @spec scratch_paths() :: MapSet.t(String.t())
  defp scratch_paths do
    base = Worktree.scratch_base()

    case File.ls(base) do
      {:ok, names} -> MapSet.new(names, &Path.join(base, &1))
      {:error, _reason} -> MapSet.new()
    end
  end

  @spec entry_from_run(WorkflowRun.t(), [Worktree.listed()], MapSet.t(String.t())) :: Entry.t()
  defp entry_from_run(%WorkflowRun{} = run, git_entries, scratch_paths) do
    path = run.worktree_path || Path.join(Worktree.scratch_base(), to_string(run.id))

    %Entry{
      branch: run.worktree_branch,
      path: path,
      run_id: run.id,
      run_status: run.status,
      merge_status: run.merge_status,
      merged_sha: run.merged_sha,
      on_disk?: File.dir?(path) or MapSet.member?(scratch_paths, path),
      in_git?: Enum.any?(git_entries, &(&1.branch == run.worktree_branch)),
      run_inserted_at: run.inserted_at
    }
  end

  # Orphans: registered in git or lying in the scratch dir with NO run row — exactly
  # the drift the panel exists to surface. The scratch base is SHARED across projects,
  # so a scratch dir only counts as this project's orphan when its worktree `.git`
  # pointer file targets this project's repository.
  @spec append_orphans([Entry.t()], [Worktree.listed()], MapSet.t(String.t()), String.t() | nil) ::
          [Entry.t()]
  defp append_orphans(entries, git_entries, scratch_paths, root_path) do
    known_branches = MapSet.new(entries, & &1.branch)
    known_paths = MapSet.new(entries, & &1.path)

    git_orphans =
      git_entries
      |> Enum.reject(&MapSet.member?(known_branches, &1.branch))
      |> Enum.map(fn %{path: path, branch: branch} ->
        %Entry{
          branch: branch,
          path: path,
          on_disk?: File.dir?(path),
          in_git?: true
        }
      end)

    orphan_paths =
      scratch_paths
      |> MapSet.difference(known_paths)
      |> MapSet.reject(fn path -> Enum.any?(git_orphans, &(&1.path == path)) end)
      |> Enum.filter(&worktree_of?(&1, root_path))
      |> Enum.map(fn path ->
        %Entry{
          branch: @branch_prefix <> Path.basename(path),
          path: path,
          on_disk?: true,
          in_git?: false
        }
      end)

    entries ++ git_orphans ++ orphan_paths
  end

  # A linked worktree's `.git` is a FILE reading "gitdir: <repo>/.git/worktrees/<name>";
  # match it against the project root to attribute shared-scratch dirs correctly.
  @spec worktree_of?(String.t(), String.t() | nil) :: boolean()
  defp worktree_of?(path, root_path) when is_binary(root_path) do
    case File.read(Path.join(path, ".git")) do
      {:ok, "gitdir: " <> gitdir} -> String.contains?(gitdir, root_path)
      _other -> false
    end
  end

  defp worktree_of?(_path, _root_path), do: false

  @spec enrich([Entry.t()], String.t() | nil) :: [Entry.t()]
  defp enrich(entries, root_path) when is_binary(root_path) do
    case Worktree.detect_trunk(root_path) do
      {:ok, trunk} ->
        {head, tail} = Enum.split(entries, @enrich_cap)
        Enum.map(head, &enrich_entry(&1, root_path, trunk)) ++ tail

      {:error, _reason} ->
        entries
    end
  end

  defp enrich(entries, _root_path), do: entries

  # A dead branch's enrichment errors degrade to nils — the row still renders.
  @spec enrich_entry(Entry.t(), String.t(), String.t()) :: Entry.t()
  defp enrich_entry(%Entry{} = entry, root_path, trunk) do
    entry =
      case Worktree.ahead_behind(root_path, trunk, entry.branch) do
        {:ok, {ahead, behind}} -> %{entry | ahead: ahead, behind: behind}
        {:error, _reason} -> entry
      end

    case Worktree.diff_shortstat(root_path, trunk, entry.branch) do
      {:ok, stat} -> %{entry | shortstat: stat}
      {:error, _reason} -> entry
    end
  end

  # --- operation internals ---

  @spec unmerged_with_work?(Entry.t()) :: boolean()
  defp unmerged_with_work?(%Entry{merge_status: :merged}), do: false
  defp unmerged_with_work?(%Entry{ahead: ahead}) when is_integer(ahead), do: ahead > 0
  # Unknown ahead-count (un-enriched or dead branch): treat as having work — safe side.
  defp unmerged_with_work?(%Entry{}), do: true

  # Eligible = merged + aged + something physical left to reclaim. Without the
  # on_disk?/in_git? requirement a run-row-only memory (worktree already reclaimed)
  # would be re-counted on every sweep — the run row itself is history, never GC'd.
  @spec gc_eligible?(Entry.t(), DateTime.t()) :: boolean()
  defp gc_eligible?(
         %Entry{merge_status: :merged, run_inserted_at: %DateTime{} = at} = entry,
         cutoff
       ),
       do: (entry.on_disk? or entry.in_git?) and DateTime.compare(at, cutoff) == :lt

  defp gc_eligible?(%Entry{}, _cutoff), do: false

  @spec record_outcome(Project.t(), String.t(), map()) :: :ok
  defp record_outcome(%Project{} = project, branch, attrs) do
    project.id
    |> Workflows.list_worktree_runs()
    |> Enum.find(&(&1.worktree_branch == branch))
    |> case do
      %WorkflowRun{} = run ->
        case Workflows.record_merge(run, attrs) do
          {:ok, _run} -> :ok
          {:error, reason} -> log_skip("record_merge", branch, reason)
        end

      nil ->
        :ok
    end
  end

  # Inference-only spec: the reason union narrows to the concrete caller error types.
  defp log_skip(op, branch, reason) do
    Logger.warning("worktree inventory #{op} skipped for #{branch}: #{inspect(reason)}")
    :ok
  end

  @spec config_gc_days() :: pos_integer()
  defp config_gc_days do
    Application.get_env(:repo_builder, :worktree, [])[:gc_after_days] || 7
  end

  # Inference-only spec: callers only ever pass Worktree.merge/2's error reasons.
  defp stringify(reason) when is_binary(reason), do: reason
  defp stringify(reason), do: inspect(reason)
end
