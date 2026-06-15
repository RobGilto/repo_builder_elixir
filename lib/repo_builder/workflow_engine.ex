defmodule RepoBuilder.WorkflowEngine do
  @moduledoc """
  Facade for running ADWs (BUILD_PROMPT.md §7). `start_workflow/2` creates the
  durable `workflow_runs` row (source of truth) and starts a `Runner` under
  `RepoBuilder.WorkflowSupervisor`.
  """
  alias RepoBuilder.Workers.StepWorker
  alias RepoBuilder.WorkflowEngine.Runner
  alias RepoBuilder.Workflows
  alias RepoBuilder.Workflows.Workflow

  @sup RepoBuilder.WorkflowSupervisor

  @doc "Create a run and start its Runner. Returns `{:ok, run_id, runner_pid}`."
  @spec start_workflow(Workflow.t(), keyword()) :: {:ok, Ecto.UUID.t(), pid()} | {:error, term()}
  def start_workflow(%Workflow{} = workflow, opts \\ []) do
    case Workflows.create_run(%{
           workflow_id: workflow.id,
           status: :queued,
           current_step: first_step_name(workflow.steps)
         }) do
      {:ok, run} ->
        case DynamicSupervisor.start_child(
               @sup,
               {Runner, workflow: workflow, run: run, inputs: opts[:inputs] || %{}}
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
  The canonical `plan → build → review → fix` example ADW step list, parameterized
  by harness. Deterministic edges: plan→build→review, review succeeds to `:done`
  or branches to `fix` on failure, fix→`:done`.
  """
  @spec example_steps(String.t()) :: [map()]
  def example_steps(harness \\ "fake") do
    [
      %{
        "name" => "plan",
        "harness" => harness,
        "prompt_template" => "Plan the work for: {{input}}",
        "on_success" => "build",
        "on_failure" => "abort"
      },
      %{
        "name" => "build",
        "harness" => harness,
        "prompt_template" => "Build from the plan: {{plan}}",
        "on_success" => "review",
        "on_failure" => "abort"
      },
      %{
        "name" => "review",
        "harness" => harness,
        "prompt_template" => "Review the build: {{build}}",
        "on_success" => "done",
        "on_failure" => "fix"
      },
      %{
        "name" => "fix",
        "harness" => harness,
        "prompt_template" => "Fix the issues found: {{review}}",
        "on_success" => "done",
        "on_failure" => "abort"
      }
    ]
  end

  @doc "Create (and persist) the seeded plan→build→review→fix example workflow."
  @spec create_example_workflow(String.t(), String.t()) ::
          {:ok, Workflow.t()} | {:error, Ecto.Changeset.t()}
  def create_example_workflow(name, harness \\ "fake") do
    Workflows.create_workflow(%{name: name, state: :active, steps: example_steps(harness)})
  end

  @spec first_step_name([map()]) :: String.t() | nil
  defp first_step_name([]), do: nil
  defp first_step_name([first | _]), do: Map.get(first, "name")

  @spec stringify_keys(map()) :: map()
  defp stringify_keys(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
end
