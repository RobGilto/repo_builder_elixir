defmodule RepoBuilder.Workers.StepWorker do
  @moduledoc """
  Durable execution of ONE ADW step (BUILD_PROMPT.md §7).

  Chains the workflow by inserting the NEXT step's job from `perform/1` (OSS — no
  Pro DAG). Args are cast at the top of `perform/1`; NEVER-valid args return
  `{:cancel, _}` so a malformed payload does not become a retry storm / poison job.

  The unique key is `{workflow_run_id, step_name}` over available/scheduled/executing
  states, so a duplicate trigger (or the `WorkflowResume` reconciler re-enqueuing the
  current step) never double-runs a step.

  The hot streaming stays in the session GenServer (§6); this worker merely awaits
  that session's terminal event, honoring the durable/live split.
  """
  use Oban.Worker,
    queue: :workflows,
    max_attempts: 3,
    unique: [
      fields: [:worker, :args],
      keys: [:workflow_run_id, :step_name],
      period: :infinity,
      # All incomplete states — a step's job is deduped while available/scheduled/
      # executing/retryable/suspended, so a duplicate trigger or resume never double-runs.
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  require Logger

  alias RepoBuilder.Dashboard
  alias RepoBuilder.Harness.Event
  alias RepoBuilder.Logs.Usage
  alias RepoBuilder.Session
  alias RepoBuilder.WorkflowEngine
  alias RepoBuilder.WorkflowEngine.Step
  alias RepoBuilder.Workflows
  alias RepoBuilder.Workflows.{Workflow, WorkflowRun}

  @pubsub RepoBuilder.PubSub
  @step_timeout_ms 310_000

  @doc "Insert (or dedup) a durable job for one workflow step."
  @spec enqueue(Ecto.UUID.t(), String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(workflow_run_id, step_name) do
    %{"workflow_run_id" => workflow_run_id, "step_name" => step_name}
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    case cast_args(args) do
      {:ok, run_id, step_name} -> execute(run_id, step_name)
      :error -> {:cancel, :invalid_args}
    end
  end

  @doc "Execute a step for `run_id`/`step_name` (exposed for testing)."
  @spec execute(Ecto.UUID.t(), String.t()) :: :ok | {:cancel, term()} | {:error, term()}
  def execute(run_id, step_name) do
    run = Workflows.get_run(run_id)
    workflow = run && Workflows.get_workflow(run.workflow_id)

    cond do
      is_nil(run) -> {:cancel, :run_not_found}
      run.status not in [:queued, :running] -> :ok
      is_nil(workflow) -> {:cancel, :workflow_not_found}
      true -> drive(run, workflow, step_name)
    end
  end

  @spec drive(WorkflowRun.t(), Workflow.t(), String.t()) ::
          :ok | {:cancel, term()} | {:error, term()}
  defp drive(run, workflow, step_name) do
    case find_step(workflow, step_name) do
      nil ->
        {:cancel, :step_not_found}

      %Step{} = step ->
        {:ok, run} = Workflows.update_run(run, %{status: :running, current_step: step_name})
        # Per-step observability on the durable path (previously broadcast nothing):
        # mark this step running, broadcast the lane + progress, then run the session.
        run =
          WorkflowEngine.record_step_state(run, step_name, %{status: :running, started_at: now()})

        broadcast_lane(run, :running)
        agent_id = WorkflowEngine.step_agent_id(run.id, step_name)
        :ok = Phoenix.PubSub.subscribe(@pubsub, "agent:#{agent_id}:events")
        result = run_session(agent_id, step, run.artifacts)
        :ok = Phoenix.PubSub.unsubscribe(@pubsub, "agent:#{agent_id}:events")
        handle_result(result, run, step, workflow)
    end
  end

  @spec run_session(String.t(), Step.t(), map()) ::
          {:done, String.t() | nil, float() | nil} | {:error, term()} | :timeout
  defp run_session(agent_id, step, artifacts) do
    prompt = render(step.prompt_template, artifacts)

    case Session.Supervisor.start_session(
           agent_id: agent_id,
           harness: step.harness,
           prompt: prompt
         ) do
      {:ok, _pid} -> await(System.monotonic_time(:millisecond) + @step_timeout_ms, "")
      {:error, reason} -> {:error, reason}
    end
  end

  @spec await(integer(), String.t()) ::
          {:done, String.t() | nil, float() | nil} | {:error, term()} | :timeout
  defp await(deadline, buf) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:harness_event, %Event.TextDelta{thinking?: false, text: text}} ->
        await(deadline, buf <> text)

      {:harness_event, %Event.Done{} = done} ->
        {:done, done.final_text || buf, done.cost_usd}

      {:harness_event, %Event.Error{} = error} ->
        {:error, error.reason}

      {:harness_event, _other} ->
        await(deadline, buf)
    after
      timeout -> :timeout
    end
  end

  @spec handle_result(term(), WorkflowRun.t(), Step.t(), Workflow.t()) :: :ok | {:error, term()}
  defp handle_result({:done, output, cost}, run, step, workflow) do
    {:ok, run} = Workflows.add_run_cost(run, Usage.cost_to_decimal(cost))
    run = record_step(run, step.name, :succeeded, cost)
    artifacts = Map.put(run.artifacts, step.name, output)
    advance(run, workflow, step.on_success, artifacts)
  end

  defp handle_result({:error, reason}, run, step, workflow) do
    Logger.info("durable workflow #{run.id} step #{step.name} failed: #{inspect(reason)}")
    run = record_step(run, step.name, :failed, nil)
    advance(run, workflow, step.on_failure, run.artifacts)
  end

  defp handle_result(:timeout, run, step, _workflow) do
    Logger.warning("durable workflow #{run.id} step #{step.name} timed out")
    _ = record_step(run, step.name, :failed, nil)
    {:error, :step_timeout}
  end

  @spec advance(WorkflowRun.t(), Workflow.t(), Step.edge(), map()) :: :ok | {:error, term()}
  defp advance(run, _workflow, :done, artifacts) do
    {:ok, run} = Workflows.update_run(run, %{status: :succeeded, artifacts: artifacts})
    broadcast_lane(run, :succeeded)
    :ok
  end

  defp advance(run, _workflow, :abort, artifacts) do
    {:ok, run} = Workflows.update_run(run, %{status: :failed, artifacts: artifacts})
    broadcast_lane(run, :failed)
    :ok
  end

  defp advance(run, workflow, next, artifacts) when is_binary(next) do
    if find_step(workflow, next) do
      {:ok, run} =
        Workflows.update_run(run, %{status: :running, current_step: next, artifacts: artifacts})

      broadcast_lane(run, :running)

      case enqueue(run.id, next) do
        {:ok, _job} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, run} = Workflows.update_run(run, %{status: :failed, artifacts: artifacts})
      broadcast_lane(run, :failed)
      :ok
    end
  end

  # --- per-step observability (mirrors `Runner`, shared engine seam) ---

  # Persist + broadcast one step's terminal per-step state via the shared engine
  # seam. `cost` is a display string only — `add_run_cost/2` already owns the run's
  # Decimal total, so it never re-enters that path.
  @spec record_step(WorkflowRun.t(), String.t(), :succeeded | :failed, float() | nil) ::
          WorkflowRun.t()
  defp record_step(run, name, status, cost) do
    attrs = %{status: Atom.to_string(status), finished_at: now()}
    attrs = if cost_string(cost), do: Map.put(attrs, :cost_usd, cost_string(cost)), else: attrs
    WorkflowEngine.record_step_state(run, name, attrs)
  end

  # Mirror the live Runner's lane + per-run broadcast so a durable/resumed run is
  # visible to the console in real time (the durable path was observability-blind).
  @spec broadcast_lane(WorkflowRun.t(), atom()) :: :ok
  defp broadcast_lane(run, status) do
    _ =
      Dashboard.broadcast_lane(%{
        id: "workflow:#{run.id}",
        kind: :workflow,
        label: run.current_step || "workflow",
        status: status,
        harness: nil
      })

    Dashboard.broadcast_workflow(run.id, {:workflow_update, run})
  end

  @spec cost_string(float() | nil) :: String.t() | nil
  defp cost_string(nil), do: nil

  defp cost_string(cost) when is_float(cost),
    do: cost |> Usage.cost_to_decimal() |> Decimal.to_string()

  @spec now() :: String.t()
  defp now, do: WorkflowEngine.now_iso()

  # --- helpers ---

  @spec cast_args(map()) :: {:ok, Ecto.UUID.t(), String.t()} | :error
  defp cast_args(%{"workflow_run_id" => run_id, "step_name" => step_name})
       when is_binary(run_id) and is_binary(step_name) and step_name != "" do
    case Ecto.UUID.cast(run_id) do
      {:ok, uuid} -> {:ok, uuid, step_name}
      :error -> :error
    end
  end

  defp cast_args(_args), do: :error

  @spec find_step(Workflow.t(), String.t()) :: Step.t() | nil
  defp find_step(%Workflow{steps: steps}, name) do
    Enum.find_value(steps, fn step_map ->
      step = Step.from_map(step_map)
      if step.name == name, do: step
    end)
  end

  @spec render(String.t(), map()) :: String.t()
  defp render(template, artifacts) do
    Enum.reduce(artifacts, template, fn {key, value}, acc ->
      String.replace(acc, "{{#{key}}}", to_string(value))
    end)
  end
end
