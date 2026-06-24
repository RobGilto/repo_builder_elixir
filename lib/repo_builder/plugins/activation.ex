defmodule RepoBuilder.Plugins.Activation do
  @moduledoc """
  The behaviour-changes-per-project engine (the agentic plugin system foundation).

  Given a project, computes the EFFECTIVE contribution set — the merged,
  priority-ordered contributions of its enabled plugins, each resolved to an absolute
  path under `agentic_plugins/`. Switching the orchestrator's bound project asks for a
  different effective set, so behaviour changes live per repo.

  This GenServer is a memoizing cache only: the DB read in `compute/1` always runs in
  the CALLING process (so it is correct under the test SQL sandbox), and the cache
  merely stores the result. Caching is gated by config (`cache_enabled?`, off in test)
  so tests always see a fresh, isolated computation. `invalidate/1` is broadcast from
  the `Plugins` context on every activate/deactivate.
  """
  use GenServer
  use TypedStruct

  alias RepoBuilder.Plugins
  alias RepoBuilder.Plugins.{Contribution, Manifest, ProjectPlugin}

  typedstruct module: Resolved, enforce: true do
    @typedoc "One contribution resolved against an installed plugin on disk."
    field :plugin_id, String.t()
    field :version, String.t()
    field :install_path, String.t()
    field :kind, Contribution.kind()
    field :abs_path, String.t(), enforce: false
    field :meta, map()
  end

  @type effective :: %{Contribution.kind() => [Resolved.t()]}

  @typedoc "Cache key: `:platform` for the nil project, else the project id."
  @type cache_key :: :platform | String.t()

  @typedoc "Internal cast messages handled by the cache GenServer."
  @type cache_message ::
          {:put, cache_key(), effective()} | {:invalidate, cache_key()} | :invalidate_all

  # --- client ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, name: opts[:name] || __MODULE__)

  @doc "The effective contribution set for `project_id` (`nil` = the platform)."
  @spec effective(Ecto.UUID.t() | nil) :: effective()
  def effective(project_id) do
    if cache_enabled?() do
      case get_cached(project_id) do
        {:ok, eff} ->
          eff

        :miss ->
          eff = compute(project_id)
          put_cached(project_id, eff)
          eff
      end
    else
      compute(project_id)
    end
  end

  @doc "The resolved contributions of `kind` for `project_id`, in priority order."
  @spec contributions(Ecto.UUID.t() | nil, Contribution.kind()) :: [Resolved.t()]
  def contributions(project_id, kind), do: Map.get(effective(project_id), kind, [])

  @doc """
  The concatenated markdown of the active `:context_fragment` contributions for a
  project — appended to the orchestrator system prompt so an active plugin can prime
  the brain about how to work in this repo. `""` when none.
  """
  @spec context_fragments(Ecto.UUID.t() | nil) :: String.t()
  def context_fragments(project_id) do
    project_id
    |> contributions(:context_fragment)
    |> Enum.flat_map(&read_fragment(&1.abs_path))
    |> Enum.join("\n\n")
  rescue
    # Prompt enrichment is best-effort: a DB/plugin error must never break prompt
    # assembly (which may run in a process without DB access).
    _error -> ""
  end

  @spec read_fragment(String.t() | nil) :: [String.t()]
  defp read_fragment(nil), do: []

  defp read_fragment(path) do
    case File.read(path) do
      {:ok, content} -> [String.trim_trailing(content)]
      _ -> []
    end
  end

  @doc "Drop the cached effective set for `project_id`."
  @spec invalidate(Ecto.UUID.t() | nil) :: :ok
  def invalidate(project_id) do
    cast_if_running({:invalidate, key(project_id)})
  end

  @doc "Drop the entire cache."
  @spec invalidate_all() :: :ok
  def invalidate_all, do: cast_if_running(:invalidate_all)

  # --- server ---

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:get, cache_key}, _from, cache) do
    {:reply, Map.fetch(cache, cache_key), cache}
  end

  @impl true
  def handle_cast({:put, cache_key, eff}, cache), do: {:noreply, Map.put(cache, cache_key, eff)}
  def handle_cast({:invalidate, cache_key}, cache), do: {:noreply, Map.delete(cache, cache_key)}
  def handle_cast(:invalidate_all, _cache), do: {:noreply, %{}}

  # --- internals ---

  @spec get_cached(Ecto.UUID.t() | nil) :: {:ok, effective()} | :miss
  defp get_cached(project_id) do
    case GenServer.whereis(__MODULE__) do
      nil ->
        :miss

      _pid ->
        case GenServer.call(__MODULE__, {:get, key(project_id)}) do
          {:ok, eff} -> {:ok, eff}
          :error -> :miss
        end
    end
  end

  @spec put_cached(Ecto.UUID.t() | nil, effective()) :: :ok
  defp put_cached(project_id, eff), do: cast_if_running({:put, key(project_id), eff})

  @spec cast_if_running(cache_message()) :: :ok
  defp cast_if_running(message) do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.cast(__MODULE__, message)
    end
  end

  @spec key(Ecto.UUID.t() | nil) :: :platform | String.t()
  defp key(nil), do: :platform
  defp key(id), do: id

  @spec compute(Ecto.UUID.t() | nil) :: effective()
  defp compute(project_id) do
    empty = Map.new(Contribution.kinds(), &{&1, []})

    project_id
    |> Plugins.list_active()
    |> Enum.flat_map(&resolved_for/1)
    |> Enum.group_by(& &1.kind)
    |> then(&Map.merge(empty, &1))
  end

  @spec resolved_for(ProjectPlugin.t()) :: [Resolved.t()]
  defp resolved_for(%ProjectPlugin{plugin_id: plugin_id, version: version}) do
    plugin =
      if is_binary(version),
        do: Plugins.get_version(plugin_id, version),
        else: Plugins.get(plugin_id)

    case plugin do
      %{install_path: install_path, manifest: manifest, version: resolved_version} ->
        resolve_contributions(plugin_id, resolved_version, install_path, manifest)

      _ ->
        []
    end
  end

  @spec resolve_contributions(String.t(), String.t(), String.t(), map()) :: [Resolved.t()]
  defp resolve_contributions(plugin_id, version, install_path, manifest) do
    case Manifest.from_map(manifest) do
      {:ok, %Manifest{contributions: contributions}} ->
        Enum.map(contributions, fn contribution ->
          %Resolved{
            plugin_id: plugin_id,
            version: version,
            install_path: install_path,
            kind: contribution.kind,
            abs_path: abs_path(install_path, contribution.path),
            meta: contribution.meta
          }
        end)

      _ ->
        []
    end
  end

  @spec abs_path(String.t(), String.t() | nil) :: String.t() | nil
  defp abs_path(_install_path, nil), do: nil
  defp abs_path(install_path, path), do: Path.join(install_path, path)

  @spec cache_enabled?() :: boolean()
  defp cache_enabled? do
    Application.get_env(:repo_builder, :plugins, [])
    |> Keyword.get(:cache_enabled?, true)
  end
end
