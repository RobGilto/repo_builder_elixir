defmodule RepoBuilder.Orchestrator.ProgressEntry do
  @moduledoc """
  One per-turn Progress Ledger entry (self-healing orchestrator, Phase 3 — Magentic-One).

  Records, for one orchestrator turn against a `TaskLedger`: are we `satisfied` (done)?
  `on_track`? `looping`? did we `made_progress`? and who acts next (`next_agent`) with what
  `next_instruction`, plus a free-text `summary`. `turn_agent_id` ties the entry to the turn
  that produced it. DB access goes through `RepoBuilder.Orchestrator.Ledgers`.
  """
  use RepoBuilder.Schema

  import Ecto.Changeset

  alias RepoBuilder.Orchestrator.TaskLedger

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          task_ledger_id: Ecto.UUID.t() | nil,
          turn_agent_id: String.t() | nil,
          satisfied: boolean(),
          on_track: boolean(),
          looping: boolean(),
          made_progress: boolean(),
          next_agent: String.t() | nil,
          next_instruction: String.t() | nil,
          summary: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "progress_entries" do
    belongs_to :task_ledger, TaskLedger, foreign_key: :task_ledger_id

    field :turn_agent_id, :string
    field :satisfied, :boolean, default: false
    field :on_track, :boolean, default: true
    field :looping, :boolean, default: false
    field :made_progress, :boolean, default: false
    field :next_agent, :string
    field :next_instruction, :string
    field :summary, :string

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(entry, params) do
    entry
    |> cast(params, [
      :task_ledger_id,
      :turn_agent_id,
      :satisfied,
      :on_track,
      :looping,
      :made_progress,
      :next_agent,
      :next_instruction,
      :summary
    ])
    |> validate_required([:task_ledger_id])
  end
end
