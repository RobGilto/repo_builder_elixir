defmodule RepoBuilder.Workflows.WorkflowRun do
  @moduledoc """
  One row per ADW execution — the SOURCE OF TRUTH for run position (BUILD_PROMPT.md
  §7/§8). Every deterministic transition is persisted here before the next step.

  `total_cost_usd` is nullable: `NULL` = unpriced (never defaulted to 0).
  """
  use RepoBuilder.Schema

  import Ecto.Changeset

  @type status :: :queued | :running | :succeeded | :failed | :cancelled

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          workflow_id: Ecto.UUID.t() | nil,
          status: status() | nil,
          current_step: String.t() | nil,
          artifacts: map(),
          step_states: map(),
          total_cost_usd: Decimal.t() | nil,
          hidden: boolean(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @statuses ~w(queued running succeeded failed cancelled)a

  schema "workflow_runs" do
    field :workflow_id, :binary_id
    field :status, Ecto.Enum, values: @statuses, default: :queued
    field :current_step, :string
    field :artifacts, :map, default: %{}
    # Per-step observability: %{step_name => %{"status", "started_at", "finished_at",
    # "cost_usd"}}. Authoritative per-step view written at each transition by BOTH
    # the live Runner and the durable StepWorker. See `Workflows.run_progress/1`.
    field :step_states, :map, default: %{}
    field :total_cost_usd, :decimal
    # Soft-hide for the console CLEAR action on finished runs: hidden runs are skipped
    # by the default ADWS seed but kept in the DB (revealed by the "show hidden" toggle).
    field :hidden, :boolean, default: false
    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(run, params) do
    run
    |> cast(params, [
      :workflow_id,
      :status,
      :current_step,
      :artifacts,
      :step_states,
      :total_cost_usd
    ])
    |> validate_required([:workflow_id, :status])
    |> foreign_key_constraint(:workflow_id)
  end
end
