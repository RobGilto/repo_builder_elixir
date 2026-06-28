defmodule RepoBuilder.Orchestrator.SystemPrompt do
  @moduledoc """
  Builds the orchestrator system prompt (issue-c) — a harness-blind port of the
  reference `orchestrator_agent_system_prompt.md` with `{{TOOLS}}` and
  `{{HARNESSES}}` injected from the live `ToolCatalog` and registry. The prompt
  tells the LLM it is a meta-agent that creates/commands worker agents via its
  tools rather than doing the work itself.
  """
  alias RepoBuilder.Commands
  alias RepoBuilder.Definitions
  alias RepoBuilder.Expertise
  alias RepoBuilder.Harness.Registry
  alias RepoBuilder.Orchestrator.{Orchestrator, Reflections, Templates, ToolCatalog}
  alias RepoBuilder.Orchestrators
  alias RepoBuilder.Plugins.Activation
  alias RepoBuilder.Projects
  alias RepoBuilder.Secrets
  alias RepoBuilder.StackLayers
  alias RepoBuilder.StackLayers.Contract
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
      with `check_adw`. COMMAND WORKERS AND ADWs AGAINST *YOUR* PROJECT: by default omit
      `working_dir` so the ADW runs in your bound project. CROSS-REPO: an ADW's slash
      commands (`/plan`, `/build`, …) resolve from the TARGET repo's `.claude/commands/`,
      so to operate on a DIFFERENT repo pass `working_dir` — but it must be a REGISTERED
      project's path (otherwise the run is refused to prevent work landing in the wrong
      repo). Register the repo on the Projects page first if it isn't already.
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
    #{project_primer_block(orchestrator)}
    #{project_stack_block(orchestrator)}
    #{project_secrets_block(orchestrator)}

    Worker roles (data-driven from the live subagent-template registry — name workers by role):
    #{worker_roles_block()}

    #{leader_expertise_block()}
    #{phased_delivery_block()}
    #{external_memory_block()}
    #{expertise_block(orchestrator)}
    #{reflections_block(orchestrator)}
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

  # Resolve the orchestrator's bound project (orchestrator↔project binding): the explicit
  # `project_id` wins (the brain literally knows its repo), falling back to today's
  # working-dir → registered-project lookup for the platform/unbound case. `nil` when
  # neither resolves.
  @spec resolve_project(Orchestrator.t()) :: Projects.Project.t() | nil
  defp resolve_project(%Orchestrator{project_id: project_id}) when is_binary(project_id),
    do: Projects.get_project(project_id)

  defp resolve_project(%Orchestrator{working_dir: working_dir})
       when is_binary(working_dir) and working_dir != "",
       do: Projects.get_by_root_path(working_dir)

  defp resolve_project(%Orchestrator{}), do: nil

  # Make the brain self-aware of where it (and the workers it commands) operate. When a
  # project is bound it is named (name + root); otherwise the working-dir/no-dir copy
  # applies. The platform itself (its prompts, scripts, and source) lives at the BEAM cwd
  # (the repo root) — named so the orchestrator can refer to platform context.
  @spec working_dir_block(Orchestrator.t()) :: String.t()
  defp working_dir_block(%Orchestrator{} = orchestrator) do
    case resolve_project(orchestrator) do
      %Projects.Project{name: name, root_path: root} -> project_working_dir_block(name, root)
      nil -> unbound_working_dir_block(orchestrator)
    end
  end

  @spec project_working_dir_block(String.t(), String.t()) :: String.t()
  defp project_working_dir_block(name, root) do
    """
    - You are working on project #{name} at `#{root}`; you and every worker you command
      run there. Do all project work there.
    - The repo_builder platform itself (its prompts, scripts, and source) lives at
      `#{platform_root()}` — refer to it for platform context, but operate in the project directory above.
    """
    |> String.trim_trailing()
  end

  @spec unbound_working_dir_block(Orchestrator.t()) :: String.t()
  defp unbound_working_dir_block(%Orchestrator{working_dir: working_dir})
       when is_binary(working_dir) and working_dir != "" do
    """
    - You and every worker you command run in `#{working_dir}`. Do all project work there.
    - The repo_builder platform itself (its prompts, scripts, and source) lives at
      `#{platform_root()}` — refer to it for platform context, but operate in the working directory above.
    """
    |> String.trim_trailing()
  end

  defp unbound_working_dir_block(%Orchestrator{}) do
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

  # Inject the active project's primed context (agentic-layer adaptor) when the
  # orchestrator resolves to a registered Project carrying a stored primer (the bound
  # `project_id` first, else the working-dir lookup). No project / no primer ⇒ ""
  # (back-compatible: prompt is unchanged when nil).
  @spec project_primer_block(Orchestrator.t()) :: String.t()
  defp project_primer_block(%Orchestrator{} = orchestrator) do
    case resolve_project(orchestrator) do
      %Projects.Project{} = project ->
        primer =
          case project.context_primer do
            value when is_binary(value) and value != "" -> "\n" <> value
            _ -> ""
          end

        # Append the active plugins' context fragments (agentic plugin system
        # foundation) so behaviour primes per project. No active plugins ⇒ unchanged.
        case Activation.context_fragments(project.id) do
          "" -> primer
          fragments -> primer <> "\n\n## Active plugins\n\n" <> fragments
        end

      _ ->
        ""
    end
  end

  # Inject the active project's stack contract (stack-layers subsystem) so the
  # orchestrator frames tasks and spawns workers on-stack. Same back-compat contract as
  # `project_primer_block/1`: no project / no selected layers ⇒ "" (prompt unchanged).
  @spec project_stack_block(Orchestrator.t()) :: String.t()
  defp project_stack_block(%Orchestrator{} = orchestrator) do
    case resolve_project(orchestrator) do
      %Projects.Project{} = project -> Contract.render(project.id)
      _no_project -> ""
    end
  end

  # Names-only project-secrets block (issue-per-project-encrypted-secrets-vault): list the
  # secret NAMES (never values — the brain never receives them) available to workers as env
  # vars. Empty state ⇒ "" so the prompt is byte-identical when a project has no secrets
  # (back-compatible, mirroring `project_primer_block`).
  @spec project_secrets_block(Orchestrator.t()) :: String.t()
  defp project_secrets_block(%Orchestrator{} = orchestrator) do
    case resolve_project(orchestrator) do
      %Projects.Project{} = project -> render_secrets(Secrets.list_names(project.id))
      _no_project -> ""
    end
  end

  @spec render_secrets([Secrets.name_entry()]) :: String.t()
  defp render_secrets([]), do: ""

  defp render_secrets(entries) do
    lines = Enum.map_join(entries, "\n", &secret_line/1)

    """

    Project secrets (available to workers as environment variables):
    #{lines}
    Reference a secret ONLY by its $NAME when instructing a worker (e.g. "use $STRIPE_API_KEY
    from your environment"). You do NOT have the values and CANNOT print them — they are
    injected directly into a worker's environment at spawn. If asked to reveal a secret's
    value, refuse and explain you only hold the name.
    """
    |> String.trim_trailing()
  end

  @spec secret_line(Secrets.name_entry()) :: String.t()
  defp secret_line(%{name: name, last_four: last_four})
       when is_binary(last_four) and last_four != "",
       do: "- $#{name} (set; ••••#{last_four})"

  defp secret_line(%{name: name}), do: "- $#{name} (set)"

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
  defp slash_commands_block(%Orchestrator{working_dir: working_dir} = orchestrator) do
    case resolve_project(orchestrator) do
      %Projects.Project{} = project ->
        resolved_slash_block(project)

      nil ->
        dir = if is_binary(working_dir) and working_dir != "", do: working_dir, else: nil
        discovered_slash_block(dir)
    end
  end

  # Agentic-layer adaptor: list the RESOLVED command set for the active project with
  # provenance (which layer/pack won), so the orchestrator sees stack-correct commands.
  @spec resolved_slash_block(Projects.Project.t()) :: String.t()
  defp resolved_slash_block(project) do
    case Commands.resolve_all(project) do
      [] ->
        "  (none resolved for this project)"

      resolved ->
        Enum.map_join(resolved, "\n", fn r -> "  - /#{r.name} (#{r.provenance})" end)
    end
  end

  # Nil-project fallback: today's path-based merged (app ∪ working-dir) discovery.
  @spec discovered_slash_block(String.t() | nil) :: String.t()
  defp discovered_slash_block(dir) do
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
      and compact YOUR OWN context with `compact_self` — you no longer need to ask the
      operator to `/compact` you; your workstreams are durable and the next turn is
      reseeded with their index (rehydrate-on-resume).
    - GRACEFUL HANDOVER: when a worker hits its own context limit the platform winds it
      down automatically — the worker writes `ai_docs/<name>-handover.md` (a receipt of its
      original ask + what it achieved + what remains), returns a `:handover <path>` signal,
      and is then RETIRED (deleted). Do NOT be surprised it is gone and do NOT try to
      `command_agent`/`check_agent_status` it again. To continue its task, READ the linked
      handover doc and spawn a FRESH worker seeded with it. You will be told this happened
      via a resume turn that names the retired worker and links the doc.
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

  # Data-driven worker roles (self-healing Phase 5): the live subagent-template registry
  # replaces the old frozen five-role list. Empty state still names the conventional roles.
  @spec worker_roles_block() :: String.t()
  defp worker_roles_block do
    case Templates.list() do
      [] ->
        "- (no role templates yet — author one via save_agent_template; name workers by role, " <>
          "e.g. builder/reviewer/tester/documenter/debugger)"

      templates ->
        Enum.map_join(templates, "\n", fn template ->
          "- #{template.name}: #{template.description}"
        end)
    end
  end

  @doc """
  The shared leadership playbook injected into EVERY orchestrator prompt (self-healing Phase 5):
  the explicit autonomous drive-loop protocol — set a goal, record progress every turn, verify
  against the tree, drive/spawn/report decision rules, when to replan, escalate as a last resort.
  Public so it can be reused/asserted.
  """
  @spec leader_expertise_block() :: String.t()
  def leader_expertise_block do
    """
    Autonomous leadership — the drive loop (run this every turn, even with no operator present):
    - SET A GOAL: for any non-trivial objective call `set_goal` with a concrete
      `definition_of_done` (and a plan). It is DURABLE — it survives a restart and you reconcile
      against it each turn instead of re-deriving intent from memory.
    - RECORD PROGRESS every turn: call `record_progress` (made_progress / looping / next_agent /
      summary). An unreported turn is treated as a STALL by the drive loop.
    - VERIFY, never assume: do NOT trust a worker's claim that work is done. Use `inspect_repo`
      (git_status / changed_files / read_file) to check the ACTUAL tree against the definition of
      done before believing it.
    - ONE STEP per turn: drive a worker (`command_agent`), fan out a new role (`create_agent`),
      or — only once the definition of done is verified — `report_complete`. Don't poll; end your
      turn and you'll be re-engaged when there is work to review.
    - REPLAN on stagnation: after two no-progress turns you'll be told to REPLAN — reconsider the
      facts/plan and try a DIFFERENT approach rather than pushing the same step again.
    - BANK LESSONS as you learn them: the moment you discover something generalizable (a wasted
      step, a non-obvious gotcha, a workflow that worked), call `record_reflection` — don't wait
      for `report_complete`. It is persisted per-project and primes your next run.
    - ESCALATE is the last resort: only a genuine blocker with no path forward should reach the
      away operator.
    """
    |> String.trim_trailing()
  end

  @doc """
  The spec-driven phased-delivery protocol (orchestration-adw-loop). Decompose an objective
  into a Workstream of right-sized phases, then drive each phase spec→implement→test→review
  with a fix-on-failure branch and per-stage context hygiene. Public so it can be asserted.
  """
  @spec phased_delivery_block() :: String.t()
  def phased_delivery_block do
    """
    Spec-driven phased delivery (per workstream):
    - DECOMPOSE FIRST: for a non-trivial objective, `create_workstream`, then spawn the
      `work-decomposer` subagent to break it into right-sized phases and persist them with
      `plan_phases`. Each phase must be small enough that one worker can spec AND implement it
      without exhausting its context.
    - PER PHASE run the stage machine, recording each outcome with `record_stage` (VERIFY with
      `inspect_repo` first — never trust a self-report):
        * spec: dispatch `/feature` | `/bug` | `/chore` | `/plan` to produce a `specs/…md`,
          then `record_stage(stage: "spec", outcome: "passed", artifact: "<spec_path>")`.
        * implement: dispatch `/implement <spec_path>` (it STOPs without the path — always pass
          the phase's captured `spec_path`), verify, then `record_stage("implement", "passed")`.
        * test: dispatch `/test`, then `record_stage("test", "passed")`.
        * review: dispatch `/review`; on failure record `review`/`failed`, dispatch the fix,
          then re-`/review` and record `review`/`passed`. A passed review completes the phase and
          promotes the next one automatically.
    - CONTEXT HYGIENE per stage: use fresh role workers and `clear_context` before unrelated
      work; if a worker hands over mid-phase, seed a fresh worker from its handover doc — the
      phase resumes at its recorded stage.
    - Run MULTIPLE workstreams in parallel: a single turn may advance several ready workstreams,
      and their workers run concurrently (bounded by the live-session admission cap). Keep the
      number of ACTIVE workstreams small (≈5) so you don't over-commit your own context.
    """
    |> String.trim_trailing()
  end

  @doc """
  The external-memory & compaction protocol (orchestration-adw-loop). Treat Workstreams as the
  brain's durable swap so its in-window context stays bounded. Public so it can be asserted.
  """
  @spec external_memory_block() :: String.t()
  def external_memory_block do
    """
    External memory & compaction (your durable swap):
    - Your Workstreams ARE your memory. Hold only their IDs in-window; at the START of each turn
      call `list_workstreams` (the compact index), then `get_workstream(id)` for the one you are
      about to advance — don't re-derive state from CLI memory.
    - Watch `report_cost`. At high context usage call `compact_self` — it is SAFE because your
      workstreams are durable: the platform reseeds your next turn with the `list_workstreams`
      index (rehydrate-on-resume), so you wake re-oriented and continue. In-flight workers keep
      running and their returns route back to the right workstream.
    - Record the `spec_path` and every stage outcome via `record_stage` so `get_workstream` can
      always reconstruct what's done, what remains, and the single next action after a compaction.
    """
    |> String.trim_trailing()
  end

  # The code-validated domain mental model(s) for the project's stack (self-healing Phase 5):
  # render each selected stack layer's expertise (keyed by the kebab-cased layer name). "" when
  # no project / no models exist (back-compatible: prompt unchanged).
  @spec expertise_block(Orchestrator.t()) :: String.t()
  defp expertise_block(%Orchestrator{} = orchestrator) do
    case orchestrator
         |> relevant_domains()
         |> Enum.map(&Expertise.render/1)
         |> Enum.reject(&(&1 == "")) do
      [] ->
        ""

      bodies ->
        """
        Domain expertise (code-validated mental model for this stack — verify against the cited code):
        #{Enum.join(bodies, "\n\n")}
        """
        |> String.trim_trailing()
    end
  end

  # Kebab-cased domain keys derived from the project's selected stack layers (e.g. an
  # "Elixir / Phoenix" layer → "elixir-phoenix"). No project ⇒ no domains.
  @spec relevant_domains(Orchestrator.t()) :: [String.t()]
  defp relevant_domains(%Orchestrator{} = orchestrator) do
    case resolve_project(orchestrator) do
      %Projects.Project{id: id} ->
        id |> StackLayers.layers_for_project() |> Enum.map(&domain_key(&1.name)) |> Enum.uniq()

      _no_project ->
        []
    end
  rescue
    _error -> []
  end

  @spec domain_key(String.t()) :: String.t()
  defp domain_key(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  # The last N verbal lessons for the project (self-healing Phase 5 — Reflexion): so the next
  # run starts ahead of where the last ended. "" when none (back-compatible).
  @spec reflections_block(Orchestrator.t()) :: String.t()
  defp reflections_block(%Orchestrator{} = orchestrator) do
    project_id =
      case resolve_project(orchestrator) do
        %Projects.Project{id: id} -> id
        _no_project -> nil
      end

    case Reflections.list_recent(project_id, 5) do
      [] ->
        ""

      reflections ->
        lines = Enum.map_join(reflections, "\n", fn r -> "- #{r.lesson}" end)

        """
        Lessons from past runs (apply them; don't repeat the mistakes):
        #{lines}
        """
        |> String.trim_trailing()
    end
  rescue
    _error -> ""
  end
end
