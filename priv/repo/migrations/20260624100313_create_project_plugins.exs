defmodule RepoBuilder.Repo.Migrations.CreateProjectPlugins do
  use Ecto.Migration

  @moduledoc """
  Per-project plugin activation (the agentic plugin system foundation). A NULLABLE
  `project_id` (nil = "the platform itself", the back-compatible default) joins an
  installed plugin to a project. Switching the orchestrator's project recomputes the
  effective contribution set from the enabled rows, ordered by `priority`.

  Postgres treats NULLs as distinct in unique indexes, so uniqueness is enforced with
  two partial indexes — one for the platform (NULL) scope, one for project scopes.
  """

  def change do
    create table(:project_plugins, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id,
          references(:projects, type: :binary_id, on_delete: :delete_all)

      add :plugin_id, :string, null: false
      add :version, :string
      add :enabled, :boolean, null: false, default: true
      add :priority, :integer, null: false, default: 0
      add :config, :map, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create index(:project_plugins, [:project_id])
    create index(:project_plugins, [:plugin_id])

    create unique_index(:project_plugins, [:project_id, :plugin_id],
             where: "project_id IS NOT NULL",
             name: :project_plugins_project_plugin_index
           )

    create unique_index(:project_plugins, [:plugin_id],
             where: "project_id IS NULL",
             name: :project_plugins_platform_plugin_index
           )
  end
end
