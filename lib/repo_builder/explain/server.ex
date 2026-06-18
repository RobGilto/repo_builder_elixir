defmodule RepoBuilder.Explain.Server do
  @moduledoc """
  Ephemeral one-shot runner for an "explain these logs" request (issue-explain).

  A `:temporary` GenServer under `RepoBuilder.ExplainSupervisor` that runs exactly
  ONE Fast-tier harness session and replies to the requesting LiveView. It:

    * subscribes to the run's PRIVATE per-agent topic BEFORE starting the session
      (avoids the start/subscribe race);
    * starts the session through `RepoBuilder.Session.Supervisor` with
      `broadcast_feed?: false` and NO `agent_db_id`/`orchestrator_db_id`, so the run
      neither persists to `agent_logs` nor reaches the global console feed/swimlanes;
    * accumulates finalized assistant text (`TextDelta{partial?: false}`) and, on
      `Done`, prefers `final_text`, replying `{:explain_result, request_id, {:ok, text}}`;
    * on `Error` or a watchdog timeout, stops the session and replies `{:error, _}`.

  It writes the DB never and stops as soon as it has a terminal result.
  """
  use GenServer, restart: :temporary

  alias RepoBuilder.Explain.Request
  alias RepoBuilder.Harness.Event
  alias RepoBuilder.Session

  @sup RepoBuilder.ExplainSupervisor
  @pubsub RepoBuilder.PubSub

  # A hung provider can't leak the ephemeral run: on timeout we stop the session and
  # reply `{:error, :timeout}`.
  @watchdog_ms 60_000

  defmodule State do
    @moduledoc false
    use TypedStruct

    typedstruct enforce: true do
      field :request, Request.t()
      field :agent_id, String.t()
      field :acc, String.t(), default: ""
      field :watchdog_ref, reference(), enforce: false
    end
  end

  @doc "Start the ephemeral runner for `request` under its DynamicSupervisor."
  @spec start(Request.t()) :: DynamicSupervisor.on_start_child()
  def start(%Request{} = request) do
    DynamicSupervisor.start_child(@sup, {__MODULE__, request})
  end

  @spec start_link(Request.t()) :: GenServer.on_start()
  def start_link(%Request{} = request), do: GenServer.start_link(__MODULE__, request)

  @impl true
  def init(%Request{} = request) do
    state = %State{request: request, agent_id: "explain-" <> request.request_id}
    {:ok, state, {:continue, :launch}}
  end

  @impl true
  def handle_continue(:launch, %State{request: request, agent_id: agent_id} = state) do
    # Subscribe BEFORE the session starts so no early event is missed.
    _ = Phoenix.PubSub.subscribe(@pubsub, "agent:#{agent_id}:events")

    opts = [
      agent_id: agent_id,
      harness: request.harness,
      prompt: request.prompt,
      model: request.model,
      provider: request.provider,
      # Ephemeral: an isolated scratch workspace (cwd: nil), no global feed, and —
      # by passing neither `agent_db_id` nor `orchestrator_db_id` — no persistence.
      cwd: nil,
      broadcast_feed?: false
    ]

    case Session.Supervisor.start_session(opts) do
      {:ok, _pid} ->
        ref = Process.send_after(self(), :watchdog, @watchdog_ms)
        {:noreply, %{state | watchdog_ref: ref}}

      {:error, reason} ->
        reply(state, {:error, reason})
        {:stop, :normal, state}
    end
  end

  @impl true
  def handle_info(
        {:harness_event, %Event.TextDelta{partial?: false, text: text}},
        %State{} = state
      ) do
    {:noreply, %{state | acc: state.acc <> text}}
  end

  def handle_info({:harness_event, %Event.Done{} = event}, %State{} = state) do
    text = finalize(event.final_text, state.acc)
    reply(state, {:ok, text})
    {:stop, :normal, state}
  end

  def handle_info({:harness_event, %Event.Error{reason: reason}}, %State{} = state) do
    reply(state, {:error, reason})
    {:stop, :normal, state}
  end

  def handle_info({:harness_event, _event}, %State{} = state), do: {:noreply, state}

  def handle_info(:watchdog, %State{} = state) do
    _ = Session.Supervisor.stop_session(state.agent_id)
    reply(state, {:error, :timeout})
    {:stop, :normal, state}
  end

  def handle_info(_msg, %State{} = state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %State{watchdog_ref: ref}) do
    _ = if ref, do: Process.cancel_timer(ref)
    :ok
  end

  # --- helpers ---

  # Prefer the harness's finalized `final_text`; fall back to the accumulated stream.
  @spec finalize(String.t() | nil, String.t()) :: String.t()
  defp finalize(final_text, _acc) when is_binary(final_text) and final_text != "", do: final_text
  defp finalize(_final_text, acc), do: acc

  @spec reply(State.t(), {:ok, String.t()} | {:error, term()}) :: :ok
  defp reply(%State{request: %Request{request_id: id, reply_to: pid}}, result) do
    send(pid, {:explain_result, id, result})
    :ok
  end
end
