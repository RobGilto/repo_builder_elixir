defmodule RepoBuilder.CostCenter do
  @moduledoc """
  Cost Center context (issue-cost-center): the operator's window onto AI spend by
  `(harness, provider, model)`. The **only** `Repo` caller for `model_prices` and the
  dimensional `agent_logs` rollup (BUILD_PROMPT.md §8).

  Two distinct concerns:

    * **Actuals** — aggregated from existing `agent_logs` rows (their embedded `Usage`
      value object), grouped by the `provider`/`model` snapshots captured at write time.
      No new table; `rollup/1` produces `Rollup.t()` rows ordered most-recent-first.
    * **Rates** — the seeded, editable `model_prices` catalog. It feeds
      `price_table_for/1` (the override the session runtime merges over the config
      `price_table` so unpriced harnesses like `pi` derive `cost_usd` without a
      redeploy) and the estimate fallback in the rollup.
  """
  import Ecto.Query, only: [from: 2, where: 3]

  alias RepoBuilder.Agents.Agent
  alias RepoBuilder.CostCenter.{ModelPrice, Rollup, SpendRow, SpendSummary}
  alias RepoBuilder.Harness.Pricing
  alias RepoBuilder.Logs.AgentLog
  alias RepoBuilder.Repo
  alias RepoBuilder.Timezones
  alias RepoBuilder.Workflows

  @default_rollup_limit 50
  @max_rollup_limit 200

  # --- catalog CRUD ---

  @doc "All catalog rows, ordered `harness, provider, model`."
  @spec list_prices() :: [ModelPrice.t()]
  def list_prices do
    Repo.all(from(p in ModelPrice, order_by: [asc: p.harness, asc: p.provider, asc: p.model]))
  end

  @doc "Fetch one catalog row by its `(harness, provider, model)` key (`nil` provider → `\"\"`)."
  @spec get_price(String.t(), String.t() | nil, String.t()) :: ModelPrice.t() | nil
  def get_price(harness, provider, model) do
    Repo.get_by(ModelPrice,
      harness: harness,
      provider: normalize_provider(provider),
      model: model
    )
  end

  @doc """
  Insert or update a catalog row by `(harness, provider, model)`. An operator edit
  marks the row `source: :manual` so a future `seed_prices/0` never clobbers it.
  """
  @spec upsert_price(map()) :: {:ok, ModelPrice.t()} | {:error, Ecto.Changeset.t()}
  def upsert_price(params) do
    params = params |> stringify_keys() |> Map.put("source", "manual")

    %ModelPrice{}
    |> ModelPrice.changeset(params)
    |> Repo.insert(
      on_conflict:
        {:replace, [:input_price_per_mtok, :output_price_per_mtok, :source, :updated_at]},
      conflict_target: [:harness, :provider, :model],
      # RETURNING the persisted row so the struct carries the EXISTING id on a conflict
      # update, not the client-generated one Ecto would otherwise echo back.
      returning: true
    )
  end

  @doc "Fetch one catalog row by its id, or `nil` if it does not exist."
  @spec get_price(Ecto.UUID.t()) :: ModelPrice.t() | nil
  def get_price(id), do: Repo.get(ModelPrice, id)

  @doc """
  Update a loaded catalog row's rate columns in place, forcing `source: :manual`
  (an edit is always a manual override).

  Callers MUST NOT repoint the `(harness, provider, model)` identity key through this
  function — the edit form omits those keys from `params`. To move a row to a new key,
  `delete_price/1` the old row and `upsert_price/1` a new one, keeping the unique key and
  the `price_table_for/1` lookup unambiguous.
  """
  @spec update_price(ModelPrice.t(), map()) ::
          {:ok, ModelPrice.t()} | {:error, Ecto.Changeset.t()}
  def update_price(%ModelPrice{} = price, params) do
    params = params |> stringify_keys() |> Map.put("source", "manual")

    price
    |> ModelPrice.changeset(params)
    |> Repo.update()
  end

  @doc "Delete a catalog row by id."
  @spec delete_price(Ecto.UUID.t()) :: {:ok, ModelPrice.t()} | {:error, term()}
  def delete_price(id) do
    case Repo.get(ModelPrice, id) do
      nil -> {:error, :not_found}
      %ModelPrice{} = price -> Repo.delete(price)
    end
  end

  @doc """
  Build the per-Mtok `%{model => Pricing.Rate.t()}` table for a harness from the catalog,
  in the shape `Pricing.derive/3` consumes (separate input/output rates so cache tokens
  can be priced against the input rate).

  A catalog row stores separate input/output rates. When only one column is present, the
  missing rate falls back to the other so both fields are populated. Rows with neither
  rate are omitted.
  """
  @spec price_table_for(String.t()) :: Pricing.price_table()
  def price_table_for(harness) do
    from(p in ModelPrice, where: p.harness == ^harness)
    |> Repo.all()
    |> Enum.reduce(%{}, fn price, acc ->
      case rate_for(price) do
        nil -> acc
        %Pricing.Rate{} = rate -> Map.put(acc, price.model, rate)
      end
    end)
  end

  @doc """
  Idempotently seed the catalog from `priv/repo/pricing_seeds.exs`. Each seed row is
  inserted (or, when it already exists as a `:seed` row, refreshed); a row an operator
  has edited to `:manual` is preserved untouched. Returns the number of seed rows
  processed (stable across runs — no duplicates).
  """
  @spec seed_prices() :: {:ok, non_neg_integer()}
  def seed_prices do
    count =
      load_seed_rows()
      |> Enum.reduce(0, fn attrs, acc ->
        harness = Map.get(attrs, :harness)
        provider = normalize_provider(Map.get(attrs, :provider))
        model = Map.get(attrs, :model)

        case get_price(harness, provider, model) do
          %ModelPrice{source: :manual} -> acc
          existing -> seed_one(existing, attrs, acc)
        end
      end)

    {:ok, count}
  end

  # --- dimensional rollup ---

  @doc """
  Aggregate `agent_logs` cost/tokens by `(harness, provider, model)`, ordered by most
  recent activity (`last_used_at DESC`). Each `Rollup.t()` sums only priced rows into
  `actual_cost_usd`; when a dimension has no priced rows but the catalog prices it, an
  `estimated_cost_usd` is derived (and `estimated?` set) — the nil-vs-0 distinction is
  preserved (no price ⇒ `estimated_cost_usd: nil`).

  Options: `:limit` (default #{@default_rollup_limit}, clamped to #{@max_rollup_limit})
  and `:include_hidden?` (default `false`).
  """
  @spec rollup(keyword()) :: [Rollup.t()]
  def rollup(opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_rollup_limit) |> clamp_limit()
    include_hidden? = Keyword.get(opts, :include_hidden?, false)

    base =
      from l in AgentLog,
        where: not is_nil(l.usage),
        group_by: [l.harness, l.provider, l.model],
        order_by: [desc: max(l.inserted_at)],
        limit: ^limit,
        select: %{
          harness: l.harness,
          provider: l.provider,
          model: l.model,
          actual_cost_usd: sum(fragment("(?->>'cost_usd')::numeric", l.usage)),
          input_tokens: fragment("COALESCE(SUM((?->>'input_tokens')::bigint), 0)", l.usage),
          output_tokens: fragment("COALESCE(SUM((?->>'output_tokens')::bigint), 0)", l.usage),
          cache_read: fragment("COALESCE(SUM((?->>'cache_read')::bigint), 0)", l.usage),
          cache_creation: fragment("COALESCE(SUM((?->>'cache_creation')::bigint), 0)", l.usage),
          event_count: count(l.id),
          last_used_at: max(l.inserted_at)
        }

    base
    |> filter_hidden(include_hidden?)
    |> Repo.all()
    |> Enum.map(&to_rollup/1)
  end

  # --- period spend (time-windowed, vendor-level, hidden INCLUDED) ---

  @doc """
  Time-windowed spend summary (issue-cost-adw-periods): the operator's per-period,
  per-vendor accounting view. Sums `agent_logs` cost/tokens over three windows — today,
  this week (ISO-8601, Monday start), this month (since the 1st) — each grouped two ways
  (`by_harness`, `by_provider`).

  Windows are resolved in the operator's display timezone (then converted to UTC for the
  `inserted_at >=` filter). Crucially, and unlike `rollup/1`, this aggregation **includes
  hidden/cleared rows** — it reports real money spent, so pressing CLEAR (which hides logs)
  never changes these numbers. Actual-vs-estimated and the nil-vs-0 convention are
  preserved via `derive_costs/5`.

  Options: `:timezone` (defaults to `Timezones.default/0`) and `:now` (a UTC `DateTime`
  reference, defaults to `DateTime.utc_now/0`; supplied by tests for deterministic windows).
  """
  @spec period_spend(keyword()) :: SpendSummary.t()
  def period_spend(opts \\ []) do
    zone = resolve_zone(opts)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    starts = Timezones.period_starts(now, zone)

    %SpendSummary{
      timezone: zone,
      today: period_for(starts.today),
      week: period_for(starts.week),
      month: period_for(starts.month)
    }
  end

  @spec resolve_zone(keyword()) :: String.t()
  defp resolve_zone(opts) do
    case Keyword.get(opts, :timezone) do
      zone when is_binary(zone) -> zone
      _other -> Timezones.default()
    end
  end

  @spec period_for(DateTime.t()) :: SpendSummary.period()
  defp period_for(since) do
    derived = since |> window_rows() |> Enum.map(&derive_spend_row/1)

    %{
      since: since,
      by_harness: bucket(derived, :harness),
      by_provider: bucket(derived, :provider)
    }
  end

  # Windowed (harness, provider, model) rollup — full granularity so estimates can be
  # derived per dimension, then folded up. NO hidden filter (include cleared rows).
  @spec window_rows(DateTime.t()) :: [map()]
  defp window_rows(since) do
    Repo.all(
      from l in AgentLog,
        where: not is_nil(l.usage) and l.inserted_at >= ^since,
        group_by: [l.harness, l.provider, l.model],
        select: %{
          harness: l.harness,
          provider: l.provider,
          model: l.model,
          actual_cost_usd: sum(fragment("(?->>'cost_usd')::numeric", l.usage)),
          input_tokens: fragment("COALESCE(SUM((?->>'input_tokens')::bigint), 0)", l.usage),
          output_tokens: fragment("COALESCE(SUM((?->>'output_tokens')::bigint), 0)", l.usage),
          cache_read: fragment("COALESCE(SUM((?->>'cache_read')::bigint), 0)", l.usage),
          cache_creation: fragment("COALESCE(SUM((?->>'cache_creation')::bigint), 0)", l.usage),
          event_count: count(l.id)
        }
    )
  end

  @typep derived_row :: %{
           harness: String.t(),
           provider: String.t(),
           actual_cost_usd: Decimal.t(),
           estimated_cost_usd: Decimal.t() | nil,
           estimated?: boolean(),
           input_tokens: non_neg_integer(),
           output_tokens: non_neg_integer(),
           event_count: non_neg_integer()
         }

  @spec derive_spend_row(map()) :: derived_row()
  defp derive_spend_row(row) do
    harness = row.harness || "unknown"
    provider = row.provider || ""

    {actual, estimated_cost, estimated?} =
      derive_costs(harness, row.model, row.actual_cost_usd, token_map(row))

    %{
      harness: harness,
      provider: provider,
      actual_cost_usd: actual,
      estimated_cost_usd: estimated_cost,
      estimated?: estimated?,
      input_tokens: to_int(row.input_tokens),
      output_tokens: to_int(row.output_tokens),
      event_count: to_int(row.event_count)
    }
  end

  @spec bucket([map()], :harness | :provider) :: [SpendRow.t()]
  defp bucket(derived, dimension) do
    derived
    |> Enum.group_by(&Map.fetch!(&1, dimension))
    |> Enum.map(fn {key, group} -> fold_bucket(key, group) end)
    |> Enum.sort_by(&spend_total/1, {:desc, Decimal})
  end

  @spec fold_bucket(String.t(), [map()]) :: SpendRow.t()
  defp fold_bucket(key, group) do
    init = %{actual: Decimal.new(0), estimated: nil, input: 0, output: 0, events: 0}

    acc =
      Enum.reduce(group, init, fn row, acc ->
        %{
          actual: Decimal.add(acc.actual, row.actual_cost_usd),
          estimated: add_estimate(acc.estimated, row.estimated_cost_usd),
          input: acc.input + row.input_tokens,
          output: acc.output + row.output_tokens,
          events: acc.events + row.event_count
        }
      end)

    %SpendRow{
      key: key,
      actual_cost_usd: acc.actual,
      estimated?: acc.estimated != nil,
      estimated_cost_usd: acc.estimated,
      input_tokens: acc.input,
      output_tokens: acc.output,
      event_count: acc.events
    }
  end

  @spec add_estimate(Decimal.t() | nil, Decimal.t() | nil) :: Decimal.t() | nil
  defp add_estimate(nil, nil), do: nil
  defp add_estimate(nil, %Decimal{} = estimate), do: estimate
  defp add_estimate(%Decimal{} = acc, nil), do: acc
  defp add_estimate(%Decimal{} = acc, %Decimal{} = estimate), do: Decimal.add(acc, estimate)

  @spec spend_total(SpendRow.t()) :: Decimal.t()
  defp spend_total(%SpendRow{actual_cost_usd: actual, estimated_cost_usd: estimated}) do
    Decimal.add(actual, estimated || Decimal.new(0))
  end

  # --- scope spend (issue-budget-guardrails: Budget.Guard reconciliation source) ---

  @doc """
  Actual + estimated spend (a single `Decimal`, hidden rows INCLUDED — real money) for
  one budget scope over an optional `since` window, used by `Budget.Guard` to reconcile
  its in-memory accumulators on boot/refresh so a restart cannot zero an over-cap budget.

    * `:global`       — all spend platform-wide.
    * `:orchestrator` — the orchestrator's own turns plus every worker it owns.
    * `:workflow`     — the run's `total_cost_usd` (no agent_logs link; `since` ignored).

  Unpriced (NULL-cost) rows contribute their *estimated* cost (so a runaway on an
  unpriced harness is still capped), preserving the nil-vs-0 convention via `derive_costs/5`.
  """
  @spec scope_spend(:global | :orchestrator | :workflow, String.t(), DateTime.t() | nil) ::
          Decimal.t()
  def scope_spend(:workflow, run_id, _since), do: Workflows.run_cost(run_id)

  def scope_spend(scope, scope_id, since) when scope in [:global, :orchestrator] do
    scope
    |> scope_window_rows(scope_id, since)
    |> Enum.map(&derive_spend_row/1)
    |> Enum.reduce(Decimal.new(0), fn row, acc ->
      Decimal.add(acc, Decimal.add(row.actual_cost_usd, row.estimated_cost_usd || Decimal.new(0)))
    end)
  end

  # Windowed (harness, provider, model) rollup filtered to a scope (NO hidden filter —
  # real money), mirroring `window_rows/1` so `derive_spend_row/1` applies unchanged.
  @spec scope_window_rows(:global | :orchestrator, String.t(), DateTime.t() | nil) :: [map()]
  defp scope_window_rows(scope, scope_id, since) do
    base =
      from l in AgentLog,
        where: not is_nil(l.usage),
        group_by: [l.harness, l.provider, l.model],
        select: %{
          harness: l.harness,
          provider: l.provider,
          model: l.model,
          actual_cost_usd: sum(fragment("(?->>'cost_usd')::numeric", l.usage)),
          input_tokens: fragment("COALESCE(SUM((?->>'input_tokens')::bigint), 0)", l.usage),
          output_tokens: fragment("COALESCE(SUM((?->>'output_tokens')::bigint), 0)", l.usage),
          cache_read: fragment("COALESCE(SUM((?->>'cache_read')::bigint), 0)", l.usage),
          cache_creation: fragment("COALESCE(SUM((?->>'cache_creation')::bigint), 0)", l.usage),
          event_count: count(l.id)
        }

    base
    |> scope_filter(scope, scope_id)
    |> since_filter(since)
    |> Repo.all()
  end

  @spec scope_filter(Ecto.Queryable.t(), :global | :orchestrator, String.t()) ::
          Ecto.Queryable.t()
  defp scope_filter(query, :global, _scope_id), do: query

  defp scope_filter(query, :orchestrator, id) do
    worker_ids = from(a in Agent, where: a.orchestrator_id == ^id, select: a.id)
    where(query, [l], l.orchestrator_id == ^id or l.agent_id in subquery(worker_ids))
  end

  @spec since_filter(Ecto.Queryable.t(), DateTime.t() | nil) :: Ecto.Queryable.t()
  defp since_filter(query, nil), do: query
  defp since_filter(query, %DateTime{} = since), do: where(query, [l], l.inserted_at >= ^since)

  # --- private: rollup mapping ---

  @spec to_rollup(map()) :: Rollup.t()
  defp to_rollup(row) do
    harness = row.harness || "unknown"
    provider = row.provider || ""

    {actual, estimated_cost, estimated?} =
      derive_costs(harness, row.model, row.actual_cost_usd, token_map(row))

    %Rollup{
      harness: harness,
      provider: provider,
      model: row.model,
      actual_cost_usd: actual,
      estimated?: estimated?,
      estimated_cost_usd: estimated_cost,
      input_tokens: to_int(row.input_tokens),
      output_tokens: to_int(row.output_tokens),
      event_count: to_int(row.event_count),
      last_used_at: row.last_used_at
    }
  end

  # A NULL SUM means NO priced rows existed (every `cost_usd` was NULL) — only then do we
  # attempt a catalog estimate. A non-NULL SUM (including a priced `0`) is a real billed
  # amount and never gets an estimate, keeping priced-at-zero distinct from unpriced.
  @spec derive_costs(String.t(), String.t() | nil, Decimal.t() | nil, Pricing.tokens()) ::
          {Decimal.t(), Decimal.t() | nil, boolean()}
  defp derive_costs(_harness, _model, %Decimal{} = actual, _tokens) do
    {actual, nil, false}
  end

  defp derive_costs(harness, model, nil, tokens) do
    case Pricing.derive(model, tokens, price_table_for(harness)) do
      nil -> {Decimal.new(0), nil, false}
      cost when is_float(cost) -> {Decimal.new(0), Decimal.from_float(cost), true}
    end
  end

  # Build the cache-aware token map `Pricing.derive/3` consumes from an aggregation row.
  @spec token_map(map()) :: Pricing.tokens()
  defp token_map(row) do
    %{
      input: to_int(row.input_tokens),
      output: to_int(row.output_tokens),
      cache_read: to_int(Map.get(row, :cache_read)),
      cache_creation: to_int(Map.get(row, :cache_creation))
    }
  end

  @spec to_int(term()) :: non_neg_integer()
  defp to_int(value) when is_integer(value), do: value
  defp to_int(%Decimal{} = value), do: Decimal.to_integer(value)
  defp to_int(_value), do: 0

  @spec filter_hidden(Ecto.Queryable.t(), boolean()) :: Ecto.Queryable.t()
  defp filter_hidden(query, true), do: query
  defp filter_hidden(query, false), do: where(query, [l], l.hidden == false)

  @spec clamp_limit(term()) :: pos_integer()
  defp clamp_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_rollup_limit)
  defp clamp_limit(_limit), do: @default_rollup_limit

  # --- private: catalog/seed helpers ---

  # Build a `Pricing.Rate` from a catalog row, falling back input↔output when only one
  # column is populated; nil when neither rate is present.
  @spec rate_for(ModelPrice.t()) :: Pricing.Rate.t() | nil
  defp rate_for(%ModelPrice{input_price_per_mtok: input, output_price_per_mtok: output}) do
    case {decimal_to_float(input), decimal_to_float(output)} do
      {nil, nil} -> nil
      {in_rate, nil} -> %Pricing.Rate{input: in_rate, output: in_rate}
      {nil, out_rate} -> %Pricing.Rate{input: out_rate, output: out_rate}
      {in_rate, out_rate} -> %Pricing.Rate{input: in_rate, output: out_rate}
    end
  end

  @spec decimal_to_float(Decimal.t() | nil) :: float() | nil
  defp decimal_to_float(%Decimal{} = value), do: Decimal.to_float(value)
  defp decimal_to_float(_value), do: nil

  @spec seed_one(ModelPrice.t() | nil, map(), non_neg_integer()) :: non_neg_integer()
  defp seed_one(existing, attrs, acc) do
    params = attrs |> stringify_keys() |> Map.put("source", "seed")
    record = existing || %ModelPrice{}

    case record |> ModelPrice.changeset(params) |> Repo.insert_or_update() do
      {:ok, _price} -> acc + 1
      {:error, _changeset} -> acc
    end
  end

  @spec load_seed_rows() :: [map()]
  defp load_seed_rows do
    path = Application.app_dir(:repo_builder, "priv/repo/pricing_seeds.exs")
    {rows, _binding} = Code.eval_file(path)
    rows
  end

  @spec normalize_provider(String.t() | nil) :: String.t()
  defp normalize_provider(nil), do: ""
  defp normalize_provider(provider) when is_binary(provider), do: provider

  @spec stringify_keys(map()) :: %{optional(String.t()) => term()}
  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
