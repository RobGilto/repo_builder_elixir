defmodule RepoBuilder.Definitions.SlashCommand do
  @moduledoc """
  A single slash-command definition discovered on disk under `.claude/commands/`.

  A slash command is a markdown file whose path (relative to `commands/`) becomes a
  `:`-namespaced name (`experts/ws/q.md` → `experts:ws:q`) and whose optional YAML
  frontmatter supplies a `description`/`argument-hint`. This module is the typed
  domain value plus a pure, fail-silent `scan/2` (filesystem reads only, never
  raises): a missing directory yields `[]` and malformed frontmatter degrades to a
  struct with `description: nil`. Frontmatter parsing reuses
  `RepoBuilder.Orchestrator.Template.from_markdown/1` so the `---`-fence handling
  matches the agent-template loader.
  """
  use TypedStruct

  alias RepoBuilder.Orchestrator.Template

  @type source :: :app | :working_dir

  typedstruct enforce: true do
    field :name, String.t()
    field :namespace, [String.t()]
    field :path, String.t()
    field :source, source()
    field :description, String.t() | nil
    field :argument_hint, String.t() | nil
    field :mtime, integer()
  end

  @doc """
  Scan `<root>/.claude/commands/**/*.md` into a list of structs tagged with `source`.
  Returns `[]` when the directory is absent. Never raises.
  """
  @spec scan(root :: String.t(), source()) :: [t()]
  def scan(root, source \\ :app) when is_binary(root) and source in [:app, :working_dir] do
    commands_dir = Path.join([root, ".claude", "commands"])

    commands_dir
    |> Path.join("**/*.md")
    |> Path.wildcard()
    |> Enum.map(&from_file(&1, commands_dir, source))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.name)
  end

  @spec from_file(String.t(), String.t(), source()) :: t() | nil
  defp from_file(path, commands_dir, source) do
    relative = Path.relative_to(path, commands_dir)
    parts = relative |> Path.rootname() |> Path.split()

    case parts do
      [] ->
        nil

      _segments ->
        name = Enum.join(parts, ":")
        namespace = Enum.drop(parts, -1)
        {description, argument_hint} = read_frontmatter(path)

        %__MODULE__{
          name: name,
          namespace: namespace,
          path: path,
          source: source,
          description: description,
          argument_hint: argument_hint,
          mtime: mtime(path)
        }
    end
  end

  # Pull `description`/`argument-hint` from the file's frontmatter, degrading to
  # `{nil, nil}` on a read error or malformed/absent frontmatter.
  @spec read_frontmatter(String.t()) :: {String.t() | nil, String.t() | nil}
  defp read_frontmatter(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, attrs} <- Template.from_markdown(raw) do
      {blank(attrs["description"]), blank(attrs["argument-hint"])}
    else
      _error -> {nil, nil}
    end
  end

  @spec mtime(String.t()) :: integer()
  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} when is_integer(mtime) -> mtime
      _other -> 0
    end
  end

  @spec blank(term()) :: String.t() | nil
  defp blank(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank(_other), do: nil
end
