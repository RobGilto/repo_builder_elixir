defmodule RepoBuilder.Prompts do
  @moduledoc "Context for reusable prompt templates (BUILD_PROMPT.md §8)."
  import Ecto.Query, only: [from: 2]

  alias RepoBuilder.Prompts.Prompt
  alias RepoBuilder.Repo

  @spec list_prompts() :: [Prompt.t()]
  def list_prompts, do: Repo.all(from(p in Prompt, order_by: [asc: p.name]))

  @spec get_prompt(Ecto.UUID.t()) :: Prompt.t() | nil
  def get_prompt(id), do: Repo.get(Prompt, id)

  @spec create_prompt(map()) :: {:ok, Prompt.t()} | {:error, Ecto.Changeset.t()}
  def create_prompt(params) do
    %Prompt{}
    |> Prompt.changeset(params)
    |> Repo.insert()
  end

  @spec update_prompt(Prompt.t(), map()) :: {:ok, Prompt.t()} | {:error, Ecto.Changeset.t()}
  def update_prompt(%Prompt{} = prompt, params) do
    prompt
    |> Prompt.changeset(params)
    |> Repo.update()
  end

  @spec delete_prompt(Prompt.t()) :: {:ok, Prompt.t()} | {:error, Ecto.Changeset.t()}
  def delete_prompt(%Prompt{} = prompt), do: Repo.delete(prompt)
end
