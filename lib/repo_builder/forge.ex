defmodule RepoBuilder.Forge do
  @moduledoc """
  Context for the Forge (forge-meta-artifact-generation) — the ONLY `Repo` caller for
  `forge_artifacts`. Every public function is `@spec`'d and returns tagged tuples / typed
  values (BUILD_PROMPT.md §8).

  The Forge treats *generating a plugin* as a deterministic ADW: an operator `request/1`s
  a `kind` of tooling with a natural-language `spec` for a project (`nil` = platform-wide);
  `RepoBuilder.Forge.Workflow` renders the matching generator, drives a real harness
  session to write the artifact into an isolated scratch workspace, validates + packages
  it, and hands the package to the existing `Plugins` install → activate lifecycle. This
  module owns the durable record of that request and its lifecycle status.
  """
  import Ecto.Query, only: [from: 2]

  alias RepoBuilder.Forge.Artifact
  alias RepoBuilder.Repo

  @doc """
  Record a forge request (status `:requested`). `params` carries at least `kind` + `spec`;
  an unknown `kind` is rejected at the changeset boundary (`{:error, changeset}`).
  """
  @spec request(map()) :: {:ok, Artifact.t()} | {:error, Ecto.Changeset.t()}
  def request(params) when is_map(params) do
    %Artifact{}
    |> Artifact.changeset(params)
    |> Repo.insert()
  end

  @spec get(Ecto.UUID.t()) :: Artifact.t() | nil
  def get(id), do: Repo.get(Artifact, id)

  @spec fetch(Ecto.UUID.t()) :: {:ok, Artifact.t()} | {:error, :not_found}
  def fetch(id) do
    case Repo.get(Artifact, id) do
      nil -> {:error, :not_found}
      artifact -> {:ok, artifact}
    end
  end

  @doc "All forge requests for `project_id` (`nil` = platform), newest first."
  @spec list_for_project(Ecto.UUID.t() | nil) :: [Artifact.t()]
  def list_for_project(nil) do
    Repo.all(from(a in Artifact, where: is_nil(a.project_id), order_by: [desc: a.inserted_at]))
  end

  def list_for_project(project_id) when is_binary(project_id) do
    Repo.all(
      from(a in Artifact,
        where: a.project_id == ^project_id,
        order_by: [desc: a.inserted_at]
      )
    )
  end

  @doc """
  Transition an artifact to `status`, optionally merging extra columns (`output_path`,
  `plugin_id`, `workflow_run_id`, `error`).
  """
  @spec mark_status(Artifact.t(), Artifact.status(), map()) ::
          {:ok, Artifact.t()} | {:error, Ecto.Changeset.t()}
  def mark_status(%Artifact{} = artifact, status, extra \\ %{})
      when status in [:requested, :generating, :validating, :packaged, :installed, :failed] do
    params = Map.put(extra, :status, status)

    artifact
    |> Artifact.changeset(stringify_required(artifact, params))
    |> Repo.update()
  end

  # `changeset/2` requires kind + spec; on an update the struct already carries them, so
  # carry them forward rather than forcing callers to re-supply.
  @spec stringify_required(Artifact.t(), map()) :: map()
  defp stringify_required(%Artifact{kind: kind, spec: spec}, params) do
    params
    |> Map.put_new(:kind, kind)
    |> Map.put_new(:spec, spec)
  end
end
