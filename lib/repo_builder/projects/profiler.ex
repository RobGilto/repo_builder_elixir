defmodule RepoBuilder.Projects.Profiler do
  @moduledoc """
  Repo adapter: profile a target repository on connect. Reads what the repo already
  declares about agentic work — git metadata, language/build-tool stack heuristics, a
  derived capability map, and discovered conventions (`.claude/commands/*`,
  `AGENTS.md`/`CLAUDE.md`, `adws/adw_*.py`) — into a typed `profile()`.

  Pure-ish and fail-silent: a missing/unreadable repo never raises; git calls fall
  back to `nil`, an unknown stack yields a generic (empty) capability map. This is the
  data Phase 2's context primer renders and Phase 3's resolver templates against.
  """
  use TypedStruct

  alias RepoBuilder.Definitions
  alias RepoBuilder.Projects.Capabilities

  @type stack :: %{optional(String.t()) => term()}

  typedstruct enforce: true do
    field :root_path, String.t()
    field :exists?, boolean()
    field :git?, boolean()
    field :git_remote, String.t() | nil
    field :default_branch, String.t() | nil
    field :stack, stack()
    field :capabilities, Capabilities.t()
    field :claude_commands, [String.t()]
    field :has_agents_md, boolean()
    field :has_claude_md, boolean()
    field :adws, [Definitions.Adw.t()]
  end

  # Marker file → {language, build_tool}. First existing marker (in this order) wins.
  @markers [
    {"mix.exs", "elixir", "mix"},
    {"Cargo.toml", "rust", "cargo"},
    {"go.mod", "go", "go"},
    {"pyproject.toml", "python", "uv"},
    {"requirements.txt", "python", "pip"},
    {"package.json", "node", "npm"}
  ]

  @doc """
  Profile the repository rooted at `root_path`. Always returns a `profile()` — partial
  (with `exists?: false` / `git?: false`) for a missing or non-git directory.
  """
  @spec profile(String.t()) :: t()
  def profile(root_path) when is_binary(root_path) do
    root = Path.expand(root_path)
    exists? = File.dir?(root)
    stack = detect_stack(root)
    {git?, remote, branch} = git_metadata(root)

    %__MODULE__{
      root_path: root,
      exists?: exists?,
      git?: git?,
      git_remote: remote,
      default_branch: branch,
      stack: stack,
      capabilities: Capabilities.detect(stack),
      claude_commands: discover_commands(root),
      has_agents_md: File.regular?(Path.join(root, "AGENTS.md")),
      has_claude_md: File.regular?(Path.join(root, "CLAUDE.md")),
      adws: safe_scan_adws(root)
    }
  end

  # --- stack heuristics ---

  @spec detect_stack(String.t()) :: stack()
  defp detect_stack(root) do
    case Enum.find(@markers, fn {marker, _lang, _tool} ->
           File.regular?(Path.join(root, marker))
         end) do
      {marker, language, build_tool} ->
        %{"language" => language, "build_tool" => build_tool, "marker" => marker}

      nil ->
        %{"language" => "unknown", "build_tool" => nil, "marker" => nil}
    end
  end

  # --- git metadata (fail-silent shell-out) ---

  @spec git_metadata(String.t()) :: {boolean(), String.t() | nil, String.t() | nil}
  defp git_metadata(root) do
    if File.dir?(Path.join(root, ".git")) do
      {true, git(root, ["remote", "get-url", "origin"]), git(root, ["branch", "--show-current"])}
    else
      {false, nil, nil}
    end
  end

  # Run a git subcommand in `root`, returning trimmed stdout or nil on any failure.
  @spec git(String.t(), [String.t()]) :: String.t() | nil
  defp git(root, args) do
    case System.cmd("git", args, cd: root, stderr_to_stdout: true) do
      {output, 0} ->
        case String.trim(output) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  # --- conventions ---

  # Discovered `.claude/commands/<name>.md` command names (no extension), sorted.
  @spec discover_commands(String.t()) :: [String.t()]
  defp discover_commands(root) do
    root
    |> Path.join(".claude/commands/*.md")
    |> Path.wildcard()
    |> Enum.map(&Path.basename(&1, ".md"))
    |> Enum.sort()
  end

  @spec safe_scan_adws(String.t()) :: [Definitions.Adw.t()]
  defp safe_scan_adws(root) do
    Definitions.Adw.scan(root, :working_dir)
  rescue
    _ -> []
  end
end
