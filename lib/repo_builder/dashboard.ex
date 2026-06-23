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
  Broadcast a per-step progress view for a workflow run on the lanes topic so the
  console ADWS view can redraw per-step squares live (per-step observability §9).
  Subscribers receive `{:workflow_step, run_id, progress}`. Additive seam — NOT a
  canonical `Event` variant (§4); `progress` is the `Workflows.progress()` map.
  Emitted from BOTH the live Runner and the durable StepWorker at each transition.
  """
  @spec broadcast_workflow_step(Ecto.UUID.t(), map()) :: :ok
  def broadcast_workflow_step(run_id, progress) do
    _ =
      Phoenix.PubSub.broadcast(
        RepoBuilder.PubSub,
        @lanes_topic,
        {:workflow_step, run_id, progress}
      )

    :ok
  end

  @doc """
  Broadcast a humanized ADW `title` for every run of `workflow_id` on the lanes topic
  so open consoles swap the heuristic card title for the Fast-tier-humanized one live
  (issue-unified-adw-swimlane-cards). Subscribers receive
  `{:workflow_title, workflow_id, title}`. Additive seam — NOT a canonical `Event`.
  Emitted by `RepoBuilder.Workflows.TitleHumanizer` after it persists `metadata["title"]`.
  """
  @spec broadcast_workflow_title(Ecto.UUID.t(), String.t()) :: :ok
  def broadcast_workflow_title(workflow_id, title) do
    _ =
      Phoenix.PubSub.broadcast(
        RepoBuilder.PubSub,
        @lanes_topic,
        {:workflow_title, workflow_id, title}
      )

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
  emitting agent id and the persisted row's durable `log_no` (the `log-<n>` number).
  Subscribers receive `{:agent_event, agent_id, event, log_no}`. Non-persisted events
  (partial `text_delta` token shards) pass `log_no = nil` (rendered "—" in the drilldown).
  Additive seam (§9): does not replace the per-agent broadcast. This topic
  (`console:events`) has a single subscriber (ConsoleLive); the per-agent
  `agent:<id>:events` topic is untouched.
  """
  @spec broadcast_event(String.t(), Event.t(), integer() | nil) :: :ok
  def broadcast_event(agent_id, event, log_no \\ nil) do
    _ =
      Phoenix.PubSub.broadcast(
        RepoBuilder.PubSub,
        @events_topic,
        {:agent_event, agent_id, event, log_no}
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

  @doc """
  Announce that an orchestrator-owned worker was updated in place (e.g. its status
  changed after a `clear_context` reset) so the roster + swimlane reflect it live.
  Subscribers receive `{:agent_updated, agent}`. Additive seam (§9) — NOT a
  canonical `Event` variant. Mirrors `broadcast_agent_created/1`.
  """
  @spec broadcast_agent_updated(RepoBuilder.Agents.Agent.t()) :: :ok
  def broadcast_agent_updated(agent) do
    _ = Phoenix.PubSub.broadcast(RepoBuilder.PubSub, @events_topic, {:agent_updated, agent})
    :ok
  end

  @doc """
  Broadcast that the orchestrator record was updated so any connected ConsoleLive
  socket can refresh its assigns without a page reload.
  """
  @spec broadcast_orchestrator_updated(RepoBuilder.Orchestrator.Orchestrator.t()) :: :ok
  def broadcast_orchestrator_updated(orchestrator) do
    _ =
      Phoenix.PubSub.broadcast(
        RepoBuilder.PubSub,
        @events_topic,
        {:orchestrator_updated, orchestrator}
      )

    :ok
  end

  @doc "Topic for one orchestrator's FIFO turn-queue snapshots (issue message-queue)."
  @spec orchestrator_queue_topic(Ecto.UUID.t()) :: String.t()
  def orchestrator_queue_topic(orchestrator_id), do: "orchestrator:#{orchestrator_id}:queue"

  @doc "Subscribe the calling process to an orchestrator's queue-snapshot topic."
  @spec subscribe_orchestrator_queue(Ecto.UUID.t()) :: :ok
  def subscribe_orchestrator_queue(orchestrator_id) do
    _ = Phoenix.PubSub.subscribe(RepoBuilder.PubSub, orchestrator_queue_topic(orchestrator_id))
    :ok
  end

  @doc """
  Broadcast the latest queue snapshot for `orchestrator_id` so a connected console
  re-renders the queued-messages strip and busy/queued badge. Subscribers receive
  `{:orchestrator_queue, orchestrator_id, snapshot}`. Additive seam (issue
  message-queue) — NOT a canonical `Event` variant.
  """
  @spec broadcast_orchestrator_queue(Ecto.UUID.t(), map()) :: :ok
  def broadcast_orchestrator_queue(orchestrator_id, snapshot) do
    _ =
      Phoenix.PubSub.broadcast(
        RepoBuilder.PubSub,
        orchestrator_queue_topic(orchestrator_id),
        {:orchestrator_queue, orchestrator_id, snapshot}
      )

    :ok
  end

  @doc "Topic for an orchestrator's worker-terminal signals (holding pattern)."
  @spec orchestrator_workers_topic(Ecto.UUID.t()) :: String.t()
  def orchestrator_workers_topic(orchestrator_id), do: "orchestrator:#{orchestrator_id}:workers"

  @doc "Subscribe the calling process to an orchestrator's worker-terminal topic."
  @spec subscribe_orchestrator_workers(Ecto.UUID.t()) :: :ok
  def subscribe_orchestrator_workers(orchestrator_id) do
    _ = Phoenix.PubSub.subscribe(RepoBuilder.PubSub, orchestrator_workers_topic(orchestrator_id))
    :ok
  end

  @doc """
  Broadcast that a worker owned by `orchestrator_id` reached a terminal state, so
  the orchestrator's `Queue` can engage its holding pattern (auto-resume on worker
  return). Subscribers receive `{:worker_terminal, info}` where `info` carries at least
  `%{worker_id, name, ok?}` plus the OPTIONAL handover fields `context_tokens` (the
  worker's latest-turn occupancy) and `final_text` (the terminal message text the
  `:handover <path>` signal would ride in). The optional fields are absent for callers
  that don't track them (e.g. `WorkflowEngine.emit_orchestrator_resume/2`), and the Queue
  treats them as `context_tokens: 0` / `final_text: nil` — so those paths are unchanged.
  Additive seam (issue message-queue; enriched in issue graceful-agent-handover).
  """
  @spec broadcast_worker_terminal(Ecto.UUID.t(), %{
          required(:worker_id) => Ecto.UUID.t(),
          required(:name) => String.t(),
          required(:ok?) => boolean(),
          optional(:context_tokens) => non_neg_integer(),
          optional(:final_text) => String.t() | nil
        }) :: :ok
  def broadcast_worker_terminal(orchestrator_id, info) do
    _ =
      Phoenix.PubSub.broadcast(
        RepoBuilder.PubSub,
        orchestrator_workers_topic(orchestrator_id),
        {:worker_terminal, info}
      )

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
