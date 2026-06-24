defmodule RepoBuilder.Plans.Planner do
  @moduledoc """
  The pure planner (agentic-layer adaptor, Phase 6): turns `{project, goal,
  workflow_type, overrides}` into a previewable, costed plan with NO side effects and NO
  model call (deterministic — fast, free, testable). It composes existing engines:

    * `WorkflowEngine.Catalog.steps/2` for the step list,
    * `Commands.Resolver` for the stack-correct per-step prompt body + provenance,
    * `Orchestrator.ContextWindow` for the context-window reference,
    * a deterministic token→cost band for the estimate.

  Returns `{:ok, preview}` or `{:error, :unknown_type}`.
  """
  alias RepoBuilder.Commands
  alias RepoBuilder.Orchestrator.ContextWindow
  alias RepoBuilder.Projects.Project
  alias RepoBuilder.WorkflowEngine.Catalog

  # Nominal blended rate (USD/token) for a deterministic, model-free cost estimate.
  @usd_per_token 5.0e-6
  @preview_chars 400

  @type step_preview :: %{name: String.t(), provenance: String.t(), preview: String.t()}

  @type estimate :: %{
          context_tokens: non_neg_integer(),
          window: pos_integer(),
          estimated_cost_usd: float(),
          cost_band: String.t()
        }

  @type preview :: %{
          project_id: Ecto.UUID.t(),
          goal: String.t(),
          workflow_type: String.t(),
          harness: String.t(),
          model: String.t() | nil,
          intent: String.t(),
          steps: [step_preview()],
          estimate: estimate()
        }

  @doc """
  Resolve a previewable plan. `input` keys: `:project` (a `Project.t()`), `:goal`,
  `:workflow_type`, and optional `:harness`/`:model` overrides.
  """
  @spec resolve(%{
          required(:project) => Project.t(),
          required(:goal) => String.t(),
          required(:workflow_type) => String.t(),
          optional(:harness) => String.t() | nil,
          optional(:model) => String.t() | nil
        }) :: {:ok, preview()} | {:error, :unknown_type}
  def resolve(%{project: %Project{} = project, goal: goal, workflow_type: type} = input) do
    harness = resolve_harness(input[:harness], project)
    model = input[:model]

    case Catalog.steps(type, harness) do
      {:ok, steps} ->
        previews = Enum.map(steps, &step_preview(project, &1))
        {:ok, build_preview(project, goal, type, harness, model, previews)}

      {:error, :unknown_type} = error ->
        error
    end
  end

  @doc "Classify a goal into a coarse intent via a lightweight keyword heuristic."
  @spec classify_intent(String.t()) :: String.t()
  def classify_intent(goal) when is_binary(goal) do
    down = String.downcase(goal)

    cond do
      String.contains?(down, ["fix", "bug", "broken", "error", "crash"]) -> "fix"
      String.contains?(down, ["chore", "bump", "upgrade", "rename", "cleanup", "docs"]) -> "chore"
      true -> "feat"
    end
  end

  # The preview harness reflects the SAME real harness the wizard will launch on (fix
  # planning-wizard target-repo launch): an explicitly-passed real harness wins, then the
  # project's real `default_harness`, so the preview never silently advertises the no-op
  # `fake` adapter when a real default exists. `fake` survives only when it is the
  # explicit choice AND no real project default exists (tests/demos).
  @spec resolve_harness(String.t() | nil, Project.t()) :: String.t()
  defp resolve_harness(explicit, %Project{default_harness: default}) do
    cond do
      real_harness?(explicit) -> explicit
      real_harness?(default) -> default
      is_binary(explicit) and explicit != "" -> explicit
      true -> "fake"
    end
  end

  @spec real_harness?(term()) :: boolean()
  defp real_harness?(harness),
    do: is_binary(harness) and String.trim(harness) != "" and harness != "fake"

  # --- internals ---

  @spec build_preview(Project.t(), String.t(), String.t(), String.t(), String.t() | nil, [
          step_preview()
        ]) :: preview()
  defp build_preview(project, goal, type, harness, model, previews) do
    %{
      project_id: project.id,
      goal: goal,
      workflow_type: type,
      harness: harness,
      model: model,
      intent: classify_intent(goal),
      steps: previews,
      estimate: estimate(goal, previews, harness, model)
    }
  end

  @spec step_preview(Project.t(), map()) :: step_preview()
  defp step_preview(project, step) do
    name = step["name"]

    case Commands.resolve(project, name) do
      {:ok, resolved} ->
        %{name: name, provenance: resolved.provenance, preview: truncate(resolved.body)}

      {:error, :not_found} ->
        %{
          name: name,
          provenance: "catalog template",
          preview: truncate(step["prompt_template"] || "")
        }
    end
  end

  @spec estimate(String.t(), [step_preview()], String.t(), String.t() | nil) :: estimate()
  defp estimate(goal, previews, harness, model) do
    chars = String.length(goal) + Enum.reduce(previews, 0, &(&2 + String.length(&1.preview)))
    # ~4 chars/token is the usual rough heuristic.
    context_tokens = div(chars, 4)
    cost = context_tokens * @usd_per_token

    %{
      context_tokens: context_tokens,
      window: ContextWindow.size(harness, model),
      estimated_cost_usd: Float.round(cost, 4),
      cost_band: cost_band(cost)
    }
  end

  @spec cost_band(float()) :: String.t()
  defp cost_band(cost) when cost < 1.0, do: "low (≈ <$1)"
  defp cost_band(cost) when cost < 5.0, do: "medium (≈ $1–5)"
  defp cost_band(_cost), do: "high (≈ $5+)"

  @spec truncate(String.t()) :: String.t()
  defp truncate(body) when is_binary(body) do
    if String.length(body) > @preview_chars,
      do: String.slice(body, 0, @preview_chars) <> "…",
      else: body
  end
end
