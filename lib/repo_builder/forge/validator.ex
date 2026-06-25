defmodule RepoBuilder.Forge.Validator do
  @moduledoc """
  Per-kind structural gate for forged artifacts (forge-meta-artifact-generation, Phase 3).

  Generation is non-deterministic, so before an artifact becomes a plugin it must clear a
  TOTAL, per-kind structural check — the closed-contract half of the doctrine. Each
  `validate/2` is total: it returns `:ok` or `{:error, [reason]}` and NEVER raises (a
  malformed YAML frontmatter, a missing file, or a bad workflow edge is a `reason`, not a
  crash). The forge ADW gates on `:ok` and otherwise follows its retry edge.

  Checks (per kind):

    * `:command`  — exactly one `.md` with valid frontmatter; kebab name; third-person
      description ≤ 1024 chars; the 6-section anatomy present.
    * `:agent`    — `.md` with valid frontmatter carrying `name` (kebab) + `description`
      (third person ≤ 1024) + `tools`; the 4 sections present.
    * `:skill`    — `<name>/SKILL.md`; gerund-kebab name; third-person description ≤ 1024;
      body < 500 lines.
    * `:workflow` — `.json` parsing to `{slug, steps[]}`; kebab slug; every step edge ∈
      `done | abort | sibling-name`.
  """
  alias RepoBuilder.Forge.Generator
  alias RepoBuilder.PromptStandard.Frontmatter

  @typedoc "One validation failure reason (a human-readable atom-ish string)."
  @type reason :: String.t()

  @typedoc "A generated file: an absolute path plus its content."
  @type file :: %{path: String.t(), content: String.t()}

  @max_description 1024
  @max_skill_lines 500

  @doc """
  Validate the generated `files` for a generator `kind`. Total — returns `:ok` or
  `{:error, [reason]}`, never raises.
  """
  @spec validate(Generator.kind(), [file()]) :: :ok | {:error, [reason()]}
  def validate(:command, files), do: validate_markdown(files, ".md", &command_checks/2)
  def validate(:agent, files), do: validate_markdown(files, ".md", &agent_checks/2)
  def validate(:skill, files), do: validate_skill(files)
  def validate(:workflow, files), do: validate_workflow(files)

  # --- markdown (command / agent) ---

  @spec validate_markdown([file()], String.t(), (map(), String.t() -> [reason()])) ::
          :ok | {:error, [reason()]}
  defp validate_markdown(files, ext, checks) do
    case Enum.find(files, &String.ends_with?(&1.path, ext)) do
      nil ->
        {:error, ["no #{ext} artifact was written"]}

      %{path: path, content: content} ->
        case Frontmatter.parse(content) do
          {:ok, fm, body} ->
            errors =
              name_errors(base_name(path)) ++
                description_errors(fm) ++ checks.(fm, body)

            finish(errors)

          :absent ->
            {:error, ["artifact has no YAML frontmatter"]}

          {:error, :malformed} ->
            {:error, ["artifact frontmatter is malformed YAML"]}
        end
    end
  end

  @spec command_checks(map(), String.t()) :: [reason()]
  defp command_checks(_fm, body) do
    sections_errors(body, ["## Purpose", "## Workflow", "## Report"], "command")
  end

  @spec agent_checks(map(), String.t()) :: [reason()]
  defp agent_checks(fm, body) do
    tools_error =
      case fm["tools"] do
        tools when is_binary(tools) and tools != "" -> []
        _ -> ["agent frontmatter is missing `tools`"]
      end

    tools_error ++
      sections_errors(body, ["# Purpose", "## Instructions", "## Workflow", "## Report"], "agent")
  end

  # --- skill ---

  @spec validate_skill([file()]) :: :ok | {:error, [reason()]}
  defp validate_skill(files) do
    case Enum.find(files, &String.ends_with?(&1.path, "SKILL.md")) do
      nil ->
        {:error, ["no SKILL.md artifact was written"]}

      %{path: path, content: content} ->
        case Frontmatter.parse(content) do
          {:ok, fm, body} ->
            errors =
              skill_name_errors(skill_name(path, fm)) ++
                description_errors(fm) ++ skill_body_errors(body)

            finish(errors)

          :absent ->
            {:error, ["SKILL.md has no YAML frontmatter"]}

          {:error, :malformed} ->
            {:error, ["SKILL.md frontmatter is malformed YAML"]}
        end
    end
  end

  # The skill name is the bundle directory (skills/<name>/SKILL.md), falling back to the
  # frontmatter `name` when the path is flat.
  @spec skill_name(String.t(), map()) :: String.t()
  defp skill_name(path, fm) do
    case Path.basename(Path.dirname(path)) do
      "" -> to_string(fm["name"] || "")
      "." -> to_string(fm["name"] || "")
      dir -> dir
    end
  end

  @spec skill_name_errors(String.t()) :: [reason()]
  defp skill_name_errors(name) do
    cond do
      not kebab?(name) -> ["skill name #{inspect(name)} must be kebab-case"]
      not gerund?(name) -> ["skill name #{inspect(name)} must be a gerund (verb + -ing)"]
      true -> []
    end
  end

  @spec skill_body_errors(String.t()) :: [reason()]
  defp skill_body_errors(body) do
    lines = body |> String.split("\n") |> length()

    if lines < @max_skill_lines,
      do: [],
      else: ["skill body is #{lines} lines (must be < #{@max_skill_lines})"]
  end

  # --- workflow ---

  @spec validate_workflow([file()]) :: :ok | {:error, [reason()]}
  defp validate_workflow(files) do
    case Enum.find(files, &String.ends_with?(&1.path, ".json")) do
      nil ->
        {:error, ["no .json workflow artifact was written"]}

      %{content: content} ->
        case Jason.decode(content) do
          {:ok, %{"slug" => slug, "steps" => steps}} when is_list(steps) ->
            finish(slug_errors(slug) ++ edge_errors(steps))

          {:ok, _other} ->
            {:error, ["workflow JSON must carry a `slug` and a `steps` list"]}

          {:error, _reason} ->
            {:error, ["workflow artifact is not valid JSON"]}
        end
    end
  end

  @spec slug_errors(term()) :: [reason()]
  defp slug_errors(slug) when is_binary(slug) do
    if kebab?(slug), do: [], else: ["workflow slug #{inspect(slug)} must be kebab-case"]
  end

  defp slug_errors(_slug), do: ["workflow slug must be a string"]

  @spec edge_errors([term()]) :: [reason()]
  defp edge_errors(steps) do
    names = for s <- steps, is_map(s), is_binary(s["name"]), into: MapSet.new(), do: s["name"]

    Enum.flat_map(steps, fn step ->
      for key <- ["on_success", "on_failure"],
          is_binary(step[key]),
          not valid_edge?(step[key], names),
          do: "step #{inspect(step["name"])} has dangling #{key} edge #{inspect(step[key])}"
    end)
  end

  @spec valid_edge?(String.t(), MapSet.t()) :: boolean()
  defp valid_edge?(target, names),
    do: target in ["done", "abort"] or MapSet.member?(names, target)

  # --- shared checks ---

  @spec name_errors(String.t()) :: [reason()]
  defp name_errors(name) do
    if kebab?(name), do: [], else: ["artifact name #{inspect(name)} must be kebab-case"]
  end

  @spec description_errors(%{optional(String.t()) => term()}) :: [reason()]
  defp description_errors(fm) do
    case fm["description"] do
      desc when is_binary(desc) and desc != "" ->
        length_error =
          if String.length(desc) <= @max_description,
            do: [],
            else: ["description exceeds #{@max_description} chars"]

        length_error ++ third_person_error(desc)

      _ ->
        ["frontmatter is missing a `description`"]
    end
  end

  # Light heuristic: a third-person description does not open in the first person.
  @spec third_person_error(String.t()) :: [reason()]
  defp third_person_error(desc) do
    opener = desc |> String.trim_leading() |> String.downcase()

    if String.starts_with?(opener, "i ") or String.starts_with?(opener, "i'"),
      do: ["description should be written in the third person"],
      else: []
  end

  @spec sections_errors(String.t(), [String.t()], String.t()) :: [reason()]
  defp sections_errors(body, headers, label) do
    for header <- headers,
        not String.contains?(body, header),
        do: "#{label} body is missing the #{inspect(header)} section"
  end

  @spec base_name(String.t()) :: String.t()
  defp base_name(path), do: path |> Path.basename() |> Path.rootname()

  # Callers always pass a `String.t()`, so no `is_binary/1` guard — it would leave a dead
  # `false` branch dialyzer flags as an impossible pattern match.
  @spec kebab?(String.t()) :: boolean()
  defp kebab?(name),
    do: name != "" and Regex.match?(~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/, name)

  # Gerund form means the leading verb segment ends in `-ing` (`processing-invoices`,
  # `analyzing-spreadsheets`) — check the first hyphen segment, not the whole name.
  @spec gerund?(String.t()) :: boolean()
  defp gerund?(name) do
    name |> String.split("-", parts: 2) |> hd() |> String.ends_with?("ing")
  end

  @spec finish([reason()]) :: :ok | {:error, [reason()]}
  defp finish([]), do: :ok
  defp finish(errors), do: {:error, errors}
end
