defmodule RepoBuilderWeb.DashboardLive do
  @moduledoc """
  Top-level swimlane dashboard (BUILD_PROMPT.md §9). One swimlane row per live agent
  and per workflow run, rendered via LiveView STREAMS with a STABLE dom_id per lane
  so `running → done` replaces the row in place — server memory stays flat.

  On a connected mount the stream is seeded from persisted state (reconnect
  backfill), then it subscribes to live lane updates.
  """
  use RepoBuilderWeb, :live_view

  import RepoBuilderWeb.DashboardComponents

  alias RepoBuilder.{Agents, Dashboard, Workflows}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> stream_configure(:lanes, dom_id: &"lane-#{&1.id}")
      |> stream(:lanes, [])

    socket =
      if connected?(socket) do
        socket = Enum.reduce(seed_lanes(), socket, &stream_insert(&2, :lanes, &1))
        :ok = Dashboard.subscribe()
        socket
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_info({:lane, lane}, socket) do
    # Stable dom_id (lane.id) ⇒ re-inserting the same lane REPLACES the row in place.
    {:noreply, stream_insert(socket, :lanes, lane)}
  end

  @spec seed_lanes() :: [Dashboard.lane()]
  defp seed_lanes do
    agent_lanes =
      Enum.map(Agents.list_agents(), fn agent ->
        %{
          id: "agent:#{agent.id}",
          kind: :agent,
          label: agent.name,
          status: agent.status,
          harness: agent.harness
        }
      end)

    workflow_lanes =
      Enum.map(Workflows.list_recent_runs(), fn run ->
        %{
          id: "workflow:#{run.id}",
          kind: :workflow,
          label: run.current_step || "workflow",
          status: run.status,
          harness: nil
        }
      end)

    agent_lanes ++ workflow_lanes
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-4">
        <h1 class="text-xl font-semibold">Orchestration Dashboard</h1>

        <div id="lanes" phx-update="stream" class="space-y-2">
          <div :for={{dom_id, lane} <- @streams.lanes} id={dom_id}>
            <.swimlane_row
              id={lane.id}
              label={lane.label}
              status={lane.status}
              kind={lane.kind}
              harness={lane.harness}
            />
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
