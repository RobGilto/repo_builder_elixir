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

  @doc """
  Whether a harness is orchestrator-capable (issue-c). Driven purely by an
  `orchestrating: true` map entry — adding the capability is one config flag (§10),
  no new registry key. An unknown harness is `false`.
  """
  @spec orchestrating?(harness()) :: boolean()
  def orchestrating?(harness) do
    case all()[to_string(harness)] do
      %{orchestrating: true} -> true
      _ -> false
    end
  end

  @doc "All orchestrator-capable harness keys."
  @spec orchestrating_harnesses() :: [String.t()]
  def orchestrating_harnesses do
    all()
    |> Enum.filter(fn {_key, config} -> config[:orchestrating] == true end)
    |> Enum.map(fn {key, _config} -> key end)
    |> Enum.sort()
  end

  @doc """
  Per-harness orchestrator defaults (issue-d) — the `:orchestrator` sub-map
  (`:default_provider`/`:default_model`/`:providers`). The SINGLE reader of that
  config key. An unknown harness or one without the sub-map yields `%{}`.
  """
  @spec orchestrator_defaults(harness()) :: %{optional(atom()) => term()}
  def orchestrator_defaults(harness) do
    case all()[to_string(harness)] do
      %{orchestrator: %{} = defaults} -> defaults
      _ -> %{}
    end
  end

  @doc """
  The registry-declared orchestrator model options for `harness`+`provider`
  (latest first), from the `:orchestrator` sub-map's `:models` map (`provider =>
  [model]`). Falls back to the harness's `:default_model` when no per-provider list
  is declared, and `[]` when there is nothing to offer.
  """
  @spec orchestrator_models(harness(), String.t() | nil) :: [String.t()]
  def orchestrator_models(harness, provider) do
    defaults = orchestrator_defaults(harness)

    with %{} = models <- Map.get(defaults, :models),
         [_ | _] = list <- Map.get(models, to_string(provider)) do
      list
    else
      _ -> defaults |> Map.get(:default_model) |> List.wrap()
    end
  end

  @doc """
  Whether a harness runs unattended (issue-d). Drives the programmatic autonomy
  flag in each adapter (Claude `--dangerously-skip-permissions`, pi `--approve`).
  An unknown harness is `false`.
  """
  @spec autonomous?(harness()) :: boolean()
  def autonomous?(harness) do
    case all()[to_string(harness)] do
      %{autonomous: true} -> true
      _ -> false
    end
  end
end
