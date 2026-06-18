defmodule RepoBuilder.Repo.Migrations.CreateModelPrices do
  use Ecto.Migration

  @moduledoc """
  The operator-editable price catalog (BUILD_PROMPT.md §8). Reference data the operator
  wants pre-populated (seeded from `priv/repo/pricing_seeds.exs`) and then editable; it
  becomes the override layer the `pi` (and any other unpriced) harness consults to derive
  `cost_usd`, with `config/config.exs` `price_table` as the fallback.

  `provider` defaults to `""` (empty = harness-default/unspecified) rather than NULL so
  the unique index + upsert `conflict_target` stay clean (SQL NULLs are distinct).
  """

  def change do
    create table(:model_prices, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :harness, :string, null: false
      add :provider, :string, null: false, default: ""
      add :model, :string, null: false
      add :input_price_per_mtok, :decimal
      add :output_price_per_mtok, :decimal
      # "seed" (catalog default, clobbered on re-seed) | "manual" (operator edit, preserved).
      add :source, :string, null: false, default: "seed"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:model_prices, [:harness, :provider, :model])
  end
end
