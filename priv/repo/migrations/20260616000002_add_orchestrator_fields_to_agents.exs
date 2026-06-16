defmodule RepoBuilder.Repo.Migrations.AddOrchestratorFieldsToAgents do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      # Which orchestrator owns this worker (nullable: legacy/manual agents have none).
      add :orchestrator_id, references(:orchestrators, type: :binary_id, on_delete: :nilify_all)
      # Resumable CLI session id for the worker; nil until first dispatch.
      add :session_id, :string
      add :model, :string
      add :system_prompt, :text
    end

    create index(:agents, [:orchestrator_id])

    # The legacy global unique index on :name becomes PARTIAL — it now guards only
    # manual (orchestrator-less) agents, so the same worker name may exist under
    # different orchestrators. Same constraint name ⇒ Agent.changeset's
    # `unique_constraint(:name)` keeps mapping to it.
    drop unique_index(:agents, [:name])

    create unique_index(:agents, [:name],
             where: "orchestrator_id IS NULL",
             name: :agents_name_index
           )

    # A worker name is unique PER orchestrator.
    create unique_index(:agents, [:orchestrator_id, :name],
             name: :agents_orchestrator_id_name_index
           )
  end
end
