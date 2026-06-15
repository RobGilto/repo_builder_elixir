defmodule RepoBuilder.Agents do
  @moduledoc """
  Context for durable agent definitions (BUILD_PROMPT.md §8). The only `Repo`
  caller for `agents`. Every public function is `@spec`'d and returns tagged tuples.
  """
  import Ecto.Query, only: [from: 2]

  alias RepoBuilder.Agents.Agent
  alias RepoBuilder.Repo

  @spec list_agents() :: [Agent.t()]
  def list_agents, do: Repo.all(from(a in Agent, order_by: [asc: a.name]))

  @spec get_agent(Ecto.UUID.t()) :: Agent.t() | nil
  def get_agent(id), do: Repo.get(Agent, id)

  @spec fetch_agent(Ecto.UUID.t()) :: {:ok, Agent.t()} | {:error, :not_found}
  def fetch_agent(id) do
    case Repo.get(Agent, id) do
      nil -> {:error, :not_found}
      agent -> {:ok, agent}
    end
  end

  @spec create_agent(map()) :: {:ok, Agent.t()} | {:error, Ecto.Changeset.t()}
  def create_agent(params) do
    %Agent{}
    |> Agent.changeset(params)
    |> Repo.insert()
  end

  @spec update_agent(Agent.t(), map()) :: {:ok, Agent.t()} | {:error, Ecto.Changeset.t()}
  def update_agent(%Agent{} = agent, params) do
    agent
    |> Agent.changeset(params)
    |> Repo.update()
  end

  @spec delete_agent(Agent.t()) :: {:ok, Agent.t()} | {:error, Ecto.Changeset.t()}
  def delete_agent(%Agent{} = agent), do: Repo.delete(agent)

  @doc "Set an agent's status (used by the session runtime); a missing agent is a no-op."
  @spec set_status(Ecto.UUID.t(), Agent.status()) :: {:ok, Agent.t()} | {:error, :not_found}
  def set_status(agent_id, status) do
    case Repo.get(Agent, agent_id) do
      nil ->
        {:error, :not_found}

      agent ->
        agent
        |> Agent.status_changeset(status)
        |> Repo.update!()
        |> then(&{:ok, &1})
    end
  end
end
