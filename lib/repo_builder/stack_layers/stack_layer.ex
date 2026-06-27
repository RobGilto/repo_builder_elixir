defmodule RepoBuilder.StackLayers.StackLayer do
  @moduledoc """
  One typed tech-stack layer in the operator-curated catalog (stack-layers subsystem),
  keyed by `(layer_type, name)`. A layer carries the `language`/framework it stands for
  and the worker-facing `reasoning`/guardrails injected verbatim into the stack contract.

  `source` records provenance: `:seed` rows are catalog defaults (refreshed on re-seed);
  `:manual` rows are operator-created/edited (preserved across re-seed). `layer_type` is
  a closed enum so the per-type UI grouping stays well-defined.
  """
  use RepoBuilder.Schema

  import Ecto.Changeset

  @layer_types ~w(frontend backend database tooling)a
  @sources ~w(seed manual)a

  @type layer_type :: :frontend | :backend | :database | :tooling
  @type source :: :seed | :manual

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          layer_type: layer_type() | nil,
          name: String.t() | nil,
          language: String.t() | nil,
          reasoning: String.t() | nil,
          enabled: boolean(),
          source: source(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "stack_layers" do
    field :layer_type, Ecto.Enum, values: @layer_types
    field :name, :string
    field :language, :string
    field :reasoning, :string
    field :enabled, :boolean, default: true
    field :source, Ecto.Enum, values: @sources, default: :seed
    timestamps()
  end

  @fields [:layer_type, :name, :language, :reasoning, :enabled, :source]

  @doc "The known layer types, in display order."
  @spec layer_types() :: [layer_type(), ...]
  def layer_types, do: @layer_types

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(layer, params) do
    layer
    |> cast(params, @fields)
    |> validate_required([:layer_type, :name, :language])
    |> unique_constraint([:layer_type, :name])
  end
end
