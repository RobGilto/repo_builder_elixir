defmodule RepoBuilder.Orchestrator.Templates do
  @moduledoc """
  The subagent-template CONTEXT — the ONLY module that touches the templates
  filesystem (the "no scattered I/O" analog to "no `Repo` outside contexts", §8).
  Every public function is `@spec`'d, returns tagged tuples, and never raises on the
  expected paths; all filesystem errors map to `{:error, reason}`.

  ## Storage & versioning
  Templates are markdown-with-frontmatter files laid out as `<root>/<name>/<NNNN>.md`
  where `NNNN` is a zero-padded, monotonically increasing version (highest = current).
  Two roots are merged: a writable `agents_dir` (app env) and a read-only built-in
  `priv/orchestrator/agents`; the writable root SHADOWS the built-in by version.

  Saving is APPEND-ONLY via an atomic exclusive create (`O_EXCL`): the next version
  is `max(version across both roots) + 1`, always written to the writable root, so
  editing a built-in produces a new writable version and history stays linear. A
  concurrent writer that grabbed the same `N` triggers an `:eexist` retry (≤5), and
  `restore/2` promotes an old version to a fresh current one — never destructive.
  """
  require Logger

  alias RepoBuilder.Orchestrator.Template

  @type reason :: atom() | String.t()
  @type summary :: %{
          name: String.t(),
          description: String.t(),
          version: pos_integer(),
          author: Template.author(),
          updated_at: DateTime.t(),
          deletable: boolean()
        }
  @type version_meta :: %{
          version: pos_integer(),
          author: Template.author(),
          updated_at: DateTime.t()
        }

  @max_save_attempts 5
  @version_file_regex ~r/\A(\d+)\.md\z/

  @doc "One summary per template (current version), sorted by name."
  @spec list() :: [summary()]
  def list do
    template_names()
    |> Enum.map(&summary/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc "Fetch the CURRENT (highest) version of a template by name."
  @spec fetch(String.t()) :: {:ok, Template.t()} | {:error, reason()}
  def fetch(name) when is_binary(name) do
    entries = version_entries(name)

    case Map.keys(entries) do
      [] -> {:error, :not_found}
      keys -> read_version(name, Enum.max(keys), entries)
    end
  end

  @doc "Fetch a specific version of a template."
  @spec fetch_version(String.t(), pos_integer()) :: {:ok, Template.t()} | {:error, reason()}
  def fetch_version(name, version) when is_binary(name) and is_integer(version) do
    entries = version_entries(name)

    case Map.has_key?(entries, version) do
      true -> read_version(name, version, entries)
      false -> {:error, :not_found}
    end
  end

  @doc "Version metadata for a template, newest first."
  @spec versions(String.t()) :: [version_meta()]
  def versions(name) when is_binary(name) do
    name
    |> version_entries()
    |> Enum.sort_by(fn {version, _path} -> version end, :desc)
    |> Enum.map(fn {version, path} -> version_meta(name, version, path) end)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Append a new version from `attrs` (`name`, `description`, `body`, optional
  `model`/`category`/`harness`/`author`). Accepts atom OR string keys. Validates,
  computes the next version across both roots, and writes it atomically to the
  writable root; never overwrites an existing version.
  """
  @spec save(map()) :: {:ok, Template.t()} | {:error, reason()}
  def save(attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    with :ok <- Template.validate(attrs) do
      base = %Template{
        name: attrs["name"],
        description: attrs["description"],
        body: attrs["body"],
        model: blank(attrs["model"]),
        category: blank(attrs["category"]),
        harness: blank(attrs["harness"]),
        version: 1,
        author: author(attrs["author"]),
        updated_at: DateTime.utc_now()
      }

      write_next_version(base, @max_save_attempts)
    end
  end

  def save(_attrs), do: {:error, :invalid_attrs}

  @doc """
  Promote version `k` to a NEW current version (non-destructive restore). The new
  version copies `k`'s content; history stays linear.
  """
  @spec restore(String.t(), pos_integer()) :: {:ok, Template.t()} | {:error, reason()}
  def restore(name, version) when is_binary(name) and is_integer(version) do
    with {:ok, source} <- fetch_version(name, version) do
      save(%{
        "name" => source.name,
        "description" => source.description,
        "body" => source.body,
        "model" => source.model,
        "category" => source.category,
        "harness" => source.harness,
        "author" => source.author
      })
    end
  end

  @doc """
  Delete a template's writable history. Built-ins (no writable dir) are read-only and
  return `{:error, :builtin}`; an unknown name returns `{:error, :not_found}`.
  """
  @spec delete(String.t()) :: :ok | {:error, reason()}
  def delete(name) when is_binary(name) do
    writable = Path.join(writable_root(), name)

    cond do
      File.dir?(writable) ->
        case File.rm_rf(writable) do
          {:ok, _paths} -> :ok
          {:error, posix, _file} -> {:error, posix}
        end

      File.dir?(Path.join(builtin_root(), name)) ->
        {:error, :builtin}

      true ->
        {:error, :not_found}
    end
  end

  # --- internals ---

  @spec write_next_version(Template.t(), non_neg_integer()) ::
          {:ok, Template.t()} | {:error, reason()}
  defp write_next_version(_base, 0), do: {:error, :version_conflict}

  defp write_next_version(base, attempts) do
    next = max_version(base.name) + 1
    template = %{base | version: next, updated_at: DateTime.utc_now()}
    path = version_path(writable_root(), base.name, next)

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      case File.open(path, [:write, :exclusive]) do
        {:ok, io} ->
          _ = IO.binwrite(io, Template.to_markdown(template))
          _ = File.close(io)
          {:ok, template}

        {:error, :eexist} ->
          write_next_version(base, attempts - 1)

        {:error, posix} ->
          {:error, posix}
      end
    end
  end

  @spec summary(String.t()) :: summary() | nil
  defp summary(name) do
    case fetch(name) do
      {:ok, template} ->
        %{
          name: template.name,
          description: template.description,
          version: template.version,
          author: template.author,
          updated_at: template.updated_at,
          deletable: writable?(name)
        }

      {:error, reason} ->
        Logger.warning("skipping unreadable template #{name}: #{inspect(reason)}")
        nil
    end
  end

  @spec version_meta(String.t(), pos_integer(), String.t()) :: version_meta() | nil
  defp version_meta(name, version, path) do
    case read_template(name, version, path) do
      {:ok, template} ->
        %{version: version, author: template.author, updated_at: template.updated_at}

      {:error, _reason} ->
        nil
    end
  end

  @spec read_version(String.t(), pos_integer(), %{pos_integer() => String.t()}) ::
          {:ok, Template.t()} | {:error, reason()}
  defp read_version(name, version, entries) do
    read_template(name, version, Map.fetch!(entries, version))
  end

  @spec read_template(String.t(), pos_integer(), String.t()) ::
          {:ok, Template.t()} | {:error, reason()}
  defp read_template(name, version, path) do
    with {:ok, raw} <- read_utf8(path),
         {:ok, attrs} <- Template.from_markdown(raw),
         :ok <- Template.validate(attrs) do
      {:ok,
       %Template{
         name: name,
         description: attrs["description"],
         body: attrs["body"],
         model: blank(attrs["model"]),
         category: blank(attrs["category"]),
         harness: blank(attrs["harness"]),
         version: version,
         author: author(attrs["author"]),
         updated_at: parse_datetime(attrs["updated_at"])
       }}
    end
  end

  @spec read_utf8(String.t()) :: {:ok, String.t()} | {:error, reason()}
  defp read_utf8(path) do
    case File.read(path) do
      {:ok, content} ->
        if String.valid?(content), do: {:ok, content}, else: {:error, :not_utf8}

      {:error, posix} ->
        {:error, posix}
    end
  end

  # Versions of `name` across both roots, keyed by version number. Built-in entries
  # are loaded first so a writable file at the same version SHADOWS the built-in.
  @spec version_entries(String.t()) :: %{pos_integer() => String.t()}
  defp version_entries(name) do
    Enum.reduce([builtin_root(), writable_root()], %{}, fn root, acc ->
      collect_versions(Path.join(root, name), acc)
    end)
  end

  @spec collect_versions(String.t(), %{pos_integer() => String.t()}) ::
          %{pos_integer() => String.t()}
  defp collect_versions(dir, acc) do
    case File.ls(dir) do
      {:ok, files} -> Enum.reduce(files, acc, &put_version(dir, &1, &2))
      {:error, _posix} -> acc
    end
  end

  @spec put_version(String.t(), String.t(), %{pos_integer() => String.t()}) ::
          %{pos_integer() => String.t()}
  defp put_version(dir, file, acc) do
    case parse_version(file) do
      {:ok, version} -> Map.put(acc, version, Path.join(dir, file))
      :error -> acc
    end
  end

  @spec max_version(String.t()) :: non_neg_integer()
  defp max_version(name) do
    case Map.keys(version_entries(name)) do
      [] -> 0
      keys -> Enum.max(keys)
    end
  end

  @spec template_names() :: [String.t()]
  defp template_names do
    [builtin_root(), writable_root()]
    |> Enum.reduce(MapSet.new(), &collect_names/2)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  @spec collect_names(String.t(), MapSet.t(String.t())) :: MapSet.t(String.t())
  defp collect_names(root, acc) do
    case File.ls(root) do
      {:ok, entries} -> Enum.reduce(entries, acc, &put_dir_name(root, &1, &2))
      {:error, _posix} -> acc
    end
  end

  @spec put_dir_name(String.t(), String.t(), MapSet.t(String.t())) :: MapSet.t(String.t())
  defp put_dir_name(root, entry, acc) do
    if File.dir?(Path.join(root, entry)), do: MapSet.put(acc, entry), else: acc
  end

  @spec parse_version(String.t()) :: {:ok, pos_integer()} | :error
  defp parse_version(file) do
    case Regex.run(@version_file_regex, file) do
      [_match, digits] -> {:ok, String.to_integer(digits)}
      _no_match -> :error
    end
  end

  @spec version_path(String.t(), String.t(), pos_integer()) :: String.t()
  defp version_path(root, name, version) do
    padded = version |> Integer.to_string() |> String.pad_leading(4, "0")
    Path.join([root, name, "#{padded}.md"])
  end

  @spec writable?(String.t()) :: boolean()
  defp writable?(name), do: File.dir?(Path.join(writable_root(), name))

  @spec writable_root() :: String.t()
  defp writable_root do
    case Application.get_env(:repo_builder, :orchestrator, [])[:agents_dir] do
      dir when is_binary(dir) -> dir
      _nil -> Path.expand("~/.repo_builder/agents")
    end
  end

  # The read-only shipped-templates root. Defaults to `priv/orchestrator/agents`;
  # overridable via app env ONLY as a test seam (point it at an empty dir to exercise
  # the empty-state paths the shipped built-in would otherwise mask).
  @spec builtin_root() :: String.t()
  defp builtin_root do
    case Application.get_env(:repo_builder, :orchestrator, [])[:agents_builtin_dir] do
      dir when is_binary(dir) -> dir
      _nil -> Application.app_dir(:repo_builder, "priv/orchestrator/agents")
    end
  end

  @spec author(term()) :: Template.author()
  defp author(:orchestrator), do: :orchestrator
  defp author("orchestrator"), do: :orchestrator
  defp author(_other), do: :operator

  @spec parse_datetime(term()) :: DateTime.t()
  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> DateTime.utc_now()
    end
  end

  defp parse_datetime(_other), do: DateTime.utc_now()

  @spec blank(term()) :: String.t() | nil
  defp blank(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank(_other), do: nil

  @spec stringify_keys(map()) :: map()
  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
