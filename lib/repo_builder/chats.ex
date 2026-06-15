defmodule RepoBuilder.Chats do
  @moduledoc "Context for conversational turns (BUILD_PROMPT.md §8). CRUD-only — not populated by the runtime."
  import Ecto.Query, only: [from: 2]

  alias RepoBuilder.Chats.Chat
  alias RepoBuilder.Repo

  @spec list_chats(Ecto.UUID.t()) :: [Chat.t()]
  def list_chats(agent_id) do
    Repo.all(from(c in Chat, where: c.agent_id == ^agent_id, order_by: [asc: c.inserted_at]))
  end

  @spec get_chat(Ecto.UUID.t()) :: Chat.t() | nil
  def get_chat(id), do: Repo.get(Chat, id)

  @spec create_chat(map()) :: {:ok, Chat.t()} | {:error, Ecto.Changeset.t()}
  def create_chat(params) do
    %Chat{}
    |> Chat.changeset(params)
    |> Repo.insert()
  end

  @spec delete_chat(Chat.t()) :: {:ok, Chat.t()} | {:error, Ecto.Changeset.t()}
  def delete_chat(%Chat{} = chat), do: Repo.delete(chat)
end
