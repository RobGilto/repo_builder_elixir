defmodule RepoBuilder.Plugins do
  @moduledoc """
  Context for the agentic plugin system (the agentic plugin system foundation) — the
  ONLY `Repo` caller for `plugins` and `project_plugins`. Every public function is
  `@spec`'d and returns tagged tuples / typed values (BUILD_PROMPT.md §8).

  Two concerns:

    * **Install** (global, on disk + a `plugins` row) — a package is present and
      loadable. See `RepoBuilder.Plugins.Installer`.
    * **Activate** (per project, a `project_plugins` row) — a plugin's contributions
      apply to a project. A `nil` `project_id` means "the platform itself".

  Activating/deactivating invalidates the per-project effective-contribution cache
  and broadcasts `{:plugins_changed, project_id}` so live views refresh.
  """
  import Ecto.Query, only: [from: 2]

  alias RepoBuilder.Plugins.{Activation, Plugin, ProjectPlugin}
  alias RepoBuilder.Repo

  @topic "plugins:changed"

  # --- installed plugins ---

  @spec list_installed() :: [Plugin.t()]
  def list_installed do
    Repo.all(from(p in Plugin, order_by: [asc: p.plugin_id, desc: p.version]))
  end

  @doc "The newest installed row for `plugin_id`, or `nil`."
  @spec get(String.t()) :: Plugin.t() | nil
  def get(plugin_id) when is_binary(plugin_id) do
    Repo.one(
      from(p in Plugin,
        where: p.plugin_id == ^plugin_id,
        order_by: [desc: p.version],
        limit: 1
      )
    )
  end

  @spec get_version(String.t(), String.t()) :: Plugin.t() | nil
  def get_version(plugin_id, version) when is_binary(plugin_id) and is_binary(version) do
    Repo.get_by(Plugin, plugin_id: plugin_id, version: version)
  end

  @spec fetch(String.t()) :: {:ok, Plugin.t()} | {:error, :not_found}
  def fetch(plugin_id) do
    case get(plugin_id) do
      nil -> {:error, :not_found}
      plugin -> {:ok, plugin}
    end
  end

  @spec installed?(String.t()) :: boolean()
  def installed?(plugin_id), do: get(plugin_id) != nil

  @doc "Insert (or update an existing `{plugin_id, version}`) install record — idempotent re-install."
  @spec install_record(map()) :: {:ok, Plugin.t()} | {:error, Ecto.Changeset.t()}
  def install_record(params) do
    plugin_id = params[:plugin_id] || params["plugin_id"]
    version = params[:version] || params["version"]

    base =
      case plugin_id && version && get_version(plugin_id, version) do
        %Plugin{} = existing -> existing
        _ -> %Plugin{}
      end

    base
    |> Plugin.changeset(params)
    |> Repo.insert_or_update()
  end

  @spec set_status(Plugin.t(), Plugin.status()) ::
          {:ok, Plugin.t()} | {:error, Ecto.Changeset.t()}
  def set_status(%Plugin{} = plugin, status) do
    plugin
    |> Plugin.changeset(%{status: status})
    |> Repo.update()
  end

  @spec delete_record(Plugin.t()) :: {:ok, Plugin.t()} | {:error, Ecto.Changeset.t()}
  def delete_record(%Plugin{} = plugin), do: Repo.delete(plugin)

  # --- per-project activation ---

  @doc """
  Activate `plugin_id` for `project_id` (`nil` = the platform). Idempotent: an existing
  activation is re-enabled rather than duplicated. Invalidates the cache + broadcasts.
  """
  @spec activate(Ecto.UUID.t() | nil, String.t(), keyword()) ::
          {:ok, ProjectPlugin.t()} | {:error, Ecto.Changeset.t()}
  def activate(project_id, plugin_id, opts \\ []) when is_binary(plugin_id) do
    attrs = %{
      project_id: project_id,
      plugin_id: plugin_id,
      version: opts[:version],
      enabled: true,
      priority: opts[:priority] || 0,
      config: opts[:config] || %{}
    }

    result =
      case get_activation(project_id, plugin_id) do
        nil -> %ProjectPlugin{}
        existing -> existing
      end
      |> ProjectPlugin.changeset(attrs)
      |> Repo.insert_or_update()

    on_change(result, project_id)
  end

  @doc "Deactivate (delete) `plugin_id` for `project_id`. Invalidates the cache + broadcasts."
  @spec deactivate(Ecto.UUID.t() | nil, String.t()) :: :ok
  def deactivate(project_id, plugin_id) when is_binary(plugin_id) do
    case get_activation(project_id, plugin_id) do
      nil -> :ok
      activation -> Repo.delete(activation)
    end

    _ = Activation.invalidate(project_id)
    broadcast(project_id)
    :ok
  end

  @doc "Whether `plugin_id` is enabled for `project_id`."
  @spec active?(Ecto.UUID.t() | nil, String.t()) :: boolean()
  def active?(project_id, plugin_id) do
    case get_activation(project_id, plugin_id) do
      %ProjectPlugin{enabled: true} -> true
      _ -> false
    end
  end

  @doc "All enabled activations for `project_id` (`nil` = platform), ordered by `priority`."
  @spec list_active(Ecto.UUID.t() | nil) :: [ProjectPlugin.t()]
  def list_active(nil) do
    Repo.all(
      from(pp in ProjectPlugin,
        where: is_nil(pp.project_id) and pp.enabled == true,
        order_by: [asc: pp.priority, asc: pp.plugin_id]
      )
    )
  end

  def list_active(project_id) when is_binary(project_id) do
    Repo.all(
      from(pp in ProjectPlugin,
        where: pp.project_id == ^project_id and pp.enabled == true,
        order_by: [asc: pp.priority, asc: pp.plugin_id]
      )
    )
  end

  @doc "Per-project plugin config (the activation `config` map), or `%{}`."
  @spec config(Ecto.UUID.t() | nil, String.t()) :: map()
  def config(project_id, plugin_id) do
    case get_activation(project_id, plugin_id) do
      %ProjectPlugin{config: config} when is_map(config) -> config
      _ -> %{}
    end
  end

  @spec set_config(Ecto.UUID.t() | nil, String.t(), map()) ::
          {:ok, ProjectPlugin.t()} | {:error, :not_active}
  def set_config(project_id, plugin_id, config) when is_map(config) do
    case get_activation(project_id, plugin_id) do
      nil ->
        {:error, :not_active}

      activation ->
        result =
          activation
          |> ProjectPlugin.changeset(%{config: config})
          |> Repo.update()

        on_change(result, project_id)
    end
  end

  @doc "Subscribe the caller to `{:plugins_changed, project_id}` broadcasts."
  @spec subscribe() :: :ok
  def subscribe do
    _ = Phoenix.PubSub.subscribe(RepoBuilder.PubSub, @topic)
    :ok
  end

  # --- internals ---

  @spec get_activation(Ecto.UUID.t() | nil, String.t()) :: ProjectPlugin.t() | nil
  defp get_activation(nil, plugin_id) do
    Repo.one(
      from(pp in ProjectPlugin, where: is_nil(pp.project_id) and pp.plugin_id == ^plugin_id)
    )
  end

  defp get_activation(project_id, plugin_id) when is_binary(project_id) do
    Repo.get_by(ProjectPlugin, project_id: project_id, plugin_id: plugin_id)
  end

  @spec on_change(
          {:ok, ProjectPlugin.t()} | {:error, Ecto.Changeset.t()},
          Ecto.UUID.t() | nil
        ) :: {:ok, ProjectPlugin.t()} | {:error, Ecto.Changeset.t()}
  defp on_change({:ok, _} = result, project_id) do
    _ = Activation.invalidate(project_id)
    broadcast(project_id)
    result
  end

  defp on_change(error, _project_id), do: error

  @spec broadcast(Ecto.UUID.t() | nil) :: :ok
  defp broadcast(project_id) do
    _ = Phoenix.PubSub.broadcast(RepoBuilder.PubSub, @topic, {:plugins_changed, project_id})
    :ok
  end
end
