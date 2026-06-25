defmodule RepoBuilder.Repo.Migrations.CreateProjectSecrets do
  use Ecto.Migration

  @moduledoc """
  Per-project encrypted secrets vault (issue-per-project-encrypted-secrets-vault). A
  NULLABLE `project_id` (nil = "the platform itself", the back-compatible default) scopes
  each secret. `ciphertext` is the Base64 AES-256-GCM blob — the plaintext NEVER touches
  the DB; `last_four` is a masked UI hint only.

  Postgres treats NULLs as distinct in unique indexes, so uniqueness is enforced with two
  partial indexes — one for project scopes, one for the platform (NULL) scope.
  """

  def change do
    create table(:project_secrets, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id,
          references(:projects, type: :binary_id, on_delete: :delete_all)

      add :name, :string, null: false
      add :ciphertext, :string, null: false
      add :last_four, :string
      timestamps(type: :utc_datetime_usec)
    end

    create index(:project_secrets, [:project_id])

    create unique_index(:project_secrets, [:project_id, :name],
             where: "project_id IS NOT NULL",
             name: :project_secrets_project_name_index
           )

    create unique_index(:project_secrets, [:name],
             where: "project_id IS NULL",
             name: :project_secrets_platform_name_index
           )
  end
end
