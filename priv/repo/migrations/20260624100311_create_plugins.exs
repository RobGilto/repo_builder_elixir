defmodule RepoBuilder.Repo.Migrations.CreatePlugins do
  use Ecto.Migration

  @moduledoc """
  Durable record of installed plugins (the agentic plugin system foundation).
  One row per installed `<id>@<version>` package unpacked under `agentic_plugins/`.
  binary_id PK, JSONB manifest, status as a validated string. Fully additive.
  """

  def change do
    create table(:plugins, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :plugin_id, :string, null: false
      add :version, :string, null: false
      add :source, :string
      add :install_path, :string, null: false
      add :manifest, :map, default: %{}
      add :checksum, :string
      add :status, :string, null: false, default: "installed"
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:plugins, [:plugin_id, :version])
    create index(:plugins, [:plugin_id])
  end
end
