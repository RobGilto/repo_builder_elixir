defmodule RepoBuilder.Workflows.TitleHumanizer.Server do
  @moduledoc """
  Ephemeral one-shot runner for a Fast-tier ADW title humanization
  (issue-unified-adw-swimlane-cards).

  A `:temporary` GenServer under `RepoBuilder.TitleHumanizerSupervisor` that runs
  exactly ONE Fast-tier harness session and, on a finalized reply, persists the
  proposed title via `RepoBuilder.Workflows.TitleHumanizer.apply_title/2` (which
  writes `metadata["title"]` and broadcasts). It mirrors `RepoBuilder.Explain.Server`:

    * subscribes to the run's PRIVATE per-agent topic BEFORE starting the session;
    * starts the session with `broadcast_feed?: false` and NO `agent_db_id`/
      `orchestrator_db_id`, so the run neither persists to `agent_logs` nor reaches
      the global console feed/swimlanes;
    * accumulates finalized assistant text and, on `Done`, applies the title;
    * on `Error` or a watchdog timeout, stops the session and leaves the title
      untouched.

  Unlike `Explain.Server` there is no `reply_to`: the result is applied directly to
  the workflow, not messaged back.
  """
  use GenServer, restart: :temporary

  alias RepoBuilder.Harness.Event
  alias RepoBuilder.Session
  alias RepoBuilder.Workflows.{TitleHumanizer, Workflow}

  @sup RepoBuilder.TitleHumanizerSupervisor
  @pubsub RepoBuilder.PubSub
  @watchdog_ms 60_000

  defmodule State do
    @moduledoc false
    use TypedStruct

    typedstruct enforce: true do
      field :workflow, Workflow.t()
      field :config, map()
      field :agent_id, String.t()
      field :acc, String.t(), default: ""
      field :watchdog_ref, reference(), enforce: false
    end
  end

  @doc """
  The `TitleHumanizer` runner-seam entry point: start the ephemeral runner for
  `workflow` using the resolved Fast `config`. Fire-and-forget; returns the child
  start result (or `{:error, reason}` — the caller ignores it).
  """
  @spec dispatch(Workflow.t(), map()) :: DynamicSupervisor.on_start_child()
  def dispatch(%Workflow{} = workflow, config) do
    DynamicSupervisor.start_child(@sup, {__MODULE__, {workflow, config}})
  end

  @spec start_link({Workflow.t(), map()}) :: GenServer.on_start()
  def start_link({%Workflow{}, _config} = arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init({%Workflow{} = workflow, config}) do
    agent_id = "adw-title-" <> short_id(workflow.id)
    state = %State{workflow: workflow, config: config, agent_id: agent_id}
    {:ok, state, {:continue, :launch}}
  end

  @impl true
  def handle_continue(:launch, %State{} = state) do
    _ = Phoenix.PubSub.subscribe(@pubsub, "agent:#{state.agent_id}:events")

    opts = [
      agent_id: state.agent_id,
      harness: state.config.harness,
      prompt: TitleHumanizer.build_prompt(state.workflow),
      model: state.config.model,
      provider: state.config[:provider],
      cwd: nil,
      broadcast_feed?: false
    ]

    case Session.Supervisor.start_session(opts) do
      {:ok, _pid} ->
        ref = Process.send_after(self(), :watchdog, @watchdog_ms)
        {:noreply, %{state | watchdog_ref: ref}}

      {:error, _reason} ->
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
    _ = TitleHumanizer.apply_title(state.workflow, finalize(event.final_text, state.acc))
    {:stop, :normal, state}
  end

  def handle_info({:harness_event, %Event.Error{}}, %State{} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:harness_event, _event}, %State{} = state), do: {:noreply, state}

  def handle_info(:watchdog, %State{} = state) do
    _ = Session.Supervisor.stop_session(state.agent_id)
    {:stop, :normal, state}
  end

  def handle_info(_msg, %State{} = state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %State{watchdog_ref: ref}) do
    _ = if ref, do: Process.cancel_timer(ref)
    :ok
  end

  # --- helpers ---

  @spec finalize(String.t() | nil, String.t()) :: String.t()
  defp finalize(final_text, _acc) when is_binary(final_text) and final_text != "", do: final_text
  defp finalize(_final_text, acc), do: acc

  @spec short_id(Ecto.UUID.t() | nil) :: String.t()
  defp short_id(id), do: id |> to_string() |> String.slice(0, 8)
end
