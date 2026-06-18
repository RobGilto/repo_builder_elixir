defmodule RepoBuilder.Definitions.Agent do
  @moduledoc """
  A single agent (subagent template) definition surfaced to the prompt palette.

  App agents are reused verbatim from `RepoBuilder.Orchestrator.Templates.list/0`
  (the existing disk-loaded, versioned template context — we do NOT re-glob its
  roots). The operator's `working_dir` may additionally contribute portable
  `.claude/agents/*.md` files, which OVERLAY and shadow app agents of the same name.
  Pure and fail-silent: a missing working dir contributes nothing, never raises.
  """
  use TypedStruct

  alias RepoBuilder.Orchestrator.Template
  alias RepoBuilder.Orchestrator.Templates

  @type source :: :app | :working_dir

  typedstruct enforce: true do
    field :name, String.t()
    field :description, String.t() | nil
    field :source, source()
    field :version, pos_integer() | nil
    field :path, String.t() | nil
    field :mtime, integer()
  end

  @doc """
  All agent definitions for the merged root: app templates plus the `working_dir`'s
  `.claude/agents/*.md` overlay (working-dir entries shadow app entries by `name`).
  """
  @spec scan(working_dir :: String.t() | nil) :: [t()]
  def scan(working_dir) do
    app = Enum.map(Templates.list(), &from_summary/1)
    working = working_dir_agents(working_dir)

    app
    |> Map.new(&{&1.name, &1})
    |> Map.merge(Map.new(working, &{&1.name, &1}))
    |> Map.values()
    |> Enum.sort_by(& &1.name)
  end

  @spec from_summary(Templates.summary()) :: t()
  defp from_summary(summary) do
    %__MODULE__{
      name: summary.name,
      description: blank(summary.description),
      source: :app,
      version: summary.version,
      path: nil,
      mtime: DateTime.to_unix(summary.updated_at)
    }
  end

  @spec working_dir_agents(String.t() | nil) :: [t()]
  defp working_dir_agents(nil), do: []

  defp working_dir_agents(working_dir) when is_binary(working_dir) do
    working_dir
    |> Path.join(".claude/agents/*.md")
    |> Path.wildcard()
    |> Enum.map(&from_file/1)
  end

  @spec from_file(String.t()) :: t()
  defp from_file(path) do
    %__MODULE__{
      name: Path.basename(path, ".md"),
      description: read_description(path),
      source: :working_dir,
      version: nil,
      path: path,
      mtime: mtime(path)
    }
  end

  @spec read_description(String.t()) :: String.t() | nil
  defp read_description(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, attrs} <- Template.from_markdown(raw) do
      blank(attrs["description"])
    else
      _error -> nil
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
