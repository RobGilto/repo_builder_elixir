defmodule RepoBuilder.Workflows do
  @moduledoc """
  Context for ADW definitions and runs (BUILD_PROMPT.md §7/§8). The only `Repo`
  caller for `workflows`/`workflow_runs`. `workflow_runs` is the source of truth
  for run position; cost rolling preserves the NULL (unpriced) vs 0 distinction.
  """
  import Ecto.Query, only: [from: 2]

  alias RepoBuilder.Repo
  alias RepoBuilder.Workflows.{Workflow, WorkflowRun}

  # --- workflows ---

  @spec list_workflows() :: [Workflow.t()]
  def list_workflows, do: Repo.all(from(w in Workflow, order_by: [asc: w.name]))

  @spec get_workflow(Ecto.UUID.t()) :: Workflow.t() | nil
  def get_workflow(id), do: Repo.get(Workflow, id)

  @spec create_workflow(map()) :: {:ok, Workflow.t()} | {:error, Ecto.Changeset.t()}
  def create_workflow(params) do
    %Workflow{}
    |> Workflow.changeset(params)
    |> Repo.insert()
  end

  @spec update_workflow(Workflow.t(), map()) :: {:ok, Workflow.t()} | {:error, Ecto.Changeset.t()}
  def update_workflow(%Workflow{} = workflow, params) do
    workflow
    |> Workflow.changeset(params)
    |> Repo.update()
  end

  @spec delete_workflow(Workflow.t()) :: {:ok, Workflow.t()} | {:error, Ecto.Changeset.t()}
  def delete_workflow(%Workflow{} = workflow), do: Repo.delete(workflow)

  # --- runs ---

  @spec get_run(Ecto.UUID.t()) :: WorkflowRun.t() | nil
  def get_run(id), do: Repo.get(WorkflowRun, id)

  @spec create_run(map()) :: {:ok, WorkflowRun.t()} | {:error, Ecto.Changeset.t()}
  def create_run(params) do
    %WorkflowRun{}
    |> WorkflowRun.changeset(params)
    |> Repo.insert()
  end

  @spec update_run(WorkflowRun.t(), map()) ::
          {:ok, WorkflowRun.t()} | {:error, Ecto.Changeset.t()}
  def update_run(%WorkflowRun{} = run, params) do
    run
    |> WorkflowRun.changeset(params)
    |> Repo.update()
  end

  @doc """
  Roll a step's cost into the run total, preserving the unpriced (NULL) distinction:
  adding `nil` is a no-op (stays NULL until a priced amount arrives); adding a
  `Decimal` accumulates onto `current || 0`.
  """
  @spec add_run_cost(WorkflowRun.t(), Decimal.t() | nil) ::
          {:ok, WorkflowRun.t()} | {:error, Ecto.Changeset.t()}
  def add_run_cost(%WorkflowRun{} = run, nil), do: {:ok, run}

  def add_run_cost(%WorkflowRun{} = run, %Decimal{} = cost) do
    :telemetry.execute([:repo_builder, :cost, :recorded], %{amount: Decimal.to_float(cost)}, %{
      run_id: run.id
    })

    current = run.total_cost_usd || Decimal.new(0)
    update_run(run, %{total_cost_usd: Decimal.add(current, cost)})
  end

  @doc "Runs that are still in flight (no live Runner survives a restart) — the resume reconciler's input (M5)."
  @spec list_unfinished_runs() :: [WorkflowRun.t()]
  def list_unfinished_runs do
    Repo.all(from(r in WorkflowRun, where: r.status in [:queued, :running]))
  end

  @doc "The most recent runs (dashboard swimlane seeding)."
  @spec list_recent_runs(pos_integer()) :: [WorkflowRun.t()]
  def list_recent_runs(limit \\ 50) do
    Repo.all(from(r in WorkflowRun, order_by: [desc: r.updated_at], limit: ^limit))
  end
end
