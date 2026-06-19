defmodule Mix.Tasks.RepoBuilder.PromptStandard.Validate do
  @shortdoc "Validate a prompt .md file against the §7 prompt standard"
  @moduledoc """
  Validate a single prompt file against the §7 checklist (HARD H1–H9, SOFT S1–S5; H10 is
  deferred and shown as SKIP).

      mix repo_builder.prompt_standard.validate <file> [--population A|B]

  Population is auto-detected from frontmatter presence (present → A, else B) unless
  `--population` is given. Exit codes: `0` = PASS, `1` = HARD-check failure, `2` = usage error.
  """
  use Mix.Task

  alias RepoBuilder.PromptStandard.Cli

  @impl Mix.Task
  @spec run([String.t()]) :: no_return()
  def run(argv) do
    case parse_args(argv) do
      {:ok, path, population} -> dispatch(Cli.validate(path, population))
      {:error, message} -> halt_usage(message)
    end
  end

  @spec parse_args([String.t()]) ::
          {:ok, String.t(), RepoBuilder.PromptStandard.Population.t() | nil}
          | {:error, String.t()}
  defp parse_args(argv) do
    {opts, positionals, _invalid} = OptionParser.parse(argv, strict: [population: :string])

    with {:ok, path} <- first_positional(positionals, "validate"),
         {:ok, population} <- population_opt(opts[:population]) do
      {:ok, path, population}
    end
  end

  @spec first_positional([String.t()], String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp first_positional([path | _rest], _cmd) when is_binary(path), do: {:ok, path}
  defp first_positional([], cmd), do: {:error, "error: #{cmd}: missing <file> argument"}

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
