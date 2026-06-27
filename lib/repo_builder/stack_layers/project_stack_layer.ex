defmodule RepoBuilder.StackLayers.ProjectStackLayer do
  @moduledoc """
  Per-project stack composition (stack-layers subsystem): joins one catalog
  `StackLayer` to a project. The set of rows for a project — grouped by the layer's
  type — composes the stack contract injected into every worker the project's
  orchestrator spawns. Mirrors `project_plugins`: both FKs cascade, the pair is unique.
  """
  use RepoBuilder.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          project_id: Ecto.UUID.t() | nil,
          stack_layer_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "project_stack_layers" do
    field :project_id, :binary_id
    field :stack_layer_id, :binary_id
    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(selection, params) do
    selection
    |> cast(params, [:project_id, :stack_layer_id])
    |> validate_required([:project_id, :stack_layer_id])
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:stack_layer_id)
    |> unique_constraint([:project_id, :stack_layer_id])
  end
end
