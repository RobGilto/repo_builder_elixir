defmodule RepoBuilder.Orchestrator.Workstream do
  @moduledoc """
  A Workstream — the orchestrator's top-level durable unit of work and external memory
  (orchestration-adw-loop). One row per independent objective an orchestrator is driving:
  its `title`, `goal`, `definition_of_done`, a lifecycle `status`
  (`running|blocked|done|abandoned`), a `stall_count` the scheduler bumps when a turn makes
  no advance, a `current_phase_position` pointer, and an ordered `has_many :phases` Pipeline.

  Unlike the single-goal `TaskLedger`, an orchestrator may hold MULTIPLE `:running`
  workstreams at once (the parallel-workstream scheduler) — there is no "one active"
  constraint. Each Workstream is a complete REHYDRATION RECORD: nothing important lives only
  in the LLM window, so the brain can `compact_self` and re-read its workstreams to continue.
  DB access goes through `RepoBuilder.Orchestrator.Workstreams` (the only `Repo` caller).
  """
  use RepoBuilder.Schema

  import Ecto.Changeset

  alias RepoBuilder.Orchestrator.WorkstreamPhase

  @type status :: :running | :blocked | :done | :abandoned

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          orchestrator_id: Ecto.UUID.t() | nil,
          title: String.t() | nil,
          goal: String.t() | nil,
          definition_of_done: String.t() | nil,
          status: status(),
          stall_count: non_neg_integer(),
          current_phase_position: non_neg_integer(),
          focus: String.t() | nil,
          focus_set_at: DateTime.t() | nil,
          phases: [WorkstreamPhase.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @statuses [:running, :blocked, :done, :abandoned]

  @doc "The lifecycle status values."
  @spec statuses() :: [status(), ...]
  def statuses, do: @statuses

  schema "orchestrator_workstreams" do
    field :orchestrator_id, :binary_id
    field :title, :string
    field :goal, :string
    field :definition_of_done, :string
    field :status, Ecto.Enum, values: @statuses, default: :running
    field :stall_count, :integer, default: 0
    field :current_phase_position, :integer, default: 0
    # The single concrete thing this workstream is focused on right now (focus discipline).
    field :focus, :string
    field :focus_set_at, :utc_datetime_usec

    has_many :phases, WorkstreamPhase,
      foreign_key: :workstream_id,
      preload_order: [asc: :position]

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(workstream, params) do
    workstream
    |> cast(params, [
      :orchestrator_id,
      :title,
      :goal,
      :status,
      :definition_of_done,
      :stall_count,
      :current_phase_position,
      :focus,
      :focus_set_at
    ])
    |> validate_required([:orchestrator_id, :title, :goal])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:stall_count, greater_than_or_equal_to: 0)
    |> validate_number(:current_phase_position, greater_than_or_equal_to: 0)
    |> validate_length(:focus, max: 2_000)
  end
end
