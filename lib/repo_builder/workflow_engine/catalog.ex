defmodule RepoBuilder.WorkflowEngine.Catalog do
  @moduledoc """
  The typed registry of built-in ADW workflow types (the Elixir analog of the
  reference `_get_available_workflow_types`). Each type is a slug + label +
  description + a harness-parameterized step-list builder; this module is the SINGLE
  source of truth for "what ADWs can I run", mirroring the `subagent_map`/tier-roster
  patterns.

  The step builders generalize the former `WorkflowEngine.example_steps/1`:

    * `plan_build`            — plan → build → done
    * `plan_build_review`     — plan → build → review → done
    * `plan_build_review_fix` — plan → build → review →(fix on failure)→ done

  Pure data + pure builders — no side effects, no `Repo`.
  """
  use TypedStruct

  typedstruct module: TypeDef, enforce: true do
    @typedoc "One catalog entry: a stable slug, a human label, and a one-line description."
    field :slug, String.t()
    field :label, String.t()
    field :description, String.t()
  end

  @type type_def :: TypeDef.t()

  @default_type "plan_build_review_fix"

  @doc "All built-in workflow types, in a stable order."
  @spec types() :: [type_def()]
  def types do
    [
      %TypeDef{
        slug: "plan_build",
        label: "Plan → Build",
        description: "Plan the work, then build it. The leanest ADW (no review)."
      },
      %TypeDef{
        slug: "plan_build_review",
        label: "Plan → Build → Review",
        description: "Plan, build, then review the build. Stops after review (no auto-fix)."
      },
      %TypeDef{
        slug: "plan_build_review_fix",
        label: "Plan → Build → Review → Fix",
        description:
          "Plan, build, review, and on a failed review branch to a fix step. The default full cycle."
      }
    ]
  end

  @doc "The default workflow type slug (the current `start_adw` shape, for back-compat)."
  @spec default_type() :: String.t()
  def default_type, do: @default_type

  @doc "Fetch a type definition by slug, or `{:error, :unknown_type}`."
  @spec fetch(String.t()) :: {:ok, type_def()} | {:error, :unknown_type}
  def fetch(slug) when is_binary(slug) do
    case Enum.find(types(), &(&1.slug == slug)) do
      nil -> {:error, :unknown_type}
      %TypeDef{} = type -> {:ok, type}
    end
  end

  def fetch(_slug), do: {:error, :unknown_type}

  @doc """
  The harness-parameterized step maps for a type slug, or `{:error, :unknown_type}`.
  The step maps share the canonical JSONB shape consumed by the engines/`Step`.
  """
  @spec steps(String.t(), String.t()) :: {:ok, [map()]} | {:error, :unknown_type}
  def steps(slug, harness \\ "fake")

  def steps("plan_build", harness) do
    {:ok,
     [
       step("plan", harness, "Plan the work for: {{input}}", "build"),
       step("build", harness, "Build from the plan: {{plan}}", "done")
     ]}
  end

  def steps("plan_build_review", harness) do
    {:ok,
     [
       step("plan", harness, "Plan the work for: {{input}}", "build"),
       step("build", harness, "Build from the plan: {{plan}}", "review"),
       step("review", harness, "Review the build: {{build}}", "done")
     ]}
  end

  def steps("plan_build_review_fix", harness) do
    {:ok,
     [
       step("plan", harness, "Plan the work for: {{input}}", "build"),
       step("build", harness, "Build from the plan: {{plan}}", "review"),
       # review branches to `fix` on failure, else succeeds to `:done`.
       %{
         "name" => "review",
         "harness" => harness,
         "prompt_template" => "Review the build: {{build}}",
         "on_success" => "done",
         "on_failure" => "fix"
       },
       step("fix", harness, "Fix the issues found: {{review}}", "done")
     ]}
  end

  def steps(_slug, _harness), do: {:error, :unknown_type}

  # A linear step: succeeds to `on_success`, aborts on failure.
  @spec step(String.t(), String.t(), String.t(), String.t()) :: map()
  defp step(name, harness, template, on_success) do
    %{
      "name" => name,
      "harness" => harness,
      "prompt_template" => template,
      "on_success" => on_success,
      "on_failure" => "abort"
    }
  end
end
