defmodule RepoBuilder.Plugins.Code do
  @moduledoc """
  OPTIONAL behaviour for CODE-bearing plugins (the agentic plugin system foundation).

  A plugin that ships BEAM modules (under its `lib/`) declares a `code` block in its
  manifest naming an `on_load` module that implements this behaviour. At load the
  `RepoBuilder.Plugins.Loader` `Code.require_file/1`s each module then calls
  `on_load/1`, where the plugin registers its programmatic contributions — most often
  a harness adapter via `RepoBuilder.Plugins.HarnessOverlay` (satisfying the §10
  "add a harness = one module" promise from a dropped-in plugin).

  > Trust boundary: this runs arbitrary code in-node. Loading is gated by
  > `config :repo_builder, :plugins, trust: %{allow_code: …}` and checksum
  > verification; the store never auto-installs a code plugin without confirmation.
  """

  @typedoc "Context passed to `on_load/1`: the plugin id, version, and install dir."
  @type ctx :: %{
          required(:plugin_id) => String.t(),
          required(:version) => String.t(),
          required(:install_path) => String.t()
        }

  @doc "Register the plugin's programmatic contributions. Called once per load."
  @callback on_load(ctx()) :: :ok | {:error, term()}

  @doc "Optional: the kinds this code plugin contributes (advisory)."
  @callback contributions() :: [RepoBuilder.Plugins.Contribution.kind()]

  @optional_callbacks contributions: 0
end
