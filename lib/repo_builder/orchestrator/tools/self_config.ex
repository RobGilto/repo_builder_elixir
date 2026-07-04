defmodule RepoBuilder.Orchestrator.Tools.SelfConfig do
  @moduledoc """
  Self-configuration tools: the orchestrator's own harness/provider/model config
  (`get_config`/`set_orchestrator_config`) and the per-category worker roster
  tiers (`configure_tier`). Extracted verbatim from the monolithic
  `Orchestrator.Tools` (audit F3) — behaviour is byte-identical.
  """

  import RepoBuilder.Orchestrator.Tools.Shared,
    only: [blank_to_nil: 1, fetch_orchestrator: 1, fetch_string: 2, resolve_harness: 2]

  alias RepoBuilder.Harness.ModelResolver
  alias RepoBuilder.Harness.Pi.Models, as: PiModels
  alias RepoBuilder.Harness.Registry
  alias RepoBuilder.Orchestrator.Orchestrator
  alias RepoBuilder.Orchestrator.Tools.Shared
  alias RepoBuilder.Orchestrators

  @type reason :: Shared.reason()
  @type result :: Shared.result()

  @doc """
  The orchestrator's own config snapshot: its harness/provider/model, the effective
  per-category worker tiers, the registered harnesses, and the available models.
  """
  @spec get_config(Ecto.UUID.t()) :: result()
  def get_config(orchestrator_id) do
    with {:ok, orch} <- fetch_orchestrator(orchestrator_id) do
      tiers =
        Map.new(Orchestrators.agent_categories(), fn category ->
          {category, tier_view(category, orch)}
        end)

      {:ok,
       %{
         "orchestrator" => %{
           "harness" => orch.harness,
           "provider" => orch.provider,
           "model" => orch.model
         },
         "tiers" => tiers,
         "harnesses" => Registry.known(),
         "available_models" => available_models(orch.harness)
       }}
    end
  end

  @spec configure_tier(Ecto.UUID.t(), map()) :: result()
  def configure_tier(orchestrator_id, args) do
    with {:ok, category} <- fetch_string(args, "category"),
         {:ok, selected} <- fetch_string(args, "model"),
         {:ok, harness} <- resolve_harness(orchestrator_id, args) do
      provider = blank_to_nil(args["provider"])
      # Resolve to the latest of the family before persisting, and echo the resolved
      # model so the orchestrator sees what was actually stored on the roster.
      model = ModelResolver.latest(harness, provider, selected)
      attrs = %{"harness" => harness, "provider" => provider, "model" => model}

      case Orchestrators.set_agent_model(orchestrator_id, category, attrs) do
        {:ok, _orch} ->
          {:ok,
           %{
             "status" => "configured",
             "category" => category,
             "harness" => harness,
             "provider" => provider,
             "model" => model
           }}

        {:error, :invalid_category} ->
          {:error, "invalid category: #{category}"}

        {:error, :not_found} ->
          {:error, :orchestrator_not_found}
      end
    end
  end

  @spec set_orchestrator_config(Ecto.UUID.t(), map()) :: result()
  def set_orchestrator_config(orchestrator_id, args) do
    harness = blank_to_nil(args["harness"])
    provider = blank_to_nil(args["provider"])
    model = blank_to_nil(args["model"])

    if is_nil(harness) and is_nil(provider) and is_nil(model) do
      {:error, "no config fields provided"}
    else
      # Apply in a fixed, safe order — harness first (it resets provider/model to the
      # harness defaults), then provider (resets model), then model last.
      with {:ok, _} <- apply_harness(orchestrator_id, harness),
           {:ok, _} <- apply_provider(orchestrator_id, provider),
           {:ok, _} <- apply_model(orchestrator_id, model),
           {:ok, orch} <- fetch_orchestrator(orchestrator_id) do
        {:ok, %{"harness" => orch.harness, "provider" => orch.provider, "model" => orch.model}}
      end
    end
  end

  @spec apply_harness(Ecto.UUID.t(), String.t() | nil) ::
          {:ok, Orchestrator.t() | :skip} | {:error, reason()}
  defp apply_harness(_orchestrator_id, nil), do: {:ok, :skip}

  defp apply_harness(orchestrator_id, harness) do
    if harness in Registry.known() do
      route_config(Orchestrators.set_harness(orchestrator_id, harness))
    else
      {:error, "not a registered harness: #{harness}"}
    end
  end

  @spec apply_provider(Ecto.UUID.t(), String.t() | nil) ::
          {:ok, Orchestrator.t() | :skip} | {:error, reason()}
  defp apply_provider(_orchestrator_id, nil), do: {:ok, :skip}

  defp apply_provider(orchestrator_id, provider),
    do: route_config(Orchestrators.set_provider(orchestrator_id, provider))

  @spec apply_model(Ecto.UUID.t(), String.t() | nil) ::
          {:ok, Orchestrator.t() | :skip} | {:error, reason()}
  defp apply_model(_orchestrator_id, nil), do: {:ok, :skip}

  defp apply_model(orchestrator_id, model),
    do: route_config(Orchestrators.set_model(orchestrator_id, model))

  @spec route_config({:ok, Orchestrator.t()} | {:error, :not_found}) ::
          {:ok, Orchestrator.t()} | {:error, reason()}
  defp route_config({:ok, orch}), do: {:ok, orch}
  defp route_config({:error, :not_found}), do: {:error, :orchestrator_not_found}

  # The EFFECTIVE view of one worker tier: the per-project assignment when set, else the
  # inherited global default. `inherited?` is true when the model came from the default
  # (so the console/MCP caller can show an "inherited" indicator); `assigned` stays true
  # whenever a model resolves at all (project or default), since that is what `create_agent`
  # can spawn into.
  # Inference-only spec — the concrete tier map (with boolean `assigned`/`inherited?`)
  # narrows below a hand-written `map()` spec, which Dialyzer rejects as a supertype under
  # :underspecs.
  defp tier_view(category, orchestrator) do
    {entry, source} = Orchestrators.effective_agent_model(orchestrator, category)
    entry = entry || %{}
    model = blank_to_nil(entry["model"])

    %{
      "harness" => entry["harness"],
      "provider" => entry["provider"],
      "model" => model,
      "assigned" => not is_nil(model),
      "inherited?" => not is_nil(model) and source == :default
    }
  end

  # The available models for the orchestrator's harness: merge the live pi catalog
  # (empty in test/when pi is absent) with the static registry lists per provider.
  # Fail-soft: an empty map is a valid answer.
  @spec available_models(String.t()) :: %{String.t() => %{String.t() => [String.t()]}}
  defp available_models(harness) do
    pi_catalog = PiModels.all()

    providers =
      pi_catalog |> Map.keys() |> Enum.concat(registry_providers(harness)) |> Enum.uniq()

    by_provider =
      Map.new(providers, fn provider ->
        models =
          (Map.get(pi_catalog, provider, []) ++ Registry.orchestrator_models(harness, provider))
          |> Enum.uniq()

        {provider, models}
      end)

    %{harness => by_provider}
  end

  @spec registry_providers(String.t()) :: [String.t()]
  defp registry_providers(harness) do
    harness
    |> Registry.orchestrator_defaults()
    |> Map.get(:models, %{})
    |> Map.keys()
  end
end
