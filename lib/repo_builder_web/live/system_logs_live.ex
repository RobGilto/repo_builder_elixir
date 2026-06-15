defmodule RepoBuilderWeb.SystemLogsLive do
  @moduledoc """
  App-level system-log view (BUILD_PROMPT.md §9). Append-only via LiveView streams,
  seeded from persisted rows on connect, then live via the `system_logs` topic.
  """
  use RepoBuilderWeb, :live_view

  alias RepoBuilder.Logs

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> stream_configure(:logs, dom_id: &"syslog-#{&1.id}")
      |> stream(:logs, [])

    socket =
      if connected?(socket) do
        seeded =
          Logs.list_system_logs()
          |> Enum.reverse()
          |> Enum.reduce(socket, &stream_insert(&2, :logs, &1, at: -1, limit: -200))

        :ok = Logs.subscribe_system_logs()
        seeded
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_info({:system_log, log}, socket) do
    {:noreply, stream_insert(socket, :logs, log, at: -1, limit: -200)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-4">
        <h1 class="text-xl font-semibold">System logs</h1>

        <ul id="system-logs" phx-update="stream" class="space-y-1 font-mono text-sm">
          <li :for={{dom_id, log} <- @streams.logs} id={dom_id}>
            <span class="font-semibold">[{log.level}]</span>
            <span>{log.message}</span>
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
  end
end
