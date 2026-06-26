defmodule RepoBuilder.Settings.AppSetting do
  @moduledoc """
  One operator-editable application setting (BUILD_PROMPT.md §8), keyed by a unique
  string `key` with a JSONB `value` map. The only row this table holds today is
  `"default_agent_models"`, the global default worker-model roster that new projects'
  orchestrators inherit. `RepoBuilder.Settings` is the single `Repo` caller for this table.

  `value` stores string-keyed JSON (never atom keys) so it round-trips through Postgres
  JSONB unchanged.
  """
  use RepoBuilder.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          key: String.t() | nil,
          value: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "app_settings" do
    field :key, :string
    field :value, :map, default: %{}
    timestamps()
  end

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(setting, params) do
    setting
    |> cast(params, [:key, :value])
    |> validate_required([:key])
    |> unique_constraint(:key)
  end
end
