defmodule RepoBuilder.Prompts.Prompt do
  @moduledoc "Reusable prompt template (BUILD_PROMPT.md §8)."
  use RepoBuilder.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          body: String.t() | nil,
          variables: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "prompts" do
    field :name, :string
    field :body, :string
    field :variables, :map, default: %{}
    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(prompt, params) do
    prompt
    |> cast(params, [:name, :body, :variables])
    |> validate_required([:name, :body])
    |> unique_constraint(:name)
  end
end
