defmodule RepoBuilder.Commands.Resolver do
  @moduledoc """
  Stack-aware command resolution (agentic-layer adaptor, Phase 3). Walks a precedence
  chain for a command name and returns the first hit, with capability tokens filled
  from the project's capability map and the provenance attached:

      1. repo-local  — `<project.root>/.claude/commands/<name>.md`  (the repo wins)
      2. pinned pack — `project.command_pack`/`command_pack_version` (when not "auto")
      3. stack pack  — the pack matching the project's detected stack
      4. generic     — the base, token-templated pack

  The repo wins because this is an *adaptor*: a repo that ships its own commands knows
  itself best (mirrors `Definitions.SlashCommand.scan/2`'s working-dir-wins). Repo-local
  bodies are returned verbatim; pack bodies get `{{TEST_COMMAND}}` … filled from
  `project.capabilities`. Pure and fail-silent — never raises.
  """
  alias RepoBuilder.Commands.{Pack, Resolved}
  alias RepoBuilder.Orchestrator.Template
  alias RepoBuilder.Plugins.Activation
  alias RepoBuilder.Projects.Capabilities
  alias RepoBuilder.Projects.CapabilityTokens
  alias RepoBuilder.Projects.Project

  @doc """
  Resolve `name` for `project`, returning `{:ok, %Resolved{}}` or `{:error, :not_found}`
  when no layer supplies the command.
  """
  @spec resolve(Project.t(), String.t()) :: {:ok, Resolved.t()} | {:error, :not_found}
  def resolve(%Project{} = project, name) when is_binary(name) do
    Enum.find_value(layers(project, name), {:error, :not_found}, fn
      nil -> false
      resolved -> {:ok, resolved}
    end)
  end

  @doc """
  Resolve every command available to `project` across all layers (repo-local ∪ pinned
  ∪ stack ∪ generic), de-duplicated by name with higher-precedence layers winning.
  Used by the project dashboard's command-pack panel and the system-prompt palette.
  """
  @spec resolve_all(Project.t()) :: [Resolved.t()]
  def resolve_all(%Project{} = project) do
    project
    |> available_names()
    |> Enum.sort()
    |> Enum.flat_map(fn name ->
      case resolve(project, name) do
        {:ok, resolved} -> [resolved]
        _ -> []
      end
    end)
  end

  # The ordered candidate resolutions (nil = layer absent). `Enum.find_value` takes the
  # first non-nil — i.e. highest precedence.
  @spec layers(Project.t(), String.t()) :: [Resolved.t() | nil]
  defp layers(%Project{} = project, name) do
    [
      repo_local(project, name),
      plugin_layer(project, name),
      pinned_pack(project, name),
      stack_pack(project, name),
      generic_pack(project, name)
    ]
  end

  # Active-plugin command packs (the agentic plugin system foundation). Each active
  # plugin's `command_pack` contribution resolves to its `commands/` dir; the
  # first (highest-priority) plugin that supplies `name` wins. Capability tokens are
  # filled like any pack, but the repo-local layer still wins over plugins.
  @spec plugin_layer(Project.t(), String.t()) :: Resolved.t() | nil
  defp plugin_layer(%Project{id: project_id} = project, name) do
    project_id
    |> plugin_command_contributions()
    |> Enum.find_value(fn %Activation.Resolved{plugin_id: plugin_id, abs_path: commands_dir} ->
      path = command_file(commands_dir, name)

      case path && read_body(path) do
        {:ok, body} ->
          %Resolved{
            name: name,
            body: fill_tokens(body, project),
            layer: :plugin,
            pack: plugin_id,
            version: nil,
            provenance: "plugin #{plugin_id} commands/#{name}.md"
          }

        _ ->
          nil
      end
    end)
  end

  @spec command_file(String.t() | nil, String.t()) :: String.t() | nil
  defp command_file(nil, _name), do: nil

  defp command_file(commands_dir, name) do
    path = Path.join(commands_dir, String.replace(name, ":", "/") <> ".md")
    if File.regular?(path), do: path, else: nil
  end

  @spec repo_local(Project.t(), String.t()) :: Resolved.t() | nil
  defp repo_local(%Project{root_path: root}, name) when is_binary(root) do
    path = Path.join([root, ".claude", "commands", String.replace(name, ":", "/") <> ".md"])

    case read_body(path) do
      {:ok, body} ->
        # The repo knows itself — returned verbatim, no capability-token fill.
        %Resolved{
          name: name,
          body: body,
          layer: :repo_local,
          pack: nil,
          version: nil,
          provenance: "repo-local .claude/commands/#{name}.md"
        }

      _ ->
        nil
    end
  end

  defp repo_local(_project, _name), do: nil

  @spec pinned_pack(Project.t(), String.t()) :: Resolved.t() | nil
  defp pinned_pack(%Project{command_pack: pack} = project, name)
       when is_binary(pack) and pack not in ["", "auto"] do
    from_pack(project, pack, project.command_pack_version, name, :pinned_pack)
  end

  defp pinned_pack(_project, _name), do: nil

  @spec stack_pack(Project.t(), String.t()) :: Resolved.t() | nil
  defp stack_pack(%Project{stack: stack} = project, name) do
    case Pack.stack_pack_id(stack) do
      "generic" -> nil
      pack_id -> from_pack(project, pack_id, "latest", name, :stack_pack)
    end
  end

  @spec generic_pack(Project.t(), String.t()) :: Resolved.t() | nil
  defp generic_pack(%Project{} = project, name) do
    from_pack(project, "generic", "latest", name, :generic)
  end

  # Resolve a command body from a concrete pack id/version, filling capability tokens.
  @spec from_pack(Project.t(), String.t(), String.t(), String.t(), Resolved.layer()) ::
          Resolved.t() | nil
  defp from_pack(%Project{} = project, pack_id, version, name, layer) do
    with {:ok, pack} <- Pack.resolve(pack_id, version),
         path when is_binary(path) <- Pack.command_path(pack, name),
         {:ok, body} <- read_body(path) do
      %Resolved{
        name: name,
        body: fill_tokens(body, project),
        layer: layer,
        pack: pack.id,
        version: pack.version,
        provenance: "#{layer} pack #{pack.id}@#{pack.version}"
      }
    else
      _ -> nil
    end
  end

  # Read a command file's BODY (frontmatter stripped) via the shared template parser.
  @spec read_body(String.t()) :: {:ok, String.t()} | {:error, term()}
  defp read_body(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, attrs} <- Template.from_markdown(raw),
         body when is_binary(body) <- attrs["body"] do
      {:ok, body}
    else
      _ -> {:error, :unreadable}
    end
  end

  # Fill capability tokens via the shared `CapabilityTokens` machinery (extracted so the
  # command resolver and the quality-gate resolver share one token registry + fill).
  @spec fill_tokens(String.t(), Project.t()) :: String.t()
  defp fill_tokens(body, %Project{capabilities: capabilities}) do
    CapabilityTokens.fill(body, Capabilities.from_map(capabilities))
  end

  # All command names reachable for a project across every layer.
  @spec available_names(Project.t()) :: [String.t()]
  defp available_names(%Project{} = project) do
    repo = repo_local_names(project.root_path)
    plugins = plugin_command_names(project)

    pack_ids =
      Enum.uniq([project.command_pack, Pack.stack_pack_id(project.stack), "generic"])

    (repo ++ plugins ++ Enum.flat_map(pack_ids, &pack_command_names/1)) |> Enum.uniq()
  end

  # All command names contributed by the project's active plugins.
  @spec plugin_command_names(Project.t()) :: [String.t()]
  defp plugin_command_names(%Project{id: project_id}) do
    project_id
    |> plugin_command_contributions()
    |> Enum.flat_map(fn %Activation.Resolved{abs_path: commands_dir} ->
      command_names_in(commands_dir)
    end)
  end

  # Best-effort: command resolution must fall through to packs if the plugin subsystem
  # (DB) is unavailable — e.g. a resolver call from a process without DB access. Never
  # crashes resolution.
  @spec plugin_command_contributions(Ecto.UUID.t() | nil) :: [Activation.Resolved.t()]
  defp plugin_command_contributions(project_id) do
    Activation.contributions(project_id, :command_pack)
  rescue
    _error -> []
  end

  @spec command_names_in(String.t() | nil) :: [String.t()]
  defp command_names_in(nil), do: []

  defp command_names_in(commands_dir) do
    commands_dir
    |> Path.join("**/*.md")
    |> Path.wildcard()
    |> Enum.map(fn path ->
      path
      |> Path.relative_to(commands_dir)
      |> Path.rootname()
      |> Path.split()
      |> Enum.join(":")
    end)
  end

  @spec repo_local_names(String.t() | nil) :: [String.t()]
  defp repo_local_names(root) when is_binary(root) do
    root
    |> Path.join(".claude/commands/**/*.md")
    |> Path.wildcard()
    |> Enum.map(fn path ->
      path
      |> Path.relative_to(Path.join([root, ".claude", "commands"]))
      |> Path.rootname()
      |> Path.split()
      |> Enum.join(":")
    end)
  end

  defp repo_local_names(_root), do: []

  @spec pack_command_names(String.t() | nil) :: [String.t()]
  defp pack_command_names(pack_id) when is_binary(pack_id) and pack_id not in ["", "auto"] do
    case Pack.resolve(pack_id, "latest") do
      {:ok, pack} ->
        pack.root
        |> Path.join("commands/**/*.md")
        |> Path.wildcard()
        |> Enum.map(fn path ->
          path
          |> Path.relative_to(Path.join(pack.root, "commands"))
          |> Path.rootname()
          |> Path.split()
          |> Enum.join(":")
        end)

      _ ->
        []
    end
  end

  defp pack_command_names(_pack_id), do: []
end
