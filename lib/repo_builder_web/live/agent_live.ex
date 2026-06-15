defmodule RepoBuilderWeb.AgentLive do
  @moduledoc """
  Minimal per-agent observability LiveView (BUILD_PROMPT.md §9, M2).

  Subscribes to a live session's canonical events (only on a CONNECTED socket) and
  renders them as an append-only log via LiveView STREAMS — server memory stays
  flat. One `handle_info/2` clause per canonical event variant (exhaustive). Extended
  in M3 (persisted-history backfill on reconnect) and M7 (swimlanes/cost/async).
  """
  use RepoBuilderWeb, :live_view

  alias RepoBuilder.Harness.Event
  alias RepoBuilder.Logs
  alias RepoBuilder.Logs.AgentLog
  alias RepoBuilder.Session

  @impl true
  def mount(%{"id" => agent_id}, _session, socket) do
    socket =
      socket
      |> assign(:agent_id, agent_id)
      |> assign(:status, :idle)
      |> assign(:seq, 0)
      |> stream_configure(:events, dom_id: &"event-#{&1.id}")
      |> stream(:events, [])

    # On a CONNECTED socket: seed the stream from persisted history FIRST (reconnect
    # backfill — events broadcast while disconnected are gone), THEN subscribe.
    socket =
      if connected?(socket) do
        socket = seed_history(socket, agent_id)
        :ok = Phoenix.PubSub.subscribe(RepoBuilder.PubSub, "agent:#{agent_id}:events")
        socket
      else
        socket
      end

    {:ok, socket}
  end

  @spec seed_history(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  defp seed_history(socket, agent_id) do
    case Ecto.UUID.cast(agent_id) do
      {:ok, uuid} ->
        uuid
        |> Logs.list_recent()
        |> Enum.reduce(socket, fn log, acc ->
          stream_insert(acc, :events, log_to_row(log), at: -1, limit: -500)
        end)

      :error ->
        socket
    end
  end

  @spec log_to_row(AgentLog.t()) :: %{
          id: String.t(),
          kind: String.t(),
          body: String.t(),
          thinking?: boolean()
        }
  defp log_to_row(%AgentLog{} = log) do
    %{id: "log-#{log.id}", kind: to_string(log.event_type), body: log_body(log), thinking?: false}
  end

  @spec log_body(AgentLog.t()) :: String.t()
  defp log_body(%AgentLog{event_type: :text_delta, payload: %{"text" => text}})
       when is_binary(text), do: text

  defp log_body(%AgentLog{payload: payload}), do: payload |> inspect() |> String.slice(0, 200)

  @impl true
  def handle_event("start", _params, socket) do
    socket =
      case Session.Supervisor.start_session(
             agent_id: socket.assigns.agent_id,
             harness: "fake",
             prompt: "demo run"
           ) do
        {:ok, _pid} -> assign(socket, :status, :running)
        {:error, :at_capacity} -> put_flash(socket, :error, "At capacity")
        {:error, _reason} -> put_flash(socket, :error, "Could not start session")
      end

    {:noreply, socket}
  end

  def handle_event("interrupt", _params, socket) do
    :ok = Session.Supervisor.interrupt(socket.assigns.agent_id)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:harness_event, %Event.SessionStarted{} = event}, socket) do
    {:noreply, push_row(socket, "session", event.session_id, false, :running)}
  end

  def handle_info({:harness_event, %Event.TextDelta{} = event}, socket) do
    label = if event.thinking?, do: "thinking", else: "text"
    {:noreply, push_row(socket, label, event.text, event.thinking?)}
  end

  def handle_info({:harness_event, %Event.ToolCall{} = event}, socket) do
    {:noreply, push_row(socket, "tool_call", "#{event.name} #{inspect(event.input)}", false)}
  end

  def handle_info({:harness_event, %Event.ToolResult{} = event}, socket) do
    {:noreply, push_row(socket, "tool_result", inspect(event.content), false)}
  end

  def handle_info({:harness_event, %Event.Usage{} = event}, socket) do
    {:noreply,
     push_row(socket, "usage", "in=#{event.input_tokens} out=#{event.output_tokens}", false)}
  end

  def handle_info({:harness_event, %Event.Status{} = event}, socket) do
    {:noreply, push_row(socket, "status", "#{event.kind} #{inspect(event.detail)}", false)}
  end

  def handle_info({:harness_event, %Event.Done{} = event}, socket) do
    status = if event.ok, do: :succeeded, else: :failed
    {:noreply, push_row(socket, "done", "reason=#{event.reason}", false, status)}
  end

  def handle_info({:harness_event, %Event.Error{} = event}, socket) do
    {:noreply, push_row(socket, "error", "#{event.reason}: #{event.message}", false, :failed)}
  end

  @spec push_row(Phoenix.LiveView.Socket.t(), String.t(), String.t(), boolean()) ::
          Phoenix.LiveView.Socket.t()
  defp push_row(socket, kind, body, thinking?, status \\ nil) do
    seq = socket.assigns.seq + 1
    row = %{id: seq, kind: kind, body: body, thinking?: thinking?}

    socket
    |> assign(:seq, seq)
    |> then(fn s -> if status, do: assign(s, :status, status), else: s end)
    |> stream_insert(:events, row, at: -1, limit: -500)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-4">
        <div class="flex items-center justify-between">
          <h1 class="text-xl font-semibold">Agent <code>{@agent_id}</code></h1>
          <span class="badge">{@status}</span>
        </div>

        <div class="flex gap-2">
          <button class="btn btn-primary" phx-click="start">Start</button>
          <button class="btn btn-ghost" phx-click="interrupt">Interrupt</button>
        </div>

        <ul id="events" phx-update="stream" class="space-y-1 font-mono text-sm">
          <li
            :for={{dom_id, row} <- @streams.events}
            id={dom_id}
            class={row.thinking? && "opacity-60 italic"}
          >
            <span class="font-semibold">{row.kind}</span>
            <span>{row.body}</span>
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
  end
end
