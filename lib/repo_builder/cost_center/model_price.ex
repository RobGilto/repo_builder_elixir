defmodule RepoBuilder.CostCenter.ModelPrice do
  @moduledoc """
  One operator-editable per-model rate in the price catalog (BUILD_PROMPT.md §8),
  keyed by `(harness, provider, model)`. Prices are USD per million tokens, stored as
  `Decimal` (rule 10 — money never floats). `provider` is normalized to `""` (never
  `nil`) so the `(harness, provider, model)` unique key stays stable.

  `source` records provenance: `:seed` rows are catalog defaults (clobbered on
  re-seed); `:manual` rows are operator edits (preserved across re-seed).
  """
  use RepoBuilder.Schema

  import Ecto.Changeset

  alias RepoBuilder.Harness.Registry

  @type source :: :seed | :manual

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          harness: String.t() | nil,
          provider: String.t(),
          model: String.t() | nil,
          input_price_per_mtok: Decimal.t() | nil,
          output_price_per_mtok: Decimal.t() | nil,
          source: source(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @unique_index :model_prices_harness_provider_model_index

  schema "model_prices" do
    field :harness, :string
    field :provider, :string, default: ""
    field :model, :string
    field :input_price_per_mtok, :decimal
    field :output_price_per_mtok, :decimal
    field :source, Ecto.Enum, values: [:seed, :manual], default: :seed
    timestamps()
  end

  @fields [
    :harness,
    :provider,
    :model,
    :input_price_per_mtok,
    :output_price_per_mtok,
    :source
  ]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(price, params) do
    price
    |> cast(params, @fields)
    |> normalize_provider()
    |> validate_required([:harness, :model])
    |> validate_inclusion(:harness, Registry.known())
    |> validate_number(:input_price_per_mtok, greater_than_or_equal_to: 0)
    |> validate_number(:output_price_per_mtok, greater_than_or_equal_to: 0)
    |> unique_constraint([:harness, :provider, :model], name: @unique_index)
  end

  # A nil/absent provider becomes `""` so the unique key `(harness, provider, model)`
  # is stable (SQL NULLs are distinct, which would break the upsert conflict target).
  @spec normalize_provider(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  defp normalize_provider(changeset) do
    case get_field(changeset, :provider) do
      nil -> put_change(changeset, :provider, "")
      _provider -> changeset
    end
  end
end
