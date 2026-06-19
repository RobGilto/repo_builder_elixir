defmodule RepoBuilder.PromptStandard.Validator do
  @moduledoc """
  The §7 checklist linter for factory slash-commands (Population A) and runtime `.md`
  prompts (Population B). Faithful port of `prompt_builder/validator.py`.

  HARD checks H1–H9 are pass/fail and machine-enforced; H10 is intentionally **deferred**
  (it lives only as a `SKIP` row in the CLI table, never as a real check — see
  `RepoBuilder.PromptStandard.Cli`). SOFT checks S1–S5 are advisory warnings. Population is
  auto-detected from frontmatter presence unless overridden.

  ## H6 `.format` equivalence (the one genuine language gap)

  Python's H6 uses `str.format(**slots)` as a render smoke-test. Elixir has no `str.format`,
  so H6 is implemented as the semantic equivalent: strip every declared `{slot}` occurrence,
  then assert the remainder contains no stray `{`/`}`. This reproduces the Python contract
  for the cases the standard cares about (a clean named-slot template passes; a stray brace
  fails) without depending on a foreign formatter's grammar.
  """
  import Kernel, except: [to_string: 1]

  alias RepoBuilder.PromptStandard.{Checks, Frontmatter, Population, Taxonomy, TokenRegistry}
  alias RepoBuilder.PromptStandard.ValidationResult

  @required_fm_keys MapSet.new(["description", "argument-hint"])

  @purpose_re ~r/^# Purpose\b(.+?)(?=^##|\z)/ms
  @variables_re ~r/^## Variables\b(.+?)(?=^##|\z)/ms
  @instructions_re ~r/^## Instructions\b(.+?)(?=^##|\z)/ms
  @workflow_re ~r/^## Workflow\b(.+?)(?=^##|\z)/ms
  @report_re ~r/^## Report\b(.+?)(?=^##|\z)/ms

  @doc """
  Validate raw prompt `content`. `population` forces the population (`:a`/`:b`); `nil`
  auto-detects from frontmatter presence. `rendered` is the fully-substituted prompt (used
  by H5/H9 to assert the injection invariant); `nil` falls back to a best-effort check on
  the raw content.
  """
  @spec validate(String.t(), Population.t() | nil, String.t() | nil) :: ValidationResult.t()
  def validate(content, population \\ nil, rendered \\ nil) when is_binary(content) do
    pop = population || Population.detect(content)
    body = Frontmatter.body(content)

    stripped = Checks.strip_double_brace(content)
    has_double = Checks.has_double_brace?(content)
    has_single = Checks.has_single_brace?(stripped)
    found_tokens = content |> Checks.find_tokens() |> Enum.uniq()
    unregistered = found_tokens |> Enum.reject(&TokenRegistry.member?/1) |> Enum.sort()

    errors =
      h1(pop, content) ++
        h2(pop, body) ++
        h3(has_double, has_single) ++
        h4(unregistered) ++
        h5(content, rendered, unregistered) ++
        h6(pop, content, stripped, has_single, has_double) ++
        h7(pop, body) ++
        h8(content) ++
        h9(pop, content, rendered)

    warnings =
      s1(pop, body) ++
        s2(pop, body, has_single) ++
        s3(pop, body) ++
        s4(pop, body) ++
        s5(content)

    ValidationResult.new(errors, warnings, pop)
  end

  @doc """
  Read a file and validate it. `population` overrides auto-detection. Returns
  `{:error, posix}` on a read failure (never raises) so callers can report it.
  """
  @spec validate_file(String.t(), Population.t() | nil) ::
          {:ok, ValidationResult.t()} | {:error, File.posix()}
  def validate_file(path, population \\ nil) when is_binary(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, validate(content, population)}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── HARD checks ────────────────────────────────────────────────────────────

  # H1: frontmatter present + valid YAML + required keys for A; absent for B.
  @spec h1(Population.t(), String.t()) :: [String.t()]
  defp h1(:a, content) do
    if Frontmatter.present?(content) do
      h1_a_present(content)
    else
      [
        "H1: Population A prompt must have YAML frontmatter " <>
          "(--- block with 'description' and 'argument-hint' keys)."
      ]
    end
  end

  defp h1(:b, content) do
    if Frontmatter.present?(content) do
      [
        "H1: Population B (runtime) prompt MUST NOT have YAML frontmatter. " <>
          "The loader does raw File.read! — frontmatter would be passed verbatim to the model."
      ]
    else
      []
    end
  end

  @spec h1_a_present(String.t()) :: [String.t()]
  defp h1_a_present(content) do
    case Frontmatter.parse(content) do
      {:error, :malformed} -> ["H1: Frontmatter YAML is malformed (parse error)."]
      {:ok, map, _body} -> h1_missing_keys(map)
      :absent -> []
    end
  end

  # Inference-only spec — the success typing narrows below a hand-written `map()`.
  defp h1_missing_keys(map) do
    missing = MapSet.difference(@required_fm_keys, MapSet.new(Map.keys(map)))

    if MapSet.size(missing) > 0 do
      sorted = missing |> MapSet.to_list() |> Enum.sort()

      [
        "H1: Frontmatter missing required keys: #{inspect(sorted)}. " <>
          "Required: description, argument-hint."
      ]
    else
      []
    end
  end

  # H2: `# Purpose` heading present (Population A only).
  @spec h2(Population.t(), String.t()) :: [String.t()]
  defp h2(:a, body) do
    if Regex.match?(~r/^# Purpose\b/m, body),
      do: [],
      else: ["H2: Population A prompt must have a '# Purpose' section."]
  end

  defp h2(:b, _body), do: []

  # H3: no mixed {{TOKEN}} and {slot} in the same file.
  @spec h3(boolean(), boolean()) :: [String.t()]
  defp h3(true, true),
    do: [
      "H3: File mixes {{TOKEN}} (.replace path) and {slot} (.format path). " <>
        "Only one templating mechanism is allowed per file. See prompt-standard-spec.md §5c."
    ]

  defp h3(_has_double, _has_single), do: []

  # H4: every {{TOKEN}} is in the closed registry.
  @spec h4([String.t()]) :: [String.t()]
  defp h4([]), do: []

  defp h4(unregistered),
    do: [
      "H4: Unregistered {{TOKEN}} found: #{inspect(unregistered)}. " <>
        "Allowed registry: #{inspect(TokenRegistry.list())}. " <>
        "To add a token, update TOKEN_REGISTRY and the loader's branches."
    ]

  # H5: after render, no unresolved {{ or }} remain (injection invariant).
  @spec h5(String.t(), String.t() | nil, [String.t()]) :: [String.t()]
  defp h5(content, rendered, unregistered) do
    check_text = rendered || content

    cond do
      not (String.contains?(check_text, "{{") or String.contains?(check_text, "}}")) ->
        []

      not is_nil(rendered) ->
        [
          "H5: Injection invariant violated — rendered prompt still contains " <>
            ~s("{{" or "}}") <> " after substitution. Every {{TOKEN}} must be resolved."
        ]

      unregistered != [] ->
        [
          "H5: Unresolved {{TOKEN}} sentinels will survive rendering " <>
            "(unregistered tokens cannot be substituted). Injection invariant will fail at runtime."
        ]

      true ->
        []
    end
  end

  # H6: Path-2 (.format) Population-B templates must render cleanly (see @moduledoc).
  @spec h6(Population.t(), String.t(), String.t(), boolean(), boolean()) :: [String.t()]
  defp h6(:b, content, stripped, true, false) do
    slots = stripped |> Checks.find_slots() |> Enum.uniq()
    remainder = Enum.reduce(slots, content, fn slot, acc -> String.replace(acc, slot, "") end)

    if String.contains?(remainder, "{") or String.contains?(remainder, "}") do
      [
        "H6: Path-2 (.format) template has stray or malformed braces — " <>
          "a .format-based template must contain only its declared named {slot}s " <>
          "and no other bare { or }. See prompt-standard-spec.md §5c."
      ]
    else
      []
    end
  end

  defp h6(_pop, _content, _stripped, _has_single, _has_double), do: []

  # H7: section headers follow one population's taxonomy (shared headings never fail).
  @spec h7(Population.t(), String.t()) :: [String.t()]
  defp h7(:a, body) do
    case foreign_headings(body, :b) do
      [] ->
        []

      foreign ->
        [
          "H7: Population A prompt uses Population B headings: #{inspect(foreign)}. " <>
            "Factory prompts use Purpose/Variables/Instructions/Workflow/Report taxonomy."
        ]
    end
  end

  defp h7(:b, body) do
    case foreign_headings(body, :a) do
      [] ->
        []

      foreign ->
        [
          "H7: Population B prompt uses Population A headings: #{inspect(foreign)}. " <>
            "Runtime prompts use Core Operating Principle/Your Tools/Routing rules taxonomy."
        ]
    end
  end

  @spec foreign_headings(String.t(), Population.t()) :: [String.t()]
  defp foreign_headings(body, foreign_pop) do
    body
    |> Checks.headings()
    |> Enum.filter(fn heading -> Taxonomy.classify_heading(heading) == foreign_pop end)
  end

  # H8: no UTF-8 BOM.
  @spec h8(String.t()) :: [String.t()]
  defp h8(content) do
    if Checks.has_bom?(content),
      do: [
        "H8: File has a UTF-8 BOM (byte-order mark). Prompts must be plain UTF-8 without BOM."
      ],
      else: []
  end

  # H9: no unresolved $ARGUMENTS in a rendered Population A prompt.
  @spec h9(Population.t(), String.t(), String.t() | nil) :: [String.t()]
  defp h9(:a, content, rendered) do
    final_text = rendered || content

    if String.contains?(final_text, "$ARGUMENTS"),
      do: [
        "H9: Rendered Population A prompt still contains '$ARGUMENTS' placeholder. " <>
          "Substitute all variables before delivering to model."
      ],
      else: []
  end

  defp h9(:b, _content, _rendered), do: []

  # ── SOFT checks (warnings) ───────────────────────────────────────────────────

  # S1: # Purpose is at least one non-empty sentence (Population A).
  @spec s1(Population.t(), String.t()) :: [String.t()]
  defp s1(:a, body) do
    case section_body(body, @purpose_re) do
      nil ->
        []

      text ->
        trimmed = String.trim(text)

        if trimmed == "" or String.length(trimmed) < 10,
          do: [
            "S1: # Purpose section appears empty or too short (< 10 characters). " <>
              "It should be at least 1 non-empty sentence."
          ],
          else: []
    end
  end

  defp s1(:b, _body), do: []

  # S2: ## Variables declares all {slot} names used in ## Instructions (Population A).
  @spec s2(Population.t(), String.t(), boolean()) :: [String.t()]
  defp s2(:a, body, true) do
    instr = section_body(body, @instructions_re)
    vars = section_body(body, @variables_re)
    s2_from_sections(instr, vars)
  end

  defp s2(_pop, _body, _has_single), do: []

  @spec s2_from_sections(String.t() | nil, String.t() | nil) :: [String.t()]
  defp s2_from_sections(nil, _vars), do: []

  defp s2_from_sections(instr, nil) do
    if Checks.find_slots(instr) == [],
      do: [],
      else: ["S2: ## Instructions uses {slot} syntax but ## Variables section is missing."]
  end

  defp s2_from_sections(instr, vars) do
    instr_slots = instr |> Checks.find_slots() |> MapSet.new()
    vars_slots = vars |> Checks.find_slots() |> MapSet.new()
    undeclared = MapSet.difference(instr_slots, vars_slots)

    if MapSet.size(undeclared) > 0 do
      sorted = undeclared |> MapSet.to_list() |> Enum.sort()
      ["S2: ## Instructions uses slots not declared in ## Variables: #{inspect(sorted)}."]
    else
      []
    end
  end

  # S3: ## Workflow has at least 2 numbered steps (Population A).
  @spec s3(Population.t(), String.t()) :: [String.t()]
  defp s3(:a, body) do
    case section_body(body, @workflow_re) do
      nil ->
        []

      text ->
        steps = Regex.scan(~r/^\d+\./m, text)

        if length(steps) < 2,
          do: [
            "S3: ## Workflow has fewer than 2 numbered steps. " <>
              "A workflow with only 1 step may be better expressed as Instructions."
          ],
          else: []
    end
  end

  defp s3(:b, _body), do: []

  # S4: ## Report specifies an output format (Population A).
  @spec s4(Population.t(), String.t()) :: [String.t()]
  defp s4(:a, body) do
    case section_body(body, @report_re) do
      text when is_binary(text) ->
        if String.length(String.trim(text)) < 10, do: s4_warning(), else: []

      nil ->
        s4_warning()
    end
  end

  defp s4(:b, _body), do: []

  @spec s4_warning() :: [String.t()]
  defp s4_warning,
    do: [
      "S4: ## Report section is missing or empty. " <>
        "Pin the exact output format for prompts consumed downstream."
    ]

  # S5: no TODO/FIXME markers.
  @spec s5(String.t()) :: [String.t()]
  defp s5(content) do
    if Regex.match?(~r/\b(TODO|FIXME)\b/i, content),
      do: [
        "S5: Content contains TODO or FIXME markers. " <>
          "Remove placeholder text before finalizing the prompt."
      ],
      else: []
  end

  @spec section_body(String.t(), Regex.t()) :: String.t() | nil
  defp section_body(body, regex) do
    case Regex.run(regex, body, capture: :all_but_first) do
      [text] when is_binary(text) -> text
      _no_match -> nil
    end
  end
end
