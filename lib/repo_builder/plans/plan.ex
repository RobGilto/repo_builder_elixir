defmodule RepoBuilder.Plans.Plan do
  @moduledoc """
  A durable Plan artifact (agentic-layer adaptor, Phase 6): the output of the
  Planning-Mode Wizard tied to a project — the goal, chosen workflow type, the
  resolved (stack-correct) steps, and the cost/context estimate. Persisted so a plan is
  a shareable, durable artifact (mirroring this HTML plan's lifecycle), and linked to
  its `workflow_run` once launched.

  `resolved_steps`/`estimate` are JSONB maps. `status` is a closed `Ecto.Enum`.
  """
  use RepoBuilder.Schema

  import Ecto.Changeset

  @type status :: :draft | :launched | :failed

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          project_id: Ecto.UUID.t() | nil,
          goal: String.t() | nil,
          workflow_type: String.t() | nil,
          resolved_steps: map(),
          estimate: map(),
          status: status(),
          workflow_run_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @statuses ~w(draft launched failed)a

  schema "plans" do
    field :project_id, :binary_id
    field :goal, :string
    field :workflow_type, :string
    # Stored as %{"steps" => [...]} (Ecto :map wants a map, not a bare list).
    field :resolved_steps, :map, default: %{}
    field :estimate, :map, default: %{}
    field :status, Ecto.Enum, values: @statuses, default: :draft
    field :workflow_run_id, :binary_id
    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(plan, params) do
    plan
    |> cast(params, [
      :project_id,
      :goal,
      :workflow_type,
      :resolved_steps,
      :estimate,
      :status,
      :workflow_run_id
    ])
    |> validate_required([:project_id, :goal, :workflow_type])
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:workflow_run_id)
  end
end
