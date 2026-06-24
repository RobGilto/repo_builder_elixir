defmodule RepoBuilder.Projects do
  @moduledoc """
  Context for first-class target repositories — the agentic-layer adaptor's data
  seam (BUILD_PROMPT.md §8). The only `Repo` caller for `projects`. Every public
  function is `@spec`'d and returns tagged tuples.

  A `nil` project everywhere else in the platform means "the platform itself"
  (today's back-compatible default); `active_or_default/1` resolves a (possibly nil)
  id to a concrete project, falling back to the seeded platform project.
  """
  import Ecto.Query, only: [from: 2]

  alias RepoBuilder.Projects.{Capabilities, ContextPrimer, Profiler, Project}
  alias RepoBuilder.Repo

  @spec list_projects() :: [Project.t()]
  def list_projects do
    Repo.all(from(p in Project, order_by: [asc: p.name]))
  end

  @spec get_project(Ecto.UUID.t()) :: Project.t() | nil
  def get_project(id), do: Repo.get(Project, id)

  @doc "Resolve a project by its (absolute) root path, or `nil`. Used to map a cwd to a project."
  @spec get_by_root_path(String.t()) :: Project.t() | nil
  def get_by_root_path(root_path) when is_binary(root_path),
    do: Repo.get_by(Project, root_path: Path.expand(root_path))

  @spec get_project!(Ecto.UUID.t()) :: Project.t()
  def get_project!(id), do: Repo.get!(Project, id)

  @spec fetch_project(Ecto.UUID.t()) :: {:ok, Project.t()} | {:error, :not_found}
  def fetch_project(id) do
    case Repo.get(Project, id) do
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  end

  @spec create_project(map()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def create_project(params) do
    %Project{}
    |> Project.changeset(params)
    |> Repo.insert()
  end

  @spec update_project(Project.t(), map()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def update_project(%Project{} = project, params) do
    project
    |> Project.changeset(params)
    |> Repo.update()
  end

  @spec delete_project(Project.t()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def delete_project(%Project{} = project), do: Repo.delete(project)

  @doc """
  Create a project AND profile its repo in one step (the registration flow): runs the
  Profiler against `root_path`, fills git metadata / detected stack / capability map /
  primed context, then merges the operator's explicit `params` on top (so operator
  overrides win). Falls back to a bare `create_project/1` when no `root_path` is given.

  When the operator opts in via a truthy `"create_dir"` param and `root_path` does not
  exist yet, the folder is created (`mkdir -p`) before profiling — a `{:error, changeset}`
  with a `:root_path` error is returned if creation fails (e.g. permissions).
  """
  @spec create_and_profile(map()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def create_and_profile(params) do
    case params["root_path"] || params[:root_path] do
      root when is_binary(root) and root != "" ->
        attrs = Map.drop(params, ["create_dir", :create_dir])
        create_dir? = truthy?(params["create_dir"] || params[:create_dir])

        with :ok <- maybe_create_dir(root, attrs, create_dir?) do
          profile_and_create(root, attrs)
        end

      _ ->
        create_project(params)
    end
  end

  @spec profile_and_create(String.t(), map()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  defp profile_and_create(root, attrs) do
    profile = Profiler.profile(root)

    attrs
    |> Map.merge(profile_attrs(profile), fn _k, operator, _profiled -> operator end)
    |> create_project()
  end

  # Create the target folder (mkdir -p) when the operator opted in and it doesn't exist.
  # On failure, surface an Ecto changeset error on :root_path so the UI can render it.
  @spec maybe_create_dir(String.t(), map(), boolean()) :: :ok | {:error, Ecto.Changeset.t()}
  defp maybe_create_dir(_root, _attrs, false), do: :ok

  defp maybe_create_dir(root, attrs, true) do
    expanded = Path.expand(root)

    if File.dir?(expanded) do
      :ok
    else
      case File.mkdir_p(expanded) do
        :ok -> :ok
        {:error, reason} -> {:error, mkdir_error(attrs, reason)}
      end
    end
  end

  @spec mkdir_error(map(), File.posix()) :: Ecto.Changeset.t()
  defp mkdir_error(attrs, reason) do
    %Project{}
    |> Project.changeset(attrs)
    |> Ecto.Changeset.add_error(
      :root_path,
      "could not create folder: #{:file.format_error(reason)}"
    )
    |> Map.put(:action, :insert)
  end

  @spec truthy?(term()) :: boolean()
  defp truthy?(value), do: value in [true, "true", "on", "1"]

  @doc """
  Re-run the Profiler for an existing project and persist the refreshed git metadata,
  detected stack, capability map, and primed orchestrator context. Operator-set
  defaults (harness/model/budget/isolation/pack pins) are untouched.
  """
  @spec refresh_profile(Project.t()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def refresh_profile(%Project{root_path: root} = project) when is_binary(root) do
    update_project(project, profile_attrs(Profiler.profile(root)))
  end

  # Profile → the changeset attrs it populates (string keys, since the changeset and
  # the registration form both speak string keys).
  @spec profile_attrs(Profiler.t()) :: %{optional(String.t()) => term()}
  defp profile_attrs(%Profiler{} = profile) do
    %{
      "git_remote" => profile.git_remote,
      "default_branch" => profile.default_branch,
      "stack" => profile.stack,
      "capabilities" => Capabilities.to_map(profile.capabilities),
      "context_primer" => ContextPrimer.render(profile)
    }
  end

  @doc """
  The platform's own project — the seeded row whose `root_path` is the BEAM cwd, or
  the earliest project as a fallback. `nil` only before seeding.
  """
  @spec default_project() :: Project.t() | nil
  def default_project do
    root = File.cwd!()

    case Repo.get_by(Project, root_path: root) do
      %Project{} = project -> project
      nil -> Repo.one(from(p in Project, order_by: [asc: p.inserted_at], limit: 1))
    end
  end

  @doc """
  Resolve a (possibly nil) project id to a concrete project: the named project when
  found, otherwise the seeded default platform project. `nil` only when no project
  exists at all.
  """
  @spec active_or_default(Ecto.UUID.t() | nil) :: Project.t() | nil
  def active_or_default(nil), do: default_project()

  def active_or_default(id) when is_binary(id) do
    case Repo.get(Project, id) do
      %Project{} = project -> project
      nil -> default_project()
    end
  end
end
