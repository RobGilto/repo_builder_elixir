defmodule RepoBuilder.WorkflowEngine.Runner do
  @moduledoc """
  Deterministic ADW state machine, one GenServer per running workflow
  (BUILD_PROMPT.md §7), supervised by `RepoBuilder.WorkflowSupervisor`.

  `workflow_runs` is the SOURCE OF TRUTH: every transition (step start, success,
  failure, current_step change, accumulated cost) is persisted there BEFORE the
  next step. This GenServer is a fast cache of that row.

  Each `:running` step renders its prompt from accumulated artifacts (deterministic),
  starts a LIVE session (§6) for the step's harness, subscribes to that session's
  canonical events, captures the terminal `Done`/`Error` plus final text/usage as
  the step output, then follows the `on_success`/`on_failure` edge. A failed step is
  isolated — it follows `on_failure`, it does not crash the workflow (or any other).

  `:temporary` — a finished/crashed run is not auto-restarted; resume is the M5
  `WorkflowResume` reconciler's job.
  """
  use GenServer, restart: :temporary

  require Logger

  alias RepoBuilder.Budget
  alias RepoBuilder.Budget.Scope
  alias RepoBuilder.Harness.Event
  alias RepoBuilder.Logs.Usage
  alias RepoBuilder.Projects.Worktree
  alias RepoBuilder.Session
  alias RepoBuilder.WorkflowEngine
  alias RepoBuilder.WorkflowEngine.Step
  alias RepoBuilder.Workflows
  alias RepoBuilder.Workflows.WorkflowRun

  @pubsub RepoBuilder.PubSub

  defmodule State do
    @moduledoc false
    use TypedStruct

    typedstruct enforce: true do
      field :run, WorkflowRun.t()
      field :steps, %{optional(String.t()) => Step.t()}
      field :current_step, String.t(), enforce: false
      field :artifacts, map(), default: %{}
      field :session_agent_id, String.t(), enforce: false
      field :text_buf, String.t(), default: ""
      # Execution location threaded from `start_workflow/2` (fix planning-wizard
      # target-repo launch): the target project's working directory and its isolation
      # mode. Both nil ⇒ each step runs in an ephemeral managed scratch workspace.
      field :cwd, Path.t(), enforce: false
      field :isolation_mode, atom(), enforce: false
    end
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    workflow = Keyword.fetch!(opts, :workflow)
    run = Keyword.fetch!(opts, :run)
    inputs = Keyword.get(opts, :inputs, %{})

    state = %State{
      run: run,
      steps: parse_steps(workflow.steps),
      current_step: first_step_name(workflow.steps),
      artifacts: stringify_keys(inputs),
      cwd: Keyword.get(opts, :cwd),
      isolation_mode: Keyword.get(opts, :isolation_mode)
    }

    if state.current_step do
      {:ok, state, {:continue, :run_step}}
    else
      {:ok, finalize(state, :succeeded), {:continue, :stop}}
    end
  end

  @impl true
  def handle_continue(:stop, state), do: {:stop, :normal, state}

  def handle_continue(:run_step, %State{current_step: name} = state) do
    step = Map.fetch!(state.steps, name)
    {:ok, run} = Workflows.update_run(state.run, %{status: :running, current_step: name})
    # Per-step observability: mark this step running, then broadcast the lane + progress.
    run = WorkflowEngine.record_step_state(run, name, %{status: :running, started_at: now()})
    broadcast_lane(run, :running)
    agent_id = WorkflowEngine.step_agent_id(run.id, name)
    :ok = Phoenix.PubSub.subscribe(@pubsub, "agent:#{agent_id}:events")
    state = %{state | run: run, session_agent_id: agent_id, text_buf: ""}
    prompt = render(step.prompt_template, state.artifacts)

    # Budget breaker (issue-budget-guardrails): a tripped cap in this run's scope blocks
    # the step. Isolated — the step follows `on_failure`, the transition persists to
    # `workflow_runs`, and neither this run nor any other crashes.
    case Budget.Guard.check(Scope.scopes_for(%{workflow_run_id: run.id})) do
      :ok ->
        start_step_session(state, name, step, agent_id, prompt)

      {:error, {:budget_exceeded, cap}} ->
        Logger.warning("workflow #{run.id} step #{name} blocked by budget cap #{cap.id}")
        state = record_step(state, name, :failed, nil)
        reply(advance(state, step.on_failure))
    end
  end

  @spec start_step_session(State.t(), String.t(), Step.t(), String.t(), String.t()) ::
          {:noreply, State.t()}
          | {:noreply, State.t(), {:continue, :run_step}}
          | {:stop, :normal, State.t()}
  defp start_step_session(%State{run: run} = state, name, step, agent_id, prompt) do
    case Session.Supervisor.start_session(
           agent_id: agent_id,
           harness: step.harness,
           prompt: prompt,
           workflow_run_id: run.id,
           workflow_run_db_id: run.id,
           # Run THIS step in the target repo (fix planning-wizard target-repo launch).
           # The session runtime (§6) honours these from Phase 4: a nil `cwd` falls back
           # to the managed scratch workspace and a nil `isolation_mode` runs direct, so
           # every cwd-less caller is unchanged.
           run_id: run.id,
           cwd: state.cwd,
           isolation_mode: state.isolation_mode
         ) do
      {:ok, _pid} ->
        {:noreply, maybe_record_worktree(state)}

      {:error, reason} ->
        Logger.warning("workflow #{run.id} step #{name} could not start: #{inspect(reason)}")
        state = record_step(state, name, :failed, nil)
        reply(advance(state, step.on_failure))
    end
  end

  # Persist the run's reviewable worktree (path + `adw/<run_id>` branch) for the UI
  # PR/merge handoff once the worktree-backed session has started. The provisioning is
  # deterministic (`Worktree`), so this records the same path the session resolved
  # without re-provisioning. Guarded for the non-git fallthrough (no worktree) and the
  # direct/managed paths, where there is nothing to record. Updates `state.run` so the
  # later `finalize/2` write keeps the worktree columns.
  @spec maybe_record_worktree(State.t()) :: State.t()
  defp maybe_record_worktree(%State{cwd: cwd, isolation_mode: :worktree, run: run} = state)
       when is_binary(cwd) do
    if Worktree.git_repo?(cwd) do
      %{path: path, branch: branch} = Worktree.expected_info(cwd, run.id)

      case Workflows.record_worktree(run, %{path: path, branch: branch}) do
        {:ok, updated} -> %{state | run: updated}
        {:error, _changeset} -> state
      end
    else
      state
    end
  end

  defp maybe_record_worktree(state), do: state

  @impl true
  def handle_info(
        {:harness_event, %Event.TextDelta{thinking?: false, text: text}},
        %State{} = state
      ) do
    {:noreply, %{state | text_buf: state.text_buf <> text}}
  end

  def handle_info({:harness_event, %Event.Done{} = done}, %State{current_step: name} = state) do
    step = Map.fetch!(state.steps, name)
    output = done.final_text || state.text_buf
    state = capture_output(state, name, output, done.cost_usd)
    state = record_step(state, name, :succeeded, done.cost_usd)
    reply(advance(state, step.on_success))
  end

  def handle_info({:harness_event, %Event.Error{} = error}, %State{current_step: name} = state) do
    step = Map.fetch!(state.steps, name)
    Logger.info("workflow #{state.run.id} step #{name} failed: #{error.reason}")
    state = record_step(state, name, :failed, nil)
    reply(advance(state, step.on_failure))
  end

  # Other canonical events are noise for the deterministic engine.
  def handle_info({:harness_event, _event}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  # --- transitions ---

  @typep transition :: {:cont, State.t()} | {:halt, State.t()}

  @spec reply(transition()) ::
          {:noreply, State.t(), {:continue, :run_step}} | {:stop, :normal, State.t()}
  defp reply({:cont, state}), do: {:noreply, state, {:continue, :run_step}}
  defp reply({:halt, state}), do: {:stop, :normal, state}

  @spec advance(State.t(), Step.edge()) :: transition()
  defp advance(state, edge) do
    unsubscribe(state)

    case edge do
      :done ->
        {:halt, finalize(state, :succeeded)}

      :abort ->
        {:halt, finalize(state, :failed)}

      next when is_binary(next) ->
        if Map.has_key?(state.steps, next) do
          {:cont, %{state | current_step: next, session_agent_id: nil}}
        else
          Logger.warning("workflow #{state.run.id}: unknown edge target #{inspect(next)}")
          {:halt, finalize(state, :failed)}
        end
    end
  end

  @spec finalize(State.t(), WorkflowRun.status()) :: State.t()
  defp finalize(state, status) do
    {:ok, run} = Workflows.update_run(state.run, %{status: status, artifacts: state.artifacts})
    broadcast_lane(run, status)
    # Re-engage the launching orchestrator (holding pattern) on a terminal run; no-op
    # when this run was not orchestrator-launched (issue-fallback).
    _ = WorkflowEngine.emit_orchestrator_resume(run, status == :succeeded)
    %{state | run: run, current_step: nil, session_agent_id: nil}
  end

  @spec broadcast_lane(WorkflowRun.t(), atom()) :: :ok
  defp broadcast_lane(run, status) do
    _ =
      RepoBuilder.Dashboard.broadcast_lane(%{
        id: "workflow:#{run.id}",
        kind: :workflow,
        label: run.current_step || "workflow",
        status: status,
        harness: nil
      })

    RepoBuilder.Dashboard.broadcast_workflow(run.id, {:workflow_update, run})
  end

  @spec capture_output(State.t(), String.t(), String.t() | nil, float() | nil) :: State.t()
  defp capture_output(state, name, output, cost) do
    {:ok, run} = Workflows.add_run_cost(state.run, Usage.cost_to_decimal(cost))
    %{state | run: run, artifacts: Map.put(state.artifacts, name, output)}
  end

  # Persist + broadcast one step's terminal per-step state via the shared engine seam.
  # `cost` is the step's display cost (string), never re-entering the run's Decimal
  # accumulation (`capture_output/4` already rolled it into the run total).
  @spec record_step(State.t(), String.t(), :succeeded | :failed, float() | nil) :: State.t()
  defp record_step(state, name, status, cost) do
    attrs = %{status: Atom.to_string(status), finished_at: now()}
    attrs = if cost_string(cost), do: Map.put(attrs, :cost_usd, cost_string(cost)), else: attrs
    %{state | run: WorkflowEngine.record_step_state(state.run, name, attrs)}
  end

  @spec cost_string(float() | nil) :: String.t() | nil
  defp cost_string(nil), do: nil

  defp cost_string(cost) when is_float(cost),
    do: cost |> Usage.cost_to_decimal() |> Decimal.to_string()

  @spec now() :: String.t()
  defp now, do: WorkflowEngine.now_iso()

  @spec unsubscribe(State.t()) :: :ok
  defp unsubscribe(%State{session_agent_id: nil}), do: :ok

  defp unsubscribe(%State{session_agent_id: agent_id}),
    do: Phoenix.PubSub.unsubscribe(@pubsub, "agent:#{agent_id}:events")

  # --- helpers ---

  @spec parse_steps([map()]) :: %{optional(String.t()) => Step.t()}
  defp parse_steps(steps) do
    Map.new(steps, fn step_map ->
      step = Step.from_map(step_map)
      {step.name, step}
    end)
  end

  @spec first_step_name([map()]) :: String.t() | nil
  defp first_step_name([]), do: nil
  defp first_step_name([first | _]), do: Map.fetch!(first, "name")

  @spec render(String.t(), map()) :: String.t()
  defp render(template, artifacts) do
    resolved =
      Enum.reduce(artifacts, template, fn {key, value}, acc ->
        String.replace(acc, "{{#{key}}}", to_string(value))
      end)

    # Drop any tokens whose artifact was never produced (e.g. {{plan}} in a build-only
    # workflow). Leaving them literal causes agents to see confusing template text.
    String.replace(resolved, ~r/\{\{[^}]+\}\}/, "")
  end

  @spec stringify_keys(map()) :: map()
  defp stringify_keys(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
end
