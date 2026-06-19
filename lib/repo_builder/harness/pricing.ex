defmodule RepoBuilder.Harness.Pricing do
  @moduledoc """
  Derive per-run cost for harnesses that do NOT report USD in their stream (pi),
  from a per-model price table (BUILD_PROMPT.md §4.3/§6).

  The estimate is **cache-aware**: input and output tokens are priced at their own
  per-Mtok rates, and the cached-prompt tokens — `cache_read` and `cache_creation` —
  are billed relative to the input rate via Anthropic's published multipliers
  (`@cache_read_multiplier`, `@cache_creation_multiplier`). In a resumed Claude session
  `cache_read` dominates the prompt, so excluding it (the old behaviour) made the
  estimate appear frozen while the displayed token count grew.

      cost = (input * rate.input
              + output * rate.output
              + cache_read * rate.input * 0.1
              + cache_creation * rate.input * 1.25) / 1e6

  An UNPRICED model returns `nil` (and warns) — it is NEVER defaulted to `0.0`. The
  canonical `Usage.cost_usd` therefore stays `nil` (distinct from a priced `0.0`),
  preserving the NULL-vs-0 distinction all the way to persistence (§8).

  A legacy flat `price_table` value (`%{model => number()}`, e.g. pi's
  `glm-4.6 => 0.6`) keeps working: a bare number is treated as both the input and the
  output rate, so the cache multipliers still apply against it.
  """
  require Logger

  defmodule Rate do
    @moduledoc "Separate input/output per-Mtok USD rates for one model."
    use TypedStruct

    typedstruct enforce: true do
      field :input, float()
      field :output, float()
    end
  end

  # Anthropic prompt-caching pricing relative to the input rate: a cache READ is billed
  # at ~0.1x the input rate, a cache CREATION (write) at ~1.25x. Named here so the
  # multipliers are auditable and adjustable in one place.
  @cache_read_multiplier 0.1
  @cache_creation_multiplier 1.25

  @typedoc "Per-model price: either a `Rate.t()` (separate in/out) or a flat combined number."
  @type price_table :: %{optional(String.t()) => Rate.t() | number()}

  @typedoc "The token counts priced by `derive/3`. Cache tokens are nil-safe/optional."
  @type tokens :: %{
          required(:input) => non_neg_integer(),
          required(:output) => non_neg_integer(),
          optional(:cache_read) => non_neg_integer() | nil,
          optional(:cache_creation) => non_neg_integer() | nil
        }

  @doc "Derive cost in USD, or `nil` when the model is unknown/unpriced."
  @spec derive(String.t() | nil, tokens(), price_table()) :: float() | nil
  def derive(model, tokens, price_table) do
    case lookup(model, price_table) do
      nil ->
        if is_binary(model),
          do: Logger.warning("no price for model #{inspect(model)} — cost left nil")

        nil

      %Rate{} = rate ->
        input = nz(tokens[:input])
        output = nz(tokens[:output])
        cache_read = nz(tokens[:cache_read])
        cache_creation = nz(tokens[:cache_creation])

        (input * rate.input + output * rate.output +
           cache_read * rate.input * @cache_read_multiplier +
           cache_creation * rate.input * @cache_creation_multiplier) / 1_000_000
    end
  end

  @spec lookup(String.t() | nil, price_table()) :: Rate.t() | nil
  defp lookup(model, price_table) when is_binary(model) and is_map(price_table) do
    case Map.get(price_table, model) do
      %Rate{} = rate -> rate
      n when is_number(n) -> %Rate{input: n / 1, output: n / 1}
      _ -> nil
    end
  end

  defp lookup(_model, _price_table), do: nil

  @spec nz(non_neg_integer() | nil) :: non_neg_integer()
  defp nz(n) when is_integer(n) and n >= 0, do: n
  defp nz(_), do: 0
end
