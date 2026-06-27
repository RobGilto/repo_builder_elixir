defmodule RepoBuilder.Orchestrator.Reflections do
  @moduledoc """
  Context for the orchestrator's verbal self-improving memory (self-healing Phase 5 —
  Reflexion). The ONLY `Repo` caller for `orchestrator_reflections`. A reflection turn (after
  `report_complete` or escalation) records a one-line `lesson`; `SystemPrompt` injects the
  last N for a project on the next run so each run starts ahead of the last. Every public
  function is `@spec`'d; the write path is fail-soft.
  """
  import Ecto.Query, only: [from: 2]

  alias RepoBuilder.Orchestrator.Reflection
  alias RepoBuilder.Repo

  @default_limit 5

  @doc """
  Record one verbal lesson. `attrs` carries `:lesson` (required) and optional
  `:project_id`/`:orchestrator_id`/`:goal`. Fail-soft: a write error returns `:error` rather
  than raising into the calling turn.
  """
  @spec record(map()) :: {:ok, Reflection.t()} | :error
  def record(attrs) when is_map(attrs) do
    case %Reflection{} |> Reflection.changeset(normalize(attrs)) |> Repo.insert() do
      {:ok, reflection} -> {:ok, reflection}
      {:error, _changeset} -> :error
    end
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  @doc "The most recent `limit` lessons for a project (newest first). `nil` project ⇒ unscoped."
  @spec list_recent(Ecto.UUID.t() | nil, pos_integer()) :: [Reflection.t()]
  def list_recent(project_id, limit \\ @default_limit) do
    Reflection
    |> scope_by_project(project_id)
    |> then(&from(r in &1, order_by: [desc: r.inserted_at, desc: r.id], limit: ^limit))
    |> Repo.all()
  end

  @spec scope_by_project(Ecto.Queryable.t(), Ecto.UUID.t() | nil) :: Ecto.Query.t()
  defp scope_by_project(query, nil), do: from(r in query, where: is_nil(r.project_id))

  defp scope_by_project(query, project_id),
    do: from(r in query, where: r.project_id == ^project_id)

  @spec normalize(map()) :: map()
  defp normalize(attrs) do
    %{
      lesson: fetch(attrs, :lesson),
      goal: fetch(attrs, :goal),
      project_id: fetch(attrs, :project_id),
      orchestrator_id: fetch(attrs, :orchestrator_id)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  # Inference-only spec — the success typing narrows below a hand-written `term()` range.
  defp fetch(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, Atom.to_string(key))
    end
  end
end
