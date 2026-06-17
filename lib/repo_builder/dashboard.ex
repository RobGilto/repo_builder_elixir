defmodule RepoBuilder.Dashboard do
  @moduledoc """
  PubSub helper for the swimlane dashboard (BUILD_PROMPT.md §9).

  Live sessions and workflow runners publish a compact `lane` update on key
  transitions (start / status change / done / error). The dashboard renders one
  swimlane row per lane and replaces it IN PLACE via `stream_insert` keyed on the
  stable `lane.id` — `running → done` mutates a single row, keeping server memory
  flat.
  """
  alias RepoBuilder.Harness.Event

  @lanes_topic "dashboard:lanes"
  @events_topic "console:events"

  @type kind :: :agent | :workflow

  @type lane :: %{
          id: String.t(),
          kind: kind(),
          label: String.t(),
          status: atom(),
          harness: String.t() | nil
        }

  @spec subscribe() :: :ok
  def subscribe do
    _ = Phoenix.PubSub.subscribe(RepoBuilder.PubSub, @lanes_topic)
    :ok
  end

  @spec broadcast_lane(lane()) :: :ok
  def broadcast_lane(lane) do
    _ = Phoenix.PubSub.broadcast(RepoBuilder.PubSub, @lanes_topic, {:lane, lane})
    :ok
  end

  @doc """
  Subscribe to the GLOBAL console event feed — a unified stream of every live
  session's canonical events across ALL agents (the per-agent
  `agent:<id>:events` topics stay unchanged). The multi-layered console (§9)
  renders this in its center column so one page shows all agents at once.
  """
  @spec subscribe_events() :: :ok
  def subscribe_events do
    _ = Phoenix.PubSub.subscribe(RepoBuilder.PubSub, @events_topic)
    :ok
  end

  @doc """
  Broadcast one canonical event onto the global console feed, tagged with the
  emitting agent id. Subscribers receive `{:agent_event, agent_id, event}`.
  Additive seam (§9): does not replace the per-agent broadcast.
  """
  @spec broadcast_event(String.t(), Event.t()) :: :ok
  def broadcast_event(agent_id, event) do
    _ =
      Phoenix.PubSub.broadcast(
        RepoBuilder.PubSub,
        @events_topic,
        {:agent_event, agent_id, event}
      )

    :ok
  end

  @doc """
  Announce a newly orchestrator-created worker on the console feed so the roster
  picks it up live. Subscribers receive `{:agent_created, agent}`. Additive seam
  (§9) — NOT a canonical `Event` variant, so the core event sum type is untouched.
  """
  @spec broadcast_agent_created(RepoBuilder.Agents.Agent.t()) :: :ok
  def broadcast_agent_created(agent) do
    _ = Phoenix.PubSub.broadcast(RepoBuilder.PubSub, @events_topic, {:agent_created, agent})
    :ok
  end

  @doc """
  Announce that an orchestrator-owned worker was deleted so the roster drops it
  live. Subscribers receive `{:agent_deleted, agent}`. Additive seam (§9) — NOT a
  canonical `Event` variant, so the core event sum type is untouched. Mirrors
  `broadcast_agent_created/1`.
  """
  @spec broadcast_agent_deleted(RepoBuilder.Agents.Agent.t()) :: :ok
  def broadcast_agent_deleted(agent) do
    _ = Phoenix.PubSub.broadcast(RepoBuilder.PubSub, @events_topic, {:agent_deleted, agent})
    :ok
  end

  @doc "Topic for one workflow run's transition stream (per-workflow view)."
  @spec workflow_topic(Ecto.UUID.t()) :: String.t()
  def workflow_topic(run_id), do: "workflow:#{run_id}:events"

  @spec subscribe_workflow(Ecto.UUID.t()) :: :ok
  def subscribe_workflow(run_id) do
    _ = Phoenix.PubSub.subscribe(RepoBuilder.PubSub, workflow_topic(run_id))
    :ok
  end

  @spec broadcast_workflow(Ecto.UUID.t(), term()) :: :ok
  def broadcast_workflow(run_id, message) do
    _ = Phoenix.PubSub.broadcast(RepoBuilder.PubSub, workflow_topic(run_id), message)
    :ok
  end
end
