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
        {surface, framework} = detect_surface_framework(root, language, marker)

        %{
          "language" => language,
          "build_tool" => build_tool,
          "marker" => marker,
          "surface" => surface,
          "framework" => framework
        }

      nil ->
        %{
          "language" => "unknown",
          "build_tool" => nil,
          "marker" => nil,
          "surface" => "none",
          "framework" => "none"
        }
    end
  end

  # --- UI surface + framework detection (design-system-plugins) ---
  #
  # Decides the UI surface (`web` / `tui` / `none`) and framework from the language's
  # manifest. TUI deps are checked FIRST because they pin the surface (a repo with both a
  # web framework and a companion CLI resolves as its detected TUI dep; the run's goal can
  # override downstream). Fail-silent: an unreadable manifest yields `{"none", "none"}`.
  @spec detect_surface_framework(String.t(), String.t(), String.t()) ::
          {String.t(), String.t()}
  defp detect_surface_framework(root, language, marker) do
    content = read_marker(root, marker)

    case tui_framework(language, content) do
      nil ->
        case web_framework(language, content) do
          nil -> {"none", "none"}
          framework -> {"web", framework}
        end

      framework ->
        {"tui", framework}
    end
  end

  @spec read_marker(String.t(), String.t()) :: String.t()
  defp read_marker(root, marker) do
    case File.read(Path.join(root, marker)) do
      {:ok, content} -> content
      {:error, _} -> ""
    end
  end

  # Language → TUI framework, from the manifest content. `nil` ⇒ no TUI dep.
  @spec tui_framework(String.t(), String.t()) :: String.t() | nil
  defp tui_framework("elixir", content),
    do: if(content =~ ~r/:(ratatouille|owl)\b/, do: "ratatouille")

  defp tui_framework("go", content), do: if(content =~ ~r/\bbubbletea\b/, do: "bubbletea")
  defp tui_framework("rust", content), do: if(content =~ ~r/\bratatui\b/, do: "ratatui")
  defp tui_framework("python", content), do: if(content =~ ~r/\btextual\b/, do: "textual")

  defp tui_framework("node", content) do
    deps = node_deps(content)
    if "ink" in deps or Enum.any?(deps, &String.starts_with?(&1, "@opentui/")), do: "ink"
  end

  defp tui_framework(_language, _content), do: nil

  # Language → web framework, from the manifest content. `nil` ⇒ no web framework dep.
  @spec web_framework(String.t(), String.t()) :: String.t() | nil
  defp web_framework("elixir", content), do: if(content =~ ~r/:phoenix\b/, do: "phoenix")

  defp web_framework("node", content) do
    deps = node_deps(content)

    cond do
      "react" in deps -> "react"
      "svelte" in deps -> "svelte"
      "vue" in deps -> "vue"
      true -> nil
    end
  end

  defp web_framework(_language, _content), do: nil

  # Dependency names declared in a package.json (dependencies + devDependencies). Fail-silent:
  # malformed JSON yields `[]`.
  @spec node_deps(String.t()) :: [String.t()]
  defp node_deps(content) do
    case Jason.decode(content) do
      {:ok, %{} = json} ->
        [Map.get(json, "dependencies"), Map.get(json, "devDependencies")]
        |> Enum.flat_map(fn
          %{} = deps -> Map.keys(deps)
          _ -> []
        end)

      _ ->
        []
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
