defmodule RepoBuilder.Definitions.Adw do
  @moduledoc """
  A single ADW (AI Developer Workflow) definition discovered on disk under `adws/`.

  Each `adws/adw_*.py` script becomes a struct whose `name` is the filename with the
  `adw_` prefix stripped (`adw_plan_build_iso.py` → `plan_build_iso`) and whose
  `description` is the first non-empty line of the leading `\"""docstring\"""`, falling
  back to a humanized filename when no docstring is present. Pure and fail-silent: a
  missing directory yields `[]`, never raises.

  This list is PRESENTATION ONLY — `RepoBuilder.WorkflowEngine.Catalog` stays the
  validation source of truth for the `start_adw` tool. A non-catalog `adw_*.py`
  renders a chip but the orchestrator validates the slug on use.
  """
  use TypedStruct

  @type source :: :app | :working_dir

  typedstruct enforce: true do
    field :name, String.t()
    field :path, String.t()
    field :source, source()
    field :description, String.t() | nil
    field :mtime, integer()
  end

  @docstring_regex ~r/"""(.*?)"""/s

  @doc """
  Scan ADW scripts under `<root>/adws/` into structs tagged with `source`. Globs both
  the top-level `adws/adw_*.py` (the repo's `*_iso` workflows) AND the portable
  `adws/adw_workflows/adw_*.py` (the real shell-out workflows the orchestrator launches
  via the `adw` harness). Same-named scripts are de-duplicated by name (first wins,
  top-level before `adw_workflows/`). Returns `[]` when the directory is absent; never
  raises.
  """
  @spec scan(root :: String.t(), source()) :: [t()]
  def scan(root, source \\ :app) when is_binary(root) and source in [:app, :working_dir] do
    ["adws/adw_*.py", "adws/adw_workflows/adw_*.py"]
    |> Enum.flat_map(fn pattern -> root |> Path.join(pattern) |> Path.wildcard() end)
    |> Enum.map(&from_file(&1, source))
    |> Enum.uniq_by(& &1.name)
    |> Enum.sort_by(& &1.name)
  end

  @spec from_file(String.t(), source()) :: t()
  defp from_file(path, source) do
    name = path |> Path.basename(".py") |> String.replace_prefix("adw_", "")

    %__MODULE__{
      name: name,
      path: path,
      source: source,
      description: description(path, name),
      mtime: mtime(path)
    }
  end

  # First non-empty line of the leading docstring, else the humanized filename.
  @spec description(String.t(), String.t()) :: String.t()
  defp description(path, name) do
    with {:ok, raw} <- File.read(path),
         [_full, body] <- Regex.run(@docstring_regex, raw),
         line when is_binary(line) <- first_nonempty_line(body) do
      line
    else
      _no_docstring -> humanize(name)
    end
  end

  @spec first_nonempty_line(String.t()) :: String.t() | nil
  defp first_nonempty_line(body) do
    body
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.find(&(&1 != ""))
  end

  @spec humanize(String.t()) :: String.t()
  defp humanize(name), do: name |> String.replace("_", " ")

  @spec mtime(String.t()) :: integer()
  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} when is_integer(mtime) -> mtime
      _other -> 0
    end
  end
end
