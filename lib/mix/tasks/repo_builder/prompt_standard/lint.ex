defmodule Mix.Tasks.RepoBuilder.PromptStandard.Lint do
  @shortdoc "Lint every prompt .md file under a directory against the §7 standard"
  @moduledoc """
  Validate every `*.md` file under a directory (recursive) against the §7 checklist.

      mix repo_builder.prompt_standard.lint <dir> [--population A|B]

  Prints one `PASS/FAIL` line per file and a `Summary:` line. Population is auto-detected per
  file unless `--population` is given. Exit codes: `0` = all pass, `1` = any file fails,
  `2` = usage error (not a directory / no `.md` files).
  """
  use Mix.Task

  alias RepoBuilder.PromptStandard.Cli

  @impl Mix.Task
  @spec run([String.t()]) :: no_return()
  def run(argv) do
    case parse_args(argv) do
      {:ok, dir, population} -> dispatch(Cli.lint(dir, population))
      {:error, message} -> halt_usage(message)
    end
  end

  @spec parse_args([String.t()]) ::
          {:ok, String.t(), RepoBuilder.PromptStandard.Population.t() | nil}
          | {:error, String.t()}
  defp parse_args(argv) do
    {opts, positionals, _invalid} = OptionParser.parse(argv, strict: [population: :string])

    with {:ok, dir} <- first_positional(positionals),
         {:ok, population} <- population_opt(opts[:population]) do
      {:ok, dir, population}
    end
  end

  @spec first_positional([String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  defp first_positional([dir | _rest]) when is_binary(dir), do: {:ok, dir}
  defp first_positional([]), do: {:error, "error: lint: missing <dir> argument"}

  @spec population_opt(String.t() | nil) ::
          {:ok, RepoBuilder.PromptStandard.Population.t() | nil} | {:error, String.t()}
  defp population_opt(nil), do: {:ok, nil}
  defp population_opt("A"), do: {:ok, :a}
  defp population_opt("B"), do: {:ok, :b}
  defp population_opt(other), do: {:error, "error: invalid --population #{other} (use A or B)"}

  @spec dispatch(Cli.outcome()) :: no_return()
  defp dispatch({:ok, output, code}) do
    IO.puts(output)
    System.halt(code)
  end

  defp dispatch({:error, message}), do: halt_usage(message)

  @spec halt_usage(String.t()) :: no_return()
  defp halt_usage(message) do
    IO.puts(:stderr, message)
    System.halt(2)
  end
end
