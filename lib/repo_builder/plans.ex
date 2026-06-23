defmodule RepoBuilder.Plans do
  @moduledoc """
  Context for durable Plan artifacts (agentic-layer adaptor, Phase 6). The only `Repo`
  caller for `plans`. Every public function is `@spec`'d and returns tagged tuples.
  """
  import Ecto.Query, only: [from: 2]

  alias RepoBuilder.Plans.Plan
  alias RepoBuilder.Repo

  @spec create_plan(map()) :: {:ok, Plan.t()} | {:error, Ecto.Changeset.t()}
  def create_plan(params) do
    %Plan{}
    |> Plan.changeset(params)
    |> Repo.insert()
  end

  @spec get_plan(Ecto.UUID.t()) :: Plan.t() | nil
  def get_plan(id), do: Repo.get(Plan, id)

  @spec fetch_plan(Ecto.UUID.t()) :: {:ok, Plan.t()} | {:error, :not_found}
  def fetch_plan(id) do
    case Repo.get(Plan, id) do
      nil -> {:error, :not_found}
      plan -> {:ok, plan}
    end
  end

  @spec list_plans_for_project(Ecto.UUID.t()) :: [Plan.t()]
  def list_plans_for_project(project_id) do
    Repo.all(from(p in Plan, where: p.project_id == ^project_id, order_by: [desc: p.inserted_at]))
  end

  @doc "Mark a plan launched, linking it to the workflow run it kicked off."
  @spec mark_launched(Plan.t(), Ecto.UUID.t()) ::
          {:ok, Plan.t()} | {:error, Ecto.Changeset.t()}
  def mark_launched(%Plan{} = plan, workflow_run_id) do
    plan
    |> Plan.changeset(%{"status" => "launched", "workflow_run_id" => workflow_run_id})
    |> Repo.update()
  end
end
