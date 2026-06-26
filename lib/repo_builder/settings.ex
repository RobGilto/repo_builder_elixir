defmodule RepoBuilder.Settings do
  @moduledoc """
  Operator-editable application settings (BUILD_PROMPT.md §8). This module is the **only**
  `Repo` caller for the `app_settings` table.

  Today it backs one setting: the **global default worker-model roster**
  (`"default_agent_models"`). A new project's orchestrator seeds its per-project roster
  (`orchestrators.metadata["agent_models"]`) from this default, and any tier a project
  leaves unset reads through to it at spawn time. The roster is string-keyed JSON
  (`%{category => %{"harness" => h, "provider" => p | nil, "model" => m}}`, §8 — no atom
  keys) so it matches the on-orchestrator shape exactly and round-trips through JSONB.

  When no `"default_agent_models"` row exists yet (first boot / tests), reads fall back to
  the compile-time `config :repo_builder, :default_agent_models` map.
  """
  import Ecto.Query, warn: false

  alias RepoBuilder.Harness.Registry
  alias RepoBuilder.Orchestrators
  alias RepoBuilder.Repo
  alias RepoBuilder.Settings.AppSetting

  @typedoc "One worker-model assignment: harness/provider/model (string-keyed, JSONB)."
  @type model_spec :: %{optional(String.t()) => String.t() | nil}
  @typedoc "The worker-model roster keyed by category (`fast`/`main`/`heavy`/`leader`)."
  @type roster :: %{optional(String.t()) => model_spec()}

  @key "default_agent_models"

  @doc """
  The global default worker-model roster. Reads the persisted `"default_agent_models"`
  row; falls back to `config :repo_builder, :default_agent_models` (default `%{}`) when no
  row exists.
  """
  @spec default_agent_models() :: roster()
  def default_agent_models do
    case Repo.get_by(AppSetting, key: @key) do
      %AppSetting{value: value} when is_map(value) -> value
      _ -> Application.get_env(:repo_builder, :default_agent_models, %{})
    end
  end

  @doc """
  Override one tier of the global default roster. Validates `category` against
  `Orchestrators.agent_categories/0` and `harness` against `Registry.known/0` (open-identity
  rules, §10), then upserts the merged roster. Returns the new roster.
  """
  @spec set_default_agent_model(String.t(), String.t(), String.t() | nil, String.t()) ::
          {:ok, roster()} | {:error, :invalid_category | :unknown_harness | Ecto.Changeset.t()}
  def set_default_agent_model(category, harness, provider, model) do
    cond do
      category not in Orchestrators.agent_categories() ->
        {:error, :invalid_category}

      harness not in Registry.known() ->
        {:error, :unknown_harness}

      true ->
        entry = %{"harness" => harness, "provider" => provider, "model" => model}

        default_agent_models()
        |> Map.put(category, entry)
        |> set_default_agent_models()
    end
  end

  @doc """
  Replace the entire global default roster (bulk save from the Settings form). Persists the
  given string-keyed map as-is.
  """
  @spec set_default_agent_models(roster()) :: {:ok, roster()} | {:error, Ecto.Changeset.t()}
  def set_default_agent_models(roster) when is_map(roster) do
    %AppSetting{}
    |> AppSetting.changeset(%{"key" => @key, "value" => roster})
    |> Repo.insert(
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: :key,
      returning: true
    )
    |> case do
      {:ok, %AppSetting{value: value}} -> {:ok, value}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
    end
  end
end
