defmodule RepoBuilder.Plugins.Installer do
  @moduledoc """
  The install/uninstall lifecycle (the agentic plugin system foundation):

      fetch (Source) → validate assets → compat → trust (checksum/code) →
      unpack into agentic_plugins/<id>@<version>/ → record a durable plugins row

  Unpack is atomic (stage to a temp dir, then rename) so a failed install leaves no
  partial package. Uninstall deactivates the plugin everywhere, removes the dir, and
  deletes the row (idempotent). All steps return tagged tuples; nothing raises on the
  expected error paths.
  """
  require Logger

  alias RepoBuilder.Plugins
  alias RepoBuilder.Plugins.{Activation, Loader, Manifest, Plugin, Registry, Trust}

  @type reason ::
          :unknown_source
          | {:missing_asset, String.t()}
          | :incompatible
          | Trust.reason()
          | term()

  @doc """
  Install `id`@`version` from the named source. `version` defaults to `"latest"`.
  Code-bearing plugins are loaded after recording (gated by the trust policy).
  """
  @spec install(String.t(), String.t(), String.t()) ::
          {:ok, Plugin.t()} | {:error, reason()}
  def install(source_key, id, version \\ "latest")
      when is_binary(source_key) and is_binary(id) and is_binary(version) do
    with {:ok, source_config} <- source_config(source_key),
         module = Map.fetch!(source_config, :module),
         {:ok, %{manifest: manifest, dir: staged_dir}} <- module.fetch(source_config, id, version),
         :ok <- Manifest.validate_assets(manifest, staged_dir),
         :ok <- compat(manifest),
         :ok <- Trust.verify(manifest, staged_dir),
         {:ok, install_path} <- unpack(manifest, staged_dir),
         {:ok, plugin} <- record(manifest, source_key, install_path) do
      _ = maybe_load_code(manifest, install_path)
      {:ok, plugin}
    end
  end

  @doc "Uninstall `id`: deactivate everywhere, remove the dir, delete the row. Idempotent."
  @spec uninstall(String.t()) :: :ok
  def uninstall(id) when is_binary(id) do
    for plugin <- installed_versions(id) do
      _ = File.rm_rf(plugin.install_path)
      _ = Plugins.delete_record(plugin)
    end

    _ = Activation.invalidate_all()
    :ok
  end

  # --- internals ---

  @spec source_config(String.t()) :: {:ok, map()} | {:error, :unknown_source}
  defp source_config(source_key), do: Registry.source_config(source_key)

  @spec compat(Manifest.t()) :: :ok | {:error, :incompatible}
  defp compat(manifest) do
    if Manifest.compat?(manifest, Manifest.platform_version()),
      do: :ok,
      else: {:error, :incompatible}
  end

  @spec unpack(Manifest.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp unpack(%Manifest{id: id, version: version}, staged_dir) do
    target = Path.join(Registry.install_dir(), "#{id}@#{version}")
    tmp = "#{target}.tmp-#{:erlang.unique_integer([:positive])}"
    _ = File.rm_rf(tmp)

    with :ok <- File.mkdir_p(Path.dirname(target)),
         {:ok, _copied} <- File.cp_r(staged_dir, tmp) do
      _ = File.rm_rf(target)

      case File.rename(tmp, target) do
        :ok ->
          {:ok, target}

        {:error, reason} ->
          _ = File.rm_rf(tmp)
          {:error, {:install_move, reason}}
      end
    else
      {:error, reason} ->
        _ = File.rm_rf(tmp)
        {:error, {:install_copy, reason}}
    end
  end

  @spec record(Manifest.t(), String.t(), String.t()) ::
          {:ok, Plugin.t()} | {:error, Ecto.Changeset.t()}
  defp record(manifest, source_key, install_path) do
    Plugins.install_record(%{
      plugin_id: manifest.id,
      version: manifest.version,
      source: source_key,
      install_path: install_path,
      checksum: manifest.checksum,
      manifest: raw_manifest(install_path),
      status: :installed
    })
  end

  # Store the ORIGINAL decoded manifest map (string keys) so it round-trips through
  # `Manifest.from_map/1` after a JSONB reload.
  @spec raw_manifest(String.t()) :: map()
  defp raw_manifest(install_path) do
    with {:ok, json} <- File.read(Path.join(install_path, Manifest.filename())),
         {:ok, map} when is_map(map) <- Jason.decode(json) do
      map
    else
      _ -> %{}
    end
  end

  @spec maybe_load_code(Manifest.t(), String.t()) :: :ok
  defp maybe_load_code(manifest, install_path) do
    if Manifest.code?(manifest) do
      case Loader.load_code(manifest, install_path) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("plugin code load failed: #{inspect(reason)}")
      end
    end

    :ok
  end

  @spec installed_versions(String.t()) :: [Plugin.t()]
  defp installed_versions(id) do
    Plugins.list_installed() |> Enum.filter(&(&1.plugin_id == id))
  end
end
