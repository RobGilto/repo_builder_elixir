defmodule RepoBuilder.Orchestrator.Reflection do
  @moduledoc """
  One verbal lesson the orchestrator learned from a completed/escalated goal (self-healing
  Phase 5 — Reflexion). Scoped to a `project_id` (+ the `goal` it came from) so the next run
  for that project can be primed with the last N lessons. DB access goes through
  `RepoBuilder.Orchestrator.Reflections`.
  """
  use RepoBuilder.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          project_id: Ecto.UUID.t() | nil,
          orchestrator_id: Ecto.UUID.t() | nil,
          goal: String.t() | nil,
          lesson: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "orchestrator_reflections" do
    field :project_id, :binary_id
    field :orchestrator_id, :binary_id
    field :goal, :string
    field :lesson, :string
    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(reflection, params) do
    reflection
    |> cast(params, [:project_id, :orchestrator_id, :goal, :lesson])
    |> validate_required([:lesson])
    |> validate_length(:lesson, min: 1, max: 2_000)
  end
end
