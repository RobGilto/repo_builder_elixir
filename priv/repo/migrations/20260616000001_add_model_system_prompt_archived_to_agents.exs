defmodule RepoBuilder.Repo.Migrations.AddModelSystemPromptArchivedToAgents do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :model, :string
      add :system_prompt, :text
      add :archived, :boolean, null: false, default: false
    end

    # Partial index keeps the default (non-archived) list fast.
    create index(:agents, [:archived], where: "archived = false", name: :agents_active_index)
  end
end
