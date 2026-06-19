defmodule RepoBuilder.Budget do
  @moduledoc """
  Budget bounded context (issue-budget-guardrails): the **only** `Repo` caller for the
  `budgets` table (BUILD_PROMPT.md §8). Holds the durable spend CAPS; the live circuit
  breaker `RepoBuilder.Budget.Guard` reads them and enforces them.

  Every public function is `@spec`'d and returns `{:ok, Cap.t()} | {:error, changeset}`
  (or `[Cap.t()]` / `Cap.t() | nil`). The web layer never touches `Repo` directly.
  """
  import Ecto.Query, only: [from: 2]

  alias RepoBuilder.Budget.{Cap, Scope}
  alias RepoBuilder.Repo

  @doc "All caps, newest first."
  @spec list_caps() :: [Cap.t()]
  def list_caps do
    Repo.all(from(c in Cap, order_by: [desc: c.inserted_at]))
  end

  @doc "Only enabled caps — the live breaker's input."
  @spec list_active_caps() :: [Cap.t()]
  def list_active_caps do
    Repo.all(from(c in Cap, where: c.enabled == true, order_by: [desc: c.inserted_at]))
  end

  @doc "Fetch one cap by id, or `nil`."
  @spec get_cap(Ecto.UUID.t()) :: Cap.t() | nil
  def get_cap(id), do: Repo.get(Cap, id)

  @doc "Enabled caps matching any of the given scope_refs."
  @spec caps_for_scopes([Scope.scope_ref()]) :: [Cap.t()]
  def caps_for_scopes([]), do: []

  def caps_for_scopes(scope_refs) when is_list(scope_refs) do
    scope_refs
    |> Enum.uniq()
    |> Enum.flat_map(fn {scope, scope_id} ->
      Repo.all(
        from(c in Cap,
          where: c.enabled == true and c.scope == ^scope and c.scope_id == ^(scope_id || "")
        )
      )
    end)
  end

  @doc "Insert or update a cap by its `(scope, scope_id, period)` key."
  @spec upsert_cap(map()) :: {:ok, Cap.t()} | {:error, Ecto.Changeset.t()}
  def upsert_cap(params) do
    params = stringify_keys(params)
    scope = params["scope"]
    scope_id = scope_id_for(scope, params["scope_id"])
    period = params["period"] || "total"

    case Repo.get_by(Cap, scope: scope, scope_id: scope_id, period: period) do
      nil -> %Cap{}
      %Cap{} = existing -> existing
    end
    |> Cap.changeset(params)
    |> Repo.insert_or_update()
  end

  @doc "Update a loaded cap."
  @spec update_cap(Cap.t(), map()) :: {:ok, Cap.t()} | {:error, Ecto.Changeset.t()}
  def update_cap(%Cap{} = cap, params) do
    cap
    |> Cap.changeset(stringify_keys(params))
    |> Repo.update()
  end

  @doc """
  Restart a cap's spend window: stamp `reset_at = now` so the live breaker counts spend
  only from this moment (the tripped-banner "Reset" action). Returns the reloaded cap, or
  `nil` if it no longer exists. Never raises.
  """
  @spec reset_cap_window(Ecto.UUID.t()) :: Cap.t() | nil
  def reset_cap_window(id) do
    case Repo.get(Cap, id) do
      nil ->
        nil

      %Cap{} = cap ->
        case cap |> Ecto.Changeset.change(reset_at: DateTime.utc_now()) |> Repo.update() do
          {:ok, %Cap{} = updated} -> updated
          {:error, _changeset} -> nil
        end
    end
  rescue
    _ -> nil
  end

  @doc "Delete a cap by id."
  @spec delete_cap(Ecto.UUID.t()) :: {:ok, Cap.t()} | {:error, term()}
  def delete_cap(id) do
    case Repo.get(Cap, id) do
      nil -> {:error, :not_found}
      %Cap{} = cap -> Repo.delete(cap)
    end
  end

  @doc """
  Idempotently seed a default global `:total` `:alert` cap from
  `config :repo_builder, :alerting, :cost_threshold_usd`, so the existing alert
  threshold becomes a real (alert-only) cap. A no-op when a global total cap already
  exists, or when no threshold is configured. Never raises.
  """
  @spec seed_default_cap() :: {:ok, Cap.t()} | {:ok, :exists} | {:error, term()}
  def seed_default_cap do
    threshold = get_in(Application.get_env(:repo_builder, :alerting, []), [:cost_threshold_usd])

    cond do
      Repo.get_by(Cap, scope: :global, scope_id: "", period: :total) ->
        {:ok, :exists}

      is_number(threshold) and threshold > 0 ->
        upsert_cap(%{
          "scope" => "global",
          "scope_id" => "",
          "period" => "total",
          "limit_usd" => to_decimal(threshold),
          "action" => "alert",
          "enabled" => true
        })

      true ->
        {:ok, :exists}
    end
  end

  # --- private ---

  @spec scope_id_for(term(), term()) :: String.t()
  defp scope_id_for(scope, _scope_id) when scope in ["global", :global], do: ""
  defp scope_id_for(_scope, scope_id) when is_binary(scope_id), do: scope_id
  defp scope_id_for(_scope, _scope_id), do: ""

  @spec to_decimal(number()) :: Decimal.t()
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)

  @spec stringify_keys(map()) :: %{optional(String.t()) => term()}
  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
