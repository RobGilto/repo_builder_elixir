defmodule RepoBuilder.Projects.ContextPrimer do
  @moduledoc """
  Render a `Profiler.profile()` into a concise markdown block that primes the
  orchestrator about the target repo (stack, conventions, discovered ADWs/commands).
  Stored on `project.context_primer` and injected into the orchestrator system prompt
  (issue-c) alongside the working-directory block.

  Pure: profile in, deterministic string out.
  """
  alias RepoBuilder.Projects.{Capabilities, Profiler}

  @doc "Render the primer markdown for a profile."
  @spec render(Profiler.t()) :: String.t()
  def render(%Profiler{} = profile) do
    """
    ## Target project: #{Path.basename(profile.root_path)}

    - Root: `#{profile.root_path}`
    - Stack: #{stack_line(profile.stack)}
    - Git: #{git_line(profile)}
    #{capability_lines(profile.capabilities)}
    - Conventions: #{conventions_line(profile)}
    - Discovered ADWs: #{adw_line(profile.adws)}
    - Repo-local slash commands: #{commands_line(profile.claude_commands)}
    """
    |> String.trim_trailing()
  end

  @spec stack_line(map()) :: String.t()
  defp stack_line(%{"language" => language} = stack) do
    case stack["build_tool"] do
      tool when is_binary(tool) and tool != "" -> "#{language} (#{tool})"
      _ -> to_string(language)
    end
  end

  defp stack_line(_stack), do: "unknown"

  @spec git_line(Profiler.t()) :: String.t()
  defp git_line(%Profiler{git?: false}), do: "not a git repository"

  defp git_line(%Profiler{git_remote: remote, default_branch: branch}) do
    [remote && "remote `#{remote}`", branch && "branch `#{branch}`"]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "git repository (no remote/branch detected)"
      parts -> Enum.join(parts, ", ")
    end
  end

  @spec capability_lines(Capabilities.t()) :: String.t()
  defp capability_lines(%Capabilities{} = caps) do
    [
      {"test", caps.test_command},
      {"build", caps.build_command},
      {"lint", caps.lint_command},
      {"format", caps.format_command},
      {"typecheck", caps.typecheck_command},
      {"run", caps.run_command}
    ]
    |> Enum.filter(fn {_label, command} -> is_binary(command) and command != "" end)
    |> case do
      [] ->
        "- Commands: (none detected — generic capability map)"

      commands ->
        rendered = Enum.map_join(commands, ", ", fn {label, cmd} -> "#{label}: `#{cmd}`" end)
        "- Commands: #{rendered}"
    end
  end

  @spec conventions_line(Profiler.t()) :: String.t()
  defp conventions_line(%Profiler{has_agents_md: agents?, has_claude_md: claude?}) do
    [agents? && "AGENTS.md", claude? && "CLAUDE.md"]
    |> Enum.filter(&is_binary/1)
    |> case do
      [] -> "none"
      docs -> Enum.join(docs, ", ")
    end
  end

  @spec adw_line([RepoBuilder.Definitions.Adw.t()]) :: String.t()
  defp adw_line([]), do: "none"
  defp adw_line(adws), do: adws |> Enum.map_join(", ", & &1.name)

  @spec commands_line([String.t()]) :: String.t()
  defp commands_line([]), do: "none"
  defp commands_line(commands), do: Enum.map_join(commands, ", ", &"/#{&1}")
end
