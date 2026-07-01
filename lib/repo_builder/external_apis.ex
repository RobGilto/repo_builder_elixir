defmodule RepoBuilder.ExternalApis do
  @moduledoc """
  Context for the registered external API / MCP provider registry
  (issue-external-api-mcp-provisioning). The ONLY `Repo` caller for `external_apis`
  (BUILD_PROMPT §8). Every public function is `@spec`'d, total, and returns tagged
  tuples — no raises on expected paths.

  Two scopes, mirroring `RepoBuilder.Secrets`: a `nil` `project_id` is the
  user/platform scope ("all orchestrators"); a concrete id is a single project's scope.
  `list_for_scope/1` drives the two UI lists (rows OWNED by exactly that scope);
  `list_in_scope_for/1` is the EFFECTIVE set an orchestrator sees (platform + its
  project, active only, project shadowing a same-named platform row).

  The registration references a vault secret by `secret_name` — this context never
  reads or returns the token.
  """
  import Ecto.Query, only: [from: 2]

  alias RepoBuilder.ExternalApis.ExternalApi
  alias RepoBuilder.Repo

  @doc """
  The registrations OWNED by exactly `project_id` (a project's own rows, or the
  platform `NULL` rows when `nil`) — both active and disabled, name-sorted. Drives the
  two operator UI lists.
  """
  @spec list_for_scope(Ecto.UUID.t() | nil) :: [ExternalApi.t()]
  def list_for_scope(project_id) do
    project_id
    |> scope_query()
    |> from(order_by: [asc: :name])
    |> Repo.all()
  end

  @doc """
  The EFFECTIVE set visible to an orchestrator on `project_id`: the platform (`NULL`)
  rows PLUS that project's rows, `status: :active` only, with a project row SHADOWING a
  same-named platform row. This is the orchestrator-visibility and provisioning lookup.
  """
  @spec list_in_scope_for(Ecto.UUID.t() | nil) :: [ExternalApi.t()]
  def list_in_scope_for(nil), do: active_rows(nil)

  def list_in_scope_for(project_id) do
    platform = active_rows(nil)
    project = active_rows(project_id)
    project_names = MapSet.new(project, & &1.name)

    (project ++ Enum.reject(platform, &MapSet.member?(project_names, &1.name)))
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Resolve a provision list (`names`) against `list_in_scope_for/1`, dropping unknown or
  disabled names. Order follows the requested `names`. Used by the provisioning resolver
  and the secret-injection seam.
  """
  @spec fetch_by_names(Ecto.UUID.t() | nil, [String.t()]) :: [ExternalApi.t()]
  def fetch_by_names(_project_id, []), do: []

  def fetch_by_names(project_id, names) when is_list(names) do
    by_name = Map.new(list_in_scope_for(project_id), &{&1.name, &1})

    names
    |> Enum.map(fn name -> Map.get(by_name, to_string(name)) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.id)
  end

  def fetch_by_names(_project_id, _names), do: []

  @doc "Fetch one registration by id."
  @spec get(Ecto.UUID.t()) :: {:ok, ExternalApi.t()} | {:error, :not_found}
  def get(id) do
    case Repo.get(ExternalApi, id) do
      %ExternalApi{} = api -> {:ok, api}
      nil -> {:error, :not_found}
    end
  end

  @doc "Register a new external API from `params` (string-keyed)."
  @spec create(map()) :: {:ok, ExternalApi.t()} | {:error, Ecto.Changeset.t()}
  def create(params) do
    %ExternalApi{}
    |> ExternalApi.changeset(params)
    |> Repo.insert()
  end

  @doc "Update an existing registration."
  @spec update(ExternalApi.t(), map()) :: {:ok, ExternalApi.t()} | {:error, Ecto.Changeset.t()}
  def update(%ExternalApi{} = api, params) do
    api
    |> ExternalApi.changeset(params)
    |> Repo.update()
  end

  @doc "Delete a registration by id (no-op if already gone)."
  @spec delete(Ecto.UUID.t()) :: :ok
  def delete(id) do
    _ = from(a in ExternalApi, where: a.id == ^id) |> Repo.delete_all()
    :ok
  end

  # --- internals ---

  @spec active_rows(Ecto.UUID.t() | nil) :: [ExternalApi.t()]
  defp active_rows(project_id) do
    project_id
    |> scope_query()
    |> from(where: [status: :active], order_by: [asc: :name])
    |> Repo.all()
  end

  # Scope to a concrete project, or to the platform (NULL) rows when nil.
  @spec scope_query(Ecto.UUID.t() | nil) :: Ecto.Query.t()
  defp scope_query(nil), do: from(a in ExternalApi, where: is_nil(a.project_id))
  defp scope_query(project_id), do: from(a in ExternalApi, where: a.project_id == ^project_id)
end
