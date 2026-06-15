defmodule RepoBuilder.Harness.Registry do
  @moduledoc """
  Harness registry resolution (BUILD_PROMPT.md §10) — the SINGLE source of truth
  for which harnesses exist and the SINGLE test-injection seam (§13).

  This is the ONLY module that reads `config :repo_builder, :harnesses`. To inject
  a mock in tests, override the `:harnesses` map entry for the harness under test
  (e.g. point `"claude"` at `RepoBuilder.Harness.Mock`) — never introduce a
  separate `:harness_adapter` key, which the runtime would never consult.
  """

  @typedoc "Open harness identity (a registry key); intentionally atom()/String.t(), not a closed union (§3 rule 5)."
  @type harness :: atom() | String.t()

  @doc "The full registry map: harness key (string) => config map (`:module`, `:exe`, …)."
  @spec all() :: %{optional(String.t()) => map()}
  def all, do: Application.fetch_env!(:repo_builder, :harnesses)

  @doc "All registered harness keys — used by changeset `validate_inclusion/3` at the write boundary."
  @spec known() :: [String.t()]
  def known, do: Map.keys(all())

  @doc "Fetch the full config entry for a harness key (atom or string)."
  @spec fetch_config(harness()) :: {:ok, map()} | {:error, :unknown_harness}
  def fetch_config(harness) do
    case all()[to_string(harness)] do
      %{} = config -> {:ok, config}
      _ -> {:error, :unknown_harness}
    end
  end

  @doc "Resolve a harness key (atom or string) to its adapter module."
  @spec fetch(harness()) :: {:ok, module()} | {:error, :unknown_harness}
  def fetch(harness) do
    case all()[to_string(harness)] do
      %{module: module} -> {:ok, module}
      _ -> {:error, :unknown_harness}
    end
  end
end
