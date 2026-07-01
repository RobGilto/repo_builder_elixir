defmodule RepoBuilder.Harness.Registry do
  @moduledoc """
  Harness registry resolution (BUILD_PROMPT.md §10) — the SINGLE source of truth
  for which harnesses exist and the SINGLE test-injection seam (§13).

  This is the ONLY module that reads `config :repo_builder, :harnesses`. To inject
  a mock in tests, override the `:harnesses` map entry for the harness under test
  (e.g. point `"claude"` at `RepoBuilder.Harness.Mock`) — never introduce a
  separate `:harness_adapter` key, which the runtime would never consult.
  """

  alias RepoBuilder.Harness.Pi.Models
  alias RepoBuilder.Plugins.HarnessOverlay

  @typedoc "Open harness identity (a registry key); intentionally atom()/String.t(), not a closed union (§3 rule 5)."
  @type harness :: atom() | String.t()

  @doc """
  The full registry map: harness key (string) => config map (`:module`, `:exe`, …).

  The static `config :repo_builder, :harnesses` is authoritative; plugin-contributed
  adapters (the runtime `HarnessOverlay`, code-plugin layer) merge in additively so a
  static key always wins a conflict.
  """
  @spec all() :: %{optional(String.t()) => map()}
  def all do
    Map.merge(
      HarnessOverlay.all(),
      Application.fetch_env!(:repo_builder, :harnesses)
    )
  end

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
  Whether `model` is offered by `harness`+`provider` — the SINGLE reader for the
  orchestrator model-consistency check (keeps the `{harness, provider, model}` triple
  coherent so the header provider dropdown always matches the selected harness).

  **Lenient by design** (§3 rule 5 / §10 — open identity): the curated `:models` lists are
  *guidance, not a constraint* (pi/claude accept any model string), so a model the
  registry has never heard of (e.g. a freshly-released concrete id like
  `claude-sonnet-4-6` not yet in the alias list) is treated as **offered** rather than
  foreign. A model is only **foreign** when it is recognizably cross-harness — i.e. it
  appears in SOME harness's curated list (or, for the `pi` harness, the live
  `pi --list-models` catalog) but NOT in this harness's. This is the minimal signal that
  flags the orphan state (a `zai` model like `glm-4.6` set on a `claude` orchestrator)
  without ever rejecting a legitimate concrete model id the registry simply hasn't
  catalogued yet.

  A blank/`nil` model is always "offered" (no-op). An unknown harness is lenient
  (`true`) — never reject on a harness the registry doesn't recognise.
  """
  @spec model_offered_by_harness?(harness(), String.t() | nil, String.t() | nil) ::
          boolean()
  def model_offered_by_harness?(_harness, _provider, model) when model in [nil, ""], do: true

  def model_offered_by_harness?(harness, provider, model) do
    harness = to_string(harness)

    cond do
      not is_map(all()[harness]) ->
        # Unknown harness — lenient (never reject what we can't reason about).
        true

      offered_by_harness?(harness, provider, model) ->
        true

      offered_by_any_other_harness?(harness, model) ->
        # Recognisably cross-harness (e.g. a `zai` model on a `claude` orchestrator) —
        # the orphan signature. Flag it so the consistency guard can react.
        false

      true ->
        # Unknown to every curated list — assume a legitimate concrete id (lenient).
        true
    end
  end

  # The models `harness` offers for `provider`: the curated `:models` list, PLUS (for the
  # `pi` harness only) the live `pi --list-models` catalog so freshly-released models the
  # static list hasn't caught up with still count as offered for `pi`.
  @spec offered_by_harness?(String.t(), String.t() | nil, String.t()) :: boolean()
  defp offered_by_harness?("pi" = harness, provider, model) do
    model in orchestrator_models(harness, provider) or
      model in Models.list(provider)
  end

  defp offered_by_harness?(harness, provider, model) do
    model in orchestrator_models(harness, provider)
  end

  # Whether `model` appears in ANY harness's curated list (or the pi live catalog) other
  # than `except_harness`. Used to recognise a model that belongs to a *different*
  # harness than the one it's set on.
  @spec offered_by_any_other_harness?(String.t(), String.t()) :: boolean()
  defp offered_by_any_other_harness?(except_harness, model) do
    other_harnesses =
      all()
      |> Map.keys()
      |> Enum.reject(&(&1 == except_harness))

    Enum.any?(other_harnesses, fn harness ->
      defaults = orchestrator_defaults(harness)

      curated? =
        case Map.get(defaults, :models) do
          %{} = models ->
            models
            |> Map.values()
            |> Enum.flat_map(&List.wrap/1)
            |> Enum.member?(model)

          _ ->
            false
        end

      live_pi? =
        harness == "pi" and
          model in (Models.all() |> Map.values() |> List.flatten())

      curated? or live_pi?
    end)
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
