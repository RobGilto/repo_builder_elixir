defmodule RepoBuilder.Orchestrator.Server do
  @moduledoc """
  Runs one orchestrator TURN as a harness session (issue-c).

  An orchestrator turn = one harness invocation, resumed across turns via the
  stored CLI `session_id` (Claude `--resume`, pi `--session`). `run_turn/2` mints a
  scoped tool token, builds the per-harness tool binding context + system prompt,
  and starts a `Session.Server` for the orchestrator — reusing the EXACT
  spawning/streaming/normalize/broadcast path workers use, so the orchestrator's
  canonical events stream to the console identically.

  This GenServer is a `:temporary` per-turn monitor under
  `RepoBuilder.OrchestratorSupervisor`. It subscribes to the orchestrator session's
  event topic to:

    * capture the resumable `session_id` and accumulate cost on the orchestrator row;
    * track status (`:running` → `:idle`/`:error`);
    * for a harness with NO external tool binding (e.g. Fake), dispatch the
      orchestrator's `tool_call` events in-process to `Orchestrator.Tools` — the
      same logic the MCP endpoint runs for Claude/pi out-of-band.
  """
  use GenServer, restart: :temporary

  require Logger

  alias RepoBuilder.{Dashboard, Logs, Orchestrators, Session}
  alias RepoBuilder.Harness.Event
  alias RepoBuilder.Harness.Registry, as: HarnessRegistry
  alias RepoBuilder.Orchestrator.{Queue, SystemPrompt, Tools}

  @sup RepoBuilder.OrchestratorSupervisor
  @pubsub RepoBuilder.PubSub

  defmodule State do
    @moduledoc false
    use TypedStruct

    typedstruct enforce: true do
      field :orchestrator_id, Ecto.UUID.t()
      field :agent_id, String.t()
      field :prompt, String.t()
      field :harness, String.t()
      field :in_process?, boolean()
    end
  end

  @doc """
  Run `prompt` as one orchestrator turn, routed through the per-orchestrator FIFO
  `Queue` (issue message-queue): when a turn is already in flight the prompt is
  appended instead of racing the same resumable CLI session. Returns the started
  turn's `agent_id` (used by the console for attribution) when it ran immediately,
  the sentinel `"queued"` when it was appended, or `{:error, reason}` when the
  orchestrator is missing or its harness is not orchestrator-capable.

  Kept as the back-compatible entry point; the queue is the serialization backbone.
  """
  @spec run_turn(Ecto.UUID.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def run_turn(orchestrator_id, prompt) do
    case Queue.enqueue(orchestrator_id, prompt) do
      {:ok, :started, agent_id} -> {:ok, agent_id}
      {:ok, :queued, _position} -> {:ok, "queued"}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec ensure_orchestrating(RepoBuilder.Orchestrator.Orchestrator.t()) ::
          :ok | {:error, :not_orchestrator_capable}
  defp ensure_orchestrating(orchestrator) do
    if HarnessRegistry.orchestrating?(orchestrator.harness),
      do: :ok,
      else: {:error, :not_orchestrator_capable}
  end

  # Refuse to run with no model selected, and surface it in the observability
  # system (a persisted Error event on the console feed) — not just a flash.
  @spec ensure_model(RepoBuilder.Orchestrator.Orchestrator.t()) ::
          :ok | {:error, :no_model_selected}
  defp ensure_model(orchestrator) do
    if blank?(orchestrator.model) do
      emit_no_model_error(orchestrator)
    else
      :ok
    end
  end

  @spec emit_no_model_error(RepoBuilder.Orchestrator.Orchestrator.t()) ::
          {:error, :no_model_selected}
  defp emit_no_model_error(orchestrator) do
    agent_id = "orch-#{orchestrator.id}-#{System.unique_integer([:positive])}"

    event = %Event.Error{
      harness: String.to_atom(orchestrator.harness),
      message: "no model selected — pick a model in the console header before running",
      reason: :no_model_selected,
      retryable: false
    }

    # Persist first so the global feed broadcast can carry the persisted row's durable
    # `seq_no` (the `log-<n>` drilldown number) — parity with the session path.
    seq_no =
      case Logs.persist_orchestrator_event(event, %{
             orchestrator_id: orchestrator.id,
             session_id: agent_id,
             provider: orchestrator.provider,
             model: orchestrator.model
           }) do
        {:ok, log} -> log.seq_no
        {:error, _changeset} -> nil
      end

    _ = Dashboard.broadcast_event(agent_id, event, seq_no)

    _ = Orchestrators.set_status(orchestrator.id, :error)
    {:error, :no_model_selected}
  end

  @spec blank?(String.t() | nil) :: boolean()
  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""

  @doc """
  Start ONE orchestrator turn and return the started per-turn process pid plus its
  `agent_id`, so the `Queue` can `Process.monitor/1` it and dequeue the next item
  when it stops (on `Done`/`Error`). Validates the orchestrator can run
  (orchestrator-capable harness + a selected model) exactly as `run_turn/2` did,
  surfacing `{:error, :not_orchestrator_capable}` / `{:error, :no_model_selected}`.
  """
  @spec start_turn(Ecto.UUID.t(), String.t()) ::
          {:ok, pid(), String.t()} | {:error, term()}
  def start_turn(orchestrator_id, prompt) do
    with {:ok, orchestrator} <- Orchestrators.fetch(orchestrator_id),
         :ok <- ensure_orchestrating(orchestrator),
         :ok <- ensure_model(orchestrator) do
      do_start_turn(orchestrator, prompt)
    end
  end

  @spec do_start_turn(RepoBuilder.Orchestrator.Orchestrator.t(), String.t()) ::
          {:ok, pid(), String.t()} | {:error, term()}
  defp do_start_turn(orchestrator, prompt) do
    agent_id = "orch-#{orchestrator.id}-#{System.unique_integer([:positive])}"

    child =
      {__MODULE__, orchestrator: orchestrator, agent_id: agent_id, prompt: prompt}

    case DynamicSupervisor.start_child(@sup, child) do
      {:ok, pid} -> {:ok, pid, agent_id}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  # --- server ---

  @impl true
  def init(opts) do
    orchestrator = Keyword.fetch!(opts, :orchestrator)
    adapter = adapter_for(orchestrator.harness)

    state = %State{
      orchestrator_id: orchestrator.id,
      agent_id: Keyword.fetch!(opts, :agent_id),
      prompt: Keyword.fetch!(opts, :prompt),
      harness: orchestrator.harness,
      in_process?: not function_exported?(adapter, :orchestrator_spawn, 2)
    }

    {:ok, {state, orchestrator}, {:continue, :launch}}
  end

  @impl true
  def handle_continue(:launch, {%State{} = state, orchestrator}) do
    _ = Phoenix.PubSub.subscribe(@pubsub, "agent:#{state.agent_id}:events")
    {:ok, token} = Orchestrators.mint_token(orchestrator.id)
    _ = Orchestrators.set_status(orchestrator.id, :running)

    opts = [
      agent_id: state.agent_id,
      harness: state.harness,
      prompt: state.prompt,
      session_id: orchestrator.session_id,
      # A Claude orchestrator with no explicit model still runs Opus (per-harness
      # orchestrator default); pi leaves it nil (operator-chosen).
      model:
        orchestrator.model ||
          HarnessRegistry.orchestrator_defaults(orchestrator.harness)[:default_model],
      provider: orchestrator.provider,
      reasoning_effort: orchestrator.reasoning_effort,
      # Operator-chosen working directory (nil ⇒ managed per-orchestrator workspace).
      # The runtime writes `.mcp.json`/per-session config here and resumes turns in it.
      cwd: orchestrator.working_dir,
      config: %{orchestrator: true},
      orchestrator_ctx: tool_ctx(orchestrator, token),
      orchestrator_db_id: orchestrator.id
    ]

    case Session.Supervisor.start_session(opts) do
      {:ok, _pid} ->
        {:noreply, state}

      {:error, reason} ->
        _ = Orchestrators.set_status(orchestrator.id, :error)
        Logger.warning("orchestrator turn failed to start: #{inspect(reason)}")
        {:stop, :normal, state}
    end
  end

  @impl true
  def handle_info({:harness_event, %Event.SessionStarted{session_id: sid}}, %State{} = state)
      when is_binary(sid) and sid != "" do
    _ = Orchestrators.set_session(state.orchestrator_id, sid)
    {:noreply, state}
  end

  def handle_info({:harness_event, %Event.ToolCall{} = event}, %State{in_process?: true} = state) do
    _ = Tools.call(event.name, state.orchestrator_id, event.input)
    {:noreply, state}
  end

  def handle_info({:harness_event, %Event.Usage{} = event}, %State{} = state) do
    _ = Orchestrators.add_cost(state.orchestrator_id, event.cost_usd)
    _ = Orchestrators.add_usage(state.orchestrator_id, event.input_tokens, event.output_tokens)
    {:noreply, state}
  end

  def handle_info({:harness_event, %Event.Done{} = event}, %State{} = state) do
    _ = Orchestrators.add_cost(state.orchestrator_id, event.cost_usd)
    _ = Orchestrators.set_status(state.orchestrator_id, if(event.ok, do: :idle, else: :error))
    {:stop, :normal, state}
  end

  def handle_info({:harness_event, %Event.Error{}}, %State{} = state) do
    _ = Orchestrators.set_status(state.orchestrator_id, :error)
    {:stop, :normal, state}
  end

  def handle_info({:harness_event, _event}, %State{} = state), do: {:noreply, state}
  def handle_info(_msg, %State{} = state), do: {:noreply, state}

  # --- helpers ---

  @spec tool_ctx(RepoBuilder.Orchestrator.Orchestrator.t(), String.t()) ::
          RepoBuilder.Harness.Orchestrating.tool_ctx()
  defp tool_ctx(orchestrator, token) do
    %{
      orchestrator_id: orchestrator.id,
      mcp_base_url: mcp_base_url(),
      token: token,
      resume_session_id: orchestrator.session_id,
      system_prompt: orchestrator.system_prompt || SystemPrompt.build(orchestrator),
      system_prompt_mode: orchestrator.system_prompt_mode,
      # Placeholder: the session runtime overwrites this with the real session cwd
      # (where `.mcp.json` etc. get written) before calling `orchestrator_spawn/2`.
      cwd: ""
    }
  end

  @spec mcp_base_url() :: String.t()
  defp mcp_base_url do
    Application.get_env(:repo_builder, :orchestrator, [])[:mcp_base_url] ||
      "http://127.0.0.1:4000"
  end

  @spec adapter_for(String.t()) :: module()
  defp adapter_for(harness) do
    case HarnessRegistry.fetch(harness) do
      {:ok, module} -> module
      {:error, :unknown_harness} -> __MODULE__
    end
  end
end
