defmodule RepoBuilder.PromptStandard.Builder do
  @moduledoc """
  Generates factory slash-commands (Population A) and runtime `.md` prompts (Population B)
  that conform to the §7 standard. Faithful port of `prompt_builder/builder.py`.

  Assembly model:

    * Population A: frontmatter + `# Purpose` + optional sections + (`## Expertise` for
      `level >= 7`) + `## Workflow` + optional `## Report`.
    * Population B: NO frontmatter + `# <Role>` + `## Core Operating Principle` + optional
      sections.
    * `render/2` substitutes `{{TOKEN}}` sentinels (closed registry, Path-1) and asserts the
      injection invariant, returning tagged tuples — never raising (typed-standard rule 8).
    * `build_and_validate/2` runs the §7 validator as a quality gate.
  """
  alias RepoBuilder.PromptStandard.{PopAInput, PopBInput, Population, TokenRegistry, Validator}
  alias RepoBuilder.PromptStandard.ValidationResult

  @default_expertise "Accumulated know-how for this task. The Improve command updates this\n" <>
                       "section from eval findings and diffs; the Workflow stays frozen."

  @type render_reason :: {:unregistered_tokens, [String.t()]} | :injection_invariant_violated

  @doc "Assemble a Population A factory slash-command prompt."
  @spec build_population_a(PopAInput.t()) :: String.t()
  def build_population_a(%PopAInput{} = input) do
    [
      frontmatter_block(input),
      "# Purpose\n#{input.purpose}",
      optional_section("## Variables", input.variables),
      optional_section("## Instructions", input.instructions),
      expertise_section(input),
      workflow_section(input.workflow),
      optional_section("## Report", input.report)
    ]
    |> Enum.reject(&is_nil/1)
    |> join_parts()
  end

  @doc "Assemble a Population B runtime `.md` prompt (front-matter-FREE)."
  @spec build_population_b(PopBInput.t()) :: String.t()
  def build_population_b(%PopBInput{} = input) do
    [
      "# #{input.name}",
      "## Core Operating Principle\n\n#{input.core_principle}",
      optional_section("## Instructions", input.instructions),
      tools_section(input.tools, input.routing_rules),
      optional_section("## Guidelines", input.guidelines)
    ]
    |> Enum.reject(&is_nil/1)
    |> join_parts()
  end

  @doc """
  Substitute `{{TOKEN}}` sentinels via `String.replace/3` (Path-1). Only registry tokens are
  accepted; any unregistered key yields `{:error, {:unregistered_tokens, sorted}}`. After
  substitution the injection invariant is asserted: `{:error, :injection_invariant_violated}`
  if any `{{`/`}}` survive. Never raises.
  """
  @spec render(String.t(), %{optional(String.t()) => String.t()}) ::
          {:ok, String.t()} | {:error, render_reason()}
  def render(template, tokens) when is_binary(template) and is_map(tokens) do
    unregistered = tokens |> Map.keys() |> Enum.reject(&TokenRegistry.member?/1) |> Enum.sort()

    if unregistered != [] do
      {:error, {:unregistered_tokens, unregistered}}
    else
      rendered =
        Enum.reduce(tokens, template, fn {token, value}, acc ->
          String.replace(acc, token, value)
        end)

      if String.contains?(rendered, "{{") or String.contains?(rendered, "}}"),
        do: {:error, :injection_invariant_violated},
        else: {:ok, rendered}
    end
  end

  @doc """
  Build a prompt for the given population and run the §7 validator as a quality gate. Returns
  `{:ok, prompt, result}` when all HARD checks pass, else `{:error, result}` (the Elixir
  shape of Python's `raise PromptValidationError(result)`).
  """
  @spec build_and_validate(Population.t(), PopAInput.t() | PopBInput.t()) ::
          {:ok, String.t(), ValidationResult.t()} | {:error, ValidationResult.t()}
  def build_and_validate(:a, %PopAInput{} = input) do
    prompt = build_population_a(input)
    gate(prompt, :a)
  end

  def build_and_validate(:b, %PopBInput{} = input) do
    prompt = build_population_b(input)
    gate(prompt, :b)
  end

  @spec gate(String.t(), Population.t()) ::
          {:ok, String.t(), ValidationResult.t()} | {:error, ValidationResult.t()}
  defp gate(prompt, population) do
    result = Validator.validate(prompt, population)
    if result.passed, do: {:ok, prompt, result}, else: {:error, result}
  end

  # ── assembly helpers ─────────────────────────────────────────────────────────

  @spec frontmatter_block(PopAInput.t()) :: String.t()
  defp frontmatter_block(input) do
    [
      "---",
      "description: #{blank_default(input.description, input.name)}",
      "argument-hint: #{blank_default(input.argument_hint, "<arguments>")}",
      optional_fm_line("allowed-tools", input.allowed_tools),
      optional_fm_line("model", input.model),
      "---"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  @spec optional_fm_line(String.t(), String.t() | nil) :: String.t() | nil
  defp optional_fm_line(_key, nil), do: nil
  defp optional_fm_line(key, value), do: "#{key}: #{value}"

  @spec expertise_section(PopAInput.t()) :: String.t() | nil
  defp expertise_section(%PopAInput{level: level, expertise: expertise}) do
    if level >= 7 or not is_nil(expertise),
      do: "## Expertise\n\n#{expertise || @default_expertise}",
      else: nil
  end

  @spec workflow_section(String.t() | nil) :: String.t()
  defp workflow_section(nil), do: "## Workflow\n\n1. Execute the task.\n2. Validate output."
  defp workflow_section(workflow), do: "## Workflow\n\n#{workflow}"

  @spec tools_section(String.t() | nil, String.t() | nil) :: String.t() | nil
  defp tools_section(nil, nil), do: nil
  defp tools_section(nil, routing), do: "## Your Tools\n\n### Routing rules\n\n#{routing}"
  defp tools_section(tools, nil), do: "## Your Tools\n\n#{tools}"

  defp tools_section(tools, routing),
    do: "## Your Tools\n\n#{String.trim_trailing(tools)}\n\n### Routing rules\n\n#{routing}"

  @spec optional_section(String.t(), String.t() | nil) :: String.t() | nil
  defp optional_section(_heading, nil), do: nil
  defp optional_section(heading, content), do: "#{heading}\n\n#{content}"

  @spec blank_default(String.t(), String.t()) :: String.t()
  defp blank_default("", fallback), do: fallback
  defp blank_default(value, _fallback), do: value

  @spec join_parts([String.t()]) :: String.t()
  defp join_parts(parts), do: Enum.join(parts, "\n\n") <> "\n"
end
