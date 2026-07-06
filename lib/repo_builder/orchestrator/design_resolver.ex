defmodule RepoBuilder.Orchestrator.DesignResolver do
  @moduledoc """
  Resolve the ACTIVE design system for a project (design-system-plugins). Walks a
  precedence chain and returns the first descriptor found, tagged with its source:

      1. active plugin — a `:design_system` contribution (`Activation.contributions/2`)
      2. builtin       — `priv/design_systems/<surface>-<framework>.json` for the project's
                         detected UI surface + framework
      3. tui default   — when the surface is `tui` but no framework matched, the language's
                         default TUI framework (the reference's §1 stack router):
                         elixir→ratatouille, go→bubbletea, rust→ratatui, python→textual,
                         node→ink — because TUI has "no single default; pick by language"
      4. generic       — `priv/design_systems/generic.json`

  Pure and fail-silent — never raises. `{:error, :none}` only when no descriptor is found
  (e.g. the generic builtin is missing — should not happen in a normal install).
  """
  use TypedStruct

  alias RepoBuilder.Plugins.Activation
  alias RepoBuilder.Plugins.DesignSystem
  alias RepoBuilder.Projects.Project

  # {surface, framework} → builtin descriptor name. Anything unmatched falls through to the
  # TUI language default (for tui surfaces) and then generic.
  @stack_designs %{
    {"web", "phoenix"} => "web-phoenix",
    {"web", "react"} => "web-react",
    {"tui", "ratatouille"} => "tui-ratatouille",
    {"tui", "ink"} => "tui-ink",
    {"tui", "bubbletea"} => "tui-bubbletea",
    {"tui", "ratatui"} => "tui-ratatui",
    {"tui", "textual"} => "tui-textual"
  }

  # The reference's §1 router: language → default TUI framework descriptor. Encodes "there
  # is no single TUI default — pick by language" for the surface=tui / framework-unknown case.
  @tui_defaults %{
    "elixir" => "tui-ratatouille",
    "go" => "tui-bubbletea",
    "rust" => "tui-ratatui",
    "python" => "tui-textual",
    "node" => "tui-ink"
  }

  typedstruct enforce: true do
    @typedoc "The resolved design system for a project, tagged with its provenance."
    field :descriptor, DesignSystem.t()
    field :source, source()
    field :name, String.t()
  end

  @typedoc "Which precedence layer produced the resolved descriptor."
  @type source :: :plugin | :builtin | :tui_default | :generic

  @doc """
  Resolve the active design system for `project`. `{:error, :none}` when no descriptor
  resolves (e.g. the generic builtin is missing).
  """
  @spec resolve(Project.t()) :: {:ok, t()} | {:error, :none}
  def resolve(%Project{} = project) do
    case descriptor(project) do
      {:ok, source, name, %DesignSystem{} = ds} ->
        {:ok, %__MODULE__{descriptor: ds, source: source, name: name}}

      :error ->
        {:error, :none}
    end
  end

  # The first descriptor across the precedence chain, tagged with its source + name.
  @spec descriptor(Project.t()) :: {:ok, source(), String.t(), DesignSystem.t()} | :error
  defp descriptor(%Project{} = project) do
    Enum.find_value(
      [
        {:plugin, fn -> plugin_descriptor(project) end},
        {:builtin, fn -> named_builtin(project) end},
        {:tui_default, fn -> tui_default_builtin(project) end},
        {:generic, fn -> builtin_named("generic") end}
      ],
      :error,
      fn {source, load} ->
        case load.() do
          {:ok, name, ds} -> {:ok, source, name, ds}
          _ -> false
        end
      end
    )
  end

  # The highest-priority active `:design_system` plugin contribution that parses. Fail-silent:
  # a DB/plugin error (or a call from a process without DB access) falls through to builtin.
  @spec plugin_descriptor(Project.t()) :: {:ok, String.t(), DesignSystem.t()} | :error
  defp plugin_descriptor(%Project{id: project_id}) do
    project_id
    |> Activation.contributions(:design_system)
    |> Enum.find_value(:error, fn %Activation.Resolved{abs_path: path, plugin_id: id} ->
      case path && read_descriptor(path) do
        {:ok, ds} -> {:ok, id, ds}
        _ -> false
      end
    end)
  rescue
    _error -> :error
  end

  # A `:design_system` contribution path may be the descriptor `.json` file directly (as
  # the bundled sample plugins declare) OR the asset directory a forged plugin packages
  # (the Forge writes the `asset_subdir`). Handle both: read the file, or the first `.json`
  # inside a directory.
  @spec read_descriptor(String.t()) :: {:ok, DesignSystem.t()} | {:error, term()}
  defp read_descriptor(path) do
    if File.dir?(path) do
      case Path.wildcard(Path.join(path, "*.json")) do
        [file | _] -> DesignSystem.read(file)
        [] -> {:error, :no_descriptor}
      end
    else
      DesignSystem.read(path)
    end
  end

  # Builtin for the project's detected {surface, framework}, or :error when unmatched.
  @spec named_builtin(Project.t()) :: {:ok, String.t(), DesignSystem.t()} | :error
  defp named_builtin(%Project{} = project) do
    case Map.get(@stack_designs, {surface(project), framework(project)}) do
      nil -> :error
      name -> builtin_named(name)
    end
  end

  # For a tui surface with no framework match, the language's default TUI framework.
  @spec tui_default_builtin(Project.t()) :: {:ok, String.t(), DesignSystem.t()} | :error
  defp tui_default_builtin(%Project{} = project) do
    with "tui" <- surface(project),
         name when is_binary(name) <- Map.get(@tui_defaults, language(project)) do
      builtin_named(name)
    else
      _ -> :error
    end
  end

  @spec builtin_named(String.t()) :: {:ok, String.t(), DesignSystem.t()} | :error
  defp builtin_named(name) do
    case DesignSystem.read(builtin_path(name)) do
      {:ok, ds} -> {:ok, name, ds}
      _ -> :error
    end
  end

  @doc "Absolute path to a builtin design-system descriptor under `priv/design_systems/`."
  @spec builtin_path(String.t()) :: String.t()
  def builtin_path(name) when is_binary(name) do
    Application.app_dir(:repo_builder, "priv/design_systems/#{name}.json")
  end

  @spec surface(Project.t()) :: String.t()
  defp surface(%Project{} = project), do: stack_value(project, "surface", "none")

  @spec framework(Project.t()) :: String.t()
  defp framework(%Project{} = project), do: stack_value(project, "framework", "none")

  @spec language(Project.t()) :: String.t()
  defp language(%Project{} = project), do: stack_value(project, "language", "unknown")

  @spec stack_value(Project.t(), String.t(), String.t()) :: String.t()
  defp stack_value(%Project{stack: stack}, key, default) when is_map(stack) do
    case Map.get(stack, key) do
      value when is_binary(value) -> value
      _ -> default
    end
  end

  defp stack_value(_project, _key, default), do: default
end
