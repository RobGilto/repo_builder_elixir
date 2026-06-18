defmodule RepoBuilder.FileBrowser do
  @moduledoc """
  Read-only filesystem directory browsing for the console's working-directory picker
  (the operator chooses the cwd the orchestrator and its workers run in). Lists only
  sub-DIRECTORIES of a given absolute path so the picker can navigate the tree without
  exposing file contents. `project_root/0` is the default starting point (the dir the
  app was launched from).
  """

  @typedoc "A single directory's navigable view: its absolute path, its parent (nil at the filesystem root), and its sorted child directory names."
  @type listing :: %{path: String.t(), parent: String.t() | nil, dirs: [String.t()]}

  @type reason :: File.posix() | :not_a_directory

  @doc "The project root — the directory the application was started from. Picker default."
  @spec project_root() :: String.t()
  def project_root, do: File.cwd!()

  @doc """
  List the immediate child directories of `path` (expanded to an absolute path).
  Returns the canonical path, its parent (nil at the filesystem root), and the sorted
  child directory names. `{:error, reason}` if `path` is not an existing directory or
  is unreadable.
  """
  @spec list(String.t()) :: {:ok, listing()} | {:error, reason()}
  def list(path) when is_binary(path) do
    expanded = Path.expand(path)

    if File.dir?(expanded) do
      case File.ls(expanded) do
        {:ok, entries} ->
          dirs =
            entries
            |> Enum.filter(&File.dir?(Path.join(expanded, &1)))
            |> Enum.sort()

          {:ok, %{path: expanded, parent: parent_of(expanded), dirs: dirs}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :not_a_directory}
    end
  end

  # The parent directory, or nil once we reach the filesystem root (where dirname is
  # idempotent, e.g. Path.dirname("/") == "/").
  @spec parent_of(String.t()) :: String.t() | nil
  defp parent_of(path) do
    parent = Path.dirname(path)
    if parent == path, do: nil, else: parent
  end
end
