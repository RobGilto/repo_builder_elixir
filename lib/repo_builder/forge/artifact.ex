defmodule RepoBuilder.Forge.Artifact do
  @moduledoc """
  A durable forge request (forge-meta-artifact-generation): the typed record of "this
  project (`nil` = platform) asked for this `kind` of tool with this `spec`," tracked
  through its lifecycle and linked to the generated plugin + the workflow run that drove
  generation.

  `kind` is validated against the closed `Forge.Generator` registry at the changeset
  boundary (an unknown kind is a changeset error, never a raw Postgrex error). `status`
  is a closed `Ecto.Enum`; `error` is a JSONB map.
  """
  use RepoBuilder.Schema

  import Ecto.Changeset

  alias RepoBuilder.Forge.Generator

  @type status :: :requested | :generating | :validating | :packaged | :installed | :failed

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          project_id: Ecto.UUID.t() | nil,
          kind: String.t() | nil,
          spec: String.t() | nil,
          status: status(),
          output_path: String.t() | nil,
          plugin_id: String.t() | nil,
          workflow_run_id: Ecto.UUID.t() | nil,
          error: map() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @statuses ~w(requested generating validating packaged installed failed)a

  schema "forge_artifacts" do
    field :project_id, :binary_id
    field :kind, :string
    field :spec, :string
    field :status, Ecto.Enum, values: @statuses, default: :requested
    field :output_path, :string
    field :plugin_id, :string
    field :workflow_run_id, :binary_id
    field :error, :map
    timestamps()
  end

  @doc "The closed list of lifecycle statuses."
  @spec statuses() :: [status(), ...]
  def statuses, do: @statuses

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(artifact, params) do
    artifact
    |> cast(params, [
      :project_id,
      :kind,
      :spec,
      :status,
      :output_path,
      :plugin_id,
      :workflow_run_id,
      :error
    ])
    |> validate_required([:kind, :spec])
    |> validate_inclusion(:kind, Generator.kind_strings())
  end
end
