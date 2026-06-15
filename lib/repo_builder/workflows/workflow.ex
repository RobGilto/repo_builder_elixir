defmodule RepoBuilder.Workflows.Workflow do
  @moduledoc """
  Durable ADW definition (BUILD_PROMPT.md §8). `steps` is the ordered list of step
  maps (`{name, harness, provider, model, prompt_template, on_success, on_failure}`),
  stored as JSONB.
  """
  use RepoBuilder.Schema

  import Ecto.Changeset

  @type state :: :draft | :active | :archived

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          state: state() | nil,
          steps: [map()],
          metadata: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "workflows" do
    field :name, :string
    field :state, Ecto.Enum, values: [:draft, :active, :archived], default: :draft
    field :steps, {:array, :map}, default: []
    field :metadata, :map, default: %{}
    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(workflow, params) do
    workflow
    |> cast(params, [:name, :state, :steps, :metadata])
    |> validate_required([:name])
    |> unique_constraint(:name)
  end
end
