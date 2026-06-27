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
  def list_agents, do: list_agents([])

  @doc """
  List agents ordered by name. Archived agents (issue agent-CRUD) are excluded by
  default; pass `include_archived: true` to include them.
  """
  @spec list_agents(keyword()) :: [Agent.t()]
  def list_agents(opts) when is_list(opts) do
    query = from(a in Agent, order_by: [asc: a.name])

    query =
      if Keyword.get(opts, :include_archived, false),
        do: query,
        else: from(a in query, where: a.archived == false)

    Repo.all(query)
  end

  @doc """
  Scope a query to a target project (agentic-layer adaptor). A `nil` project id is
  the unscoped, back-compatible default — every agent, "the platform itself"
  included — so callers can pass the active project id straight through.
  """
  @spec scope_by_project(Ecto.Queryable.t(), Ecto.UUID.t() | nil) :: Ecto.Query.t()
  def scope_by_project(query, nil), do: from(a in query, [])

  def scope_by_project(query, project_id),
    do: from(a in query, where: a.project_id == ^project_id)

  @doc "List non-archived agents scoped to a project (`nil` ⇒ unscoped), ordered by name."
  @spec list_for_project(Ecto.UUID.t() | nil) :: [Agent.t()]
  def list_for_project(project_id) do
    Agent
    |> scope_by_project(project_id)
    |> then(&from(a in &1, where: a.archived == false, order_by: [asc: a.name]))
    |> Repo.all()
  end

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
  Soft-archive an agent (`archived: true`) — issue agent-CRUD. Preserves the row and
  its `agent_logs`/cost history (unlike the hard `delete_agent/1`); the agent is
  excluded from the default `list_agents/0` but reachable via
  `list_agents(include_archived: true)`.
  """
  @spec archive_agent(Agent.t()) :: {:ok, Agent.t()} | {:error, Ecto.Changeset.t()}
  def archive_agent(%Agent{} = agent) do
    agent
    |> Agent.archive_changeset()
    |> Repo.update()
  end

  @doc """
  Update an orchestrator-owned worker's `model`/`system_prompt`/`harness` via
  `Agent.worker_changeset/2` (the plain `changeset/2` does NOT cast those fields
  and requires `:provider`). The changeset's `validate_required([:name, :harness,
  :orchestrator_id])` is satisfied by the persisted struct's existing values.
  """
  @spec update_worker(Agent.t(), map()) :: {:ok, Agent.t()} | {:error, Ecto.Changeset.t()}
  def update_worker(%Agent{} = agent, params) do
    agent
    |> Agent.worker_changeset(stringify_keys(params))
    |> Repo.update()
  end

  @doc """
  Shallow-merge `attrs` into a worker's JSONB `config` map (string keys), persisting via
  `worker_changeset/2`. The flag carriers for the handover protocol — `winding_down` and
  `original_ask` — ride here so no new DB column is needed (issue graceful-agent-handover).
  """
  @spec merge_config(Agent.t(), %{optional(String.t()) => term()}) ::
          {:ok, Agent.t()} | {:error, Ecto.Changeset.t()}
  def merge_config(%Agent{config: config} = agent, attrs) do
    update_worker(agent, %{"config" => Map.merge(config || %{}, attrs)})
  end

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

  @doc """
  List non-archived agents wedged in a live status (`:running`/`:holding`) whose row
  hasn't been touched since `stale_before` (issue worker-terminal Part B). These are
  candidate phantoms: the `LivenessReaper` further filters to those with NO live
  `SessionRegistry` process before reconciling. Order is irrelevant.
  """
  @spec list_stuck_running(DateTime.t()) :: [Agent.t()]
  def list_stuck_running(stale_before) do
    Repo.all(
      from(a in Agent,
        where:
          a.archived == false and a.status in [:running, :holding] and
            a.updated_at < ^stale_before
      )
    )
  end

  @doc """
  List non-archived workers still `:running` whose `heartbeat_at` is older than
  `stale_before` (self-healing Phase 1) — live-but-quiescent candidates. Distinct from
  `list_stuck_running/1` (which targets phantoms by `updated_at`): this keys off the
  meaningful-event `heartbeat_at`, and the `LivenessReaper` further filters to those WITH
  a live `SessionRegistry` process before demoting them to `:idle`. Rows that never emitted
  an event (NULL `heartbeat_at`) are excluded — they fall to the phantom pass instead.
  """
  @spec list_stale_live_running(DateTime.t()) :: [Agent.t()]
  def list_stale_live_running(stale_before) do
    Repo.all(
      from(a in Agent,
        where:
          a.archived == false and a.status == :running and
            not is_nil(a.heartbeat_at) and a.heartbeat_at < ^stale_before
      )
    )
  end

  @doc """
  Cheap, conflict-free liveness bump (self-healing Phase 1). Sets `heartbeat_at` to now via
  a targeted `update_all` — it does NOT load the row, does NOT change `status`, and does NOT
  touch `updated_at`. Keeping `updated_at` untouched is load-bearing: the phantom reaper keys
  off `updated_at` while the live-stale pass keys off `heartbeat_at`, so the two staleness
  signals stay independent. A missing row is a no-op (`{0, nil}`).
  """
  @spec touch_heartbeat(Ecto.UUID.t()) :: :ok
  def touch_heartbeat(agent_id) do
    now = DateTime.utc_now()
    _ = Repo.update_all(from(a in Agent, where: a.id == ^agent_id), set: [heartbeat_at: now])
    :ok
  end

  @typedoc """
  A narrow live-worker projection for the deterministic drive-loop fleet gate
  (`RepoBuilder.Orchestrator.WorkerFleet`): just the id, status, and last meaningful
  `heartbeat_at` — never a full row, so the hot Driver tick stays cheap.
  """
  @type live_worker :: %{
          id: Ecto.UUID.t(),
          status: Agent.status(),
          heartbeat_at: DateTime.t() | nil
        }

  @doc """
  List the non-archived workers for `orchestrator_id` currently in a LIVE status
  (`:running`/`:holding`), projected to `{id, status, heartbeat_at}` only (self-healing
  drive-loop fleet gate). This is the cheap, token-free signal the `WorkerFleet`
  classifier uses to decide whether the autonomous Driver should stand down rather than
  spend an LLM turn polling. Indexed via `agents_orchestrator_id_index` /
  `agents_active_index`.
  """
  @spec live_workers_for(Ecto.UUID.t()) :: [live_worker()]
  def live_workers_for(orchestrator_id) do
    Repo.all(
      from(a in Agent,
        where:
          a.orchestrator_id == ^orchestrator_id and a.archived == false and
            a.status in [:running, :holding],
        select: %{id: a.id, status: a.status, heartbeat_at: a.heartbeat_at}
      )
    )
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
