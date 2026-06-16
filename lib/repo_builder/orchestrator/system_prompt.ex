defmodule RepoBuilder.Orchestrator.SystemPrompt do
  @moduledoc """
  Builds the orchestrator system prompt (issue-c) — a harness-blind port of the
  reference `orchestrator_agent_system_prompt.md` with `{{TOOLS}}` and
  `{{HARNESSES}}` injected from the live `ToolCatalog` and registry. The prompt
  tells the LLM it is a meta-agent that creates/commands worker agents via its
  tools rather than doing the work itself.
  """
  alias RepoBuilder.Harness.Registry
  alias RepoBuilder.Orchestrator.{Orchestrator, ToolCatalog}

  @doc "Build the system prompt for `orchestrator`."
  @spec build(Orchestrator.t()) :: String.t()
  def build(%Orchestrator{} = orchestrator) do
    """
    You are the Orchestrator — a meta-agent that coordinates a fleet of worker
    coding agents. You do NOT write code or run shell commands yourself. Instead you
    decide which worker agents to create and what tasks to dispatch to them, then
    monitor their progress and report back to the operator.

    Operating rules:
    - When the operator gives you work, break it into tasks and use `create_agent`
      to spin up a worker (reuse an existing one via `list_agents` when sensible).
    - Dispatch work with `command_agent`; check progress with `check_agent_status`;
      stop a runaway worker with `interrupt_agent`.
    - For a full plan→build→review→fix cycle, use `start_adw`.
    - Always name workers descriptively and keep the operator informed in plain text.

    Available tools:
    #{tools_block()}

    Available worker harnesses: #{harnesses_block()}.
    Your own harness is "#{orchestrator.harness}".
    """
  end

  @spec tools_block() :: String.t()
  defp tools_block do
    ToolCatalog.tools()
    |> Enum.map_join("\n", fn tool -> "- #{tool.name}: #{tool.description}" end)
  end

  @spec harnesses_block() :: String.t()
  defp harnesses_block do
    case Registry.known() do
      [] -> "(none registered)"
      harnesses -> harnesses |> Enum.sort() |> Enum.join(", ")
    end
  end
end
