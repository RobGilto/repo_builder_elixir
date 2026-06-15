defmodule RepoBuilder.Logs.SystemLog do
  @moduledoc "App-level/system events (BUILD_PROMPT.md §8)."
  use RepoBuilder.Schema

  import Ecto.Changeset

  @type level :: :debug | :info | :warn | :error

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          level: level() | nil,
          message: String.t() | nil,
          metadata: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "system_logs" do
    field :level, Ecto.Enum, values: [:debug, :info, :warn, :error]
    field :message, :string
    field :metadata, :map, default: %{}
    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(log, params) do
    log
    |> cast(params, [:level, :message, :metadata])
    |> validate_required([:level, :message])
  end
end
