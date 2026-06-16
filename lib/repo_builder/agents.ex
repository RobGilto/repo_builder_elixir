defmodule RepoBuilder.Agents do
  @moduledoc """
  Context for durable agent definitions (BUILD_PROMPT.md §8). The only `Repo`
  caller for `agents`. Every public function is `@spec`'d and returns tagged tuples.
  """
  import Ecto.Query, only: [from: 2]

  alias RepoBuilder.Agents.Agent
  alias RepoBuilder.Repo

  # Workers carry a provider (a non-null display column); when the orchestrator
  # does not specify one we default per harness, falling back to :anthropic.
  @harness_providers %{"pi" => :openai, "cursor" => :anthropic}

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

  @doc """
  Create an orchestrator-owned worker. `orchestrator_id` scopes the worker; `params`
  carries at least `:name` and `:harness`. A missing `:provider` is defaulted from
  the harness so the non-null column is satisfied.
  """
  @spec create_worker(Ecto.UUID.t(), map()) :: {:ok, Agent.t()} | {:error, Ecto.Changeset.t()}
  def create_worker(orchestrator_id, params) do
    params =
      params
      |> stringify_keys()
      |> Map.put("orchestrator_id", orchestrator_id)
      |> Map.put_new_lazy("provider", fn -> default_provider(params) end)

    %Agent{}
    |> Agent.worker_changeset(params)
    |> Repo.insert()
  end

  @doc "Resolve a worker by name within one orchestrator's scope."
  @spec get_by_name_for_orchestrator(Ecto.UUID.t(), String.t()) ::
          {:ok, Agent.t()} | {:error, :not_found}
  def get_by_name_for_orchestrator(orchestrator_id, name) do
    case Repo.get_by(Agent, orchestrator_id: orchestrator_id, name: name) do
      nil -> {:error, :not_found}
      agent -> {:ok, agent}
    end
  end

  @doc "List all workers owned by one orchestrator (newest first)."
  @spec list_for_orchestrator(Ecto.UUID.t()) :: [Agent.t()]
  def list_for_orchestrator(orchestrator_id) do
    Repo.all(
      from(a in Agent,
        where: a.orchestrator_id == ^orchestrator_id,
        order_by: [desc: a.inserted_at, asc: a.name]
      )
    )
  end

  @doc "Persist a worker's resumable CLI session id; a missing agent is `{:error, :not_found}`."
  @spec set_session(Ecto.UUID.t(), String.t() | nil) ::
          {:ok, Agent.t()} | {:error, :not_found}
  def set_session(agent_id, session_id) do
    case Repo.get(Agent, agent_id) do
      nil ->
        {:error, :not_found}

      agent ->
        agent
        |> Agent.session_changeset(session_id)
        |> Repo.update!()
        |> then(&{:ok, &1})
    end
  end

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

  @spec stringify_keys(map()) :: %{optional(String.t()) => term()}
  defp stringify_keys(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  @spec default_provider(map()) :: Agent.provider()
  defp default_provider(params) do
    harness = to_string(params[:harness] || params["harness"] || "")
    Map.get(@harness_providers, harness, :anthropic)
  end
end
