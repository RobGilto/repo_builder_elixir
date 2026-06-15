defmodule RepoBuilder.Repo.Migrations.CreateChat do
  use Ecto.Migration

  def change do
    create table(:chat, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :role, :string, null: false
      add :content, :text, null: false
      add :usage, :map
      timestamps(type: :utc_datetime_usec)
    end

    create index(:chat, [:agent_id])
  end
end
