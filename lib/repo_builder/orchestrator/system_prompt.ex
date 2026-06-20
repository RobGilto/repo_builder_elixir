defmodule RepoBuilder.Orchestrator.SystemPrompt do
  @moduledoc """
  Builds the orchestrator system prompt (issue-c) — a harness-blind port of the
  reference `orchestrator_agent_system_prompt.md` with `{{TOOLS}}` and
  `{{HARNESSES}}` injected from the live `ToolCatalog` and registry. The prompt
  tells the LLM it is a meta-agent that creates/commands worker agents via its
  tools rather than doing the work itself.
  """
  alias RepoBuilder.Definitions
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
    - To read a worker's findings, call `check_agent_status` and use its `final_message`
      field — that is the worker's actual output/result text. Never assume a worker
      reported back; retrieve `final_message` and relay it before reporting to the operator.
    - When you (or the operator, or a worker) reference a console `log-<n>` number, use
      `get_logs` to pull up that log's exact content — it takes a single number, an
      inclusive `from`..`to` range (e.g. log-8219..log-8228), or an explicit `numbers`
      array. (This is distinct from `read_system_logs`, which reads the separate
      tool-audit table, and `check_agent_status`, which tails a worker by name.)
    - When the operator says "use thinking" / "think harder", include the keyword
      `ultrathink` in the `command_agent` command field — a Claude worker raises its
      thinking budget on it (the maximum-reasoning-effort signal). Drop it for a
      cheap/simple task where deep reasoning is not warranted.
    - SLASH COMMANDS: the platform expands any `/command` you put at the START of a line
      in a `command_agent` prompt — it injects the body of that command's
      `.claude/commands/<name>.md` (from the worker's working directory) BEFORE the worker
      runs, so it works on EVERY harness (Claude, pi, cursor), not just Claude. Unknown
      commands pass through verbatim. Put the command on its own line with any arguments
      after it; use the AVAILABLE SLASH COMMANDS listed below (or any the operator names)
      to reuse templated workflows.
    - To run a multi-step AI Developer Workflow, use `start_adw`. For REAL substantive
      work pass `harness: "adw"` and a `workflow_type` from the AVAILABLE ADW TYPES
      below — that shells out to the portable Python ADW (the real /plan→/build→
      /review→/fix logic, plus scout/parallel variants). Pick by complexity:
        * trivial change → `plan_build`
        * standard feature → `plan_build_review_fix`
        * non-trivial / multi-area → the full SDLC ADW
        * large or exploratory → a scout/parallel ADW (`plan_w_scouts…` / `build_in_parallel`)
      For a complicated project, DECOMPOSE it into several `start_adw` runs (one per
      coherent slice) and track each with `check_adw` by its returned run id; report
      progress to the operator in plain text. Omitting `harness` runs the lightweight
      in-app catalog workflow instead (handy for demos/tests). Watch per-step progress
      with `check_adw`. CROSS-REPO: an ADW's slash commands (`/plan`, `/build`, …)
      resolve from the TARGET repo's `.claude/commands/`, so when the ADW must operate
      on a repo OTHER than your working directory, pass `working_dir` (an absolute path
      to that repo) to `start_adw` — otherwise the commands won't resolve and the run
      does nothing.
    - If a tier shows `(unassigned — cannot spawn here)` or a spawn fails with "no
      model selected", call `get_config` to inspect the available harnesses/models,
      then `configure_tier` to assign one — do NOT stop and ask the operator unless
      no model is available at all.
    - Use `set_orchestrator_config` to change your own harness/provider/model when needed.
    - RESEARCH TOOLS: workers can be granted web-research tools. Pass
      `tools: ["firecrawl"]` to `create_agent` (or `update_agent`) to give a researcher
      worker firecrawl (web scrape/search/crawl/map/extract). Grant it only to workers
      that need live web access; omit it for everyone else.
    - Always name workers descriptively and keep the operator informed in plain text.

    Worker model tiers:
    #{categories_block(orchestrator)}

    Available subagent templates (apply by name via `create_agent`'s `subagent_template`):
    #{subagent_map_block()}

    Available ADW types (pass as `start_adw`'s `workflow_type`):
    #{available_adw_types_block(orchestrator)}

    Available slash commands (put at the START of a line in a `command_agent` prompt; the platform expands them on any harness):
    #{slash_commands_block(orchestrator)}

    Context management:
    #{context_management_block()}

    Available tools:
    #{tools_block()}

    Available worker harnesses: #{harnesses_block()}.
    Your own harness is #{own_harness_block(orchestrator)}.

    Working directory:
    #{working_dir_block(orchestrator)}

    Worker specialization (name workers by the role they play):
    - builder: implement features, write code
    - reviewer: code review, quality checks
    - tester: write and run tests
    - documenter: write documentation
    - debugger: troubleshoot failures

    Message queue & holding pattern:
    - Operator messages you receive while you are working are QUEUED and delivered to
      you as your NEXT turn, in the order they were sent. You will not be interrupted
      mid-turn.
    - So finish dispatching the current batch and END YOUR TURN — report what you kicked
      off ("started the builder on X", "launched the ADW") rather than blocking in a long
      monitor loop. That lets the queue flow: your dispatched workers run in parallel in
      the background while the next operator message is processed.
    - Do NOT sit and poll `check_agent_status` waiting for a worker to finish before
      ending your turn. Check status only when the operator asks, then end the turn.
    - When a worker you dispatched returns, you WILL be re-engaged automatically (the
      holding pattern) to review its work and decide next steps. You are woken once per
      return — so do NOT poll; just end your turn and you'll be brought back when there
      is returned work to review. Operator messages always take precedence over these
      automatic resume turns.

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

  # Make the brain self-aware of where it (and the workers it commands) operate. When
  # a working dir is set, both run there; the platform itself (its prompts, scripts,
  # and source) lives at the BEAM cwd (the repo root) — named so the orchestrator can
  # refer to platform context while doing its work in the working directory.
  @spec working_dir_block(Orchestrator.t()) :: String.t()
  defp working_dir_block(%Orchestrator{working_dir: working_dir})
       when is_binary(working_dir) and working_dir != "" do
    """
    - You and every worker you command run in `#{working_dir}`. Do all project work there.
    - The repo_builder platform itself (its prompts, scripts, and source) lives at
      `#{platform_root()}` — refer to it for platform context, but operate in the working directory above.
    """
    |> String.trim_trailing()
  end

  defp working_dir_block(%Orchestrator{}) do
    """
    - No working directory is set: you and your workers each run in an isolated, empty
      scratch workspace with no project files. If a task needs a real codebase, ask the
      operator to set a Working directory in Settings → General.
    - The repo_builder platform itself lives at `#{platform_root()}`.
    """
    |> String.trim_trailing()
  end

  # The platform root = the BEAM process cwd, i.e. the directory `mix phx.server` runs
  # from (the repo root where the orchestrator's prompts/scripts live).
  @spec platform_root() :: String.t()
  defp platform_root, do: File.cwd!()

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

  # The `{{AVAILABLE_ADW_TYPES}}` equivalent. Two groups:
  #   * the REAL portable ADWs discovered on disk (`adws/adw_*.py`, app root + the
  #     orchestrator's working-dir overlay) — launch with `harness: "adw"`;
  #   * the in-app catalog fallback types — launch with any other harness.
  # `Catalog.types()` is statically non-empty, so the section never blanks.
  @spec available_adw_types_block(Orchestrator.t()) :: String.t()
  defp available_adw_types_block(orchestrator) do
    real = discovered_adws(orchestrator)

    real_block =
      case real do
        [] ->
          "  (none discovered under adws/ — drop in adws/adw_workflows/adw_<name>.py)"

        adws ->
          Enum.map_join(adws, "\n", fn adw -> "  - #{adw.name}: #{adw.description}" end)
      end

    catalog_block =
      Enum.map_join(Catalog.types(), "\n", fn type -> "  - #{type.slug}: #{type.description}" end)

    """
    Real portable ADWs (use `harness: "adw"`):
    #{real_block}
    In-app catalog fallback (any other harness):
    #{catalog_block}
    """
    |> String.trim_trailing()
  end

  # The discovered ADW scripts for the merged root (app + the orchestrator's working
  # dir), de-duplicated by slug with the working-dir overlay winning. Pure disk read.
  @spec discovered_adws(Orchestrator.t()) :: [Definitions.Adw.t()]
  defp discovered_adws(%Orchestrator{working_dir: working_dir}) do
    app = Definitions.Adw.scan(File.cwd!(), :app)

    working =
      if is_binary(working_dir) and working_dir != "",
        do: Definitions.Adw.scan(working_dir, :working_dir),
        else: []

    (working ++ app) |> Enum.uniq_by(& &1.name) |> Enum.sort_by(& &1.name)
  end

  # The file-driven slash-command palette (issue server-side slash expansion): the
  # commands discovered for the merged (app ∪ working-dir) root. The platform expands
  # any of these placed at the start of a line in a worker prompt, so listing them here
  # empowers the orchestrator to reuse templated workflows on any harness.
  @spec slash_commands_block(Orchestrator.t()) :: String.t()
  defp slash_commands_block(%Orchestrator{working_dir: working_dir}) do
    dir = if is_binary(working_dir) and working_dir != "", do: working_dir, else: nil

    case Definitions.list(:slash_command, dir) do
      [] ->
        "  (none discovered — drop a markdown file in `.claude/commands/`)"

      commands ->
        Enum.map_join(commands, "\n", fn cmd ->
          "  - /#{cmd.name}#{slash_desc(cmd.description)}"
        end)
    end
  end

  @spec slash_desc(String.t() | nil) :: String.t()
  defp slash_desc(description) when is_binary(description) and description != "",
    do: ": #{description}"

  defp slash_desc(_description), do: ""

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
    - To FULLY reset a worker before NEW, unrelated work, use `clear_context` — it
      returns the worker to a blank context window (its next task starts a fresh
      session with zero prior history). Prefer this over `compact_agent` when the new
      task does NOT depend on prior history; prefer `compact_agent` when the next task
      continues the worker's current work (it keeps a summary in-window).
    - At high usage (≈80%+), proactively `clear_context` any worker you're about to
      hand independent new work, `compact_agent` those continuing their current task,
      and tell the operator they may want to run `/compact` on you.
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
