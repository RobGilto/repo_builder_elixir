defmodule RepoBuilder.Repo.Migrations.CreateProjectStackLayers do
  use Ecto.Migration

  @moduledoc """
  Per-project stack composition (stack-layers subsystem): a join row selecting one
  catalog layer for a project. Mirrors `project_plugins` — both FKs cascade on delete,
  and `(project_id, stack_layer_id)` is unique so a layer is selected at most once per
  project. The enabled selection drives the worker stack contract.
  """

  def change do
    create table(:project_stack_layers, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id,
          references(:projects, type: :binary_id, on_delete: :delete_all),
          null: false

      add :stack_layer_id,
          references(:stack_layers, type: :binary_id, on_delete: :delete_all),
          null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:project_stack_layers, [:project_id])
    create index(:project_stack_layers, [:stack_layer_id])
    create unique_index(:project_stack_layers, [:project_id, :stack_layer_id])
  end
end
