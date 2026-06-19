defmodule RepoBuilder.PromptStandard.ValidationResult do
  @moduledoc """
  The outcome of running `RepoBuilder.PromptStandard.Validator` on a prompt (port of the
  Python `ValidationResult` dataclass in `prompt_builder/models.py`).

    * `passed` — true iff all HARD checks (H1–H9; H10 is deferred) passed.
    * `errors` — HARD-check failure messages (each prefixed `Hx:`).
    * `warnings` — SOFT-check advisory messages (each prefixed `Sx:`).
    * `population` — `:a` for factory slash-commands, `:b` for runtime prompts.

  The `Inspect` implementation mirrors the Python `__str__` PASS/FAIL report so `iex` and
  test failures read like the original tool.
  """
  use TypedStruct

  alias RepoBuilder.PromptStandard.Population

  typedstruct enforce: true do
    field :passed, boolean()
    field :errors, [String.t()]
    field :warnings, [String.t()]
    field :population, Population.t()
  end

  @doc "Build a result, computing `passed` from `errors == []`."
  @spec new([String.t()], [String.t()], Population.t()) :: t()
  def new(errors, warnings, population)
      when is_list(errors) and is_list(warnings) and population in [:a, :b] do
    %__MODULE__{
      passed: errors == [],
      errors: errors,
      warnings: warnings,
      population: population
    }
  end

  defimpl Inspect do
    alias RepoBuilder.PromptStandard.Population

    @spec inspect(@for.t(), Inspect.Opts.t()) :: String.t()
    def inspect(%@for{} = result, _opts) do
      status = if result.passed, do: "PASS", else: "FAIL"

      header =
        "ValidationResult [#{status}] population=#{Population.to_string(result.population)}"

      errors = Enum.map(result.errors, &"  ERROR: #{&1}")
      warnings = Enum.map(result.warnings, &"  WARN:  #{&1}")
      Enum.join([header | errors ++ warnings], "\n")
    end
  end
end
