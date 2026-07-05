defmodule RepoBuilder.Projects.Worktree do
  @moduledoc """
  Opt-in git-worktree isolation per run (agentic-layer adaptor, Phase 4). When a
  project's `isolation_mode` is `:worktree`, each run works in a fresh
  `git worktree add <scratch>/<run_id> -b adw/<run_id> <base>` so parallel agents never
  collide on the operator's tree and changes land on a reviewable branch.

  Fail-safe: a non-git repository (or a git failure) falls through to `{:direct, root}`
  so the run still proceeds in the operator's directory. `cleanup/1` is idempotent and
  tolerant of an already-removed tree. Pure shell-outs; never raises.
  """

  require Logger

  @type info :: %{path: String.t(), branch: String.t(), repo: String.t()}
  @type checkout_result :: {:ok, info()} | {:direct, String.t()} | {:error, term()}

  @branch_prefix "adw/"

  @doc """
  Provision a worktree+branch for `run_id` off `repo_root`. Options:

    * `:default_branch` — base ref for the new branch (defaults to the repo's current
      branch, then `HEAD`).
    * `:scratch_base` — parent dir for worktrees (defaults to the configured base, then
      a tmp dir).

  Returns `{:ok, info}` on success, `{:direct, repo_root}` for a non-git repo, or
  `{:error, reason}` if the git command fails. Idempotent across teardown: an existing
  worktree dir is reused; a kept `adw/*` branch whose dir was removed (the takeover path,
  issue worktree-takeover) is RE-ATTACHED with its commits intact — a fresh run id creates
  a new branch off the base.
  """
  @spec checkout(String.t(), keyword()) :: checkout_result()
  def checkout(repo_root, opts \\ []) when is_binary(repo_root) do
    run_id = opts[:run_id] || raise ArgumentError, "checkout/2 requires :run_id"

    if git_repo?(repo_root) do
      provision(repo_root, to_string(run_id), opts)
    else
      {:direct, repo_root}
    end
  end

  @doc """
  Remove a worktree (idempotent; tolerant of an already-removed tree). The run's
  `adw/*` branch is kept for review.

  Uncommitted work is **safety-committed** to that branch before removal (issue
  worktree-loss): a dirty tree is `git add -A` + committed WIP on its own branch, so
  `--force` removal never destroys work the worker did not itself commit. If the safety
  commit fails while the tree is dirty, the tree is removed WITHOUT `--force` (git then
  refuses on a dirty tree, leaving the work on disk) rather than force-destroyed — losing
  work is the one unacceptable outcome. A clean tree commits nothing and behaves exactly
  as before. Fail-soft; always `:ok`.
  """
  @spec cleanup(%{
          required(:repo) => String.t(),
          required(:path) => String.t(),
          optional(:branch) => String.t()
        }) :: :ok
  def cleanup(%{repo: repo, path: path}) do
    if dirty?(path) do
      case safety_commit(path) do
        :ok ->
          remove_force(repo, path)

        {:error, _reason} ->
          # Could not commit a dirty tree — refuse to force-destroy it. A non-force
          # remove leaves the working tree in place with the operator's work intact.
          _ = git(repo, ["worktree", "remove", path])
          _ = git(repo, ["worktree", "prune"])

          Logger.warning(
            "worktree cleanup could not safety-commit dirty tree #{path}; left it in place"
          )

          :ok
      end
    else
      remove_force(repo, path)
    end
  end

  def cleanup(_other), do: :ok

  @spec remove_force(String.t(), String.t()) :: :ok
  defp remove_force(repo, path) do
    _ = git(repo, ["worktree", "remove", "--force", path])
    # Best-effort prune of stale administrative entries; ignore result.
    _ = git(repo, ["worktree", "prune"])
    :ok
  end

  # Whether the worktree at `path` has uncommitted changes (staged, unstaged, or
  # untracked). A missing path or git failure ⇒ false (the tolerant/idempotent path).
  @spec dirty?(String.t()) :: boolean()
  defp dirty?(path) do
    case git(path, ["status", "--porcelain"]) do
      {out, 0} -> String.trim(out) != ""
      _ -> false
    end
  end

  # Stage and commit everything in the worktree onto its own `adw/*` branch with an
  # explicit identity, so a missing global git config can't fail the emergency commit and
  # a target repo's commit hooks can't block it (`--no-verify`).
  @spec safety_commit(String.t()) :: :ok | {:error, term()}
  defp safety_commit(path) do
    with {_out, 0} <- git(path, ["add", "-A"]),
         {_out, 0} <-
           git(path, [
             "-c",
             "user.name=RepoBuilder",
             "-c",
             "user.email=repo-builder@local",
             "commit",
             "--no-verify",
             "-m",
             "wip(platform): safety commit on session teardown"
           ]) do
      :ok
    else
      {out, _code} -> {:error, String.trim(out)}
    end
  end

  @doc """
  The deterministic worktree `info` for a run WITHOUT provisioning — the same `path`
  (`<scratch_base>/<run_id>`) and `branch` (`adw/<run_id>`) `checkout/2` would resolve.
  Pure: used by the workflow `Runner` to record the reviewable branch onto the run for
  the UI handoff after the session has provisioned it.
  """
  @spec expected_info(String.t(), term(), keyword()) :: info()
  def expected_info(repo_root, run_id, opts \\ []) when is_binary(repo_root) do
    rid = to_string(run_id)
    %{path: Path.join(scratch_base(opts), rid), branch: @branch_prefix <> rid, repo: repo_root}
  end

  @doc "Whether `path` is (inside) a git working tree."
  @spec git_repo?(String.t()) :: boolean()
  def git_repo?(path) when is_binary(path) do
    File.dir?(path) and match?({_out, 0}, git(path, ["rev-parse", "--is-inside-work-tree"]))
  end

  @typedoc "One `git worktree list --porcelain` block; detached/bare blocks carry `branch: nil`."
  @type listed :: %{path: String.t(), head_sha: String.t() | nil, branch: String.t() | nil}

  @doc """
  List the repository's registered worktrees (`git worktree list --porcelain`),
  INCLUDING the main working tree as the first entry — callers filter (the inventory
  keeps only `adw/`-prefixed branches).
  """
  @spec list(String.t()) :: {:ok, [listed()]} | {:error, term()}
  def list(repo_root) when is_binary(repo_root) do
    if git_repo?(repo_root) do
      case git(repo_root, ["worktree", "list", "--porcelain"]) do
        {out, 0} -> {:ok, parse_porcelain(out)}
        {out, _code} -> {:error, String.trim(out)}
      end
    else
      {:error, :not_a_git_repo}
    end
  end

  @doc """
  `{ahead, behind}` commit counts of `branch` relative to `trunk`
  (`git rev-list --left-right --count trunk...branch`: left = behind, right = ahead).
  A branch or trunk that no longer exists returns `{:error, reason}`.
  """
  @spec ahead_behind(String.t(), String.t(), String.t()) ::
          {:ok, {non_neg_integer(), non_neg_integer()}}
          | {:error, :unparseable_rev_list | String.t()}
  def ahead_behind(repo_root, trunk, branch)
      when is_binary(repo_root) and is_binary(trunk) and is_binary(branch) do
    case git(repo_root, ["rev-list", "--left-right", "--count", "#{trunk}...#{branch}"]) do
      {out, 0} -> parse_left_right(out)
      {out, _code} -> {:error, String.trim(out)}
    end
  end

  @doc """
  The `git diff --shortstat trunk...branch` summary line ("N files changed, …").
  Identical branches return `{:ok, ""}`.
  """
  @spec diff_shortstat(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def diff_shortstat(repo_root, trunk, branch)
      when is_binary(repo_root) and is_binary(trunk) and is_binary(branch) do
    case git(repo_root, ["diff", "--shortstat", "#{trunk}...#{branch}"]) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, _code} -> {:error, String.trim(out)}
    end
  end

  @doc """
  Force-delete a run branch (`git branch -D`). GUARDED to the `#{@branch_prefix}` prefix:
  any other name is refused with `{:error, :not_an_adw_branch}` — this function must never
  be able to delete a trunk or operator branch.
  """
  @spec delete_branch(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_branch(repo_root, @branch_prefix <> _rest = branch) when is_binary(repo_root) do
    case git(repo_root, ["branch", "-D", branch]) do
      {_out, 0} -> :ok
      {out, _code} -> {:error, String.trim(out)}
    end
  end

  def delete_branch(_repo_root, _branch), do: {:error, :not_an_adw_branch}

  @doc "Best-effort `git worktree prune` of stale administrative entries; always `:ok`."
  @spec prune(String.t()) :: :ok
  def prune(repo_root) when is_binary(repo_root) do
    _ = git(repo_root, ["worktree", "prune"])
    :ok
  end

  @doc """
  The configured parent dir for run worktrees (config `:repo_builder, :worktree,
  :scratch_base`, falling back to `<tmp>/rb_worktrees`) — the same resolution
  `checkout/2` uses when no `:scratch_base` option is passed. Public so the
  worktree inventory can reconcile scratch-dir contents.
  """
  @spec scratch_base() :: String.t()
  def scratch_base, do: scratch_base([])

  @doc """
  Detect the repository's TRUNK branch dynamically (issue-adw-non-iso-merge) — never
  assume the literal `main`. Precedence:

    1. `git symbolic-ref refs/remotes/origin/HEAD` (the remote's default branch);
    2. `git remote show origin`'s "HEAD branch" line (works when the symbolic ref was
       never fetched);
    3. `git branch --show-current` (offline/local-only repos — the checked-out branch
       is the best available trunk heuristic);
    4. `{:ok, "main"}` as a documented last-resort historical default.

  A non-git `repo_root` is `{:error, :not_a_git_repo}`.
  """
  @spec detect_trunk(String.t()) :: {:ok, String.t()} | {:error, term()}
  def detect_trunk(repo_root) when is_binary(repo_root) do
    if git_repo?(repo_root) do
      trunk =
        trunk_from_symbolic_ref(repo_root) ||
          trunk_from_remote_show(repo_root) ||
          current_branch(repo_root) ||
          "main"

      {:ok, trunk}
    else
      {:error, :not_a_git_repo}
    end
  end

  @doc """
  Land `opts[:branch]` on the repo's trunk (issue-adw-non-iso-merge): detect the trunk
  via `detect_trunk/1`, fetch + checkout it, `git merge --no-ff`, and push when an
  `origin` remote exists (a fully local repo merges locally and skips fetch/pull/push).

  Returns `{:ok, %{sha: merged_sha, trunk: trunk}}`, or `{:error, reason}` — on a merge
  conflict the merge is aborted and the previously checked-out branch restored, so the
  operator's tree is never left mid-merge. A no-op merge (branch has no commits ahead of
  trunk) succeeds. Never raises.
  """
  @spec merge(String.t(), keyword()) ::
          {:ok, %{sha: String.t(), trunk: String.t()}} | {:error, term()}
  def merge(repo_root, opts) when is_binary(repo_root) do
    branch = opts[:branch] || raise ArgumentError, "merge/2 requires :branch"

    with {:ok, trunk} <- detect_trunk(repo_root),
         original = current_branch(repo_root),
         :ok <- fetch_if_remote(repo_root),
         :ok <- git_ok(repo_root, ["checkout", trunk]),
         :ok <- pull_if_remote(repo_root, trunk),
         :ok <- merge_or_restore(repo_root, branch, trunk, original),
         :ok <- push_if_remote(repo_root, trunk),
         {:ok, sha} <- head_sha(repo_root) do
      {:ok, %{sha: sha, trunk: trunk}}
    end
  end

  @spec trunk_from_symbolic_ref(String.t()) :: String.t() | nil
  defp trunk_from_symbolic_ref(repo_root) do
    case git(repo_root, ["symbolic-ref", "refs/remotes/origin/HEAD"]) do
      {out, 0} ->
        case String.trim(out) do
          "refs/remotes/origin/" <> branch when branch != "" -> branch
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @spec trunk_from_remote_show(String.t()) :: String.t() | nil
  defp trunk_from_remote_show(repo_root) do
    with true <- has_origin?(repo_root),
         {out, 0} <- git(repo_root, ["remote", "show", "origin"]),
         [_, branch] when is_binary(branch) <- Regex.run(~r/HEAD branch:\s*(\S+)/, out) do
      if branch in ["", "(unknown)"], do: nil, else: branch
    else
      _ -> nil
    end
  end

  @spec has_origin?(String.t()) :: boolean()
  defp has_origin?(repo_root) do
    match?({_out, 0}, git(repo_root, ["remote", "get-url", "origin"]))
  end

  @spec fetch_if_remote(String.t()) :: :ok | {:error, String.t()}
  defp fetch_if_remote(repo_root) do
    if has_origin?(repo_root), do: git_ok(repo_root, ["fetch", "origin"]), else: :ok
  end

  @spec pull_if_remote(String.t(), String.t()) :: :ok | {:error, String.t()}
  defp pull_if_remote(repo_root, trunk) do
    if has_origin?(repo_root), do: git_ok(repo_root, ["pull", "origin", trunk]), else: :ok
  end

  @spec push_if_remote(String.t(), String.t()) :: :ok | {:error, String.t()}
  defp push_if_remote(repo_root, trunk) do
    if has_origin?(repo_root), do: git_ok(repo_root, ["push", "origin", trunk]), else: :ok
  end

  # `--no-ff` keeps every ADW landing visible as a merge commit. A conflict aborts the
  # merge and restores the branch that was checked out before `merge/2` ran.
  @spec merge_or_restore(String.t(), String.t(), String.t(), String.t() | nil) ::
          :ok | {:error, String.t()}
  defp merge_or_restore(repo_root, branch, trunk, original) do
    case git(repo_root, ["merge", "--no-ff", branch, "-m", "merge #{branch} into #{trunk}"]) do
      {_out, 0} ->
        :ok

      {out, _code} ->
        _ = git(repo_root, ["merge", "--abort"])

        _ =
          if is_binary(original) and original != trunk,
            do: git(repo_root, ["checkout", original])

        {:error, String.trim(out)}
    end
  end

  @spec head_sha(String.t()) :: {:ok, String.t()} | {:error, term()}
  defp head_sha(repo_root) do
    case git(repo_root, ["rev-parse", "HEAD"]) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, _} -> {:error, String.trim(out)}
    end
  end

  @spec git_ok(String.t(), [String.t()]) :: :ok | {:error, String.t()}
  defp git_ok(repo_root, args) do
    case git(repo_root, args) do
      {_out, 0} -> :ok
      {out, _code} -> {:error, String.trim(out)}
    end
  end

  # --- internals ---

  # Porcelain blocks are blank-line separated; the `worktree <path>` line leads each
  # block, so the reducer only upgrades an already-started map (a stray field line
  # before any `worktree` line is ignored rather than crashing).
  @spec parse_porcelain(String.t()) :: [listed()]
  defp parse_porcelain(out) do
    out
    |> String.split("\n\n", trim: true)
    |> Enum.map(&parse_porcelain_block/1)
    |> Enum.reject(&is_nil/1)
  end

  @spec parse_porcelain_block(String.t()) :: listed() | nil
  defp parse_porcelain_block(block) do
    block
    |> String.split("\n", trim: true)
    |> Enum.reduce(nil, fn
      "worktree " <> path, _acc -> %{path: path, head_sha: nil, branch: nil}
      "HEAD " <> sha, %{} = acc -> %{acc | head_sha: sha}
      "branch refs/heads/" <> name, %{} = acc -> %{acc | branch: name}
      _line, acc -> acc
    end)
  end

  @spec parse_left_right(String.t()) ::
          {:ok, {non_neg_integer(), non_neg_integer()}} | {:error, term()}
  defp parse_left_right(out) do
    with [left, right] <- String.split(String.trim(out), ~r/\s+/),
         {behind, ""} <- Integer.parse(left),
         {ahead, ""} <- Integer.parse(right) do
      {:ok, {ahead, behind}}
    else
      _ -> {:error, :unparseable_rev_list}
    end
  end

  @spec provision(String.t(), String.t(), keyword()) :: checkout_result()
  defp provision(repo_root, run_id, opts) do
    path = Path.join(scratch_base(opts), run_id)
    branch = @branch_prefix <> run_id
    base = opts[:default_branch] || current_branch(repo_root) || "HEAD"

    cond do
      File.dir?(path) ->
        {:ok, %{path: path, branch: branch, repo: repo_root}}

      # Takeover (issue worktree-takeover): the branch survived a prior worker's teardown
      # but its dir was removed — re-attach the worktree to the EXISTING branch (no `-b`,
      # which would fail on an already-existing branch) so all prior commits carry over.
      branch_exists?(repo_root, branch) ->
        File.mkdir_p!(scratch_base(opts))
        add_worktree(repo_root, path, branch, ["worktree", "add", path, branch])

      true ->
        File.mkdir_p!(scratch_base(opts))
        add_worktree(repo_root, path, branch, ["worktree", "add", path, "-b", branch, base])
    end
  end

  @spec add_worktree(String.t(), String.t(), String.t(), [String.t()]) ::
          {:ok, info()} | {:error, term()}
  defp add_worktree(repo_root, path, branch, argv) do
    case git(repo_root, argv) do
      {_out, 0} -> {:ok, %{path: path, branch: branch, repo: repo_root}}
      {out, _code} -> {:error, String.trim(out)}
    end
  end

  # Whether a local branch named `branch` already exists in the repo.
  @spec branch_exists?(String.t(), String.t()) :: boolean()
  defp branch_exists?(repo_root, branch) do
    match?(
      {_out, 0},
      git(repo_root, ["rev-parse", "--verify", "--quiet", "refs/heads/" <> branch])
    )
  end

  @spec scratch_base(keyword()) :: String.t()
  defp scratch_base(opts) do
    opts[:scratch_base] ||
      Application.get_env(:repo_builder, :worktree, [])[:scratch_base] ||
      Path.join(System.tmp_dir!(), "rb_worktrees")
  end

  @spec current_branch(String.t()) :: String.t() | nil
  defp current_branch(repo_root) do
    case git(repo_root, ["branch", "--show-current"]) do
      {out, 0} ->
        case String.trim(out) do
          "" -> nil
          branch -> branch
        end

      _ ->
        nil
    end
  end

  @spec git(String.t(), [String.t()]) :: {String.t(), non_neg_integer()} | {String.t(), :error}
  defp git(repo, args) do
    System.cmd("git", args, cd: repo, stderr_to_stdout: true)
  rescue
    _ -> {"git unavailable", :error}
  end
end
