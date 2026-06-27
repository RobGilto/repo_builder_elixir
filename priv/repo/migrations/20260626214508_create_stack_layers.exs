defmodule RepoBuilder.Repo.Migrations.CreateStackLayers do
  use Ecto.Migration

  @moduledoc """
  Operator-CRUDable catalog of typed tech-stack layers (stack-layers subsystem). Each
  row is one composable layer — `(layer_type, name)` unique — carrying the `language`
  and worker-facing `reasoning`/guardrails that compose into a project's stack contract.
  binary_id PK; fully additive.
  """

  def change do
    create table(:stack_layers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :layer_type, :string, null: false
      add :name, :string, null: false
      add :language, :string, null: false
      add :reasoning, :text
      add :enabled, :boolean, null: false, default: true
      add :source, :string, null: false, default: "seed"
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:stack_layers, [:layer_type, :name])
  end
end
