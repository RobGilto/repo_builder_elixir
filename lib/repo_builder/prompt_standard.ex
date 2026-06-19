defmodule RepoBuilder.PromptStandard do
  @moduledoc """
  A self-contained prompt-standard toolkit: a §7 checklist validator, a Population A/B
  prompt builder, and a lint walk — the canonical Elixir home of the feature originally
  built (by mistake) in the Python repo's `prompt_builder/` package.

  This context is pure and dependency-free at runtime (no DB, no Ecto, no HTTP): it uses
  only `yaml_elixir`, `typedstruct`, and the stdlib. It deliberately does NOT live under
  `RepoBuilder.Prompts` — that is the DB-backed reusable-template context (BUILD_PROMPT §8)
  and the two notions of "prompt" must never be conflated.

  Two prompt populations:

    * Population A — factory slash-commands, which HAVE YAML frontmatter.
    * Population B — runtime `.md` prompts, which are frontmatter-FREE.

  See `RepoBuilder.PromptStandard.Validator` and `RepoBuilder.PromptStandard.Builder`.
  """
  alias RepoBuilder.PromptStandard.{
    Builder,
    PopAInput,
    PopBInput,
    Population,
    TokenRegistry,
    Validator
  }

  alias RepoBuilder.PromptStandard.ValidationResult

  @type lint_entry ::
          %{path: String.t(), result: ValidationResult.t()}
          | %{path: String.t(), error: File.posix()}

  @doc "Validate raw prompt content (population auto-detected unless given)."
  @spec validate(String.t(), Population.t() | nil, String.t() | nil) :: ValidationResult.t()
  defdelegate validate(content, population \\ nil, rendered \\ nil), to: Validator

  @doc "Read and validate a file (population auto-detected unless given)."
  @spec validate_file(String.t(), Population.t() | nil) ::
          {:ok, ValidationResult.t()} | {:error, File.posix()}
  defdelegate validate_file(path, population \\ nil), to: Validator

  @doc "Assemble a Population A factory slash-command prompt."
  @spec build_population_a(PopAInput.t()) :: String.t()
  defdelegate build_population_a(input), to: Builder

  @doc "Assemble a Population B runtime prompt."
  @spec build_population_b(PopBInput.t()) :: String.t()
  defdelegate build_population_b(input), to: Builder

  @doc "Substitute closed-registry `{{TOKEN}}` sentinels; enforce the injection invariant."
  @spec render(String.t(), %{optional(String.t()) => String.t()}) ::
          {:ok, String.t()} | {:error, Builder.render_reason()}
  defdelegate render(template, tokens), to: Builder

  @doc "Build a prompt and run the §7 validator as a quality gate."
  @spec build_and_validate(Population.t(), PopAInput.t() | PopBInput.t()) ::
          {:ok, String.t(), ValidationResult.t()} | {:error, ValidationResult.t()}
  defdelegate build_and_validate(population, input), to: Builder

  @doc "The closed `{{TOKEN}}` registry as a sorted list."
  @spec token_registry() :: [String.t()]
  defdelegate token_registry, to: TokenRegistry, as: :list

  @doc "The supported populations."
  @spec populations() :: [Population.t()]
  def populations, do: [:a, :b]

  @doc """
  Validate every `*.md` file under `dir` (recursive). Returns one entry per file in sorted
  path order. `{:error, :not_a_directory}` when `dir` is not a directory;
  `{:error, :no_md_files}` when it contains no markdown.
  """
  @spec lint(String.t(), Population.t() | nil) ::
          {:ok, [lint_entry()]} | {:error, :not_a_directory | :no_md_files}
  def lint(dir, population \\ nil) when is_binary(dir) do
    if File.dir?(dir) do
      files =
        dir
        |> Path.join("**/*.md")
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)
        |> Enum.sort()

      case files do
        [] -> {:error, :no_md_files}
        _ -> {:ok, Enum.map(files, &lint_entry(&1, dir, population))}
      end
    else
      {:error, :not_a_directory}
    end
  end

  @spec lint_entry(String.t(), String.t(), Population.t() | nil) :: lint_entry()
  defp lint_entry(file, dir, population) do
    rel = Path.relative_to(file, dir)

    case validate_file(file, population) do
      {:ok, result} -> %{path: rel, result: result}
      {:error, reason} -> %{path: rel, error: reason}
    end
  end
end
