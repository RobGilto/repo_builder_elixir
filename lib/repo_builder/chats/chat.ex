defmodule RepoBuilder.Chats.Chat do
  @moduledoc """
  Conversational turn (BUILD_PROMPT.md §8).

  CRUD-only: this table is NOT populated by the event runtime (per spec) — it
  exists for storing conversational turns via the contexts/UI.
  """
  use RepoBuilder.Schema

  import Ecto.Changeset

  @type role :: :user | :assistant | :system

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          agent_id: Ecto.UUID.t() | nil,
          role: role() | nil,
          content: String.t() | nil,
          usage: map() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "chat" do
    field :agent_id, :binary_id
    field :role, Ecto.Enum, values: [:user, :assistant, :system]
    field :content, :string
    field :usage, :map
    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(chat, params) do
    chat
    |> cast(params, [:agent_id, :role, :content, :usage])
    |> validate_required([:agent_id, :role, :content])
    |> foreign_key_constraint(:agent_id)
  end
end
