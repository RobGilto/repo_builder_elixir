defmodule RepoBuilder.Orchestrator.TaskLedger do
  @moduledoc """
  The durable Task Ledger (self-healing orchestrator, Phase 3 — Magentic-One dual-ledger).

  One row per goal an orchestrator drives: the objective (`goal`), the definition-of-done it
  is verified against, known `facts`, working `guesses`, a jsonb step `plan`, a lifecycle
  `status`, and a `stall_count` the drive loop bumps when a turn makes no progress. An
  orchestrator has at most ONE `:active` ledger at a time (partial-unique index). DB access
  goes through `RepoBuilder.Orchestrator.Ledgers` (the only `Repo` caller).
  """
  use RepoBuilder.Schema

  import Ecto.Changeset

  alias RepoBuilder.Orchestrator.ProgressEntry

  @type status :: :active | :done | :escalated | :abandoned

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          orchestrator_id: Ecto.UUID.t() | nil,
          project_id: Ecto.UUID.t() | nil,
          goal: String.t() | nil,
          definition_of_done: String.t() | nil,
          facts: String.t() | nil,
          guesses: String.t() | nil,
          plan: [map()],
          status: status(),
          stall_count: non_neg_integer(),
          focus: String.t() | nil,
          focus_set_at: DateTime.t() | nil,
          progress_entries: [ProgressEntry.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @statuses [:active, :done, :escalated, :abandoned]

  @doc "The lifecycle status values, in order."
  @spec statuses() :: [status(), ...]
  def statuses, do: @statuses

  schema "task_ledgers" do
    field :orchestrator_id, :binary_id
    field :project_id, :binary_id
    field :goal, :string
    field :definition_of_done, :string
    field :facts, :string
    field :guesses, :string
    # jsonb list of `%{"step" => ..., "status" => ...}` step maps.
    field :plan, {:array, :map}, default: []
    field :status, Ecto.Enum, values: @statuses, default: :active
    field :stall_count, :integer, default: 0
    # The single concrete thing the orchestrator is focused on right now (focus discipline).
    field :focus, :string
    field :focus_set_at, :utc_datetime_usec

    has_many :progress_entries, ProgressEntry, foreign_key: :task_ledger_id

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(ledger, params) do
    ledger
    |> cast(params, [
      :orchestrator_id,
      :project_id,
      :goal,
      :definition_of_done,
      :facts,
      :guesses,
      :plan,
      :status,
      :stall_count,
      :focus,
      :focus_set_at
    ])
    |> validate_required([:orchestrator_id, :goal, :definition_of_done])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:stall_count, greater_than_or_equal_to: 0)
    |> validate_length(:focus, max: 2_000)
  end
end
