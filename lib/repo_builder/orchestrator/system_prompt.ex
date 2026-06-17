defmodule RepoBuilder.Orchestrator.SystemPrompt do
  @moduledoc """
  Builds the orchestrator system prompt (issue-c) — a harness-blind port of the
  reference `orchestrator_agent_system_prompt.md` with `{{TOOLS}}` and
  `{{HARNESSES}}` injected from the live `ToolCatalog` and registry. The prompt
  tells the LLM it is a meta-agent that creates/commands worker agents via its
  tools rather than doing the work itself.
  """
  alias RepoBuilder.Harness.Registry
  alias RepoBuilder.Orchestrator.{Orchestrator, Templates, ToolCatalog}
  alias RepoBuilder.Orchestrators
  alias RepoBuilder.WorkflowEngine.Catalog

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
    - When the operator says "use thinking" / "think harder", include the keyword
      `ultrathink` in the `command_agent` command field — a Claude worker raises its
      thinking budget on it (the maximum-reasoning-effort signal). Drop it for a
      cheap/simple task where deep reasoning is not warranted.
    - If the operator gives a custom `/slash-command`, place it in the `command_agent`
      command field at the SAME position they wrote it (start, middle, or end) — that
      kicks off the worker's slash command exactly where intended.
    - To run a multi-step AI Developer Workflow, use `start_adw` and pick a
      `workflow_type` from the AVAILABLE ADW TYPES below (it defaults to the full
      plan→build→review→fix cycle). Watch its per-step progress with `check_adw`.
    - If a tier shows `(unassigned — cannot spawn here)` or a spawn fails with "no
      model selected", call `get_config` to inspect the available harnesses/models,
      then `configure_tier` to assign one — do NOT stop and ask the operator unless
      no model is available at all.
    - Use `set_orchestrator_config` to change your own harness/provider/model when needed.
    - Always name workers descriptively and keep the operator informed in plain text.

    Worker model tiers:
    #{categories_block(orchestrator)}

    Available subagent templates (apply by name via `create_agent`'s `subagent_template`):
    #{subagent_map_block()}

    Available ADW types (pass as `start_adw`'s `workflow_type`):
    #{available_adw_types_block()}

    Context management:
    #{context_management_block()}

    Available tools:
    #{tools_block()}

    Available worker harnesses: #{harnesses_block()}.
    Your own harness is #{own_harness_block(orchestrator)}.

    Worker specialization (name workers by the role they play):
    - builder: implement features, write code
    - reviewer: code review, quality checks
    - tester: write and run tests
    - documenter: write documentation
    - debugger: troubleshoot failures

    Working rhythm: analyze the request → plan which workers are needed → create or
    reuse them → dispatch clear, specific instructions → monitor with
    `check_agent_status` (only when asked, and not too eagerly — workers take time to
    run) → report results back in plain text. Once an ADW is launched, observe rather
    than interfere: it drives its own steps; only step in if the operator asks.

    You are the conductor of this multi-agent orchestra. Coordinate effectively.
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

  # The `{{SUBAGENT_MAP}}` equivalent: a markdown list of the available worker
  # recipes the orchestrator can apply by name, with an empty-state fallback.
  @spec subagent_map_block() :: String.t()
  defp subagent_map_block do
    case Templates.list() do
      [] ->
        "No subagent templates yet — author one in Settings → Agent Templates or via save_agent_template."

      templates ->
        Enum.map_join(templates, "\n", fn template ->
          "- #{template.name}: #{template.description}"
        end)
    end
  end

  # The `{{AVAILABLE_ADW_TYPES}}` equivalent: a markdown list of the catalog's
  # workflow types the orchestrator can launch via `start_adw`, with an empty-state
  # fallback. Mirrors `subagent_map_block/0`/`tools_block/0`.
  @spec available_adw_types_block() :: String.t()
  defp available_adw_types_block do
    # `Catalog.types()` is statically non-empty (the built-in registry), so this never
    # blanks the prompt section.
    Enum.map_join(Catalog.types(), "\n", fn type -> "- #{type.slug}: #{type.description}" end)
  end

  # Guidance for watching spend + context-window pressure and relieving it via
  # compaction (ports the reference "Context Window Management" prompt section).
  @spec context_management_block() :: String.t()
  defp context_management_block do
    """
    - Call `report_cost` to check your own session: running USD cost, cumulative
      tokens, and context-window usage %. Watch it on long multi-agent sessions.
    - When a worker is filling its context window (or its output starts degrading),
      compact it with `compact_agent` (or `command_agent(name, "/compact")`) to free
      room before it hits the limit.
    - At high usage (≈80%+), proactively compact the busiest workers and tell the
      operator they may want to run `/compact` on you.
    """
    |> String.trim_trailing()
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
