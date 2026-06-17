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
  alias RepoBuilder.Orchestrators

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
    - Prefer the `category` argument to `create_agent` to pick a worker tier; it
      resolves to the operator-assigned harness/provider/model below. Choose `fast`
      for cheap/simple steps, `main` for normal work, `heavy` for hard reasoning,
      `leader` for coordination. A category with no model assigned cannot be spawned.
    - Dispatch work with `command_agent`; check progress with `check_agent_status`;
      stop a runaway worker with `interrupt_agent`.
    - For a full plan→build→review→fix cycle, use `start_adw`.
    - If a tier shows `(unassigned — cannot spawn here)` or a spawn fails with "no
      model selected", call `get_config` to inspect the available harnesses/models,
      then `configure_tier` to assign one — do NOT stop and ask the operator unless
      no model is available at all.
    - Use `set_orchestrator_config` to change your own harness/provider/model when needed.
    - Always name workers descriptively and keep the operator informed in plain text.

    Worker model tiers:
    #{categories_block(orchestrator)}

    Available tools:
    #{tools_block()}

    Available worker harnesses: #{harnesses_block()}.
    Your own harness is #{own_harness_block(orchestrator)}.
    """
  end

  @spec categories_block(Orchestrator.t()) :: String.t()
  defp categories_block(orchestrator) do
    roster = Orchestrators.agent_models(orchestrator)

    Enum.map_join(Orchestrators.agent_categories(), "\n", fn category ->
      entry = Map.get(roster, category, %{})

      case entry["model"] do
        model when is_binary(model) and model != "" ->
          "- #{category}: #{entry["harness"]}/#{entry["provider"] || "default"} #{model}"

        _ ->
          "- #{category}: (unassigned — cannot spawn here)"
      end
    end)
  end

  # Make the brain self-aware of its execution context (harness + provider + model).
  @spec own_harness_block(Orchestrator.t()) :: String.t()
  defp own_harness_block(%Orchestrator{harness: harness, provider: provider, model: model}) do
    details =
      [provider && "provider \"#{provider}\"", model && "model \"#{model}\""]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    case details do
      "" -> "\"#{harness}\""
      detail -> "\"#{harness}\" (#{detail})"
    end
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
