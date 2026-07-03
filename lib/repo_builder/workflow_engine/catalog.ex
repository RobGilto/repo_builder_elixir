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

  alias RepoBuilder.Plugins.Activation

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
      },
      %TypeDef{
        slug: "spec_implement_test_review",
        label: "Spec → Implement → Test → Review",
        description:
          "Spec-driven phase shape (orchestration-adw-loop): write the spec, implement it, test, " <>
            "then review with a fix-on-failure branch — one ADW mirroring a workstream phase."
      }
    ]
  end

  @doc """
  All workflow types available to a project (`nil` = the platform): the built-in types
  PLUS those contributed by the project's active plugins (the agentic plugin system
  foundation, the code→data extensibility win).
  """
  @spec types(Ecto.UUID.t() | nil) :: [type_def()]
  def types(project_id) do
    types() ++ Enum.map(plugin_definitions(project_id), & &1.def)
  end

  @doc "The default workflow type slug (the current `start_adw` shape, for back-compat)."
  @spec default_type() :: String.t()
  def default_type, do: @default_type

  @doc "Fetch a built-in type definition by slug, or `{:error, :unknown_type}`."
  @spec fetch(String.t()) :: {:ok, type_def()} | {:error, :unknown_type}
  def fetch(slug) when is_binary(slug) do
    case Enum.find(types(), &(&1.slug == slug)) do
      nil -> {:error, :unknown_type}
      %TypeDef{} = type -> {:ok, type}
    end
  end

  def fetch(_slug), do: {:error, :unknown_type}

  @doc "Fetch a type definition by slug for a project — built-in first, then active plugins."
  @spec fetch(String.t(), Ecto.UUID.t() | nil) :: {:ok, type_def()} | {:error, :unknown_type}
  def fetch(slug, project_id) when is_binary(slug) do
    case fetch(slug) do
      {:ok, _type} = ok ->
        ok

      {:error, :unknown_type} ->
        case Enum.find(plugin_definitions(project_id), &(&1.def.slug == slug)) do
          %{def: %TypeDef{} = type} -> {:ok, type}
          _ -> {:error, :unknown_type}
        end
    end
  end

  def fetch(_slug, _project_id), do: {:error, :unknown_type}

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

  def steps("spec_implement_test_review", harness) do
    {:ok,
     [
       step("spec", harness, "Write the spec for: {{input}}", "implement"),
       step("implement", harness, "Implement from the spec: {{spec}}", "test"),
       step("test", harness, "Test the implementation: {{implement}}", "review"),
       # review branches to `fix` on failure, else succeeds to `:done`.
       %{
         "name" => "review",
         "harness" => harness,
         "prompt_template" => "Review the work: {{test}}",
         "on_success" => "done",
         "on_failure" => "fix"
       },
       step("fix", harness, "Fix the issues found: {{review}}", "done")
     ]}
  end

  def steps(_slug, _harness), do: {:error, :unknown_type}

  @doc """
  The canonical default `prompt_template` for a single ADW-Builder step name.

  This is the SINGLE source of truth shared by the catalog step builders (`step/4`)
  and the console ADW Builder (`ConsoleLive.launch_adw_builder/4`), so a hand-built
  ADW renders the same prompts as a catalog-built one. Every template references the
  initial prompt (`{{input}}`) and/or a prior step's output (`{{plan}}`, `{{build}}`,
  `{{test}}`, `{{review}}`), plus the optional pre-written spec (`{{spec}}`) where
  relevant, so `Runner.render/2` resolves them against the run's artifacts.

  The names cover the ADW Builder palette (`plan patch build test review document ship`);
  any other name falls back to a generic `{{input}}`-driven template so a custom step
  still receives the task context rather than an empty prompt.
  """
  @spec default_prompt_template(String.t()) :: String.t()
  def default_prompt_template("plan"),
    do: "Plan the work for: {{input}}\n\nSpec (optional): {{spec}}"

  def default_prompt_template("patch"),
    do: "Plan a targeted patch/hotfix for: {{input}}\n\nSpec (optional): {{spec}}"

  def default_prompt_template("build"), do: "Build from the plan: {{plan}}"

  def default_prompt_template("test"), do: "Test the implementation: {{build}}"

  def default_prompt_template("review"), do: "Review the build: {{build}}"

  def default_prompt_template("document"), do: "Document the implemented changes: {{build}}"

  def default_prompt_template("ship"),
    do: "Ship the work — finalize the branch and open a PR. Review: {{review}}"

  def default_prompt_template(_other), do: "Work on: {{input}}\n\nSpec (optional): {{spec}}"

  @doc """
  Project-aware steps: a built-in type's steps, else a plugin-contributed type's
  data-defined steps (with `harness` substituted per step where the data omits it).
  """
  @spec steps(String.t(), String.t(), Ecto.UUID.t() | nil) ::
          {:ok, [map()]} | {:error, :unknown_type}
  def steps(slug, harness, project_id) do
    case steps(slug, harness) do
      {:ok, _steps} = ok -> ok
      {:error, :unknown_type} -> plugin_steps(slug, harness, project_id)
    end
  end

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

  # --- plugin-contributed workflow types (agentic plugin system foundation) ---

  @spec plugin_steps(String.t(), String.t(), Ecto.UUID.t() | nil) ::
          {:ok, [map()]} | {:error, :unknown_type}
  defp plugin_steps(slug, harness, project_id) do
    case Enum.find(plugin_definitions(project_id), &(&1.def.slug == slug)) do
      %{steps: steps} -> {:ok, Enum.map(steps, &normalize_step(&1, harness))}
      _ -> {:error, :unknown_type}
    end
  end

  # Best-effort: the built-in catalog must remain available even if the plugin
  # subsystem (DB) is unreachable from the calling process.
  @spec plugin_definitions(Ecto.UUID.t() | nil) :: [%{def: type_def(), steps: [map()]}]
  defp plugin_definitions(project_id) do
    project_id
    |> Activation.contributions(:workflow_type)
    |> Enum.flat_map(fn %Activation.Resolved{abs_path: path} -> load_definition(path) end)
  rescue
    _error -> []
  end

  @spec load_definition(String.t() | nil) :: [%{def: type_def(), steps: [map()]}]
  defp load_definition(nil), do: []

  defp load_definition(path) do
    with {:ok, json} <- File.read(path),
         {:ok, %{"slug" => slug, "label" => label} = map} <- Jason.decode(json),
         steps when is_list(steps) <- Map.get(map, "steps") do
      [
        %{
          def: %TypeDef{slug: slug, label: label, description: map["description"] || ""},
          steps: steps
        }
      ]
    else
      _ -> []
    end
  end

  # Normalize a plugin's data step into the canonical JSONB shape, filling `harness`.
  @spec normalize_step(map(), String.t()) :: map()
  defp normalize_step(step, harness) when is_map(step) do
    Map.new([
      {"name", step["name"]},
      {"harness", step["harness"] || harness},
      {"prompt_template", step["prompt_template"] || ""},
      {"on_success", step["on_success"] || "done"},
      {"on_failure", step["on_failure"] || "abort"}
    ])
  end
end
