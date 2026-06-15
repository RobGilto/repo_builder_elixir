defmodule RepoBuilder.Harness.Pricing do
  @moduledoc """
  Derive per-run cost for harnesses that do NOT report USD in their stream (pi),
  from a per-model price table (BUILD_PROMPT.md §4.3/§6).

  `cost = (input_tokens + output_tokens) / 1e6 * price_per_mtok`.

  An UNPRICED model returns `nil` (and warns) — it is NEVER defaulted to `0.0`. The
  canonical `Usage.cost_usd` therefore stays `nil` (distinct from a priced `0.0`),
  preserving the NULL-vs-0 distinction all the way to persistence (§8).
  """
  require Logger

  @typedoc "Per-model price in USD per million tokens."
  @type price_table :: %{optional(String.t()) => number()}

  @doc "Derive cost in USD, or `nil` when the model is unknown/unpriced."
  @spec derive(String.t() | nil, non_neg_integer(), non_neg_integer(), price_table()) ::
          float() | nil
  def derive(model, input_tokens, output_tokens, price_table) do
    case lookup(model, price_table) do
      nil ->
        if is_binary(model),
          do: Logger.warning("no price for model #{inspect(model)} — cost left nil")

        nil

      price ->
        (input_tokens + output_tokens) / 1_000_000 * price
    end
  end

  @spec lookup(String.t() | nil, price_table()) :: number() | nil
  defp lookup(model, price_table) when is_binary(model) and is_map(price_table) do
    case Map.get(price_table, model) do
      price when is_number(price) -> price
      _ -> nil
    end
  end

  defp lookup(_model, _price_table), do: nil
end
