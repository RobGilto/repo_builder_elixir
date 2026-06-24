defmodule RepoBuilder.Plugins.Source.LocalLibrary do
  @moduledoc """
  The local folder-library source (the agentic plugin system foundation): plugins
  authored on disk under `plugin_library/<id>/` (configurable via
  `RepoBuilder.Plugins.Registry.library_dir/0`). Fully hermetic — no network.

  Each `<id>/` holds one package whose version is its `plugin.json` version. `fetch/3`
  stages by returning the library dir itself (the installer copies out of it).
  """
  @behaviour RepoBuilder.Plugins.Source

  alias RepoBuilder.Plugins.{Manifest, Registry, Source}

  @impl true
  def list(config) do
    root = root(config)

    summaries =
      root
      |> safe_ls()
      |> Enum.flat_map(fn entry ->
        case Manifest.read(Path.join(root, entry)) do
          {:ok, manifest} -> [Source.summary(manifest)]
          {:error, _} -> []
        end
      end)
      |> Enum.sort_by(& &1.id)

    {:ok, summaries}
  end

  @impl true
  def info(config, id, _version) do
    case Manifest.read(package_dir(config, id)) do
      {:ok, manifest} -> {:ok, Source.summary(manifest)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def fetch(config, id, version) do
    dir = package_dir(config, id)

    with {:ok, manifest} <- Manifest.read(dir),
         :ok <- check_version(manifest, version) do
      {:ok, %{manifest: manifest, dir: dir}}
    end
  end

  @spec root(map()) :: String.t()
  defp root(config), do: Map.get(config, :dir) || Registry.library_dir()

  @spec package_dir(map(), String.t()) :: String.t()
  defp package_dir(config, id), do: Path.join(root(config), id)

  # A local library holds one version per id; accept "", "latest", or an exact match.
  @spec check_version(Manifest.t(), String.t()) :: :ok | {:error, :version_not_found}
  defp check_version(_manifest, version) when version in ["", "latest", "auto"], do: :ok
  defp check_version(%Manifest{version: version}, version), do: :ok
  defp check_version(_manifest, _version), do: {:error, :version_not_found}

  @spec safe_ls(String.t()) :: [String.t()]
  defp safe_ls(dir) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.filter(entries, &File.dir?(Path.join(dir, &1)))
      _ -> []
    end
  end
end
