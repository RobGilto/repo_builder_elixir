defmodule RepoBuilder.Repo.Migrations.CreateForgeArtifacts do
  use Ecto.Migration

  @moduledoc """
  Durable record of a forge request (forge-meta-artifact-generation): "this project
  asked for this kind of tool, with this spec." binary_id PK; `project_id` nullable
  (`nil` = platform-wide); `kind` validated vs the `Forge.Generator` registry at the
  changeset boundary; `status` an Ecto.Enum string; `error` JSONB. Fully additive.
  """

  def change do
    create table(:forge_artifacts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, :binary_id
      add :kind, :string, null: false
      add :spec, :text, null: false
      add :status, :string, null: false, default: "requested"
      add :output_path, :string
      add :plugin_id, :string
      add :workflow_run_id, :binary_id
      add :error, :map
      timestamps(type: :utc_datetime_usec)
    end

    create index(:forge_artifacts, [:project_id])
    create index(:forge_artifacts, [:plugin_id])
  end
end
