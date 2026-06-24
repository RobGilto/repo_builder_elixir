defmodule RepoBuilder.WorkflowEngine do
  @moduledoc """
  Facade for running ADWs (BUILD_PROMPT.md §7). `start_workflow/2` creates the
  durable `workflow_runs` row (source of truth) and starts a `Runner` under
  `RepoBuilder.WorkflowSupervisor`.
  """
  alias RepoBuilder.Dashboard
  alias RepoBuilder.Workers.StepWorker
  alias RepoBuilder.WorkflowEngine.{Catalog, Runner}
  alias RepoBuilder.Workflows
  alias RepoBuilder.Workflows.{Workflow, WorkflowRun}

  @sup RepoBuilder.WorkflowSupervisor

  @type reason :: atom() | Ecto.Changeset.t()

  @doc """
  Create a run and start its Runner. Returns `{:ok, run_id, runner_pid}`.

  Optional opts thread the run's *execution location* down to each step session
  (agentic-layer adaptor — fix planning-wizard target-repo launch):

    * `:cwd` — the target project's working directory. Each step session runs there
      (`Session` §6) instead of an ephemeral managed scratch workspace. Omitted/`nil`
      ⇒ today's managed-scratch behaviour (every existing caller is unchanged).
    * `:isolation_mode` — `:worktree` provisions a git worktree+branch per run on a
      git-backed `:cwd`; `:direct`/`nil` runs in `:cwd` itself.
  """
  @spec start_workflow(Workflow.t(), keyword()) :: {:ok, Ecto.UUID.t(), pid()} | {:error, term()}
  def start_workflow(%Workflow{} = workflow, opts \\ []) do
    case Workflows.create_run(%{
           workflow_id: workflow.id,
           orchestrator_id: opts[:orchestrator_id],
           # Agentic-layer adaptor: scope the run to a target project when launched from
           # the planning wizard. Nullable ⇒ unchanged for every existing caller.
           project_id: opts[:project_id],
           status: :queued,
           current_step: first_step_name(workflow.steps)
         }) do
      {:ok, run} ->
        case DynamicSupervisor.start_child(
               @sup,
               {Runner,
                workflow: workflow,
                run: run,
                inputs: opts[:inputs] || %{},
                cwd: opts[:cwd],
                isolation_mode: opts[:isolation_mode]}
             ) do
          {:ok, pid} -> {:ok, run.id, pid}
          {:error, reason} -> {:error, reason}
          other -> {:error, other}
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  DURABLE trigger (BUILD_PROMPT.md §7): create the run (source of truth) and enqueue
  the first step as an Oban `StepWorker` job. Survives a node restart — `inputs` are
  persisted into `workflow_runs.artifacts`. Returns `{:ok, run_id}`.
  """
  @spec enqueue_workflow(Workflow.t(), map()) :: {:ok, Ecto.UUID.t()} | {:error, term()}
  def enqueue_workflow(%Workflow{} = workflow, inputs \\ %{}) do
    first = first_step_name(workflow.steps)

    case Workflows.create_run(%{
           workflow_id: workflow.id,
           status: :queued,
           current_step: first,
           artifacts: stringify_keys(inputs)
         }) do
      {:ok, run} when is_binary(first) ->
        case StepWorker.enqueue(run.id, first) do
          {:ok, _job} -> {:ok, run.id}
          {:error, reason} -> {:error, reason}
        end

      {:ok, run} ->
        {:ok, run.id}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Build and persist a `Workflow` for a catalog `type` slug on `harness`. The chosen
  type is recorded on the row. An unknown type is `{:error, :unknown_type}` (validate
  at the tool boundary for a helpful message).
  """
  @spec create_workflow_of_type(String.t(), String.t(), String.t()) ::
          {:ok, Workflow.t()} | {:error, reason()}
  def create_workflow_of_type(name, type, harness \\ "fake") do
    case Catalog.steps(type, harness) do
      {:ok, steps} ->
        Workflows.create_workflow(%{name: name, type: type, state: :active, steps: steps})

      {:error, :unknown_type} = error ->
        error
    end
  end

  @doc """
  Create (and persist) the seeded default (`plan_build_review_fix`) workflow.
  Delegates to `create_workflow_of_type/3` (back-compat).
  """
  @spec create_example_workflow(String.t(), String.t()) ::
          {:ok, Workflow.t()} | {:error, reason()}
  def create_example_workflow(name, harness \\ "fake") do
    create_workflow_of_type(name, Catalog.default_type(), harness)
  end

  @doc """
  The ONE canonical step-session agent id, shared by the live Runner and the durable
  StepWorker so per-step logs/events correlate under a single prefix (`wf-<run>-<step>`).
  """
  @spec step_agent_id(Ecto.UUID.t(), String.t()) :: String.t()
  def step_agent_id(run_id, step_name), do: "wf-#{run_id}-#{step_name}"

  @doc """
  Persist one step's per-step state AND broadcast the refreshed per-step progress —
  the SHARED transition seam called by BOTH the live Runner and the durable
  StepWorker so the two paths emit the identical observability shape. Returns the
  updated run (or the unchanged run if the write fails — observability is never
  load-bearing for the run's terminal status).
  """
  @spec record_step_state(WorkflowRun.t(), String.t(), map()) :: WorkflowRun.t()
  def record_step_state(%WorkflowRun{} = run, step_name, attrs) do
    case Workflows.put_step_state(run, step_name, attrs) do
      {:ok, updated} ->
        _ = Dashboard.broadcast_workflow_step(updated.id, Workflows.run_progress(updated))
        updated

      {:error, _changeset} ->
        run
    end
  end

  @doc """
  Re-engage the launching orchestrator when an engine ADW run reaches a terminal state
  (issue-fallback). When `run.orchestrator_id` is set, broadcast the holding-pattern
  worker-terminal wakeup the `Queue` already consumes (`%{worker_id, name, ok?}` on the
  `orchestrator:<id>:workers` topic). A `nil` `orchestrator_id` is a no-op (the run was
  not orchestrator-launched). Wrapped defensively so a DB blip never breaks the run's
  terminal path. The SHARED seam called by BOTH the live Runner and durable StepWorker.
  """
  @spec emit_orchestrator_resume(WorkflowRun.t(), boolean()) :: :ok
  def emit_orchestrator_resume(%WorkflowRun{orchestrator_id: nil}, _ok?), do: :ok

  def emit_orchestrator_resume(%WorkflowRun{orchestrator_id: orchestrator_id} = run, ok?)
      when is_binary(orchestrator_id) do
    label = resume_label(run)

    Dashboard.broadcast_worker_terminal(orchestrator_id, %{
      worker_id: run.id,
      name: label,
      ok?: ok?
    })
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  @spec resume_label(WorkflowRun.t()) :: String.t()
  defp resume_label(%WorkflowRun{workflow_id: workflow_id}) when is_binary(workflow_id) do
    case Workflows.get_workflow(workflow_id) do
      %Workflow{type: type} when is_binary(type) -> type
      %Workflow{name: name} when is_binary(name) -> name
      _ -> "workflow"
    end
  end

  defp resume_label(_run), do: "workflow"

  @doc "An ISO-8601 UTC timestamp for per-step `started_at`/`finished_at` fields."
  @spec now_iso() :: String.t()
  def now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()

  @spec first_step_name([map()]) :: String.t() | nil
  defp first_step_name([]), do: nil
  defp first_step_name([first | _]), do: Map.get(first, "name")

  @spec stringify_keys(map()) :: map()
  defp stringify_keys(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
end
