defmodule RepoBuilder.Plugins.Source.RemoteStore do
  @moduledoc """
  The remote HTTP plugin store source (the agentic plugin system foundation). Browses
  and fetches packages over HTTP with `Req` (the project's mandated HTTP client).

  Store contract (a simple static layout, so any backend that serves these works):

    * `GET {base_url}/index.json`                       → `[{id, version, name, description}]`
    * `GET {base_url}/plugins/{id}/{version}.tar.gz`    → a gzip tarball of the package

  Config (from the `:plugins` `sources["store"]` registry entry): `:base_url` and an
  optional `:req_options` keyword merged into `Req.new/1` (the test-injection seam —
  e.g. `plug: {Req.Test, …}`). A code plugin in the store is NEVER auto-installed
  without operator confirmation (see the trust model).
  """
  @behaviour RepoBuilder.Plugins.Source

  alias RepoBuilder.Plugins.Manifest

  @impl true
  def list(config) do
    with {:ok, base} <- base_url(config),
         {:ok, body} <- get(req(config), base <> "/index.json") do
      {:ok, parse_index(body)}
    end
  end

  @impl true
  def info(config, id, version) do
    case list(config) do
      {:ok, summaries} ->
        case Enum.find(summaries, &match_summary?(&1, id, version)) do
          nil -> {:error, :not_found}
          summary -> {:ok, summary}
        end

      error ->
        error
    end
  end

  @impl true
  def fetch(config, id, version) do
    with {:ok, base} <- base_url(config),
         url = "#{base}/plugins/#{id}/#{version}.tar.gz",
         {:ok, tarball} <- get_binary(req(config), url),
         {:ok, dir} <- stage(tarball),
         {:ok, manifest} <- Manifest.read(dir) do
      {:ok, %{manifest: manifest, dir: dir}}
    end
  end

  # --- internals ---

  @spec req(map()) :: Req.Request.t()
  defp req(config) do
    Req.new(Keyword.merge([decode_body: false], Map.get(config, :req_options, [])))
  end

  @spec base_url(map()) :: {:ok, String.t()} | {:error, :no_base_url}
  defp base_url(config) do
    case Map.get(config, :base_url) do
      url when is_binary(url) and url != "" -> {:ok, String.trim_trailing(url, "/")}
      _ -> {:error, :no_base_url}
    end
  end

  @spec get(Req.Request.t(), String.t()) :: {:ok, term()} | {:error, term()}
  defp get(req, url) do
    case Req.get(req, url: url) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec get_binary(Req.Request.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  defp get_binary(req, url) do
    case get(req, url) do
      {:ok, body} when is_binary(body) -> {:ok, body}
      {:ok, _other} -> {:error, :not_binary}
      error -> error
    end
  end

  @spec parse_index(term()) :: [RepoBuilder.Plugins.Source.summary()]
  defp parse_index(body) when is_list(body), do: Enum.flat_map(body, &index_entry/1)

  defp parse_index(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, list} when is_list(list) -> parse_index(list)
      _ -> []
    end
  end

  defp parse_index(_body), do: []

  @spec index_entry(term()) :: [RepoBuilder.Plugins.Source.summary()]
  defp index_entry(%{"id" => id, "version" => version} = entry)
       when is_binary(id) and is_binary(version) do
    [%{id: id, version: version, name: entry["name"] || id, description: entry["description"]}]
  end

  defp index_entry(_entry), do: []

  @spec match_summary?(RepoBuilder.Plugins.Source.summary(), String.t(), String.t()) :: boolean()
  defp match_summary?(summary, id, version) do
    summary.id == id and (version in ["", "latest", "auto"] or summary.version == version)
  end

  @spec stage(binary()) :: {:ok, String.t()} | {:error, term()}
  defp stage(tarball) do
    dir = Path.join(System.tmp_dir!(), "rb_plugin_#{:erlang.unique_integer([:positive])}")
    tar_path = Path.join(dir, "package.tar.gz")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tar_path, tarball),
         :ok <- untar(tar_path, dir) do
      _ = File.rm(tar_path)
      locate_package(dir)
    end
  end

  @spec untar(String.t(), String.t()) :: :ok | {:error, {:untar, term()}}
  defp untar(tar_path, dir) do
    case :erl_tar.extract(String.to_charlist(tar_path), [
           :compressed,
           {:cwd, String.to_charlist(dir)}
         ]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:untar, reason}}
    end
  end

  # The package may be at the staged root or nested one level (tarred as `<id>/…`).
  @spec locate_package(String.t()) :: {:ok, String.t()} | {:error, :no_manifest}
  defp locate_package(dir) do
    if File.regular?(Path.join(dir, Manifest.filename())) do
      {:ok, dir}
    else
      case Enum.filter(safe_ls(dir), &File.regular?(Path.join([dir, &1, Manifest.filename()]))) do
        [sub] -> {:ok, Path.join(dir, sub)}
        _ -> {:error, :no_manifest}
      end
    end
  end

  @spec safe_ls(String.t()) :: [String.t()]
  defp safe_ls(dir) do
    case File.ls(dir) do
      {:ok, entries} -> entries
      _ -> []
    end
  end
end
