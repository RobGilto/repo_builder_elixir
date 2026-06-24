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
  `{:error, reason}` if the git command fails. Idempotent: an existing worktree dir for
  the run is reused.
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

  @doc "Remove a worktree (idempotent; tolerant of an already-removed tree). The branch is kept."
  @spec cleanup(info()) :: :ok
  def cleanup(%{repo: repo, path: path}) do
    _ = git(repo, ["worktree", "remove", "--force", path])
    # Best-effort prune of stale administrative entries; ignore result.
    _ = git(repo, ["worktree", "prune"])
    :ok
  end

  def cleanup(_other), do: :ok

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

  # --- internals ---

  @spec provision(String.t(), String.t(), keyword()) :: checkout_result()
  defp provision(repo_root, run_id, opts) do
    path = Path.join(scratch_base(opts), run_id)
    branch = @branch_prefix <> run_id
    base = opts[:default_branch] || current_branch(repo_root) || "HEAD"

    if File.dir?(path) do
      {:ok, %{path: path, branch: branch, repo: repo_root}}
    else
      File.mkdir_p!(scratch_base(opts))

      case git(repo_root, ["worktree", "add", path, "-b", branch, base]) do
        {_out, 0} -> {:ok, %{path: path, branch: branch, repo: repo_root}}
        {out, _code} -> {:error, String.trim(out)}
      end
    end
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
