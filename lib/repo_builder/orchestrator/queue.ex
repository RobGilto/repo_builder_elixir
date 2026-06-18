defmodule RepoBuilder.Orchestrator.Queue do
  @moduledoc """
  Per-orchestrator FIFO turn queue (issue message-queue).

  A long-lived GenServer (one per orchestrator id, registered on
  `RepoBuilder.OrchestratorQueueRegistry`, started on demand under
  `RepoBuilder.OrchestratorQueueSupervisor`) that SERIALIZES orchestrator turns so a
  second operator message sent mid-turn does not start a concurrent turn racing the
  same resumable CLI session (Claude `--resume`, pi `--session`).

  Lifecycle:

    * `enqueue/2` — when idle, start a turn immediately via `Server.start_turn/2`,
      `Process.monitor/1` the per-turn pid, and reply `{:ok, :started, agent_id}`.
      When busy, append the prompt and reply `{:ok, :queued, position}`.
    * the per-turn `Server` stops on `Done`/`Error`; its monitor `:DOWN` pops the head
      of the FIFO and starts it — guaranteeing only ONE turn resumes the session at a
      time, in operator order.
    * `cancel/2` removes a still-queued item (never the in-flight turn).
    * holding pattern — when `Orchestrators.auto_resume?/0` is enabled and the queue is
      fully idle, a worker-terminal signal enqueues ONE low-priority auto-resume turn so
      the orchestrator reviews the returned work. Operator messages always front-run it.

  The queue is in-memory runtime state (it does not survive a process restart), matching
  OTP norms — see the spec's Notes.
  """
  use GenServer

  alias RepoBuilder.Dashboard
  alias RepoBuilder.Logs
  alias RepoBuilder.Orchestrator.Server
  alias RepoBuilder.Orchestrators

  @registry RepoBuilder.OrchestratorQueueRegistry
  @sup RepoBuilder.OrchestratorQueueSupervisor

  @type kind :: :operator | :auto_resume
  @type item :: %{id: String.t(), prompt: String.t(), kind: kind()}
  @type snapshot :: %{
          busy?: boolean(),
          current: String.t() | nil,
          queued: [%{id: String.t(), preview: String.t(), kind: kind()}],
          depth: non_neg_integer()
        }
  @type enqueue_result ::
          {:ok, :started, String.t()} | {:ok, :queued, pos_integer()} | {:error, term()}
  @type starter :: (Ecto.UUID.t(), String.t() -> {:ok, pid(), String.t()} | {:error, term()})

  defmodule State do
    @moduledoc false
    use TypedStruct

    typedstruct enforce: true do
      field :orchestrator_id, Ecto.UUID.t()
      # FIFO of queued-item maps awaiting their turn.
      field :queue, :queue.queue()
      # The in-flight turn: {per-turn pid, monitor ref, agent_id}, or nil when idle.
      field :current, {pid(), reference(), String.t()} | nil
      # The pluggable turn launcher (defaults to Server.start_turn/2; tests inject a
      # controllable starter so the busy/idle state machine is fully deterministic).
      field :starter, (Ecto.UUID.t(), String.t() -> {:ok, pid(), String.t()} | {:error, term()})
    end
  end

  # --- client API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    orchestrator_id = Keyword.fetch!(opts, :orchestrator_id)
    GenServer.start_link(__MODULE__, opts, name: via(orchestrator_id))
  end

  @doc "Resolve the queue pid for `orchestrator_id`, starting it on demand."
  @spec start_or_get(Ecto.UUID.t()) :: {:ok, pid()} | {:error, term()}
  def start_or_get(orchestrator_id) do
    case whereis(orchestrator_id) do
      nil ->
        case DynamicSupervisor.start_child(@sup, {__MODULE__, orchestrator_id: orchestrator_id}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end

      pid ->
        {:ok, pid}
    end
  end

  @doc """
  Enqueue an operator `prompt` for `orchestrator_id`. Starts the queue on demand,
  runs the turn immediately when idle (`{:ok, :started, agent_id}`) or appends it
  (`{:ok, :queued, position}`). Rejects with `{:error, :queue_full}` past
  `Orchestrators.max_queue_depth/0` and surfaces start errors verbatim.
  """
  @spec enqueue(Ecto.UUID.t(), String.t()) :: enqueue_result()
  def enqueue(orchestrator_id, prompt) do
    with {:ok, pid} <- start_or_get(orchestrator_id) do
      GenServer.call(pid, {:enqueue, prompt, :operator})
    end
  end

  @doc "Cancel a still-queued item by id (never the in-flight turn)."
  @spec cancel(Ecto.UUID.t(), String.t()) :: {:ok, snapshot()} | {:error, :not_found}
  def cancel(orchestrator_id, id) do
    case whereis(orchestrator_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:cancel, id})
    end
  end

  @doc "The current queue snapshot for the console (busy?/current/queued/depth)."
  @spec snapshot(Ecto.UUID.t()) :: snapshot()
  def snapshot(orchestrator_id) do
    case whereis(orchestrator_id) do
      nil -> empty_snapshot()
      pid -> GenServer.call(pid, :snapshot)
    end
  end

  @doc "Resolve the queue pid for an orchestrator id, or nil when not running."
  @spec whereis(Ecto.UUID.t()) :: pid() | nil
  def whereis(orchestrator_id) do
    case Registry.lookup(@registry, orchestrator_id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @spec via(Ecto.UUID.t()) :: {:via, Registry, {module(), Ecto.UUID.t()}}
  defp via(orchestrator_id), do: {:via, Registry, {@registry, orchestrator_id}}

  # --- server ---

  @impl true
  def init(opts) do
    orchestrator_id = Keyword.fetch!(opts, :orchestrator_id)
    _ = Dashboard.subscribe_orchestrator_workers(orchestrator_id)

    state = %State{
      orchestrator_id: orchestrator_id,
      queue: :queue.new(),
      current: nil,
      starter: opts[:starter] || (&Server.start_turn/2)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:enqueue, prompt, kind}, _from, %State{current: nil} = state) do
    case start_item(state, build_item(prompt, kind)) do
      {:started, agent_id, state} ->
        log(state, "start", "started turn #{agent_id}")
        broadcast(state)
        {:reply, {:ok, :started, agent_id}, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:enqueue, prompt, kind}, _from, %State{} = state) do
    if :queue.len(state.queue) >= Orchestrators.max_queue_depth() do
      {:reply, {:error, :queue_full}, state}
    else
      item = build_item(prompt, kind)
      # Operator messages always front-run any pending auto-resume holding-pattern item.
      queue = item |> append_with_priority(state.queue)
      state = %{state | queue: queue}
      position = :queue.len(queue)
      log(state, "enqueue", "queued #{kind} at position #{position}")
      broadcast(state)
      {:reply, {:ok, :queued, position}, state}
    end
  end

  def handle_call({:cancel, id}, _from, %State{} = state) do
    list = :queue.to_list(state.queue)

    if Enum.any?(list, &(&1.id == id)) do
      queue = list |> Enum.reject(&(&1.id == id)) |> :queue.from_list()
      state = %{state | queue: queue}
      log(state, "cancel", "cancelled queued item #{id}")
      broadcast(state)
      {:reply, {:ok, to_snapshot(state)}, state}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:snapshot, _from, %State{} = state) do
    {:reply, to_snapshot(state), state}
  end

  @impl true
  def handle_info(
        {:DOWN, ref, :process, _down_pid, _reason},
        %State{current: {_pid, ref, _id}} = state
      ) do
    # The in-flight turn finished dispatching (Server stopped on Done/Error). Advance.
    state = %{state | current: nil}
    state = advance(state)
    broadcast(state)
    {:noreply, state}
  end

  # A dangling monitor (e.g. after a queue-process restart) — ignore, never wedge.
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, %State{} = state) do
    {:noreply, state}
  end

  def handle_info({:worker_terminal, info}, %State{} = state) do
    {:noreply, maybe_auto_resume(state, info)}
  end

  def handle_info(_msg, %State{} = state), do: {:noreply, state}

  # --- internals ---

  # Pop the head of the FIFO and start it, looping past items that fail to start so a
  # single bad turn never wedges the queue. Leaves :current nil when the queue drains.
  @spec advance(State.t()) :: State.t()
  defp advance(%State{} = state) do
    case :queue.out(state.queue) do
      {{:value, item}, rest} ->
        state = %{state | queue: rest}

        case start_item(state, item) do
          {:started, agent_id, state} ->
            log(state, "start", "started turn #{agent_id}")
            state

          {:error, _reason, state} ->
            advance(state)
        end

      {:empty, _queue} ->
        state
    end
  end

  # Launch one item via the (pluggable) starter, monitoring the per-turn pid on
  # success so its terminal :DOWN advances the queue.
  @spec start_item(State.t(), item()) ::
          {:started, String.t(), State.t()} | {:error, term(), State.t()}
  defp start_item(%State{} = state, item) do
    case state.starter.(state.orchestrator_id, item.prompt) do
      {:ok, pid, agent_id} ->
        ref = Process.monitor(pid)
        {:started, agent_id, %{state | current: {pid, ref, agent_id}}}

      {:error, reason} ->
        log(state, "error", "turn failed to start: #{inspect(reason)}")
        {:error, reason, state}
    end
  end

  # Holding pattern: only when enabled, fully idle, and not already holding an
  # auto-resume item — so worker-return bursts coalesce to at most one pending resume,
  # and any operator work suppresses it.
  @spec maybe_auto_resume(State.t(), map()) :: State.t()
  defp maybe_auto_resume(%State{current: nil} = state, info) do
    cond do
      not Orchestrators.auto_resume?() -> state
      not :queue.is_empty(state.queue) -> state
      true -> start_auto_resume(state, info)
    end
  end

  defp maybe_auto_resume(%State{} = state, _info), do: state

  @spec start_auto_resume(State.t(), map()) :: State.t()
  defp start_auto_resume(%State{} = state, info) do
    item = build_item(auto_resume_prompt(info), :auto_resume)

    case start_item(state, item) do
      {:started, agent_id, state} ->
        log(state, "auto_resume", "holding-pattern resume #{agent_id}")
        broadcast(state)
        state

      {:error, _reason, state} ->
        state
    end
  end

  @spec auto_resume_prompt(map()) :: String.t()
  defp auto_resume_prompt(info) do
    name = Map.get(info, :name) || "a worker"
    outcome = if Map.get(info, :ok?), do: "completed successfully", else: "finished with errors"

    "Worker #{name} #{outcome} and returned. Review its work and decide the next steps " <>
      "(report back, dispatch follow-up work, or stop)."
  end

  # Operator items go to the back, but ahead of any pending auto-resume item(s):
  # drop pending auto-resume entries (they re-trigger when idle) so operators win.
  @spec append_with_priority(item(), :queue.queue()) :: :queue.queue()
  defp append_with_priority(%{kind: :auto_resume} = item, queue), do: :queue.in(item, queue)

  defp append_with_priority(%{kind: :operator} = item, queue) do
    queue
    |> :queue.to_list()
    |> Enum.reject(&(&1.kind == :auto_resume))
    |> :queue.from_list()
    |> then(&:queue.in(item, &1))
  end

  @spec build_item(String.t(), kind()) :: item()
  defp build_item(prompt, kind) do
    %{id: gen_id(), prompt: prompt, kind: kind}
  end

  @spec gen_id() :: String.t()
  defp gen_id, do: "q-" <> (8 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))

  @spec broadcast(State.t()) :: :ok
  defp broadcast(%State{orchestrator_id: id} = state) do
    Dashboard.broadcast_orchestrator_queue(id, to_snapshot(state))
  end

  @spec snapshot(State.t()) :: snapshot()
  defp to_snapshot(%State{} = state) do
    %{
      busy?: state.current != nil,
      current: current_agent_id(state.current),
      queued:
        state.queue
        |> :queue.to_list()
        |> Enum.map(&%{id: &1.id, preview: preview(&1.prompt), kind: &1.kind}),
      depth: :queue.len(state.queue)
    }
  end

  @spec current_agent_id({pid(), reference(), String.t()} | nil) :: String.t() | nil
  defp current_agent_id({_pid, _ref, agent_id}), do: agent_id
  defp current_agent_id(nil), do: nil

  # Inference-only spec — the fully-concrete idle map narrows below the hand-written
  # `snapshot()` contract, which Dialyzer rejects as a supertype.
  defp empty_snapshot, do: %{busy?: false, current: nil, queued: [], depth: 0}

  @spec preview(String.t()) :: String.t()
  defp preview(prompt) do
    trimmed = String.trim(prompt)

    if String.length(trimmed) > 80 do
      String.slice(trimmed, 0, 80) <> "…"
    else
      trimmed
    end
  end

  # Queue lifecycle observability (parity with Tools). Wrapped quietly so a DB blip
  # (e.g. test sandbox teardown) never crashes the queue process.
  @spec log(State.t(), String.t(), String.t()) :: :ok
  defp log(%State{orchestrator_id: id}, action, message) do
    _ =
      Logs.create_system_log(%{
        level: :info,
        message: "orchestrator queue #{action}: #{message}",
        metadata: %{"orchestrator_id" => id, "action" => action}
      })

    :ok
  rescue
    _error -> :ok
  catch
    _kind, _value -> :ok
  end
end
