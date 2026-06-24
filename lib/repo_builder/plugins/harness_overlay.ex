defmodule RepoBuilder.Plugins.HarnessOverlay do
  @moduledoc """
  Runtime overlay of plugin-contributed harness adapters (the agentic plugin system
  foundation, code layer). A code plugin's `on_load/1` registers a harness here; the
  static `config :repo_builder, :harnesses` stays authoritative and plugins layer
  additively, so a new harness can arrive entirely via a dropped-in plugin with zero
  edits to `Event`/`Agent`/runtime (§10).

  Backed by `:persistent_term` (read-mostly, no GenServer): `Harness.Registry`
  consults `all/0` on top of the static config.
  """

  @key {__MODULE__, :harnesses}

  @doc "All overlaid harness entries: `key => config map` (`:module`, `:exe`, …)."
  @spec all() :: %{optional(String.t()) => map()}
  def all, do: :persistent_term.get(@key, %{})

  @doc "Register (or replace) an overlaid harness adapter under `key`."
  @spec put(String.t(), map()) :: :ok
  def put(key, config) when is_binary(key) and is_map(config) do
    :persistent_term.put(@key, Map.put(all(), key, config))
  end

  @doc "Remove an overlaid harness."
  @spec delete(String.t()) :: :ok
  def delete(key) when is_binary(key) do
    :persistent_term.put(@key, Map.delete(all(), key))
  end

  @doc "Clear the whole overlay (test teardown / full reload)."
  @spec clear() :: :ok
  def clear, do: :persistent_term.put(@key, %{})
end
