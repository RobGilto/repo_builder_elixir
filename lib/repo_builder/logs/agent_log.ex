defmodule RepoBuilder.Logs.AgentLog do
  @moduledoc """
  One row per canonical event for an agent/session (BUILD_PROMPT.md §8).

  `payload` is the SECRET-REDACTED `raw` wire frame (the in-flight broadcast keeps
  the full `raw`; only this persisted copy is scrubbed, §4.1). `usage` is the
  embedded `Usage` value object (nullable).
  """
  use RepoBuilder.Schema

  import Ecto.Changeset

  alias RepoBuilder.Logs.Usage

  @type event_type ::
          :session_started
          | :text_delta
          | :tool_call
          | :tool_result
          | :usage
          | :status
          | :done
          | :error

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          agent_id: Ecto.UUID.t() | nil,
          orchestrator_id: Ecto.UUID.t() | nil,
          workflow_run_id: Ecto.UUID.t() | nil,
          project_id: Ecto.UUID.t() | nil,
          session_id: String.t() | nil,
          event_type: event_type() | nil,
          harness: String.t() | nil,
          provider: String.t() | nil,
          model: String.t() | nil,
          payload: map(),
          usage: Usage.t() | nil,
          hidden: boolean(),
          log_no: integer() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @event_types ~w(session_started text_delta tool_call tool_result usage status done error)a

  schema "agent_logs" do
    field :agent_id, :binary_id
    # Orchestrator-scoped persistence (issue-d): set instead of agent_id for an
    # orchestrator turn's events. Exactly one of the two is present (app-enforced).
    field :orchestrator_id, :binary_id
    # Workflow-step-scoped persistence (issue-custom-adw-observability): set instead of
    # agent_id/orchestrator_id for an in-app workflow step session's events (custom ADWs
    # launched from the Builder). Exactly one of the three is present (app-enforced).
    field :workflow_run_id, :binary_id
    # Project attribution (issue per-project-cost-tracking): the project this row's spend
    # belongs to, resolved from the bound session/orchestrator at write time. Nullable —
    # NULL = unscoped (the platform / pre-feature rows), excluded from any project total.
    field :project_id, :binary_id
    field :session_id, :string
    field :event_type, Ecto.Enum, values: @event_types
    field :harness, :string
    # Time-stable snapshot of the owner's identity at write time (issue-cost-center):
    # cost rolls up by (harness, provider, model) via GROUP BY, not a fragile join to
    # the owner's mutable current identity. Both nullable → "unknown" dimension.
    field :provider, :string
    field :model, :string
    field :payload, :map, default: %{}
    embeds_one :usage, Usage, on_replace: :update
    # Soft-hide for the console CLEAR action: hidden rows are skipped by the default
    # backfill but kept in the DB (revealed by the settings "show hidden" toggle).
    field :hidden, :boolean, default: false
    # DB-assigned durable, human-readable, best-effort-chronological number (`log-<n>`),
    # backed by an owned sequence (migration). `read_after_writes: true` so the live path
    # gets the value back in the inserted struct at broadcast time. Never cast — DB-managed,
    # never user input.
    field :log_no, :integer, read_after_writes: true
    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(log, params) do
    log
    |> cast(params, [
      :agent_id,
      :orchestrator_id,
      :workflow_run_id,
      :project_id,
      :session_id,
      :event_type,
      :harness,
      :provider,
      :model,
      :payload
    ])
    |> cast_embed(:usage)
    |> validate_required([:event_type])
    |> validate_owner()
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:orchestrator_id)
    |> foreign_key_constraint(:workflow_run_id)
    |> foreign_key_constraint(:project_id)
  end

  # A log row belongs to EXACTLY ONE owner: a worker (agent_id), an orchestrator
  # (orchestrator_id), or an in-app workflow step (workflow_run_id) — never more than
  # one, never none. Worker/orchestrator rows keep their existing shape.
  @spec validate_owner(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  defp validate_owner(changeset) do
    owners =
      [:agent_id, :orchestrator_id, :workflow_run_id]
      |> Enum.reject(&is_nil(get_field(changeset, &1)))

    case owners do
      [] ->
        add_error(
          changeset,
          :agent_id,
          "agent_id, orchestrator_id, or workflow_run_id is required"
        )

      [_single] ->
        changeset

      _multiple ->
        add_error(
          changeset,
          :orchestrator_id,
          "exactly one of agent_id, orchestrator_id, workflow_run_id may be set"
        )
    end
  end
end
