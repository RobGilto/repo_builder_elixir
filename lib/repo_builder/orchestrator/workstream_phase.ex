defmodule RepoBuilder.Orchestrator.WorkstreamPhase do
  @moduledoc """
  One phase of a `Workstream`'s ordered Pipeline (orchestration-adw-loop). A phase is the
  unit a single worker can carry through `spec → implement → test → review` without
  exhausting its context window.

  It carries its `position` in the pipeline, the `spec_path` produced by the spec stage
  (the durable hand-off artifact into `/implement <spec_path>`), a lifecycle `status`
  (`pending|running|done|blocked`), a `current_stage` pointer (`spec|implement|test|
  review|done`), and a JSONB `stages` map recording each stage's outcome:
  `%{optional(stage()) => %{status, worker, artifact, note}}`. DB access goes through
  `RepoBuilder.Orchestrator.Workstreams` (the only `Repo` caller).
  """
  use RepoBuilder.Schema

  import Ecto.Changeset

  alias RepoBuilder.Orchestrator.Workstream

  @type status :: :pending | :running | :done | :blocked
  @type stage :: :spec | :implement | :test | :review
  @type current_stage :: :spec | :implement | :test | :review | :done
  @type stage_status :: :pending | :passed | :failed | :blocked
  @typedoc "The phase KIND: a normal backend phase, or an iterative UI/UX polish phase."
  @type kind :: :backend | :ui_ux
  @typedoc "The front-end SURFACE a `:ui_ux` phase polishes (nil for a `:backend` phase)."
  @type surface :: :web | :desktop | :tui

  @typedoc "One stage's recorded outcome, as round-tripped through the JSONB `stages` map."
  @type stage_record :: %{
          optional(String.t()) => String.t() | nil
        }

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          workstream_id: Ecto.UUID.t() | nil,
          position: pos_integer() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          definition_of_done: String.t() | nil,
          spec_path: String.t() | nil,
          stages: %{optional(String.t()) => stage_record()},
          status: status(),
          current_stage: current_stage(),
          kind: kind(),
          surface: surface() | nil,
          iteration: non_neg_integer(),
          workstream: Workstream.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @statuses [:pending, :running, :done, :blocked]
  @stages [:spec, :implement, :test, :review]
  @current_stages [:spec, :implement, :test, :review, :done]
  @stage_statuses [:pending, :passed, :failed, :blocked]
  @kinds [:backend, :ui_ux]
  @surfaces [:web, :desktop, :tui]

  @doc "The phase lifecycle status values."
  @spec statuses() :: [status(), ...]
  def statuses, do: @statuses

  @doc "The ordered work stages a phase runs through."
  @spec stages() :: [stage(), ...]
  def stages, do: @stages

  @doc "The `current_stage` pointer values (the work stages plus the terminal `:done`)."
  @spec current_stages() :: [current_stage(), ...]
  def current_stages, do: @current_stages

  @doc "The per-stage recorded outcome values."
  @spec stage_statuses() :: [stage_status(), ...]
  def stage_statuses, do: @stage_statuses

  @doc "The phase KIND values (`backend` | `ui_ux`)."
  @spec kinds() :: [kind(), ...]
  def kinds, do: @kinds

  @doc "The front-end SURFACE values a `:ui_ux` phase can polish."
  @spec surfaces() :: [surface(), ...]
  def surfaces, do: @surfaces

  schema "orchestrator_workstream_phases" do
    belongs_to :workstream, Workstream, foreign_key: :workstream_id

    field :position, :integer
    field :title, :string
    field :description, :string
    field :definition_of_done, :string
    field :spec_path, :string
    # jsonb stage map (string keys): `%{"spec" => %{"status" => ..., ...}, ...}`.
    field :stages, :map, default: %{}
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :current_stage, Ecto.Enum, values: @current_stages, default: :spec
    # UI/UX polish phase (iterative-ui-ux): `kind` distinguishes a `:ui_ux` phase from a
    # `:backend` one; `surface` names the front-end it polishes; `iteration` counts the
    # bounded review→fix loops. Defaults keep every existing backend phase unchanged.
    field :kind, Ecto.Enum, values: @kinds, default: :backend
    field :surface, Ecto.Enum, values: @surfaces
    field :iteration, :integer, default: 0

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(phase, params) do
    phase
    |> cast(params, [
      :workstream_id,
      :position,
      :title,
      :description,
      :definition_of_done,
      :spec_path,
      :stages,
      :status,
      :current_stage,
      :kind,
      :surface,
      :iteration
    ])
    |> validate_required([:workstream_id, :position, :title])
    |> validate_number(:position, greater_than: 0)
    |> validate_number(:iteration, greater_than_or_equal_to: 0)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:current_stage, @current_stages)
    |> validate_inclusion(:kind, @kinds)
  end
end
