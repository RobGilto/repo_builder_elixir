defmodule RepoBuilder.Budget.Scope do
  @moduledoc """
  The budget SCOPE vocabulary (issue-budget-guardrails). A `scope_ref` identifies a
  bucket that spend is attributed to and that a `Budget.Cap` can limit:

    * `{:global, ""}`       — all spend, platform-wide (the `""` sentinel keeps the
      caps unique key total/NULL-free, mirroring `CostCenter`'s provider convention).
    * `{:orchestrator, id}` — spend driven by one orchestrator and its workers.
    * `{:workflow, run_id}` — spend of one workflow run.
    * `{:project, id}`      — spend attributed to one project (issue per-project-cost).

  `scopes_for/1` derives the list of scope_refs a given session/step/worker belongs to,
  so one unit of spend is checked against the global cap AND its orchestrator/workflow
  caps at once. Pure — no `Repo`, fully unit-testable.
  """

  @global_id ""

  @type scope ::
          :global | :orchestrator | :workflow | :project
  @type scope_ref ::
          {:global, String.t()}
          | {:orchestrator, String.t()}
          | {:workflow, String.t()}
          | {:project, String.t()}

  @doc "The canonical global scope_ref (always applies)."
  @spec global() :: scope_ref()
  def global, do: {:global, @global_id}

  @doc "The `\"\"` sentinel used for the global scope's `scope_id`."
  @spec global_id() :: String.t()
  def global_id, do: @global_id

  @doc """
  Build the list of scope_refs that apply to a context map. `{:global, \"\"}` is always
  included; `:orchestrator_id`/`:workflow_run_id`/`:project_id` (when present and non-blank)
  add their scoped refs. Accepts string or atom keys; blank/nil ids are ignored.
  """
  @spec scopes_for(map()) :: [scope_ref()]
  def scopes_for(context) when is_map(context) do
    [global()]
    |> maybe_add(:orchestrator, fetch(context, :orchestrator_id))
    |> maybe_add(:workflow, fetch(context, :workflow_run_id))
    |> maybe_add(:project, fetch(context, :project_id))
  end

  # Inference-only specs: the concrete return types narrow below a hand-written spec,
  # which Dialyzer rejects as a contract supertype.
  defp maybe_add(refs, _scope, nil), do: refs
  defp maybe_add(refs, scope, id), do: refs ++ [{scope, id}]

  # Read a key from a string- or atom-keyed map, normalizing "" / nil to nil.
  defp fetch(context, key) do
    value = Map.get(context, key) || Map.get(context, to_string(key))

    case value do
      v when is_binary(v) and v != "" -> v
      _ -> nil
    end
  end
end
