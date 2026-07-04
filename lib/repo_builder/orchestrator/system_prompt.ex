defmodule RepoBuilder.Orchestrator.SystemPrompt do
  @moduledoc """
  Builds the orchestrator system prompt (issue-c) — a harness-blind port of the
  reference `orchestrator_agent_system_prompt.md` with `{{TOOLS}}` and
  `{{HARNESSES}}` injected from the live `ToolCatalog` and registry. The prompt
  tells the LLM it is a meta-agent that creates/commands worker agents via its
  tools rather than doing the work itself.

  Layering (concept before the mechanics that depend on it — each concept has ONE
  authoritative home; other mentions are bare cross-references):

  1. Identity + durable memory (workstreams as external memory; why `compact_self`
     is safe)
  2. The core loop (goal → decompose → drive → VERIFY → report, incl. turn
     discipline / queue semantics)
  3. Spec-driven phased delivery + the quality gate — repo-bound renders only
  4. Context management for workers (compact vs clear, graceful handover)
  5. Dispatch reference (tiers, subagent templates, ADWs, slash commands)
  6. Terse tool index + rendered environment facts (harnesses, working dir,
     primer/stack/secrets/APIs, expertise, reflections)

  Repo-dependent machinery (phased delivery, quality gate, cross-repo ADW rules)
  is omitted when `repo_bound?/1` is false — a no-repo orchestrator gets an
  inactive-protocols notice instead. The dedupe/occurrence ledger for the
  2026-07 consolidation lives in `ai_docs/system-prompt-dedupe-ledger.md`.
  """
  alias RepoBuilder.Commands
  alias RepoBuilder.Definitions
  alias RepoBuilder.Expertise
  alias RepoBuilder.ExternalApis
  alias RepoBuilder.Harness.Registry

  alias RepoBuilder.Orchestrator.{
    Orchestrator,
    Reflections,
    SurfaceDetector,
    Templates,
    ToolCatalog
  }

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
    You are the conductor of this multi-agent orchestra — coordinate effectively.

    #{external_memory_block()}

    #{leader_expertise_block()}
    #{delivery_protocol_blocks(orchestrator)}
    Context management:
    #{context_management_block()}

    Dispatching workers:
    #{dispatch_rules_block()}

    Worker model tiers:
    #{categories_block(orchestrator)}

    Available subagent templates & worker roles (apply one by name via `create_agent`'s `subagent_template`; name workers by their role):
    #{subagent_map_block()}

    #{adw_block(orchestrator)}

    Available slash commands (put at the START of a line in a `command_agent` prompt; the platform expands them on any harness):
    #{slash_commands_block(orchestrator)}

    Available tools (terse index — your tool channel carries each tool's full schema):
    #{tools_block()}

    Available worker harnesses: #{harnesses_block()}.
    Your own harness is #{own_harness_block(orchestrator)}.

    Working directory:
    #{working_dir_block(orchestrator)}
    #{project_primer_block(orchestrator)}
    #{project_stack_block(orchestrator)}
    #{project_secrets_block(orchestrator)}
    #{registered_apis_block(orchestrator)}

    #{expertise_block(orchestrator)}
    #{reflections_block(orchestrator)}
    """
  end

  # Whether this orchestrator operates against a real repo: a bound/resolvable
  # project OR an explicit working directory. Gates the repo-dependent protocol
  # blocks (phased delivery, quality gate, cross-repo ADW rules) — a no-repo
  # orchestrator gets the inactive-protocols notice in its working-directory
  # section instead.
  @spec repo_bound?(Orchestrator.t()) :: boolean()
  defp repo_bound?(%Orchestrator{working_dir: dir} = orchestrator) do
    (is_binary(dir) and dir != "") or
      match?(%Projects.Project{}, resolve_project(orchestrator))
  end

  # §3 of the layering: the phase machine + quality gate, only when a repo exists
  # for them to run against.
  @spec delivery_protocol_blocks(Orchestrator.t()) :: String.t()
  defp delivery_protocol_blocks(%Orchestrator{} = orchestrator) do
    if repo_bound?(orchestrator) do
      "\n" <> phased_delivery_block() <> "\n\n" <> quality_gate_block() <> "\n"
    else
      ""
    end
  end

  # The single home for worker-dispatch mechanics (tiers, self-unblock, thinking
  # mode, slash-command expansion, research-tool grants, console-log lookups).
  @spec dispatch_rules_block() :: String.t()
  defp dispatch_rules_block do
    """
    - When the operator gives you work, break it into tasks and use `create_agent`
      to spin up a worker (reuse an existing one via `list_agents` when sensible).
      Always name workers descriptively and keep the operator informed in plain text.
    - WORKER TIERS: prefer the `category` argument to `create_agent`; it resolves to
      the operator-assigned harness/provider/model listed below. Choose `fast` for
      cheap/simple steps, `main` for normal work, `heavy` for hard reasoning, `leader`
      for coordination. A category with no model assigned cannot be spawned: if a tier
      shows `(unassigned — cannot spawn here)` or a spawn fails with "no model
      selected", call `get_config` to inspect the available harnesses/models, then
      `configure_tier` to assign one — do NOT stop and ask the operator unless no
      model is available at all. Use `set_orchestrator_config` to change your own
      harness/provider/model when needed.
    - Dispatch work with `command_agent`; check progress with `check_agent_status`;
      stop a runaway worker with `interrupt_agent`.
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
    - RESEARCH TOOLS: workers can be granted web-research tools. Pass
      `tools: ["firecrawl"]` to `create_agent` (or `update_agent`) to give a researcher
      worker firecrawl (web scrape/search/crawl/map/extract). Grant it only to workers
      that need live web access; omit it for everyone else.
    - When you (or the operator, or a worker) reference a console `log-<n>` number, use
      `get_logs` to pull up that log's exact content — it takes a single number, an
      inclusive `from`..`to` range (e.g. log-8219..log-8228), or an explicit `numbers`
      array. (This is distinct from `read_system_logs`, which reads the separate
      tool-audit table, and `check_agent_status`, which tails a worker by name.)
    """
    |> String.trim_trailing()
  end

  # The single home for ADW guidance: modes, the complexity selection ladder,
  # decompose-into-runs, launch-then-observe, and (repo-bound only) the cross-repo
  # `working_dir` rules — followed by the rendered ADW-types listing.
  @spec adw_block(Orchestrator.t()) :: String.t()
  defp adw_block(%Orchestrator{} = orchestrator) do
    prose =
      """
      ADWs — multi-step AI Developer Workflows (launch with `start_adw`, watch per-step progress with `check_adw`):
      - For REAL substantive work pass `harness: "adw"` and a `workflow_type` from the
        AVAILABLE ADW TYPES below — that shells out to the portable Python ADW (the real
        /plan→/build→/review→/fix logic, plus scout/parallel variants). Pick by complexity:
          * trivial change → `plan_build`
          * standard feature → `plan_build_review_fix`
          * non-trivial / multi-area → the full SDLC ADW
          * large or exploratory → a scout/parallel ADW (`plan_w_scouts…` / `build_in_parallel`)
      - For a complicated project, DECOMPOSE it into several `start_adw` runs (one per
        coherent slice) and track each with `check_adw` by its returned run id; report
        progress to the operator in plain text. Omitting `harness` runs the lightweight
        in-app catalog workflow instead (handy for demos/tests).
      - Once an ADW is launched, observe rather than interfere: it drives its own steps;
        only step in if the operator asks.
      """
      |> String.trim_trailing()

    cross_repo =
      if repo_bound?(orchestrator) do
        """
        - COMMAND WORKERS AND ADWs AGAINST *YOUR* PROJECT: by default omit `working_dir`
          so the ADW runs in your bound project. CROSS-REPO: an ADW's slash commands
          (`/plan`, `/build`, …) resolve from the TARGET repo's `.claude/commands/`, so to
          operate on a DIFFERENT repo pass `working_dir` — but it must be a REGISTERED
          project's path (otherwise the run is refused to prevent work landing in the
          wrong repo). Register the repo on the Projects page first if it isn't already.
        """
        |> String.trim_trailing()
      else
        nil
      end

    [
      prose,
      cross_repo,
      "",
      "Available ADW types (pass as `start_adw`'s `workflow_type`):",
      available_adw_types_block(orchestrator)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
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
    - Repo-dependent protocols (spec-driven phased delivery, the quality gate, UI/UX
      polish, cross-repo ADW dispatch) are INACTIVE until a working directory is set.
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

  # Registered external APIs the orchestrator may DELEGATE to workers
  # (issue-external-api-mcp-provisioning): name + description only (never the secret), so
  # the brain knows what capabilities it can transfer without a `list_apis` round-trip.
  # Empty scope ⇒ "" so the prompt is byte-identical when nothing is registered.
  @spec registered_apis_block(Orchestrator.t()) :: String.t()
  defp registered_apis_block(%Orchestrator{project_id: project_id}) do
    render_apis(ExternalApis.list_in_scope_for(project_id))
  rescue
    _error -> ""
  end

  @spec render_apis([ExternalApis.ExternalApi.t()]) :: String.t()
  defp render_apis([]), do: ""

  defp render_apis(apis) do
    lines = Enum.map_join(apis, "\n", &api_line/1)

    """

    Registered APIs you may delegate to workers:
    #{lines}
    You CANNOT call these tools yourself — pass their names in `apis` when you
    `create_agent`/`command_agent` to transfer a capability to a worker (use `list_apis`
    for the full instructions/doc URLs). The credentials live in the vault and are
    injected only into the provisioned worker's environment — you never hold them.
    """
    |> String.trim_trailing()
  end

  @spec api_line(ExternalApis.ExternalApi.t()) :: String.t()
  defp api_line(%ExternalApis.ExternalApi{name: name, description: description})
       when is_binary(description) and description != "",
       do: "- #{name} — #{description}"

  defp api_line(%ExternalApis.ExternalApi{name: name}), do: "- #{name}"

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
  # recipes the orchestrator can apply by name, data-driven from the live
  # subagent-template registry (the single roster print — it doubles as the
  # worker-roles list). The empty state still names the conventional roles.
  @spec subagent_map_block() :: String.t()
  defp subagent_map_block do
    case Templates.list() do
      [] ->
        "No subagent templates yet — author one in Settings → Agent Templates or via " <>
          "save_agent_template; name workers by role, e.g. builder/reviewer/tester/documenter/debugger."

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

  # Guidance for watching WORKER context-window pressure and relieving it (ports the
  # reference "Context Window Management" prompt section). Self-compaction policy lives
  # in `external_memory_block/0` — the single `compact_self` home.
  @spec context_management_block() :: String.t()
  defp context_management_block do
    """
    - When a worker is filling its context window (or its output starts degrading),
      compact it with `compact_agent` (or `command_agent(name, "/compact")`) to free
      room before it hits the limit.
    - To FULLY reset a worker before NEW, unrelated work, use `clear_context` — it
      returns the worker to a blank context window (its next task starts a fresh
      session with zero prior history). Prefer this over `compact_agent` when the new
      task does NOT depend on prior history; prefer `compact_agent` when the next task
      continues the worker's current work (it keeps a summary in-window).
    - At high usage (≈80%+), proactively `clear_context` any worker you're about to
      hand independent new work and `compact_agent` those continuing their current
      task; for your OWN window use `compact_self` (see the durable-memory section).
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

  # One terse line per tool (`ToolCatalog.prompt_line/1`); the full descriptions
  # still reach the model as the tool schemas on the MCP/pi channel.
  @spec tools_block() :: String.t()
  defp tools_block do
    ToolCatalog.tools()
    |> Enum.map_join("\n", fn tool -> "- #{tool.name}: #{ToolCatalog.prompt_line(tool)}" end)
  end

  @spec harnesses_block() :: String.t()
  defp harnesses_block do
    case Registry.known() do
      [] -> "(none registered)"
      harnesses -> harnesses |> Enum.sort() |> Enum.join(", ")
    end
  end

  @doc """
  The shared leadership playbook injected into EVERY orchestrator prompt (self-healing Phase 5) —
  §2 of the layering, the core loop: set a goal, record progress every turn, VERIFY against the
  tree (the single authoritative statement of that rule), one-step turn discipline + queue
  semantics, focus, replan, reflections, escalate as a last resort. Public so it can be
  reused/asserted.
  """
  @spec leader_expertise_block() :: String.t()
  def leader_expertise_block do
    """
    Autonomous leadership — the core loop (drive it every turn, even with no operator present):
    - SET A GOAL: for any non-trivial objective call `set_goal` with a concrete
      `definition_of_done` (and a plan). It is DURABLE — it survives a restart and you reconcile
      against it each turn instead of re-deriving intent from memory.
    - RECORD PROGRESS every turn: call `record_progress` (made_progress / looping / next_agent /
      summary). An unreported turn is treated as a STALL by the drive loop.
    - VERIFY, never assume — the rule every stage and completion decision cites: do NOT trust a
      worker's claim (self-report) that work is done. Read what the worker actually produced
      first — call `check_agent_status` and use its `final_message` field (never assume a worker
      reported back; retrieve it and relay it to the operator) — then use `inspect_repo`
      (git_status / changed_files / read_file) to check the ACTUAL tree against the definition of
      done before believing it.
    - ONE STEP per turn, then END YOUR TURN: drive a worker (`command_agent`), fan out a new role
      (`create_agent`), or — only once the definition of done is verified — `report_complete`.
      Report what you kicked off in plain text ("started the builder on X", "launched the ADW")
      rather than blocking in a monitor loop, and do NOT sit and poll `check_agent_status`
      waiting for a worker to finish (check status when the operator asks — workers take time to
      run). Your dispatched workers run in parallel in the background; operator messages that
      arrive while you work are QUEUED and delivered as your NEXT turn, in order — you will not
      be interrupted mid-turn. When a worker you dispatched returns you WILL be re-engaged
      automatically (the holding pattern), woken once per return, to review its work and decide
      next steps; operator messages always take precedence over these automatic resume turns.
    - DECLARE YOUR FOCUS before spending budget: `set_focus` names the single concrete thing you
      are working on right now, and an unfocused scope is BLOCKED from `command_agent` /
      `create_agent` / `start_adw`. Focus the workstream you are advancing (`set_focus` with its
      `workstream`) before commanding a worker on it; omit `workstream` to focus yourself for
      untagged work. Keep exactly one focus per scope; `clear_focus` only once that focus is
      verified done against the tree, then set the next one.
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
    - PER PHASE run the stage machine, recording each outcome with `record_stage` (verify each
      stage first — the core loop's VERIFY rule):
        * spec: dispatch `/feature` | `/bug` | `/chore` | `/plan` to produce a `specs/…md`,
          then `record_stage(stage: "spec", outcome: "passed", artifact: "<spec_path>")`.
        * implement: dispatch `/implement <spec_path>` (it STOPs without the path — always pass
          the phase's captured `spec_path`), verify, then `record_stage("implement", "passed")`.
        * test: dispatch `/test`, then drive the QUALITY GATE to green (see the Quality gate
          section) before `record_stage("test", "passed")` (pass the GateResult as the stage
          `note`).
        * review: dispatch `/review`; on failure record `review`/`failed`, dispatch the fix,
          then re-`/review` and record `review`/`passed`. A passed review completes the phase and
          promotes the next one automatically.
    - CONTEXT HYGIENE per stage: use fresh role workers and `clear_context` before unrelated
      work; if a worker hands over mid-phase, seed a fresh worker from its handover doc — the
      phase resumes at its recorded stage.
    - Run MULTIPLE workstreams in parallel: a single turn may advance several ready workstreams,
      and their workers run concurrently (bounded by the live-session admission cap). Keep the
      number of ACTIVE workstreams small (≈5) so you don't over-commit your own context.
    - ITERATIVE UI/UX POLISH after the backend passes: once the backend phases are green, check
      for a front-end surface with `inspect_repo(op: "surfaces")`. If it returns any of
      `web`/`desktop`/`tui`, append ONE `:ui_ux` phase per surface via `plan_phases` (set each
      phase's `kind: "ui_ux"` and its `surface`), and drive them to done BEFORE `report_complete`.
      A `:ui_ux` phase runs the same four stages, UI-flavored: spec = a UX design brief; implement
      = build/refine the interface; test = VISUAL/BEHAVIORAL validation producing real evidence
      (Playwright screenshots + console/network logs for web via the `playwright-cli` shell tool;
      a terminal snapshot for tui; a window screenshot or an honest block for desktop) attached as
      the stage `artifact`; review = the `ui-ux-foundations` rubric, whose failure re-enters the
      fix loop. That review→fix loop is BOUNDED — it converges to a decent MVP and auto-completes
      at the iteration cap. STOP AT MVP: fix concrete rubric failures with evidence, don't
      gold-plate. An empty `surfaces` result means no front end — skip UI/UX entirely.
    """
    |> String.trim_trailing()
  end

  @doc """
  The quality-gate protocol (quality-gate-plugins): the stack-aware five-stage green gate the
  orchestrator runs at each phase's `:test` stage, plus the strict/no-warnings tier and the
  pre-merge mutation/property tier run at workstream close. Public so it can be asserted.
  """
  @spec quality_gate_block() :: String.t()
  def quality_gate_block do
    """
    Quality gate (per-phase rigorous testing, stack-aware):
    - The `:test` stage is a GREEN GATE, not a single `/test`. `run_quality_gate` resolves this
      project's stack-aware gate — an ORDERED five stages: format · lint · type · test · mutation —
      each a single command with a binary red/green exit code. A phase may only advance to `:review`
      once EVERY per_phase stage is green.
    - STRICT / NO-WARNINGS tier: warnings are errors. The type stage is the cheapest verifier — it
      catches hallucinated APIs without executing anything, so never skip it. `typed_enforcement`
      (default strict) runs the strict type checker plus an annotation/`@spec`-coverage sub-stage;
      a passing type checker is not a typed system enforced.
    - FIX LOOP: on a red stage, dispatch a fix worker with the parsed `file:line` diagnostics from
      the GateResult, re-run the gate, and loop until green — bounded by the stall limit so a
      genuinely stuck gate blocks the phase rather than looping forever.
    - MUTATION / PROPERTY run at CLOSE, not per edit: they are slow (mutation re-runs the suite per
      mutant), so they are `pre_merge`-cadence. Before `close_workstream`, call
      `run_quality_gate(cadence: "pre_merge")` once; a red mutation score blocks the close (fix the
      vacuous tests) — passing tests with empty assertions clear a coverage gate but not a mutation
      gate.
    """
    |> String.trim_trailing()
  end

  @doc """
  The external-memory & compaction protocol (orchestration-adw-loop) — §1 of the layering and
  the keystone concept the rest of the prompt builds on: Workstreams are the brain's durable
  swap, so its in-window context stays bounded and self-compaction is safe. The SINGLE home
  for `compact_self` / rehydrate-on-resume policy. Public so it can be asserted.
  """
  @spec external_memory_block() :: String.t()
  def external_memory_block do
    """
    Durable memory (workstreams) & self-compaction — the model everything below builds on:
    - Your Workstreams ARE your memory: each is a durable objective (goal, definition of
      done, right-sized phases, per-phase stage outcomes) that persists across turns and a
      restart. Hold only their IDs in-window; at the START of each turn call
      `list_workstreams` (the compact index), then `get_workstream(id)` for the one you are
      about to advance — don't re-derive state from CLI memory.
    - Record the `spec_path` and every stage outcome via `record_stage` so `get_workstream` can
      always reconstruct what's done, what remains, and the single next action after a compaction.
    - BECAUSE workstreams are durable, compacting yourself is SAFE. Watch `report_cost` (your
      running cost and context-window usage %) on long multi-agent sessions; at high context
      usage call `compact_self` — the platform reseeds your next turn with the
      `list_workstreams` index (rehydrate-on-resume), so you wake re-oriented and continue;
      you no longer need to ask the operator to `/compact` you. In-flight workers keep
      running and their returns route back to the right workstream.
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
  # "Elixir / Phoenix" layer → "elixir-phoenix"), plus the `ui-ux-mvp` domain when the built
  # repo has a detected front-end surface (iterative-ui-ux polish phase) — so the orchestrator
  # gets UI/UX guidance exactly when a UI/UX phase is warranted. No project ⇒ no domains.
  @spec relevant_domains(Orchestrator.t()) :: [String.t()]
  defp relevant_domains(%Orchestrator{} = orchestrator) do
    case resolve_project(orchestrator) do
      %Projects.Project{id: id} = project ->
        base = id |> StackLayers.layers_for_project() |> Enum.map(&domain_key(&1.name))
        Enum.uniq(base ++ ui_ux_domain(project))

      _no_project ->
        []
    end
  rescue
    _error -> []
  end

  # `["ui-ux-mvp"]` when the project's repo presents a front-end surface, else `[]`.
  @spec ui_ux_domain(Projects.Project.t()) :: [String.t()]
  defp ui_ux_domain(%Projects.Project{root_path: root}) when is_binary(root) and root != "" do
    case SurfaceDetector.detect(root) do
      {:ok, [_ | _]} -> ["ui-ux-mvp"]
      _none -> []
    end
  end

  defp ui_ux_domain(%Projects.Project{}), do: []

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
