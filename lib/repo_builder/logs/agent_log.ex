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
          session_id: String.t() | nil,
          event_type: event_type() | nil,
          harness: String.t() | nil,
          payload: map(),
          usage: Usage.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @event_types ~w(session_started text_delta tool_call tool_result usage status done error)a

  schema "agent_logs" do
    field :agent_id, :binary_id
    # Orchestrator-scoped persistence (issue-d): set instead of agent_id for an
    # orchestrator turn's events. Exactly one of the two is present (app-enforced).
    field :orchestrator_id, :binary_id
    field :session_id, :string
    field :event_type, Ecto.Enum, values: @event_types
    field :harness, :string
    field :payload, :map, default: %{}
    embeds_one :usage, Usage, on_replace: :update
    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(log, params) do
    log
    |> cast(params, [:agent_id, :orchestrator_id, :session_id, :event_type, :harness, :payload])
    |> cast_embed(:usage)
    |> validate_required([:event_type])
    |> validate_owner()
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:orchestrator_id)
  end

  # A log row belongs to EXACTLY ONE owner: a worker (agent_id) or an orchestrator
  # (orchestrator_id), never both/neither. Worker rows keep their existing shape.
  @spec validate_owner(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  defp validate_owner(changeset) do
    agent_id = get_field(changeset, :agent_id)
    orchestrator_id = get_field(changeset, :orchestrator_id)

    case {agent_id, orchestrator_id} do
      {nil, nil} ->
        add_error(changeset, :agent_id, "agent_id or orchestrator_id is required")

      {a, o} when not is_nil(a) and not is_nil(o) ->
        add_error(changeset, :orchestrator_id, "cannot set both agent_id and orchestrator_id")

      _ ->
        changeset
    end
  end
end
