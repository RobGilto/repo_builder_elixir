defmodule RepoBuilder.Logs.Usage do
  @moduledoc """
  Embedded usage value object (BUILD_PROMPT.md §8).

  This is where the canonical float `cost_usd` (§4.1) crosses the float→Decimal
  boundary. The nil-vs-0.0 distinction is preserved: an unpriced event's cost is
  `nil` → SQL NULL; a priced-at-zero event stores `Decimal`-0. Tokens are stored
  as integers.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{
          input_tokens: non_neg_integer() | nil,
          output_tokens: non_neg_integer() | nil,
          cache_read: non_neg_integer() | nil,
          cache_creation: non_neg_integer() | nil,
          cost_usd: Decimal.t() | nil
        }

  @primary_key false
  embedded_schema do
    field :input_tokens, :integer
    field :output_tokens, :integer
    field :cache_read, :integer
    field :cache_creation, :integer
    field :cost_usd, :decimal
  end

  @fields [:input_tokens, :output_tokens, :cache_read, :cache_creation, :cost_usd]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(usage, params) do
    cast(usage, params, @fields)
  end

  @doc """
  Convert a canonical float cost into a `Decimal` at the persistence boundary.
  `nil` (unpriced) stays `nil` → SQL NULL; a float (including `0.0`) becomes a
  `Decimal`. Never defaults an unpriced cost to zero.
  """
  @spec cost_to_decimal(float() | nil) :: Decimal.t() | nil
  def cost_to_decimal(nil), do: nil
  def cost_to_decimal(cost) when is_float(cost), do: Decimal.from_float(cost)
end
