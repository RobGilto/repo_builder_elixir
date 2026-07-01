defmodule RepoBuilder.Repo.Migrations.CreateExternalApis do
  use Ecto.Migration

  @moduledoc """
  Registered external API / MCP providers (issue-external-api-mcp-provisioning). A
  durable, two-scope registry the orchestrator transfers (never uses itself) to workers
  on demand. A NULLABLE `project_id` scopes each registration: `nil` = user/platform
  scope ("all orchestrators"), a concrete id = project scope ("the project
  orchestrator"). Mirrors `create_project_secrets.exs`.

  Auth is a REFERENCE to a vault secret name (`secret_name`) — the literal token NEVER
  touches this table. The `${SECRET}` placeholder written into a worker's `.mcp.json`
  expands from the worker's child env at CLI read time.

  Postgres treats NULLs as distinct in unique indexes, so name-uniqueness is enforced
  with two partial indexes — one per project scope, one for the platform (NULL) scope.
  """

  def change do
    create table(:external_apis, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :name, :string, null: false
      add :provider, :string

      add :transport, :string, null: false
      add :url, :string
      add :command, :string
      add :args, {:array, :string}, default: [], null: false

      add :auth_scheme, :string, null: false, default: "none"
      add :auth_header, :string
      add :secret_name, :string

      add :description, :string
      add :instructions, :text
      add :doc_urls, {:array, :string}, default: [], null: false
      add :allowed_tools, {:array, :string}, default: [], null: false

      add :status, :string, null: false, default: "active"
      add :metadata, :map, default: %{}, null: false

      add :project_id,
          references(:projects, type: :binary_id, on_delete: :delete_all)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:external_apis, [:project_id])

    create unique_index(:external_apis, [:project_id, :name],
             where: "project_id IS NOT NULL",
             name: :external_apis_project_name_index
           )

    create unique_index(:external_apis, [:name],
             where: "project_id IS NULL",
             name: :external_apis_platform_name_index
           )
  end
end
