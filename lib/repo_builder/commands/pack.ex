defmodule RepoBuilder.Commands.Pack do
  @moduledoc """
  A versioned command pack — a directory of command `.md` bodies the resolver draws
  from when the target repo ships no override of its own (the "hold different versions
  of command md files" requirement).

  Layout: `<root>/<pack>/<version>/commands/**/*.md`. Built-in packs ship under
  `priv/command_packs`; operator packs live in a configurable dir
  (`config :repo_builder, :command_packs, operator_dir: …`). Both are versioned by
  directory name; `"latest"` resolves to the newest version (semver-aware, falling
  back to string order) and `"auto"` resolves the pack id from a detected stack.

  Pure and fail-silent: a missing directory yields `[]`, never raises.
  """
  use TypedStruct

  typedstruct enforce: true do
    field :id, String.t()
    field :version, String.t()
    field :root, String.t()
  end

  # Detected-stack language → pack id (the `"auto"` mapping). Anything else ⇒ "generic".
  @stack_packs %{
    "elixir" => "elixir",
    "python" => "python-uv",
    "node" => "node",
    "rust" => "rust",
    "go" => "go"
  }

  @doc "The base directories searched for packs: the built-in priv dir then the operator dir."
  @spec roots() :: [String.t()]
  def roots do
    builtin = Application.app_dir(:repo_builder, "priv/command_packs")
    operator = Application.get_env(:repo_builder, :command_packs, [])[:operator_dir]

    [builtin, operator]
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&File.dir?/1)
  end

  @doc "Every discovered `<pack>/<version>` across all roots (later roots override earlier ids/versions)."
  @spec list() :: [t()]
  def list do
    for root <- roots(),
        pack_dir <- safe_ls(root),
        File.dir?(Path.join(root, pack_dir)),
        version <- safe_ls(Path.join(root, pack_dir)),
        full = Path.join([root, pack_dir, version]),
        File.dir?(full) do
      %__MODULE__{id: pack_dir, version: version, root: full}
    end
  end

  @doc "All versions of a pack id, newest first."
  @spec versions(String.t()) :: [String.t()]
  def versions(id) when is_binary(id) do
    list()
    |> Enum.filter(&(&1.id == id))
    |> Enum.map(& &1.version)
    |> Enum.uniq()
    |> Enum.sort(&newer_or_equal?/2)
  end

  @doc "The pack id `\"auto\"` resolves to for a detected stack descriptor."
  @spec stack_pack_id(map()) :: String.t()
  def stack_pack_id(stack) when is_map(stack) do
    language = to_string(stack["language"] || stack[:language] || "unknown")
    Map.get(@stack_packs, language, "generic")
  end

  @doc """
  Resolve a concrete pack for `id` at `version`. `version` may be `"latest"` (newest
  available) or an explicit version string. `{:error, :not_found}` when the pack id has
  no versions or the requested version is absent.
  """
  @spec resolve(String.t(), String.t()) :: {:ok, t()} | {:error, :not_found}
  def resolve(id, version) when is_binary(id) and is_binary(version) do
    case versions(id) do
      [] ->
        {:error, :not_found}

      [newest | _] = all ->
        wanted = if version in ["latest", "", "auto"], do: newest, else: version

        if wanted in all,
          do: {:ok, %__MODULE__{id: id, version: wanted, root: pack_root(id, wanted)}},
          else: {:error, :not_found}
    end
  end

  @doc """
  Absolute path to a command body within a pack, or `nil` when absent. A `:`-namespaced
  command name maps to nested directories (`experts:ws:q` → `experts/ws/q.md`).
  """
  @spec command_path(t(), String.t()) :: String.t() | nil
  def command_path(%__MODULE__{root: root}, name) when is_binary(name) do
    relative = String.replace(name, ":", "/") <> ".md"
    path = Path.join([root, "commands", relative])
    if File.regular?(path), do: path, else: nil
  end

  # --- internals ---

  @spec pack_root(String.t(), String.t()) :: String.t()
  defp pack_root(id, version) do
    Enum.find_value(roots(), fn root ->
      full = Path.join([root, id, version])
      if File.dir?(full), do: full
    end)
  end

  @spec safe_ls(String.t()) :: [String.t()]
  defp safe_ls(dir) do
    case File.ls(dir) do
      {:ok, entries} -> entries
      _ -> []
    end
  end

  # Newest-first ordering: semver when both parse, else descending string order.
  @spec newer_or_equal?(String.t(), String.t()) :: boolean()
  defp newer_or_equal?(a, b) do
    case {parse_version(a), parse_version(b)} do
      {{:ok, va}, {:ok, vb}} -> Version.compare(va, vb) != :lt
      _ -> a >= b
    end
  end

  @spec parse_version(String.t()) :: {:ok, Version.t()} | :error
  defp parse_version(version) do
    version |> String.trim_leading("v") |> Version.parse()
  end
end
