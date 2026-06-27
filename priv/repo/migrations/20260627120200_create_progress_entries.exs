defmodule RepoBuilder.Repo.Migrations.CreateProgressEntries do
  use Ecto.Migration

  @moduledoc """
  The per-turn Progress Ledger (self-healing orchestrator, Phase 3 — Magentic-One). One row
  per orchestrator turn against a Task Ledger, recording the answers to: are we satisfied?
  on track? looping? did we make progress? who acts next, with what instruction? The drive
  loop (Phase 4) reconciles each new entry against the prior to drive the stall ladder.
  FK to the task ledger (delete_all); `turn_agent_id` links the entry to the turn that
  produced it. binary_id PK; additive.
  """

  def change do
    create table(:progress_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :task_ledger_id,
          references(:task_ledgers, type: :binary_id, on_delete: :delete_all),
          null: false

      # The orchestrator turn's `agent_id` ("orch-<id>-<n>"); nil for tool-recorded entries
      # that don't carry it (the auto-record backstop stamps it).
      add :turn_agent_id, :string
      add :satisfied, :boolean, null: false, default: false
      add :on_track, :boolean, null: false, default: true
      add :looping, :boolean, null: false, default: false
      add :made_progress, :boolean, null: false, default: false
      add :next_agent, :string
      add :next_instruction, :text
      add :summary, :text
      timestamps(type: :utc_datetime_usec)
    end

    create index(:progress_entries, [:task_ledger_id])
  end
end
