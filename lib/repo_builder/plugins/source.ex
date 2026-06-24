defmodule RepoBuilder.Plugins.Source do
  @moduledoc """
  The "store" seam (the agentic plugin system foundation): a behaviour abstracting
  WHERE plugins come from. A new distribution channel is one adapter + one config
  entry — exactly the harness-registry extensibility proof (§10).

  Two adapters ship: `RepoBuilder.Plugins.Source.LocalLibrary` (the `plugin_library/`
  folder) and `RepoBuilder.Plugins.Source.RemoteStore` (an HTTP store, via Req). A
  source is resolved by key through `RepoBuilder.Plugins.Registry`.

  `fetch/3` returns a STAGED package: a directory containing the package's files
  (`plugin.json` + assets) plus the parsed manifest. The installer copies it into
  `agentic_plugins/`. A staged dir may be a temp dir the installer is free to remove.
  """
  alias RepoBuilder.Plugins.Manifest

  @typedoc "A catalog entry (no assets fetched yet)."
  @type summary :: %{
          id: String.t(),
          version: String.t(),
          name: String.t(),
          description: String.t() | nil
        }

  @typedoc "A staged package ready to install: a local dir + the parsed manifest."
  @type package :: %{manifest: Manifest.t(), dir: String.t()}

  @doc "Catalog every plugin this source offers."
  @callback list(config :: map()) :: {:ok, [summary()]} | {:error, term()}

  @doc "Catalog one plugin/version."
  @callback info(config :: map(), id :: String.t(), version :: String.t()) ::
              {:ok, summary()} | {:error, term()}

  @doc "Stage a plugin/version locally and return its dir + parsed manifest."
  @callback fetch(config :: map(), id :: String.t(), version :: String.t()) ::
              {:ok, package()} | {:error, term()}

  @doc "Build a `summary` from a parsed manifest."
  @spec summary(Manifest.t()) :: summary()
  def summary(%Manifest{} = manifest) do
    %{
      id: manifest.id,
      version: manifest.version,
      name: manifest.name,
      description: manifest.description
    }
  end
end
