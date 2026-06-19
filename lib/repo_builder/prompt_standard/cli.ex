defmodule RepoBuilder.PromptStandard.Cli do
  @moduledoc """
  Pure rendering + exit-code logic for the `prompt_standard.{validate,lint}` mix tasks (port
  of `prompt_builder/__main__.py`). Kept free of `System.halt`/`IO.puts` so it is unit-
  testable: the mix tasks are thin wrappers that print the returned output and halt with the
  returned code.

  Exit codes mirror the Python contract: `0` = pass, `1` = HARD-check failure, `2` = usage
  error.
  """
  import Kernel, except: [to_string: 1]

  alias RepoBuilder.PromptStandard
  alias RepoBuilder.PromptStandard.{Population, ValidationResult}

  @hard_checks ~w(H1 H2 H3 H4 H5 H6 H7 H8 H9 H10)
  @soft_checks ~w(S1 S2 S3 S4 S5)
  @h10_skip_note "deferred — managed_agent_system_prompt_template.md not yet shipped; see §8 Q6"

  @type outcome :: {:ok, String.t(), 0 | 1} | {:error, String.t()}

  @doc """
  Validate a single file. `population` is `nil` (auto-detect) or `:a`/`:b`. Returns
  `{:ok, output, code}` (code 0 pass / 1 fail) or `{:error, stderr_message}` (usage, exit 2).
  """
  @spec validate(String.t(), Population.t() | nil) :: outcome()
  def validate(path, population) do
    if File.regular?(path) do
      case PromptStandard.validate_file(path, population) do
        {:ok, result} ->
          {:ok, render_validate(path, result, population), exit_code(result)}

        {:error, reason} ->
          {:error, "error: validate: could not read #{path}: #{inspect(reason)}"}
      end
    else
      {:error, "error: validate: not a file: #{path}"}
    end
  end

  @doc """
  Lint every `*.md` under `dir`. Returns `{:ok, output, code}` (0 = all pass, 1 = any fail)
  or `{:error, stderr_message}` (exit 2 — not a directory / no `.md` files).
  """
  @spec lint(String.t(), Population.t() | nil) :: outcome()
  def lint(dir, population) do
    case PromptStandard.lint(dir, population) do
      {:error, :not_a_directory} -> {:error, "error: lint: not a directory: #{dir}"}
      {:error, :no_md_files} -> {:error, "error: lint: no .md files under #{dir}"}
      {:ok, entries} -> {:ok, render_lint(dir, entries), lint_code(entries)}
    end
  end

  # ── validate rendering ──────────────────────────────────────────────────────

  @spec exit_code(ValidationResult.t()) :: 0 | 1
  defp exit_code(%ValidationResult{passed: true}), do: 0
  defp exit_code(%ValidationResult{passed: false}), do: 1

  @spec render_validate(String.t(), ValidationResult.t(), Population.t() | nil) :: String.t()
  defp render_validate(path, result, population_opt) do
    overall = if result.passed, do: "PASS", else: "FAIL"

    [
      "Validating: #{path}",
      "Population: #{pop_label(result.population, population_opt)}",
      "",
      "Overall: #{overall}",
      "",
      "Hard checks:",
      hard_lines(result.errors),
      "",
      "Soft notes:",
      soft_lines(result.warnings)
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  @spec pop_label(Population.t(), Population.t() | nil) :: String.t()
  defp pop_label(population, nil),
    do: "#{Population.to_string(population)} (auto-detected: front-matter -> A, else B)"

  defp pop_label(population, _explicit),
    do: "#{Population.to_string(population)} (explicit --population)"

  @spec hard_lines([String.t()]) :: [String.t()]
  defp hard_lines(errors), do: Enum.map(@hard_checks, &hard_line(&1, errors))

  @spec hard_line(String.t(), [String.t()]) :: String.t() | [String.t()]
  defp hard_line("H10", _errors), do: "  #{pad("H10")} SKIP   (#{@h10_skip_note})"

  defp hard_line(cid, errors) do
    case msgs_for(cid, errors) do
      [] -> "  #{pad(cid)} PASS"
      msgs -> msgs |> Enum.with_index() |> Enum.map(&fail_line(cid, &1))
    end
  end

  @spec fail_line(String.t(), {String.t(), non_neg_integer()}) :: String.t()
  defp fail_line(cid, {msg, idx}) do
    tag = if idx == 0, do: "FAIL", else: "    "
    "  #{pad(cid)} #{tag}  #{body(msg)}"
  end

  @spec soft_lines([String.t()]) :: String.t() | [String.t()]
  defp soft_lines(warnings) do
    lines =
      for cid <- @soft_checks, w <- msgs_for(cid, warnings) do
        "  #{pad(cid)} NOTE  #{body(w)}"
      end

    if lines == [], do: "  (none)", else: lines
  end

  # ── lint rendering ──────────────────────────────────────────────────────────

  @spec render_lint(String.t(), [PromptStandard.lint_entry()]) :: String.t()
  defp render_lint(dir, entries) do
    pass = Enum.count(entries, &entry_passed?/1)
    fail = length(entries) - pass

    [
      "Linting: #{dir} (recursive, *.md)",
      "",
      Enum.map(entries, &lint_file_line/1),
      "",
      "Summary: #{length(entries)} files, #{pass} pass, #{fail} fail"
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  @spec lint_file_line(PromptStandard.lint_entry()) :: String.t()
  defp lint_file_line(%{path: path, result: result}) do
    status = if result.passed, do: "PASS", else: "FAIL"
    "  #{status}  #{length(result.errors)} errors  #{path}"
  end

  defp lint_file_line(%{path: path, error: reason}),
    do: "  FAIL  error reading: #{inspect(reason)}  #{path}"

  @spec entry_passed?(PromptStandard.lint_entry()) :: boolean()
  defp entry_passed?(%{result: %ValidationResult{passed: passed}}), do: passed
  defp entry_passed?(%{error: _reason}), do: false

  @spec lint_code([PromptStandard.lint_entry()]) :: 0 | 1
  defp lint_code(entries), do: if(Enum.all?(entries, &entry_passed?/1), do: 0, else: 1)

  # ── message bucketing ───────────────────────────────────────────────────────

  # Messages whose prefix is exactly `cid:` — the trailing colon guards the H1/H10 collision.
  @spec msgs_for(String.t(), [String.t()]) :: [String.t()]
  defp msgs_for(cid, messages), do: Enum.filter(messages, &String.starts_with?(&1, cid <> ":"))

  @spec body(String.t()) :: String.t()
  defp body(msg) do
    case String.split(msg, ": ", parts: 2) do
      [_prefix, rest] -> rest
      [whole] -> whole
    end
  end

  @spec pad(String.t()) :: String.t()
  defp pad(cid), do: String.pad_trailing(cid, 4)
end
