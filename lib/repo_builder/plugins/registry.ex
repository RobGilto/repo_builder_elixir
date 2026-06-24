defmodule RepoBuilder.Plugins.Registry do
  @moduledoc """
  The SINGLE reader of `config :repo_builder, :plugins` — the install/library dirs,
  the plugin SOURCES map, and the trust policy. Mirrors `Harness.Registry` (§10): the
  one config seam, so tests override the `:plugins` key rather than poke internals.
  """

  @default_install_dir "agentic_plugins"
  @default_library_dir "plugin_library"
  @default_trust %{require_checksum: false, allow_code: true, require_signature: false}

  @spec config() :: keyword()
  def config, do: Application.get_env(:repo_builder, :plugins, [])

  @doc "Absolute path to the live install dir (`agentic_plugins/`)."
  @spec install_dir() :: String.t()
  def install_dir do
    config()
    |> Keyword.get(:install_dir, @default_install_dir)
    |> Path.expand(File.cwd!())
  end

  @doc "Absolute path to the local folder library (`plugin_library/`), the `\"library\"` source root."
  @spec library_dir() :: String.t()
  def library_dir do
    config()
    |> Keyword.get(:library_dir, @default_library_dir)
    |> Path.expand(File.cwd!())
  end

  @doc "The configured sources map: `source key => %{module: …, …}`."
  @spec sources() :: %{optional(String.t()) => map()}
  def sources, do: Keyword.get(config(), :sources, %{})

  @doc "All configured source keys."
  @spec source_keys() :: [String.t()]
  def source_keys, do: Map.keys(sources())

  @doc "Resolve a source key to its adapter module + config."
  @spec source_config(String.t()) :: {:ok, map()} | {:error, :unknown_source}
  def source_config(key) when is_binary(key) do
    case sources()[key] do
      %{} = source -> {:ok, source}
      _ -> {:error, :unknown_source}
    end
  end

  @doc "Resolve a source key to its adapter module."
  @spec source_module(String.t()) :: {:ok, module()} | {:error, :unknown_source}
  def source_module(key) do
    case source_config(key) do
      {:ok, %{module: module}} -> {:ok, module}
      {:ok, _} -> {:error, :unknown_source}
      error -> error
    end
  end

  @doc "The trust policy map (checksum/code/signature gates)."
  @spec trust() :: %{
          required(:require_checksum) => boolean(),
          required(:allow_code) => boolean(),
          required(:require_signature) => boolean()
        }
  def trust do
    Map.merge(@default_trust, Map.new(Keyword.get(config(), :trust, [])))
  end
end
