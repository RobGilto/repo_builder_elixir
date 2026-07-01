defmodule RepoBuilder.Orchestrator.Tools do
  @moduledoc """
  The orchestrator's agent-management tool LOGIC, implemented ONCE in harness-blind
  Elixir (issue-c). Every harness binding — Claude's native MCP, the pi extension,
  the in-process Fake loop — reaches this exact module, so tool behavior is
  identical regardless of harness.

  `call/3` is the single entry point: it dispatches a tool name to its handler,
  NEVER raises (every failure becomes `{:error, reason()}`), and logs each
  invocation as a `system_logs` row. Handlers drive only the platform's existing
  seams: `Agents`, `Session.Supervisor`, `WorkflowEngine`, `Logs`, and the
  `Dashboard` console feed.
  """
  alias RepoBuilder.{
    Agents,
    Budget,
    Commands,
    ExternalApis,
    Logs,
    Orchestrators,
    Session,
    WorkflowEngine,
    Workflows
  }

  alias RepoBuilder.ExternalApis.Provisioning

  alias RepoBuilder.Agents.Handover
  alias RepoBuilder.Agents.Holding
  alias RepoBuilder.Budget.Scope
  alias RepoBuilder.Dashboard
  alias RepoBuilder.Definitions
  alias RepoBuilder.Harness.McpTools
  alias RepoBuilder.Harness.ModelResolver
  alias RepoBuilder.Harness.Pi.Models, as: PiModels
  alias RepoBuilder.Harness.Redact
  alias RepoBuilder.Harness.Registry

  alias RepoBuilder.Orchestrator.{
    Breaker,
    ContextWindow,
    GateResolver,
    GateRunner,
    Ledgers,
    Orchestrator,
    Queue,
    Reflections,
    Server,
    SurfaceDetector,
    TaskLedger,
    Template,
    Templates,
    Workstream,
    WorkstreamPhase,
    Workstreams
  }

  alias RepoBuilder.Projects
  alias RepoBuilder.Projects.Project
  alias RepoBuilder.Secrets
  alias RepoBuilder.StackLayers
  alias RepoBuilder.WorkflowEngine.Catalog
  alias RepoBuilder.Workflows.TitleHumanizer

  # The registry key for the portable-Python-ADW shell-out harness (issue-the-adw-gap).
  # `start_adw` routes to the real ADW adapter when the resolved harness is this; every
  # other harness keeps the in-app WorkflowEngine catalog path (Fake-testable fallback).
  @adw_harness "adw"

  # Max characters of worker text surfaced through `check_agent_status` (issue-2541).
  # Bounded to keep the tool result small even at limit=20 (the platform has a known
  # large-tool-result stdout-overflow concern — see issue-log-2389). The reporting clause
  # (`worker_reporting_clause/0`) interpolates this so the documented limit never drifts
  # from the enforced one.
  @worker_text_cap 2_000

  # Max distinct `log_no` numbers `get_logs` resolves in one call (issue
  # orchestrator-log-lookup-tools). Bounds an enormous `from..to` span (or array) so the
  # tool result can never overflow stdout — same rationale as `@worker_text_cap` (see
  # issue-log-2389). A request wider than this is clamped (first N after sort) and flagged
  # `capped` so the orchestrator can narrow/paginate rather than silently lose data.
  @max_log_lookup 100

  # Caps for the read-only `inspect_repo` tool (self-healing Phase 3): bound the returned
  # text so a large file / huge diff can never overflow the orchestrator's stdout framing
  # (same rationale as `@worker_text_cap` — see issue-log-2389).
  @inspect_read_cap 8_000
  @inspect_files_cap 200

  # Soft cap on concurrently-active workstreams (orchestration-adw-loop): past this the brain
  # is warned (not refused) so it consolidates rather than over-committing its own context.
  @active_workstream_cap 5

  # Budget-spending WORKER tools blocked by the focus gate (focus discipline). `plan_phases` is
  # deliberately absent — it is the workstream-DECLARATION step, which must run before a
  # meaningful focus can be named (the analogue of tilldone "declare your tasks").
  @focus_gated_tools ~w(command_agent create_agent start_adw)

  # Changeset failures are stringified at the boundary (`changeset_reason/1`), so a
  # reason that escapes a tool is always an atom or a string.
  @type reason :: atom() | String.t()
  @type result :: {:ok, map()} | {:error, reason()}

  @doc """
  Execute a single orchestrator tool. `tool` is a catalog name; `args` is the
  decoded JSON arguments map (string keys). Returns a normalized tagged tuple and
  never raises.
  """
  @spec call(String.t(), Ecto.UUID.t(), map()) :: result()
  def call(tool, orchestrator_id, args) when is_binary(tool) and is_map(args) do
    result =
      case focus_gate_block(tool, orchestrator_id, args) do
        :ok -> dispatch(tool, orchestrator_id, args)
        {:error, _reason} = blocked -> blocked
      end

    log_invocation(tool, orchestrator_id, args, result)
    result
  rescue
    error -> {:error, "tool crashed: #{Exception.message(error)}"}
  catch
    kind, value -> {:error, "tool #{kind}: #{inspect(value)}"}
  end

  def call(_tool, _orchestrator_id, _args), do: {:error, :invalid_arguments}

  # --- dispatch ---

  @spec dispatch(String.t(), Ecto.UUID.t(), map()) :: result()
  defp dispatch("create_agent", orchestrator_id, args), do: create_agent(orchestrator_id, args)
  defp dispatch("command_agent", orchestrator_id, args), do: command_agent(orchestrator_id, args)
  defp dispatch("list_agents", orchestrator_id, _args), do: list_agents(orchestrator_id)
  defp dispatch("list_apis", orchestrator_id, _args), do: list_apis(orchestrator_id)

  defp dispatch("check_agent_status", orchestrator_id, args),
    do: check_agent_status(orchestrator_id, args)

  defp dispatch("interrupt_agent", orchestrator_id, args),
    do: interrupt_agent(orchestrator_id, args)

  defp dispatch("start_adw", orchestrator_id, args), do: start_adw(orchestrator_id, args)
  defp dispatch("update_agent", orchestrator_id, args), do: update_agent(orchestrator_id, args)
  defp dispatch("delete_agent", orchestrator_id, args), do: delete_agent(orchestrator_id, args)

  defp dispatch("read_system_logs", _orchestrator_id, args), do: read_system_logs(args)
  defp dispatch("get_logs", _orchestrator_id, args), do: get_logs(args)

  defp dispatch("check_adw", _orchestrator_id, args), do: check_adw(args)
  defp dispatch("get_config", orchestrator_id, _args), do: get_config(orchestrator_id)

  defp dispatch("configure_tier", orchestrator_id, args),
    do: configure_tier(orchestrator_id, args)

  defp dispatch("set_orchestrator_config", orchestrator_id, args),
    do: set_orchestrator_config(orchestrator_id, args)

  defp dispatch("report_cost", orchestrator_id, _args), do: report_cost(orchestrator_id)
  defp dispatch("compact_agent", orchestrator_id, args), do: compact_agent(orchestrator_id, args)
  defp dispatch("clear_context", orchestrator_id, args), do: clear_context(orchestrator_id, args)

  defp dispatch("list_agent_templates", _orchestrator_id, _args), do: list_agent_templates()
  defp dispatch("get_agent_template", _orchestrator_id, args), do: get_agent_template(args)
  defp dispatch("save_agent_template", _orchestrator_id, args), do: save_agent_template(args)

  # Leadership / ledger tools (self-healing Phase 3).
  defp dispatch("set_goal", orchestrator_id, args), do: set_goal(orchestrator_id, args)

  defp dispatch("record_progress", orchestrator_id, args),
    do: record_progress(orchestrator_id, args)

  defp dispatch("record_reflection", orchestrator_id, args),
    do: record_reflection(orchestrator_id, args)

  defp dispatch("get_ledger", orchestrator_id, _args), do: get_ledger(orchestrator_id)
  defp dispatch("set_focus", orchestrator_id, args), do: set_focus(orchestrator_id, args)
  defp dispatch("clear_focus", orchestrator_id, args), do: clear_focus(orchestrator_id, args)

  defp dispatch("report_complete", orchestrator_id, args),
    do: report_complete(orchestrator_id, args)

  defp dispatch("inspect_repo", orchestrator_id, args), do: inspect_repo(orchestrator_id, args)

  # Workstream tools (spec-driven phased orchestration).
  defp dispatch("create_workstream", orchestrator_id, args),
    do: create_workstream(orchestrator_id, args)

  defp dispatch("plan_phases", orchestrator_id, args), do: plan_phases(orchestrator_id, args)
  defp dispatch("record_stage", orchestrator_id, args), do: record_stage(orchestrator_id, args)

  defp dispatch("list_workstreams", orchestrator_id, _args),
    do: list_workstreams(orchestrator_id)

  defp dispatch("get_workstream", orchestrator_id, args),
    do: get_workstream(orchestrator_id, args)

  defp dispatch("close_workstream", orchestrator_id, args),
    do: close_workstream(orchestrator_id, args)

  defp dispatch("compact_self", orchestrator_id, _args), do: compact_self(orchestrator_id)

  defp dispatch("run_quality_gate", orchestrator_id, args),
    do: run_quality_gate(orchestrator_id, args)

  defp dispatch(_tool, _orchestrator_id, _args), do: {:error, :unknown_tool}

  # --- tools ---

  @spec create_agent(Ecto.UUID.t(), map()) :: result()
  defp create_agent(orchestrator_id, args) do
    with {:ok, name} <- fetch_string(args, "name"),
         {:ok, template} <- resolve_template(args),
         {:ok, tools} <- resolve_tools(args),
         project_id = orchestrator_project_id(orchestrator_id),
         {:ok, apis} <- resolve_apis(project_id, args),
         args = apply_template_args(args, template),
         {:ok, spec} <- resolve_agent_spec(orchestrator_id, args) do
      params = %{
        "name" => name,
        "harness" => spec.harness,
        "model" => spec.model,
        # Pin the worker to the commanding orchestrator's project (orchestrator↔project
        # binding): a worker spawned for repo A is permanently scoped to repo A and stays
        # on its roster. A platform orchestrator (project_id: nil) still spawns nil workers.
        "project_id" => project_id,
        # The stack contract (stack-layers subsystem) leads the worker charter so the
        # language/stack guardrail is the first thing the worker reads, then the task
        # body, then the reporting clause. Empty contract (no project / no layers) ⇒
        # exactly today's prompt (back-compatible).
        "system_prompt" =>
          args["system_prompt"]
          |> blank_to_nil()
          |> prepend_api_instructions(apis)
          |> prepend_stack_contract(project_id)
          |> with_reporting_clause(),
        # The worker's `provider` column is a closed enum that can't hold pi's open
        # provider set, so the real provider rides in `config` and is threaded into
        # the session at command time. Template provenance (name+version) rides here too;
        # a non-empty research-tool grant (issue firecrawl-grant) rides under `"tools"`;
        # a non-empty external-API provision (issue-external-api-mcp-provisioning) under
        # `"apis"` (names only — the secret stays in the vault).
        "config" =>
          spec.provider
          |> agent_config(template)
          |> maybe_put_tools(tools)
          |> maybe_put_apis(apis)
      }

      case Agents.create_worker(orchestrator_id, params) do
        {:ok, agent} ->
          _ = Dashboard.broadcast_agent_created(agent)

          {:ok,
           %{
             "id" => agent.id,
             "name" => agent.name,
             "harness" => agent.harness,
             "provider" => spec.provider,
             "model" => agent.model,
             "status" => to_string(agent.status)
           }}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset_reason(changeset)}
      end
    end
  end

  # Resolve the worker's {harness, provider, model} from a `category` (the operator's
  # roster) when given, else from explicit args. A category with no assigned model is
  # rejected so the orchestrator can't silently spawn an un-runnable worker.
  @spec resolve_agent_spec(Ecto.UUID.t(), map()) ::
          {:ok, %{harness: String.t(), provider: String.t() | nil, model: String.t() | nil}}
          | {:error, reason()}
  defp resolve_agent_spec(orchestrator_id, args) do
    # Single chokepoint: whichever branch builds the spec, the selected model is mapped
    # to the latest of its family BEFORE it is returned (and thus persisted/spawned).
    with {:ok, spec} <- build_agent_spec(orchestrator_id, args) do
      {:ok, %{spec | model: ModelResolver.latest(spec.harness, spec.provider, spec.model)}}
    end
  end

  @spec build_agent_spec(Ecto.UUID.t(), map()) ::
          {:ok, %{harness: String.t(), provider: String.t() | nil, model: String.t() | nil}}
          | {:error, reason()}
  defp build_agent_spec(orchestrator_id, args) do
    case blank_to_nil(args["category"]) do
      nil ->
        with {:ok, harness} <- resolve_harness(orchestrator_id, args) do
          {:ok,
           %{
             harness: harness,
             provider: blank_to_nil(args["provider"]),
             model: blank_to_nil(args["model"])
           }}
        end

      category ->
        resolve_category(orchestrator_id, category)
    end
  end

  @spec resolve_category(Ecto.UUID.t(), String.t()) ::
          {:ok, %{harness: String.t(), provider: String.t() | nil, model: String.t() | nil}}
          | {:error, reason()}
  defp resolve_category(orchestrator_id, category) do
    with {:ok, orchestrator} <- Orchestrators.fetch(orchestrator_id) do
      # Read through to the global default: an unset (or blank-model) per-project tier
      # inherits `Settings.default_agent_models()`, so a freshly registered project can
      # spawn category workers without manual configuration. Only an exhausted fallback
      # (no project entry AND no default) returns the clear "no model selected" error.
      {entry, _source} = Orchestrators.effective_agent_model(orchestrator, category)

      case blank_to_nil(entry && entry["model"]) do
        nil ->
          {:error, "no model selected for category #{category}"}

        model ->
          {:ok,
           %{
             harness: blank_to_nil(entry["harness"]) || orchestrator.harness,
             provider: blank_to_nil(entry["provider"]),
             model: model
           }}
      end
    end
  end

  # Inference-only spec — the concrete provider map narrows below a hand-written
  # `map()` spec, which Dialyzer rejects as a supertype under :underspecs.
  defp provider_config(nil), do: %{}
  defp provider_config(provider), do: %{"provider" => provider}

  # Fold the worker provider plus (optional) template provenance into the worker's
  # open `config` map. Inference-only spec (mirrors `provider_config/1`).
  defp agent_config(provider, nil), do: provider_config(provider)

  defp agent_config(provider, %Template{} = template) do
    provider
    |> provider_config()
    |> Map.merge(%{"template_name" => template.name, "template_version" => template.version})
    |> maybe_put_allowed_tools(template.tools)
  end

  # Record the template's per-worker capability allowlist (self-healing Phase 5) onto the
  # worker config so a harness binding can scope its tools to it. Empty ⇒ inherit defaults
  # (no key written, back-compatible). Distinct from config["tools"] (the firecrawl grant).
  # Inference-only spec — the concrete config map narrows below a hand-written `map()` range.
  defp maybe_put_allowed_tools(config, [_ | _] = tools),
    do: Map.put(config, "allowed_tools", tools)

  defp maybe_put_allowed_tools(config, _tools), do: config

  # Resolve an optional `subagent_template` to its current version; nil when absent.
  # An unknown name returns a helpful error listing the available template names.
  @spec resolve_template(map()) :: {:ok, Template.t() | nil} | {:error, reason()}
  defp resolve_template(args) do
    case blank_to_nil(args["subagent_template"]) do
      nil ->
        {:ok, nil}

      name ->
        case Templates.fetch(name) do
          {:ok, template} -> {:ok, template}
          {:error, :not_found} -> {:error, template_not_found(name)}
          {:error, reason} -> {:error, normalize_reason(reason)}
        end
    end
  end

  # Layer a template's body/model/category UNDER the explicit args (explicit wins).
  # The category default only applies when the caller pinned no concrete target
  # (category/model/harness), so an explicit `model` is never shadowed by the
  # template's category.
  @spec apply_template_args(map(), Template.t() | nil) :: map()
  defp apply_template_args(args, nil), do: args

  defp apply_template_args(args, %Template{} = template) do
    args =
      args |> put_default("system_prompt", template.body) |> put_default("model", template.model)

    if explicit_target?(args),
      do: args,
      else: put_default(args, "category", template.category)
  end

  @spec explicit_target?(map()) :: boolean()
  defp explicit_target?(args) do
    not is_nil(blank_to_nil(args["category"])) or
      not is_nil(blank_to_nil(args["model"])) or
      not is_nil(blank_to_nil(args["harness"]))
  end

  # Set `key` from `value` only when the caller left it blank (explicit args win).
  # Inference-only spec — callers pass literal string keys.
  defp put_default(args, key, value) when is_binary(value) do
    case blank_to_nil(args[key]) do
      nil -> Map.put(args, key, value)
      _present -> args
    end
  end

  defp put_default(args, _key, _value), do: args

  @spec template_not_found(String.t()) :: String.t()
  defp template_not_found(name) do
    case Enum.map(Templates.list(), & &1.name) do
      [] -> "unknown subagent_template #{name}; no templates available"
      names -> "unknown subagent_template #{name}; available: #{Enum.join(names, ", ")}"
    end
  end

  @spec command_agent(Ecto.UUID.t(), map()) :: result()
  defp command_agent(orchestrator_id, args) do
    with {:ok, name} <- fetch_string(args, "name"),
         {:ok, prompt} <- fetch_string(args, "prompt"),
         {:ok, worker} <- Agents.get_by_name_for_orchestrator(orchestrator_id, name),
         :ok <- ensure_worker_model(worker),
         :ok <- check_budget(orchestrator_id),
         :ok <- check_breaker(worker) do
      # First-dispatch only (no prior session): record the original ask as the worker's
      # handover receipt, so a later wind-down directive / retirement notice can quote it
      # verbatim (issue graceful-agent-handover). Subsequent turns leave it untouched.
      _ = maybe_record_original_ask(worker, prompt)
      # Workstream-tagged return routing (orchestration-adw-loop): when this dispatch advances
      # a workstream, tag the worker so its terminal carries the workstream_id and the Queue
      # resumes the right scratchpad.
      worker = maybe_tag_workstream(orchestrator_id, worker, args)
      # Provision-at-command-time (issue-external-api-mcp-provisioning): merge any
      # command-time `apis` into the worker's config so the spawn path grants them. Merges
      # with create-time grants; unknown names are dropped (the brain saw them via
      # `list_apis`, so a silent drop is acceptable here).
      worker = maybe_provision_apis(orchestrator_id, worker, args)
      session_id = worker.session_id || generate_session_id()
      _ = Agents.set_session(worker.id, session_id)

      # Derive the dispatch location from the WORKER'S OWN project (drift-proof): a worker
      # pinned to repo A always runs in repo A's root_path with repo A's isolation_mode,
      # regardless of where the orchestrator's working_dir now points. An unscoped worker
      # (project_id: nil) falls back to the orchestrator's working dir (back-compat).
      {cwd, isolation_mode} = worker_dispatch_location(worker, orchestrator_id)

      opts = [
        agent_id: worker.id,
        agent_db_id: worker.id,
        agent_name: worker.name,
        session_id: session_id,
        harness: worker.harness,
        prompt: prompt,
        model: worker.model,
        orchestrator_id: orchestrator_id,
        # The worker's bound project drives its encrypted-vault env layer
        # (issue-per-project-encrypted-secrets-vault); nil for an unscoped worker.
        project_id: worker.project_id,
        provider: worker_provider(worker),
        config: worker_session_config(worker),
        cwd: cwd,
        # Honour the project's worktree isolation where the session runtime applies it
        # (nil ⇒ direct, unchanged for unscoped/back-compat workers).
        isolation_mode: isolation_mode
      ]

      case Session.Supervisor.start_session(opts) do
        {:ok, pid} ->
          _ = Agents.set_status(worker.id, :running)
          # Push liveness (self-healing Phase 2): the owning Queue `Process.monitor`s this
          # worker pid, so a `:DOWN` with no preceding worker-terminal (hard kill / brutal
          # shutdown) synthesizes the worker-terminal instantly — the leader re-engages in
          # milliseconds instead of after a ≤60 s reaper sweep. No-op when no Queue is running.
          _ = Queue.monitor_worker(orchestrator_id, worker.id, pid)
          {:ok, %{"status" => "dispatched", "agent_id" => worker.id, "name" => worker.name}}

        {:error, :at_capacity} ->
          {:error, :at_capacity}

        {:error, reason} ->
          {:error, normalize_reason(reason)}
      end
    end
  end

  # Tag a worker with the workstream it is advancing (orchestration-adw-loop) so its terminal
  # routes the resume to the right scratchpad. An absent/unresolvable `workstream` leaves the
  # worker untouched (back-compat). Returns the (possibly config-updated) worker.
  @spec maybe_tag_workstream(Ecto.UUID.t(), Agents.Agent.t(), map()) :: Agents.Agent.t()
  defp maybe_tag_workstream(orchestrator_id, worker, args) do
    with ref when is_binary(ref) <- blank_to_nil(args["workstream"]),
         {:ok, workstream} <- Workstreams.resolve(orchestrator_id, ref),
         {:ok, updated} <- Agents.merge_config(worker, %{"workstream_id" => workstream.id}) do
      updated
    else
      _ -> worker
    end
  end

  # Merge a command-time `apis` provision into the worker's persisted config (names only),
  # unioned with any create-time grant. An absent/empty/unresolvable list leaves the worker
  # untouched (back-compat). Returns the (possibly config-updated) worker.
  @spec maybe_provision_apis(Ecto.UUID.t(), Agents.Agent.t(), map()) :: Agents.Agent.t()
  defp maybe_provision_apis(orchestrator_id, worker, args) do
    project_id = orchestrator_project_id(orchestrator_id)

    with {:ok, [_ | _] = apis} <- resolve_apis(project_id, args),
         existing = List.wrap(worker.config["apis"]),
         names = Enum.uniq(existing ++ Enum.map(apis, & &1.name)),
         {:ok, updated} <- Agents.merge_config(worker, %{"apis" => names}) do
      updated
    else
      _ -> worker
    end
  end

  # --- leadership / ledger tools (self-healing Phase 3) ---

  @spec set_goal(Ecto.UUID.t(), map()) :: result()
  defp set_goal(orchestrator_id, args) do
    with {:ok, goal} <- fetch_string(args, "goal"),
         {:ok, dod} <- fetch_string(args, "definition_of_done") do
      attrs = %{
        goal: goal,
        definition_of_done: dod,
        plan: args["plan"],
        project_id: orchestrator_project_id(orchestrator_id)
      }

      case Ledgers.upsert_goal(orchestrator_id, attrs) do
        {:ok, ledger} ->
          _ = broadcast_ledger(orchestrator_id)
          {:ok, %{"status" => "goal_set", "ledger_id" => ledger.id, "goal" => ledger.goal}}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset_reason(changeset)}
      end
    end
  end

  @spec record_progress(Ecto.UUID.t(), map()) :: result()
  defp record_progress(orchestrator_id, args) do
    attrs = %{
      "satisfied" => args["satisfied"],
      "looping" => args["looping"],
      "made_progress" => args["made_progress"],
      "next_agent" => args["next_agent"],
      "next_instruction" => args["next_instruction"],
      "summary" => args["summary"]
    }

    case Ledgers.record_progress(orchestrator_id, attrs) do
      {:ok, entry} ->
        _ = broadcast_ledger(orchestrator_id)
        {:ok, %{"status" => "recorded", "entry_id" => entry.id}}

      {:error, :no_active_ledger} ->
        {:error, :no_active_ledger}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset_reason(changeset)}
    end
  end

  @spec get_ledger(Ecto.UUID.t()) :: result()
  defp get_ledger(orchestrator_id) do
    case Ledgers.view(orchestrator_id) do
      nil -> {:ok, %{"status" => "no_goal"}}
      view -> {:ok, ledger_tool_map(view)}
    end
  end

  @spec report_complete(Ecto.UUID.t(), map()) :: result()
  defp report_complete(orchestrator_id, args) do
    summary = blank_to_nil(args["summary"])
    recommendations = blank_to_nil(args["recommendations"])
    # Capture the goal BEFORE marking done (mark_done deactivates the ledger) so the reflection
    # can be scoped to it.
    goal = current_goal(orchestrator_id)

    case Ledgers.mark_done(orchestrator_id) do
      {:ok, _ledger} ->
        _ = broadcast_ledger(orchestrator_id)
        _ = notify_complete(orchestrator_id, summary, recommendations)
        _ = record_completion_reflection(orchestrator_id, goal, summary)
        {:ok, %{"status" => "done", "summary" => summary}}

      {:error, :no_active_ledger} ->
        {:error, :no_active_ledger}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset_reason(changeset)}
    end
  end

  # Read-only repo inspection scoped to the orchestrator's working_dir (path-jailed, capped),
  # so the leader can verify "done" against the ACTUAL tree, not a worker's self-report.
  @spec inspect_repo(Ecto.UUID.t(), map()) :: result()
  defp inspect_repo(orchestrator_id, args) do
    with {:ok, op} <- fetch_string(args, "op"),
         {:ok, dir} <- resolve_working_dir(orchestrator_id) do
      case op do
        "git_status" -> git_status(dir)
        "changed_files" -> changed_files(dir)
        "read_file" -> read_file_jailed(dir, args["path"])
        "surfaces" -> detect_surfaces(dir)
        _ -> {:error, :invalid_op}
      end
    end
  end

  @spec broadcast_ledger(Ecto.UUID.t()) :: :ok
  defp broadcast_ledger(orchestrator_id),
    do: Dashboard.broadcast_ledger_updated(orchestrator_id, Ledgers.view(orchestrator_id))

  # --- focus discipline (two-level: per-workstream + orchestrator fallback) ---

  # Set the focus for the targeted scope: a `workstream` ref focuses that parallel stream,
  # otherwise the orchestrator itself (untagged work). Blank focus is rejected at the boundary.
  @spec set_focus(Ecto.UUID.t(), map()) :: result()
  defp set_focus(orchestrator_id, args) do
    with {:ok, focus} <- fetch_string(args, "focus") do
      case blank_to_nil(args["workstream"]) do
        nil -> set_orchestrator_focus(orchestrator_id, focus)
        ref -> set_workstream_focus(orchestrator_id, ref, focus)
      end
    end
  end

  @spec set_orchestrator_focus(Ecto.UUID.t(), String.t()) :: result()
  defp set_orchestrator_focus(orchestrator_id, focus) do
    case Ledgers.set_focus(orchestrator_id, focus) do
      {:ok, _ledger} ->
        _ = broadcast_ledger(orchestrator_id)
        {:ok, %{"status" => "focused", "scope" => "orchestrator", "focus" => focus}}

      {:error, :no_active_ledger} ->
        {:error, :no_active_ledger}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset_reason(changeset)}
    end
  end

  @spec set_workstream_focus(Ecto.UUID.t(), String.t(), String.t()) :: result()
  defp set_workstream_focus(orchestrator_id, ref, focus) do
    case Workstreams.set_focus(orchestrator_id, ref, focus) do
      {:ok, _workstream} ->
        _ = broadcast_workstreams(orchestrator_id)

        {:ok,
         %{"status" => "focused", "scope" => "workstream", "workstream" => ref, "focus" => focus}}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset_reason(changeset)}
    end
  end

  # Clear the focus for the targeted scope (its stretch of work is verified done).
  @spec clear_focus(Ecto.UUID.t(), map()) :: result()
  defp clear_focus(orchestrator_id, args) do
    case blank_to_nil(args["workstream"]) do
      nil -> clear_orchestrator_focus(orchestrator_id)
      ref -> clear_workstream_focus(orchestrator_id, ref)
    end
  end

  @spec clear_orchestrator_focus(Ecto.UUID.t()) :: result()
  defp clear_orchestrator_focus(orchestrator_id) do
    case Ledgers.clear_focus(orchestrator_id) do
      {:ok, _ledger} ->
        _ = broadcast_ledger(orchestrator_id)
        {:ok, %{"status" => "focus_cleared", "scope" => "orchestrator"}}

      {:error, :no_active_ledger} ->
        {:error, :no_active_ledger}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset_reason(changeset)}
    end
  end

  @spec clear_workstream_focus(Ecto.UUID.t(), String.t()) :: result()
  defp clear_workstream_focus(orchestrator_id, ref) do
    case Workstreams.clear_focus(orchestrator_id, ref) do
      {:ok, _workstream} ->
        _ = broadcast_workstreams(orchestrator_id)
        {:ok, %{"status" => "focus_cleared", "scope" => "workstream", "workstream" => ref}}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset_reason(changeset)}
    end
  end

  # The deterministic, scope-aware focus gate: refuse a budget-spending worker tool when the
  # scope it targets has no focus. A call naming a `workstream` is gated against THAT stream's
  # focus; an untagged call against the orchestrator-level focus. Never engages for ungated
  # tools, a disabled gate, an unresolvable/non-running workstream, or an absent active goal.
  @spec focus_gate_block(String.t(), Ecto.UUID.t(), map()) :: :ok | {:error, :focus_required}
  defp focus_gate_block(tool, orchestrator_id, args) do
    if focus_gate_enabled?() and tool in @focus_gated_tools and
         scope_unfocused?(orchestrator_id, args) do
      {:error, :focus_required}
    else
      :ok
    end
  end

  # True when the tool's target scope is an active/running unit with a blank focus.
  @spec scope_unfocused?(Ecto.UUID.t(), map()) :: boolean()
  defp scope_unfocused?(orchestrator_id, args) do
    case targeted_workstream(orchestrator_id, args) do
      %Workstream{} = ws -> blank?(ws.focus)
      nil -> orchestrator_unfocused?(orchestrator_id)
    end
  end

  # The `:running` workstream a call targets via its `workstream` ref, or nil (untagged, an
  # unresolvable ref, or a non-running stream — the last two fall through to normal dispatch).
  @spec targeted_workstream(Ecto.UUID.t(), map()) :: Workstream.t() | nil
  defp targeted_workstream(orchestrator_id, args) do
    with ref when is_binary(ref) <- blank_to_nil(args["workstream"]),
         {:ok, %Workstream{status: :running} = ws} <- Workstreams.resolve(orchestrator_id, ref) do
      ws
    else
      _ -> nil
    end
  end

  @spec orchestrator_unfocused?(Ecto.UUID.t()) :: boolean()
  defp orchestrator_unfocused?(orchestrator_id) do
    case Ledgers.current(orchestrator_id) do
      %TaskLedger{focus: focus} -> blank?(focus)
      nil -> false
    end
  end

  @spec blank?(String.t() | nil) :: boolean()
  defp blank?(value), do: is_nil(blank_to_nil(value))

  @spec focus_gate_enabled?() :: boolean()
  defp focus_gate_enabled?,
    do: Keyword.get(Application.get_env(:repo_builder, :orchestrator, []), :focus_gate, true)

  # --- workstream tools (spec-driven phased orchestration) ---

  @spec create_workstream(Ecto.UUID.t(), map()) :: result()
  defp create_workstream(orchestrator_id, args) do
    with {:ok, title} <- fetch_string(args, "title"),
         {:ok, goal} <- fetch_string(args, "goal") do
      attrs = %{
        title: title,
        goal: goal,
        definition_of_done: blank_to_nil(args["definition_of_done"])
      }

      case Workstreams.create_workstream(orchestrator_id, attrs) do
        {:ok, workstream} ->
          _ = broadcast_workstreams(orchestrator_id)

          {:ok,
           %{"status" => "created", "workstream_id" => workstream.id, "title" => workstream.title}
           |> maybe_warn_active_cap(orchestrator_id)}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset_reason(changeset)}
      end
    end
  end

  @spec plan_phases(Ecto.UUID.t(), map()) :: result()
  defp plan_phases(orchestrator_id, args) do
    with {:ok, ref} <- fetch_string(args, "workstream"),
         {:ok, phases} <- normalize_phases(args["phases"]) do
      case Workstreams.plan_phases(orchestrator_id, ref, phases) do
        {:ok, workstream} ->
          _ = broadcast_workstreams(orchestrator_id)

          {:ok,
           %{"status" => "planned", "workstream_id" => workstream.id, "phases" => length(phases)}}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset_reason(changeset)}

        {:error, reason} ->
          {:error, normalize_reason(reason)}
      end
    end
  end

  @spec record_stage(Ecto.UUID.t(), map()) :: result()
  defp record_stage(orchestrator_id, args) do
    with {:ok, ref} <- fetch_string(args, "workstream"),
         {:ok, stage} <- fetch_string(args, "stage"),
         {:ok, outcome} <- fetch_string(args, "outcome") do
      attrs = %{
        stage: stage,
        outcome: outcome,
        artifact: blank_to_nil(args["artifact"]),
        worker: blank_to_nil(args["worker"]),
        note: blank_to_nil(args["note"]),
        gate: gate_evidence(args["gate"])
      }

      case Workstreams.record_stage(orchestrator_id, ref, attrs) do
        {:ok, _workstream} ->
          _ = broadcast_workstreams(orchestrator_id)
          {:ok, workstream_record_map(orchestrator_id, ref)}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset_reason(changeset)}

        {:error, reason} ->
          {:error, normalize_reason(reason)}
      end
    end
  end

  # Accept an already-structured GateResult map as stage evidence; anything else ⇒ nil.
  @spec gate_evidence(term()) :: map() | nil
  defp gate_evidence(%{} = gate), do: gate
  defp gate_evidence(_gate), do: nil

  @spec list_workstreams(Ecto.UUID.t()) :: result()
  defp list_workstreams(orchestrator_id) do
    rows = orchestrator_id |> Workstreams.list_workstreams() |> Enum.map(&index_row_map/1)
    {:ok, %{"workstreams" => rows, "count" => length(rows)}}
  end

  @spec get_workstream(Ecto.UUID.t(), map()) :: result()
  defp get_workstream(orchestrator_id, args) do
    with {:ok, ref} <- fetch_string(args, "workstream") do
      case Workstreams.get_workstream(orchestrator_id, ref) do
        {:ok, record} -> {:ok, record_map(record)}
        {:error, reason} -> {:error, normalize_reason(reason)}
      end
    end
  end

  @spec close_workstream(Ecto.UUID.t(), map()) :: result()
  defp close_workstream(orchestrator_id, args) do
    with {:ok, ref} <- fetch_string(args, "workstream"),
         {:ok, status} <- fetch_string(args, "status") do
      case Workstreams.close_workstream(orchestrator_id, ref, status) do
        {:ok, workstream} ->
          _ = broadcast_workstreams(orchestrator_id)
          {:ok, %{"status" => to_string(workstream.status), "workstream_id" => workstream.id}}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset_reason(changeset)}

        {:error, reason} ->
          {:error, normalize_reason(reason)}
      end
    end
  end

  # Compact the orchestrator's OWN context (the brain's durable swap): schedule a `/compact`
  # turn on its own session; the queue then reseeds the next turn with the workstream index
  # (rehydrate-on-resume). Delegates to the orchestrator Server (task 8).
  @spec compact_self(Ecto.UUID.t()) :: result()
  defp compact_self(orchestrator_id) do
    case Server.compact_self(orchestrator_id) do
      {:ok, :compacting} -> {:ok, %{"status" => "compacting"}}
      {:error, reason} -> {:error, normalize_reason(reason)}
    end
  end

  # --- quality gate (quality-gate-plugins) ---

  # Resolve + run the project's stack-aware quality gate for a phase's `:test` stage. With no
  # `outputs` it returns the ordered COMMAND PLAN the phase worker executes; with `outputs`
  # (the worker's captured exit codes + text) it EVALUATES them into a structured GateResult.
  # The orchestrator BEAM never shells out — execution stays in the worker sandbox.
  @spec run_quality_gate(Ecto.UUID.t(), map()) :: result()
  defp run_quality_gate(orchestrator_id, args) do
    with {:ok, cadence} <- cast_gate_cadence(args["cadence"]),
         {:ok, gate} <- resolve_project_gate(orchestrator_id) do
      case normalize_gate_outputs(args["outputs"]) do
        {:ok, nil} -> {:ok, gate_plan_map(gate, cadence)}
        {:ok, outputs} -> {:ok, gate_result_map(gate, cadence, outputs)}
      end
    end
  end

  # The resolved gate for the orchestrator's bound project. `:no_project`/`:no_gate` are honest
  # errors the brain can act on (register a project / install a gate plugin).
  @spec resolve_project_gate(Ecto.UUID.t()) :: {:ok, GateResolver.t()} | {:error, reason()}
  defp resolve_project_gate(orchestrator_id) do
    with project_id when is_binary(project_id) <-
           orchestrator_project_id(orchestrator_id) || :no_project,
         {:ok, %Project{} = project} <- fetch_gate_project(project_id) do
      case GateResolver.resolve(project) do
        {:ok, gate} -> {:ok, gate}
        {:error, :none} -> {:error, :no_gate}
      end
    else
      :no_project -> {:error, :no_project}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec fetch_gate_project(Ecto.UUID.t()) :: {:ok, Project.t()} | {:error, :project_not_found}
  defp fetch_gate_project(project_id) do
    case Projects.fetch_project(project_id) do
      {:ok, %Project{} = project} -> {:ok, project}
      {:error, _reason} -> {:error, :project_not_found}
    end
  end

  @spec cast_gate_cadence(term()) :: {:ok, :per_phase | :pre_merge} | {:error, reason()}
  defp cast_gate_cadence(nil), do: {:ok, :per_phase}
  defp cast_gate_cadence("per_phase"), do: {:ok, :per_phase}
  defp cast_gate_cadence("pre_merge"), do: {:ok, :pre_merge}
  defp cast_gate_cadence(_other), do: {:error, "cadence must be per_phase or pre_merge"}

  # Normalize the optional `outputs` array into a `%{stage_id => %{exit_code, output}}` lookup,
  # or nil when absent/empty (plan mode). A malformed entry is dropped.
  @spec normalize_gate_outputs(term()) :: {:ok, map() | nil}
  defp normalize_gate_outputs(list) when is_list(list) and list != [] do
    {:ok, Enum.reduce(list, %{}, &maybe_put_output(&2, &1))}
  end

  defp normalize_gate_outputs(_list), do: {:ok, nil}

  @spec maybe_put_output(map(), term()) :: map()
  defp maybe_put_output(acc, %{"stage_id" => id, "exit_code" => code} = entry)
       when is_binary(id) and is_integer(code) do
    Map.put(acc, id, %{exit_code: code, output: to_string(entry["output"] || "")})
  end

  defp maybe_put_output(acc, _entry), do: acc

  # Evaluate the gate against the worker-captured outputs (exec_fun reads the lookup; a stage
  # with no captured output is treated as a clean pass so a partial report can't false-red).
  @spec gate_result_map(GateResolver.t(), :per_phase | :pre_merge, map()) :: map()
  defp gate_result_map(gate, cadence, outputs) do
    result =
      GateRunner.run(gate, cadence, fn stage ->
        Map.get(outputs, stage.id, %{exit_code: 0, output: ""})
      end)

    GateRunner.to_map(result)
    |> Map.put("mode", "result")
    |> Map.put("source", to_string(gate.source))
    |> Map.put("typed_enforcement", to_string(gate.typed_enforcement))
    |> Map.put("degraded", gate.degraded)
  end

  # The ordered command plan the worker executes (plan mode).
  # Inference-only spec — the concrete string-keyed map narrows below a hand-written `map()`.
  defp gate_plan_map(gate, cadence) do
    %{
      "mode" => "plan",
      "stack" => gate.stack,
      "source" => to_string(gate.source),
      "cadence" => to_string(cadence),
      "typed_enforcement" => to_string(gate.typed_enforcement),
      "degraded" => gate.degraded,
      "commands" => GateRunner.command_plan(gate, cadence)
    }
  end

  @spec broadcast_workstreams(Ecto.UUID.t()) :: :ok
  defp broadcast_workstreams(orchestrator_id),
    do:
      Dashboard.broadcast_workstreams(orchestrator_id, Workstreams.list_records(orchestrator_id))

  # Active-workstream cap (orchestration-adw-loop edge case): keep the brain from over-committing
  # its own context. Past the soft cap the workstream is still created, but the result carries a
  # warning so the brain consolidates rather than spawning yet more parallel scratchpads.
  # Inference-only spec — the concrete map (optionally with a "warning" key) narrows below `map()`.
  defp maybe_warn_active_cap(result, orchestrator_id) do
    active =
      orchestrator_id
      |> Workstreams.list_workstreams()
      |> Enum.count(&(&1.status in [:running, :blocked]))

    if active > @active_workstream_cap do
      Map.put(
        result,
        "warning",
        "#{active} active workstreams exceeds the soft cap of #{@active_workstream_cap} — " <>
          "finish or close some before opening more so you don't over-commit your context"
      )
    else
      result
    end
  end

  # Re-read the full record after a mutation for the tool result (string-keyed, JSON-encodable).
  # Inference-only spec — the concrete string-keyed map narrows below a hand-written `map()`.
  defp workstream_record_map(orchestrator_id, ref) do
    case Workstreams.get_workstream(orchestrator_id, ref) do
      {:ok, record} -> record_map(record)
      {:error, _reason} -> %{"status" => "recorded"}
    end
  end

  # Inference-only spec — the concrete string-keyed map narrows below a hand-written `map()`.
  defp index_row_map(row) do
    %{
      "id" => row.id,
      "title" => row.title,
      "status" => to_string(row.status),
      "phase" => row.phase,
      "current_stage" => row.current_stage && to_string(row.current_stage),
      "next_action" => row.next_action,
      "stall_count" => row.stall_count,
      "focus" => row.focus
    }
  end

  # Inference-only spec — the concrete string-keyed map narrows below a hand-written `map()`.
  defp record_map(record) do
    %{
      "id" => record.id,
      "title" => record.title,
      "goal" => record.goal,
      "definition_of_done" => record.definition_of_done,
      "status" => to_string(record.status),
      "stall_count" => record.stall_count,
      "current_phase_position" => record.current_phase_position,
      "next_action" => record.next_action,
      "focus" => record.focus,
      "phases" => Enum.map(record.phases, &phase_map/1)
    }
  end

  # Inference-only spec — the concrete string-keyed map narrows below a hand-written `map()`.
  defp phase_map(phase) do
    %{
      "position" => phase.position,
      "title" => phase.title,
      "description" => phase.description,
      "definition_of_done" => phase.definition_of_done,
      "spec_path" => phase.spec_path,
      "status" => to_string(phase.status),
      "current_stage" => to_string(phase.current_stage),
      "kind" => to_string(phase.kind),
      "surface" => phase.surface && to_string(phase.surface),
      "iteration" => phase.iteration,
      "stages" => phase.stages,
      "completed" => phase.completed,
      "remaining" => phase.remaining
    }
  end

  # Validate + normalize the `phases` array from the tool args into the context's phase maps.
  @spec normalize_phases(term()) :: {:ok, [map()]} | {:error, reason()}
  defp normalize_phases(phases) when is_list(phases) and phases != [] do
    normalized =
      Enum.map(phases, fn phase when is_map(phase) ->
        %{
          title: blank_to_nil(phase["title"]),
          description: blank_to_nil(phase["description"]),
          definition_of_done: blank_to_nil(phase["definition_of_done"]),
          # UI/UX polish phase (iterative-ui-ux): a phase may declare `kind: "ui_ux"` + a
          # `surface`. Absent/blank/unknown ⇒ nil, and the context defaults to a `:backend`
          # phase, so existing plans are byte-for-byte unchanged.
          kind: normalize_phase_kind(phase["kind"]),
          surface: normalize_phase_surface(phase["surface"])
        }
      end)

    if Enum.all?(normalized, &is_binary(&1.title)),
      do: {:ok, normalized},
      else: {:error, "each phase requires a title"}
  rescue
    _error -> {:error, "phases must be an array of objects"}
  end

  defp normalize_phases(_phases), do: {:error, "phases must be a non-empty array"}

  # Map a phase's wire `kind`/`surface` to a validated atom (or nil). Unknown strings drop to
  # nil so a malformed value degrades to the backend default rather than failing the plan.
  @spec normalize_phase_kind(term()) :: WorkstreamPhase.kind() | nil
  defp normalize_phase_kind(kind) when kind in ["backend", "ui_ux"], do: String.to_atom(kind)
  defp normalize_phase_kind(_kind), do: nil

  @spec normalize_phase_surface(term()) :: WorkstreamPhase.surface() | nil
  defp normalize_phase_surface(surface) when surface in ["web", "desktop", "tui"],
    do: String.to_atom(surface)

  defp normalize_phase_surface(_surface), do: nil

  @spec current_goal(Ecto.UUID.t()) :: String.t() | nil
  defp current_goal(orchestrator_id) do
    case Ledgers.current(orchestrator_id) do
      %{goal: goal} -> goal
      _none -> nil
    end
  end

  # Capture a verbal lesson on completion (self-healing Phase 5 — Reflexion) so the next run for
  # this project starts ahead. Fail-soft via Reflections.record/1.
  @spec record_completion_reflection(Ecto.UUID.t(), String.t() | nil, String.t() | nil) :: :ok
  defp record_completion_reflection(orchestrator_id, goal, summary) do
    lesson = summary || "completed goal: #{goal || "(unnamed)"}"

    _ =
      Reflections.record(%{
        lesson: lesson,
        goal: goal,
        orchestrator_id: orchestrator_id,
        project_id: orchestrator_project_id(orchestrator_id)
      })

    :ok
  end

  # On-demand verbal lesson write (self-healing Phase 5 — Reflexion): the LLM-callable
  # counterpart to the automatic completion/escalation writes, so a lesson learned MID-run
  # can be banked instead of lost at session end. Scoped to the orchestrator's bound project;
  # the goal defaults to the active ledger goal when omitted. Fail-soft via Reflections.record/1.
  @spec record_reflection(Ecto.UUID.t(), map()) :: result()
  defp record_reflection(orchestrator_id, args) do
    with {:ok, lesson} <- fetch_string(args, "lesson") do
      case Reflections.record(%{
             lesson: lesson,
             goal: blank_to_nil(args["goal"]) || current_goal(orchestrator_id),
             orchestrator_id: orchestrator_id,
             project_id: orchestrator_project_id(orchestrator_id)
           }) do
        {:ok, reflection} ->
          {:ok, %{"status" => "recorded", "reflection_id" => reflection.id}}

        :error ->
          {:error, :reflection_not_recorded}
      end
    end
  end

  # Inference-only spec — the concrete string-keyed map narrows below a `map()` range.
  defp ledger_tool_map(view) do
    %{
      "goal" => view.goal,
      "definition_of_done" => view.definition_of_done,
      "status" => to_string(view.status),
      "stall_count" => view.stall_count,
      "plan" => view.plan,
      "focus" => view.focus,
      "focus_set_at" => view.focus_set_at,
      "progress" => progress_tool_map(view.progress)
    }
  end

  # Inference-only spec — the concrete string-keyed map narrows below a hand-written
  # `map() | nil`, which Dialyzer rejects as a contract supertype (mirrors provider_config/1).
  defp progress_tool_map(nil), do: nil

  defp progress_tool_map(progress) do
    %{
      "satisfied" => progress.satisfied,
      "on_track" => progress.on_track,
      "looping" => progress.looping,
      "made_progress" => progress.made_progress,
      "next_agent" => progress.next_agent,
      "next_instruction" => progress.next_instruction,
      "summary" => progress.summary
    }
  end

  @spec notify_complete(Ecto.UUID.t(), String.t() | nil, String.t() | nil) :: :ok
  defp notify_complete(orchestrator_id, summary, recommendations) do
    message = "orchestrator reported goal complete" <> if(summary, do: ": #{summary}", else: "")

    _ =
      Logs.create_system_log(%{
        level: :info,
        message: message,
        metadata: %{
          "orchestrator_id" => orchestrator_id,
          "action" => "report_complete",
          "recommendations" => recommendations
        }
      })

    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  # The orchestrator's working_dir, validated to exist (inspect_repo needs a real tree).
  @spec resolve_working_dir(Ecto.UUID.t()) :: {:ok, String.t()} | {:error, reason()}
  defp resolve_working_dir(orchestrator_id) do
    case Orchestrators.fetch(orchestrator_id) do
      {:ok, %{working_dir: dir}} when is_binary(dir) and dir != "" ->
        if File.dir?(dir), do: {:ok, dir}, else: {:error, :working_dir_missing}

      {:ok, _orchestrator} ->
        {:error, :no_working_dir}

      {:error, :not_found} ->
        {:error, :orchestrator_not_found}
    end
  end

  # Front-end SURFACE detection (iterative-ui-ux polish phase): classify the built repo's
  # user-facing surface(s) so the brain can decide whether to append a `:ui_ux` phase. An
  # empty list ⇒ no front end ⇒ skip UI/UX. Never raises (SurfaceDetector is fail-soft).
  @spec detect_surfaces(String.t()) :: result()
  defp detect_surfaces(dir) do
    {:ok, surfaces} = SurfaceDetector.detect(dir)
    {:ok, %{"op" => "surfaces", "surfaces" => Enum.map(surfaces, &to_string/1)}}
  end

  @spec git_status(String.t()) :: result()
  defp git_status(dir) do
    case run_git(dir, ["status", "--short", "--branch"]) do
      {:ok, output} -> {:ok, %{"op" => "git_status", "output" => cap_text(output)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec changed_files(String.t()) :: result()
  defp changed_files(dir) do
    case run_git(dir, ["status", "--porcelain"]) do
      {:ok, output} ->
        files =
          output
          |> String.split("\n", trim: true)
          |> Enum.take(@inspect_files_cap)
          |> Enum.map(&parse_porcelain/1)

        {:ok, %{"op" => "changed_files", "files" => files, "count" => length(files)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec parse_porcelain(String.t()) :: %{String.t() => String.t()}
  defp parse_porcelain(line) do
    %{
      "status" => line |> String.slice(0, 2) |> String.trim(),
      "path" => line |> String.slice(3..-1//1) |> to_string() |> String.trim()
    }
  end

  # Read a file STRICTLY under `dir` (path-jailed): reject any path that escapes the working
  # dir or descends into `.git`, cap the returned content, and refuse non-regular files.
  @spec read_file_jailed(String.t(), term()) :: result()
  defp read_file_jailed(_dir, path) when not is_binary(path) or path == "",
    do: {:error, "missing required argument: path"}

  defp read_file_jailed(dir, path) do
    base = Path.expand(dir)
    target = Path.expand(path, base)
    rel = Path.relative_to(target, base)

    cond do
      not jailed?(target, base) -> {:error, :path_outside_working_dir}
      ".git" in Path.split(rel) -> {:error, :path_forbidden}
      not File.regular?(target) -> {:error, :not_a_file}
      true -> read_capped(path, target)
    end
  end

  @spec jailed?(String.t(), String.t()) :: boolean()
  defp jailed?(target, base), do: target == base or String.starts_with?(target, base <> "/")

  @spec read_capped(String.t(), String.t()) :: result()
  defp read_capped(path, target) do
    case File.read(target) do
      {:ok, content} ->
        {:ok,
         %{
           "op" => "read_file",
           "path" => path,
           "content" => cap_text(content),
           "truncated" => byte_size(content) > @inspect_read_cap
         }}

      {:error, reason} ->
        {:error, to_string(reason)}
    end
  end

  # Run a git subcommand in `dir`, returning trimmed stdout or a normalized error string.
  # Never raises (a missing git / bad dir is surfaced as an error, not a tool crash).
  @spec run_git(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  defp run_git(dir, args) do
    case System.cmd("git", args, cd: dir, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _status} -> {:error, output |> String.trim() |> cap_text()}
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    _kind, reason -> {:error, inspect(reason)}
  end

  @spec cap_text(String.t()) :: String.t()
  defp cap_text(text) when is_binary(text), do: String.slice(text, 0, @inspect_read_cap)

  @spec list_agents(Ecto.UUID.t()) :: result()
  defp list_agents(orchestrator_id) do
    workers =
      orchestrator_id
      |> Agents.list_for_orchestrator()
      |> Enum.map(
        &%{
          "id" => &1.id,
          "name" => &1.name,
          "harness" => &1.harness,
          "status" => to_string(&1.status),
          "model" => &1.model
        }
      )

    {:ok, %{"agents" => workers, "count" => length(workers)}}
  end

  # The external APIs in scope for this orchestrator (platform + project)
  # (issue-external-api-mcp-provisioning). Name-only auth exposure: the `secret_name` is
  # surfaced (so the brain knows a credential is referenced) but never any token value.
  @spec list_apis(Ecto.UUID.t()) :: result()
  defp list_apis(orchestrator_id) do
    apis =
      orchestrator_id
      |> orchestrator_project_id()
      |> ExternalApis.list_in_scope_for()
      |> Enum.map(&api_summary/1)

    {:ok, %{"apis" => apis, "count" => length(apis)}}
  end

  @spec api_summary(ExternalApis.ExternalApi.t()) :: map()
  defp api_summary(api) do
    %{
      "name" => api.name,
      "provider" => api.provider,
      "scope" => if(is_nil(api.project_id), do: "platform", else: "project"),
      "transport" => to_string(api.transport),
      "auth_scheme" => to_string(api.auth_scheme),
      "secret_name" => api.secret_name,
      "description" => api.description,
      "instructions" => api.instructions,
      "doc_urls" => api.doc_urls,
      "allowed_tools" => api.allowed_tools
    }
  end

  @spec check_agent_status(Ecto.UUID.t(), map()) :: result()
  defp check_agent_status(orchestrator_id, args) do
    with {:ok, name} <- fetch_string(args, "name"),
         {:ok, worker} <- Agents.get_by_name_for_orchestrator(orchestrator_id, name) do
      limit = positive_int(args["limit"], 20)
      logs = Logs.list_recent(worker.id, limit)
      tail = Enum.map(logs, &log_summary/1)
      full = worker_final_message_with_log(logs)
      final_message = full |> full_message_text() |> truncate_or_nil()
      cost = worker.id |> Logs.cost_rollup!() |> Decimal.to_string()

      {:ok,
       %{
         "id" => worker.id,
         "name" => worker.name,
         "status" => to_string(worker.status),
         "cost_usd" => cost,
         "final_message" => final_message,
         "recent_events" => tail,
         "report_file" => maybe_spill_report(orchestrator_id, worker, full)
       }}
    end
  end

  # Budget breaker (issue-budget-guardrails): before spending on a worker turn, consult
  # the breaker for the orchestrator's scopes. A tripped `:pause`/`:hard_stop` cap yields
  # a typed `budget_exceeded` TOOL RESULT (`{:ok, map}`) — so the orchestrator agent sees
  # "budget exceeded, cannot spawn worker" rather than the platform silently spending —
  # which short-circuits the caller's `with` chain. `:ok` proceeds unchanged.
  # Inference-only spec — the concrete tool-result map narrows below `{:ok, map()}`.
  defp check_budget(orchestrator_id) do
    case Budget.Guard.check(Scope.scopes_for(%{orchestrator_id: orchestrator_id})) do
      :ok ->
        :ok

      {:error, {:budget_exceeded, cap}} ->
        {:ok,
         %{
           "status" => "budget_exceeded",
           "scope" => to_string(cap.scope),
           "limit_usd" => Decimal.to_string(cap.limit_usd),
           "message" =>
             "budget exceeded for #{cap.scope} cap (limit $#{Decimal.to_string(cap.limit_usd)}); cannot spawn or drive a worker until the cap is reset or raised"
         }}
    end
  end

  # Circuit breaker (self-healing Phase 4): if this worker's harness/model path has tripped
  # (repeated failures), fail FAST so the leader reroutes to another roster tier instead of
  # burning budget on a broken path. A surfaced `{:ok, map}` short-circuits the `with` chain
  # with a brain-readable "circuit open" result (not a silent spawn); `:ok` proceeds.
  # Inference-only spec — the concrete tool-result map narrows below `{:ok, map()}`.
  defp check_breaker(worker) do
    case Breaker.ask(Breaker.key(worker.harness, worker.model)) do
      :ok ->
        :ok

      {:error, :open} ->
        {:ok,
         %{
           "status" => "circuit_open",
           "harness" => worker.harness,
           "model" => worker.model,
           "message" =>
             "circuit breaker open for #{Breaker.key(worker.harness, worker.model)} after repeated failures; reroute to another tier/model or wait for the cooldown"
         }}
    end
  end

  @spec interrupt_agent(Ecto.UUID.t(), map()) :: result()
  defp interrupt_agent(orchestrator_id, args) do
    with {:ok, name} <- fetch_string(args, "name"),
         {:ok, worker} <- Agents.get_by_name_for_orchestrator(orchestrator_id, name) do
      :ok = Session.Supervisor.interrupt(worker.id)
      {:ok, %{"status" => "interrupted", "name" => worker.name}}
    end
  end

  @spec start_adw(Ecto.UUID.t(), map()) :: result()
  defp start_adw(orchestrator_id, args) do
    with {:ok, input} <- fetch_string(args, "input"),
         {:ok, harness} <- resolve_harness(orchestrator_id, args) do
      if harness == @adw_harness do
        start_adw_via_adapter(orchestrator_id, harness, input, args)
      else
        start_adw_via_engine(orchestrator_id, harness, input, args)
      end
    end
  end

  # The in-app WorkflowEngine path (Fake-harness-testable fallback): validate the type
  # against the catalog and run a deterministic linear workflow. The run records its
  # launching `orchestrator_id` so its terminal site can re-engage the holding pattern
  # (issue-fallback) — the same contract the adapter path already honours.
  @spec start_adw_via_engine(Ecto.UUID.t(), String.t(), String.t(), map()) :: result()
  defp start_adw_via_engine(orchestrator_id, harness, input, args) do
    with {:ok, type} <- resolve_workflow_type(args) do
      name = "orch-adw-#{System.unique_integer([:positive])}"

      with {:ok, workflow} <- WorkflowEngine.create_workflow_of_type(name, type, harness),
           {:ok, run_id, _pid} <-
             WorkflowEngine.start_workflow(workflow,
               inputs: %{"input" => input},
               orchestrator_id: orchestrator_id
             ) do
        # Fire-and-forget: a machine-looking name (e.g. "orch-adw-848273") gets a
        # Fast-tier human-friendly title; never blocks the launch.
        _ = TitleHumanizer.maybe_humanize_async(workflow, orchestrator_id)
        {:ok, %{"status" => "started", "run_id" => run_id, "workflow_type" => type}}
      else
        {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset_reason(changeset)}
        {:error, reason} -> {:error, normalize_reason(reason)}
      end
    end
  end

  # The real, portable shell-out path (issue-the-adw-gap): validate the requested type
  # against the discovered `adws/adw_*.py` set, model the run as a worker/agent row, and
  # spawn it through the ADW harness adapter + the generic §6 session runtime — so its
  # per-step events stream into the console and persist to `agent_logs` like any worker.
  # The returned `run_id` IS the worker/agent id; `check_adw` reads its canonical events.
  @spec start_adw_via_adapter(Ecto.UUID.t(), String.t(), String.t(), map()) :: result()
  defp start_adw_via_adapter(orchestrator_id, harness, input, args) do
    with {:ok, cwd} <- adw_working_dir(orchestrator_id, args),
         {:ok, adw} <- resolve_discovered_adw(orchestrator_id, cwd, args) do
      # Seed the resolved, token-filled command bodies into the target repo's
      # `.claude/commands/` BEFORE spawning (issue-adw-portable-commands), so the Python
      # pre-flight and the SDK both resolve `/plan`,`/build`,… on a foster repo that ships
      # none. Fail-soft: a miss falls through to the Python pre-flight's loud error.
      provision_adw_commands(orchestrator_id, cwd, adw)

      name = "orch-adw-#{System.unique_integer([:positive])}"
      adw_id = generate_adw_id()

      params = %{
        "name" => name,
        "harness" => harness,
        "model" => blank_to_nil(args["model"]),
        "config" =>
          %{
            "adw_type" => adw.name,
            "adw_script" => adw.path,
            "adw_id" => adw_id
          }
          # Optional interpreter override (advanced/testing): defaults to `uv run`.
          |> put_present("adw_runner", blank_to_nil(args["adw_runner"]))
      }

      case Agents.create_worker(orchestrator_id, params) do
        {:ok, worker} ->
          _ = Agents.set_session(worker.id, adw_id)
          spawn_adw_session(orchestrator_id, worker, input, adw, cwd)

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset_reason(changeset)}
      end
    end
  end

  # Resolve the directory the ADW worker runs in (its `opts.cwd`, and thus the adapter's
  # `--working-dir` and the SDK's `.claude/commands/` root). This is the only LLM-chosen
  # path, so it is GUARDED (orchestrator↔project binding): an explicit `working_dir` MUST
  # map to a REGISTERED project (`Projects.get_by_root_path/1`) — closing the wrong-repo
  # hole — and resolves to that project's canonical `root_path`. Absent, default to the
  # orchestrator's bound project working dir (same-repo back-compat).
  @spec adw_working_dir(Ecto.UUID.t(), map()) :: {:ok, String.t() | nil} | {:error, reason()}
  defp adw_working_dir(orchestrator_id, args) do
    case blank_to_nil(args["working_dir"]) do
      nil ->
        {:ok, orchestrator_working_dir(orchestrator_id)}

      dir ->
        case Projects.get_by_root_path(dir) do
          %Project{root_path: root} -> {:ok, root}
          nil -> {:error, adw_working_dir_error(dir)}
        end
    end
  end

  @spec adw_working_dir_error(String.t()) :: String.t()
  defp adw_working_dir_error(dir) do
    "working_dir #{dir} is not the bound project / a registered project; register it on " <>
      "the Projects page first, or omit working_dir to run the ADW against your own project"
  end

  # Provision the ADW's slash commands into the target repo's `.claude/commands/` so the
  # portable Python harness + SDK resolve them on a foster repo (issue-adw-portable-commands).
  # Recovers the `%Project{}` for `cwd` (the same lookup `adw_working_dir/2` validated; the
  # default binding falls back to the orchestrator's project) and seeds it. Never blocks the
  # launch — no project, an unresolved cwd, or `{:error, _}` all degrade to the Python
  # pre-flight backstop. Logs a concise note of what was seeded via the existing system log.
  @spec provision_adw_commands(Ecto.UUID.t(), String.t() | nil, Definitions.Adw.t()) :: :ok
  defp provision_adw_commands(orchestrator_id, cwd, adw) do
    case adw_target_project(orchestrator_id, cwd) do
      %Project{} = project ->
        result = Commands.provision_adw_commands(project, adw)
        log_provisioning(orchestrator_id, adw, result)

      nil ->
        :ok
    end

    :ok
  rescue
    _error -> :ok
  end

  # The registered `%Project{}` an ADW runs against: the project owning `cwd`, or — when
  # `cwd` came from the orchestrator's default binding — the orchestrator's bound project.
  @spec adw_target_project(Ecto.UUID.t(), String.t() | nil) :: Project.t() | nil
  defp adw_target_project(orchestrator_id, cwd) do
    with nil <- cwd && Projects.get_by_root_path(cwd),
         project_id when is_binary(project_id) <- orchestrator_project_id(orchestrator_id) do
      Projects.get_project(project_id)
    else
      %Project{} = project -> project
      _ -> nil
    end
  end

  @spec log_provisioning(
          Ecto.UUID.t(),
          Definitions.Adw.t(),
          {:ok, [String.t()]} | {:error, term()}
        ) ::
          :ok
  defp log_provisioning(orchestrator_id, adw, {:ok, names}) do
    _ =
      Logs.create_system_log(%{
        level: :info,
        message:
          "provisioned #{length(names)} ADW command(s) for #{adw.name}: #{Enum.join(names, ", ")}",
        metadata: %{
          "orchestrator_id" => orchestrator_id,
          "adw" => adw.name,
          "provisioned" => names
        }
      })

    :ok
  end

  defp log_provisioning(orchestrator_id, adw, {:error, reason}) do
    _ =
      Logs.create_system_log(%{
        level: :warn,
        message: "ADW command provisioning skipped for #{adw.name}: #{inspect(reason)}",
        metadata: %{"orchestrator_id" => orchestrator_id, "adw" => adw.name}
      })

    :ok
  end

  @spec spawn_adw_session(
          Ecto.UUID.t(),
          Agents.Agent.t(),
          String.t(),
          Definitions.Adw.t(),
          String.t() | nil
        ) ::
          result()
  defp spawn_adw_session(orchestrator_id, worker, input, adw, cwd) do
    # Restore attribution/scoping parity with `command_agent/3` (regression from de59371):
    # the adapter worker row carries `orchestrator_id` but no `project_id`, so resolve the
    # target project (owning `cwd`, else the orchestrator's bound project) to scope the
    # persisted `agent_logs` rows and light up the correct project's feed. Its
    # `isolation_mode` mirrors the worker-dispatch contract (nil ⇒ direct, back-compat).
    {project_id, isolation_mode} =
      case adw_target_project(orchestrator_id, cwd) do
        %Project{id: id, isolation_mode: mode} -> {id, mode}
        nil -> {nil, nil}
      end

    opts = [
      agent_id: worker.id,
      agent_db_id: worker.id,
      agent_name: worker.name,
      session_id: worker.session_id,
      harness: worker.harness,
      prompt: input,
      model: worker.model,
      orchestrator_id: orchestrator_id,
      project_id: project_id,
      provider: worker_provider(worker),
      config: worker.config,
      cwd: cwd,
      isolation_mode: isolation_mode
    ]

    case Session.Supervisor.start_session(opts) do
      {:ok, _pid} ->
        _ = Agents.set_status(worker.id, :running)

        {:ok,
         %{
           "status" => "started",
           "run_id" => worker.id,
           "workflow_type" => adw.name,
           "mode" => "adw"
         }}

      {:error, :at_capacity} ->
        {:error, :at_capacity}

      {:error, reason} ->
        {:error, normalize_reason(reason)}
    end
  end

  # Validate the requested `workflow_type` against the DISCOVERED ADW scripts (app root
  # + the orchestrator's working dir + the resolved target `cwd` overlay). A
  # missing/unknown type returns a helpful error listing the discovered slugs (never a
  # crash). The target `cwd` is scanned too so a cross-repo ADW living only in the
  # target repo's `adws/` is discoverable.
  @spec resolve_discovered_adw(Ecto.UUID.t(), String.t() | nil, map()) ::
          {:ok, Definitions.Adw.t()} | {:error, reason()}
  defp resolve_discovered_adw(orchestrator_id, cwd, args) do
    discovered = discovered_adws(orchestrator_id, cwd)

    case blank_to_nil(args["workflow_type"]) do
      nil ->
        {:error, "workflow_type is required for the adw harness; available: #{slugs(discovered)}"}

      type ->
        case Enum.find(discovered, &(&1.name == type)) do
          %Definitions.Adw{} = adw -> {:ok, adw}
          nil -> {:error, "unknown workflow_type #{type}; available: #{slugs(discovered)}"}
        end
    end
  end

  @spec discovered_adws(Ecto.UUID.t(), String.t() | nil) :: [Definitions.Adw.t()]
  defp discovered_adws(orchestrator_id, cwd) do
    app = Definitions.Adw.scan(File.cwd!(), :app)

    # Scan the orchestrator's working dir and the resolved target cwd (often the same;
    # de-duplicated by slug below). The target overlay makes a target-repo-only ADW
    # discoverable for cross-repo runs.
    dirs =
      [orchestrator_working_dir(orchestrator_id), cwd] |> Enum.reject(&is_nil/1) |> Enum.uniq()

    working = Enum.flat_map(dirs, &Definitions.Adw.scan(&1, :working_dir))

    (working ++ app) |> Enum.uniq_by(& &1.name) |> Enum.sort_by(& &1.name)
  end

  @spec slugs([Definitions.Adw.t()]) :: String.t()
  defp slugs([]), do: "(none discovered under adws/)"
  defp slugs(adws), do: Enum.map_join(adws, ", ", & &1.name)

  @spec generate_adw_id() :: String.t()
  defp generate_adw_id do
    "adw-" <> (12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
  end

  # Resolve + validate the optional `workflow_type` against the catalog; an omitted
  # type defaults to the catalog default (back-compat). An unknown type returns a
  # helpful error listing the available slugs (never a crash).
  @spec resolve_workflow_type(map()) :: {:ok, String.t()} | {:error, reason()}
  defp resolve_workflow_type(args) do
    case blank_to_nil(args["workflow_type"]) do
      nil ->
        {:ok, Catalog.default_type()}

      type ->
        case Catalog.fetch(type) do
          {:ok, _type_def} -> {:ok, type}
          {:error, :unknown_type} -> {:error, unknown_workflow_type(type)}
        end
    end
  end

  @spec unknown_workflow_type(String.t()) :: String.t()
  defp unknown_workflow_type(type) do
    slugs = Enum.map_join(Catalog.types(), ", ", & &1.slug)
    "unknown workflow_type #{type}; available: #{slugs}"
  end

  @spec update_agent(Ecto.UUID.t(), map()) :: result()
  defp update_agent(orchestrator_id, args) do
    with {:ok, name} <- fetch_string(args, "name"),
         {:ok, worker} <- Agents.get_by_name_for_orchestrator(orchestrator_id, name),
         {:ok, tools} <- resolve_tools(args),
         {:ok, params} <- worker_update_params(args, worker, tools) do
      case Agents.update_worker(worker, params) do
        {:ok, updated} ->
          {:ok,
           %{
             "id" => updated.id,
             "name" => updated.name,
             "harness" => updated.harness,
             "model" => updated.model,
             "status" => to_string(updated.status)
           }}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset_reason(changeset)}
      end
    end
  end

  @spec delete_agent(Ecto.UUID.t(), map()) :: result()
  defp delete_agent(orchestrator_id, args) do
    with {:ok, name} <- fetch_string(args, "name"),
         {:ok, worker} <- Agents.get_by_name_for_orchestrator(orchestrator_id, name) do
      # Reap any live session first so deleting the row leaves no orphaned child;
      # a worker with no live session returns `{:error, :not_found}`, ignored.
      _ = Session.Supervisor.stop_session(worker.id)

      case Agents.delete_agent(worker) do
        {:ok, _deleted} ->
          _ = Dashboard.broadcast_agent_deleted(worker)
          {:ok, %{"status" => "deleted", "id" => worker.id, "name" => worker.name}}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset_reason(changeset)}
      end
    end
  end

  @spec read_system_logs(map()) :: result()
  defp read_system_logs(args) do
    opts = [
      limit: positive_int(args["limit"], 50),
      offset: non_neg_int(args["offset"], 0),
      level: blank_to_nil(args["level"]),
      message_contains: blank_to_nil(args["message_contains"])
    ]

    logs = opts |> Logs.query_system_logs() |> Enum.map(&system_log_summary/1)
    {:ok, %{"logs" => logs, "count" => length(logs)}}
  end

  # Resolve a `log-<n>` reference (single / inclusive range / explicit array) to the
  # critical content of each matching `agent_logs` row (issue orchestrator-log-lookup-
  # tools). Distinct from `read_system_logs` (the separate system-log audit table) and
  # `check_agent_status` (a worker tail by name). Bounded to `@max_log_lookup` numbers so
  # a huge span can't overflow the tool result; numbers with no row are reported under
  # `missing`, never as an error.
  @spec get_logs(map()) :: result()
  defp get_logs(args) do
    if log_selector?(args) do
      requested = requested_numbers(args)
      capped? = length(requested) > @max_log_lookup
      numbers = Enum.take(requested, @max_log_lookup)
      include_hidden? = args["include_hidden"] == true

      details =
        numbers
        |> Logs.logs_by_numbers(include_hidden?: include_hidden?)
        |> Enum.map(&log_detail/1)

      found = MapSet.new(details, & &1["log_no"])
      missing = Enum.reject(numbers, &MapSet.member?(found, &1))

      {:ok,
       %{
         "logs" => details,
         "count" => length(details),
         "requested" => length(requested),
         "missing" => missing,
         "capped" => capped?
       }}
    else
      {:error, "provide one of: log, from+to, or numbers"}
    end
  end

  # True when the args carry ANY usable log selector — a `numbers` array (even empty/
  # all-unparseable, which yields no rows but is still a request), a parseable `from`/`to`
  # range bound, or a parseable single `log`. Separating selector-presence from the
  # resolved set lets an inverted range (`from > to`) return an empty result rather than
  # the no-selector error.
  @spec log_selector?(map()) :: boolean()
  defp log_selector?(args) do
    is_list(args["numbers"]) or
      not is_nil(parse_log_no(args["from"])) or
      not is_nil(parse_log_no(args["to"])) or
      not is_nil(parse_log_no(args["log"]))
  end

  # The concrete, deduped, ascending number set for a request, in precedence order:
  # `numbers` (array) → `from`+`to` (inclusive range) → `log` (single). Unparseable
  # entries are dropped; an inverted range yields `[]`.
  @spec requested_numbers(map()) :: [integer()]
  defp requested_numbers(args) do
    cond do
      is_list(args["numbers"]) ->
        args["numbers"] |> Enum.map(&parse_log_no/1) |> normalize_numbers()

      is_integer(parse_log_no(args["from"])) and is_integer(parse_log_no(args["to"])) ->
        args["from"]
        |> parse_log_no()
        |> range_list(parse_log_no(args["to"]))
        |> normalize_numbers()

      is_integer(parse_log_no(args["log"])) ->
        [parse_log_no(args["log"])]

      true ->
        []
    end
  end

  @spec range_list(integer(), integer()) :: [integer()]
  defp range_list(from, to) when from <= to, do: Enum.to_list(from..to)
  defp range_list(_from, _to), do: []

  @spec normalize_numbers([integer() | nil]) :: [integer()]
  defp normalize_numbers(numbers) do
    numbers |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()
  end

  # Parse one log reference into its integer `log_no`: a bare integer, an integer-as-
  # string, or a `"log-<n>"` string (case-insensitive, trimmed). Anything else → nil
  # (dropped). Mirrors `blank_to_nil/1`'s tolerant-input posture.
  @spec parse_log_no(term()) :: integer() | nil
  defp parse_log_no(n) when is_integer(n), do: n

  defp parse_log_no(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() |> String.replace_prefix("log-", "") do
      "" ->
        nil

      digits ->
        case Integer.parse(digits) do
          {n, ""} -> n
          _ -> nil
        end
    end
  end

  defp parse_log_no(_value), do: nil

  # Compact critical-info summary of one persisted log for `get_logs`: label, owner,
  # type, harness identity, a capped text excerpt (content-bearing events only),
  # token/cost usage (when present), and timestamp. Reuses the `check_agent_status`
  # excerpt + truncation helpers so the stdout-overflow bound is shared.
  #
  # Inference-only spec — the concrete string-keyed map narrows below a hand-written
  # `map()` (mirrors `maybe_put_log_text/2` / `maybe_put_log_usage/2`).
  defp log_detail(log) do
    %{
      "log" => Logs.log_label(log.log_no),
      "log_no" => log.log_no,
      "owner" => owner_label(log),
      "session_id" => log.session_id,
      "event_type" => to_string(log.event_type),
      "harness" => log.harness,
      "provider" => log.provider,
      "model" => log.model,
      "at" => to_iso(log.inserted_at)
    }
    |> maybe_put_log_text(log)
    |> maybe_put_log_usage(log)
  end

  @spec owner_label(Logs.AgentLog.t()) :: String.t() | nil
  defp owner_label(%{agent_id: id}) when is_binary(id), do: "worker:#{id}"
  defp owner_label(%{orchestrator_id: id}) when is_binary(id), do: "orchestrator:#{id}"
  defp owner_label(_log), do: nil

  # Inference-only spec — the concrete map (optionally with a "text" key) narrows below
  # a hand-written `map()` (mirrors `log_summary/1`).
  defp maybe_put_log_text(detail, log) do
    case log_summary_text(log) do
      nil -> detail
      text -> Map.put(detail, "text", truncate_text(text, @worker_text_cap))
    end
  end

  # Inference-only spec — usage-less rows omit the key entirely; an unpriced row keeps
  # `cost_usd` nil (the nil-vs-0 distinction). The concrete map narrows below `map()`.
  defp maybe_put_log_usage(detail, %{usage: %Logs.Usage{} = usage}) do
    Map.put(detail, "usage", %{
      "input_tokens" => usage.input_tokens,
      "output_tokens" => usage.output_tokens,
      "cache_read" => usage.cache_read,
      "cache_creation" => usage.cache_creation,
      "cost_usd" => decimal_to_string(usage.cost_usd)
    })
  end

  defp maybe_put_log_usage(detail, _log), do: detail

  @spec check_adw(map()) :: result()
  defp check_adw(args) do
    with {:ok, raw} <- fetch_string(args, "run_id"),
         {:ok, run_id} <- ensure_uuid(raw) do
      case Workflows.get_run(run_id) do
        # A WorkflowEngine run (the catalog/Fake path) — the rich per-step summary.
        %{} = run -> {:ok, run_summary(run)}
        # Else it may be an `adw`-harness worker run (the shell-out path): read its
        # per-step status/cost from the now-canonical persisted events.
        nil -> check_adw_agent(run_id)
      end
    end
  end

  # Summarize a shell-out ADW run modeled as a worker/agent row: its status, USD cost
  # rollup, the per-step status list reconstructed from the persisted step markers, and
  # a recent activity tail — all from canonical `agent_logs` (no second system of record).
  # Inference-only spec — the fully-concrete summary map narrows below the hand-written
  # `result()` contract, which Dialyzer rejects as a supertype (mirrors `run_summary/1`).
  defp check_adw_agent(agent_id) do
    case Agents.get_agent(agent_id) do
      nil ->
        {:error, :not_found}

      agent ->
        events = Logs.list_recent(agent.id, 500)
        steps = adw_step_progress(events)

        {:ok,
         %{
           "run_id" => agent.id,
           "mode" => "adw",
           "workflow_type" => agent.config["adw_type"],
           "status" => to_string(agent.status),
           "cost_usd" => decimal_to_string(nilify_zero(Logs.cost_rollup!(agent.id))),
           "steps" => steps,
           "progress" => %{
             "completed" => Enum.count(steps, &(&1["status"] in ["succeeded", "failed"])),
             "total" => length(steps)
           },
           "tail" => events |> Enum.take(-20) |> Enum.map(&log_summary/1)
         }}
    end
  end

  # Reconstruct per-step status from the persisted ADW step markers. `step_start`
  # normalizes to a `tool_call` whose payload carries the slug; `step_end` to a
  # `tool_result` whose payload carries the final status/cost. `list_recent/2` is
  # chronological (oldest first), so a later `step_end` overwrites the earlier
  # `step_start` "running" — leaving each step's final status. First-seen order kept.
  @spec adw_step_progress([Logs.AgentLog.t()]) :: [map()]
  defp adw_step_progress(events) do
    events
    |> Enum.reduce({%{}, []}, &fold_step_marker/2)
    |> then(fn {acc, order} -> Enum.map(order, &Map.put(acc[&1], "name", &1)) end)
  end

  # Fold one log into the {by_slug, order} accumulator: merge a step marker's fields
  # (later step_end status overwriting the earlier step_start "running"), tracking
  # first-seen order; a non-step log passes through unchanged.
  @spec fold_step_marker(Logs.AgentLog.t(), {map(), [String.t()]}) :: {map(), [String.t()]}
  defp fold_step_marker(log, {acc, order}) do
    case adw_step_marker(log) do
      nil ->
        {acc, order}

      {slug, fields} ->
        order = if Map.has_key?(acc, slug), do: order, else: order ++ [slug]
        {Map.update(acc, slug, fields, &Map.merge(&1, fields)), order}
    end
  end

  # Pull the {slug, fields} a step log contributes, or nil for non-step events. Reads
  # the persisted (scrubbed) neutral frame in `payload`.
  @spec adw_step_marker(Logs.AgentLog.t()) :: {String.t(), map()} | nil
  defp adw_step_marker(%{event_type: :tool_call, payload: %{"type" => "step_start"} = p}) do
    case adw_slug(p) do
      nil -> nil
      slug -> {slug, %{"status" => "running"}}
    end
  end

  defp adw_step_marker(%{event_type: :tool_result, payload: %{"type" => "step_end"} = p}) do
    case adw_slug(p) do
      nil ->
        nil

      slug ->
        {slug, %{"status" => to_string(p["status"] || "succeeded"), "cost_usd" => p["cost_usd"]}}
    end
  end

  defp adw_step_marker(_log), do: nil

  @spec adw_slug(map()) :: String.t() | nil
  defp adw_slug(payload) do
    case payload["adw_step"] || payload["step"] do
      slug when is_binary(slug) and slug != "" -> slug
      _ -> nil
    end
  end

  # cost_rollup! returns Decimal-0 for a run with no priced events; keep that as nil
  # (unpriced) rather than "0" so the orchestrator sees "—", mirroring the console rail.
  @spec nilify_zero(Decimal.t()) :: Decimal.t() | nil
  defp nilify_zero(%Decimal{} = d), do: if(Decimal.equal?(d, 0), do: nil, else: d)

  # --- self-configuration tools ---

  # Inference-only spec — the fully-concrete snapshot map narrows below the
  # hand-written `result()` contract, which Dialyzer rejects as a supertype under
  # :underspecs (mirrors `provider_config/1`).
  defp get_config(orchestrator_id) do
    with {:ok, orch} <- fetch_orchestrator(orchestrator_id) do
      tiers =
        Map.new(Orchestrators.agent_categories(), fn category ->
          {category, tier_view(category, orch)}
        end)

      {:ok,
       %{
         "orchestrator" => %{
           "harness" => orch.harness,
           "provider" => orch.provider,
           "model" => orch.model
         },
         "tiers" => tiers,
         "harnesses" => Registry.known(),
         "available_models" => available_models(orch.harness)
       }}
    end
  end

  @spec configure_tier(Ecto.UUID.t(), map()) :: result()
  defp configure_tier(orchestrator_id, args) do
    with {:ok, category} <- fetch_string(args, "category"),
         {:ok, selected} <- fetch_string(args, "model"),
         {:ok, harness} <- resolve_harness(orchestrator_id, args) do
      provider = blank_to_nil(args["provider"])
      # Resolve to the latest of the family before persisting, and echo the resolved
      # model so the orchestrator sees what was actually stored on the roster.
      model = ModelResolver.latest(harness, provider, selected)
      attrs = %{"harness" => harness, "provider" => provider, "model" => model}

      case Orchestrators.set_agent_model(orchestrator_id, category, attrs) do
        {:ok, _orch} ->
          {:ok,
           %{
             "status" => "configured",
             "category" => category,
             "harness" => harness,
             "provider" => provider,
             "model" => model
           }}

        {:error, :invalid_category} ->
          {:error, "invalid category: #{category}"}

        {:error, :not_found} ->
          {:error, :orchestrator_not_found}
      end
    end
  end

  @spec set_orchestrator_config(Ecto.UUID.t(), map()) :: result()
  defp set_orchestrator_config(orchestrator_id, args) do
    harness = blank_to_nil(args["harness"])
    provider = blank_to_nil(args["provider"])
    model = blank_to_nil(args["model"])

    if is_nil(harness) and is_nil(provider) and is_nil(model) do
      {:error, "no config fields provided"}
    else
      # Apply in a fixed, safe order — harness first (it resets provider/model to the
      # harness defaults), then provider (resets model), then model last.
      with {:ok, _} <- apply_harness(orchestrator_id, harness),
           {:ok, _} <- apply_provider(orchestrator_id, provider),
           {:ok, _} <- apply_model(orchestrator_id, model),
           {:ok, orch} <- fetch_orchestrator(orchestrator_id) do
        {:ok, %{"harness" => orch.harness, "provider" => orch.provider, "model" => orch.model}}
      end
    end
  end

  # --- cost / context-window tools ---

  # Inference-only spec — the fully-concrete report map narrows below the hand-written
  # `result()` contract, which Dialyzer rejects as a supertype under :underspecs
  # (mirrors `get_config/1`).
  defp report_cost(orchestrator_id) do
    with {:ok, orch} <- fetch_orchestrator(orchestrator_id) do
      harness = orch.harness || ""
      totals = Orchestrators.token_totals(orch)
      fraction = ContextWindow.usage_fraction(totals.context, harness, orch.model)

      report = %{
        "session_id" => orch.session_id,
        "status" => to_string(orch.status),
        "cost_usd" => Decimal.to_string(orch.total_cost_usd),
        "input_tokens" => totals.input,
        "output_tokens" => totals.output,
        "total_tokens" => totals.total,
        "context_tokens" => totals.context,
        "context_window" => ContextWindow.size(harness, orch.model),
        "context_usage_pct" => Float.round(fraction * 100, 1)
      }

      {:ok, maybe_warn(report, fraction)}
    end
  end

  # Inference-only spec (mirrors `report_cost/1`): the concrete report map narrows
  # below a hand-written `map()` return under :underspecs. The high-usage threshold is
  # the SHARED `Handover.threshold/0`, so the warning and the worker wind-down agree.
  defp maybe_warn(report, fraction) do
    if Handover.over_threshold?(fraction) do
      Map.put(
        report,
        "warning",
        "context usage at #{Float.round(fraction * 100, 1)}% — compact workers nearing their limit or suggest the operator run /compact"
      )
    else
      report
    end
  end

  # Thin sugar over `command_agent`: resolve the worker by name and dispatch the
  # `/compact` slash command (both Claude and pi honor it). Reuses the command path,
  # so an unknown worker returns its `{:error, ...}` unchanged.
  @spec compact_agent(Ecto.UUID.t(), map()) :: result()
  defp compact_agent(orchestrator_id, args) do
    with {:ok, name} <- fetch_string(args, "name") do
      command_agent(orchestrator_id, %{"name" => name, "prompt" => "/compact"})
    end
  end

  # Fully reset a worker's context window (issue clear-context). Unlike `compact_agent`
  # (which keeps a summary in-window), this reaps any live session and NULLS the
  # worker's resumable `session_id`, so the next `command_agent` mints a fresh harness
  # session with zero prior history. Worker scoping makes a cross-tenant clear impossible.
  @spec clear_context(Ecto.UUID.t(), map()) :: result()
  defp clear_context(orchestrator_id, args) do
    with {:ok, name} <- fetch_string(args, "name"),
         {:ok, worker} <- Agents.get_by_name_for_orchestrator(orchestrator_id, name) do
      # Reap any live session first so the reset leaves no orphaned child; a worker
      # with no live session returns `{:error, :not_found}`, ignored.
      _ = Session.Supervisor.stop_session(worker.id)
      # Null the resumable session so the next command_agent takes the fresh-session branch.
      _ = Agents.set_session(worker.id, nil)

      case Agents.set_status(worker.id, :idle) do
        {:ok, idle} ->
          _ = Dashboard.broadcast_agent_updated(idle)
          {:ok, %{"status" => "cleared", "id" => worker.id, "name" => worker.name}}

        {:error, reason} ->
          {:error, normalize_reason(reason)}
      end
    end
  end

  # --- subagent-template tools ---

  @spec list_agent_templates() :: result()
  defp list_agent_templates do
    templates =
      Enum.map(Templates.list(), fn template ->
        %{
          "name" => template.name,
          "description" => template.description,
          "version" => template.version
        }
      end)

    {:ok, %{"templates" => templates, "count" => length(templates)}}
  end

  @spec get_agent_template(map()) :: result()
  defp get_agent_template(args) do
    with {:ok, name} <- fetch_string(args, "name") do
      case Templates.fetch(name) do
        {:ok, template} -> {:ok, template_view(template)}
        {:error, :not_found} -> {:error, template_not_found(name)}
        {:error, reason} -> {:error, normalize_reason(reason)}
      end
    end
  end

  @spec save_agent_template(map()) :: result()
  defp save_agent_template(args) do
    with {:ok, name} <- fetch_string(args, "name"),
         {:ok, description} <- fetch_string(args, "description"),
         {:ok, body} <- fetch_string(args, "system_prompt") do
      attrs = %{
        "name" => name,
        "description" => description,
        "body" => body,
        "model" => blank_to_nil(args["model"]),
        "category" => blank_to_nil(args["category"]),
        "author" => :orchestrator
      }

      case Templates.save(attrs) do
        {:ok, template} ->
          {:ok, %{"status" => "saved", "name" => template.name, "version" => template.version}}

        {:error, reason} ->
          {:error, normalize_reason(reason)}
      end
    end
  end

  @spec template_view(Template.t()) :: map()
  defp template_view(template) do
    %{
      "name" => template.name,
      "description" => template.description,
      "body" => template.body,
      "model" => template.model,
      "category" => template.category,
      "harness" => template.harness,
      "version" => template.version,
      "author" => Atom.to_string(template.author)
    }
  end

  @spec apply_harness(Ecto.UUID.t(), String.t() | nil) ::
          {:ok, Orchestrator.t() | :skip} | {:error, reason()}
  defp apply_harness(_orchestrator_id, nil), do: {:ok, :skip}

  defp apply_harness(orchestrator_id, harness) do
    if harness in Registry.known() do
      route_config(Orchestrators.set_harness(orchestrator_id, harness))
    else
      {:error, "not a registered harness: #{harness}"}
    end
  end

  @spec apply_provider(Ecto.UUID.t(), String.t() | nil) ::
          {:ok, Orchestrator.t() | :skip} | {:error, reason()}
  defp apply_provider(_orchestrator_id, nil), do: {:ok, :skip}

  defp apply_provider(orchestrator_id, provider),
    do: route_config(Orchestrators.set_provider(orchestrator_id, provider))

  @spec apply_model(Ecto.UUID.t(), String.t() | nil) ::
          {:ok, Orchestrator.t() | :skip} | {:error, reason()}
  defp apply_model(_orchestrator_id, nil), do: {:ok, :skip}

  defp apply_model(orchestrator_id, model),
    do: route_config(Orchestrators.set_model(orchestrator_id, model))

  @spec route_config({:ok, Orchestrator.t()} | {:error, :not_found}) ::
          {:ok, Orchestrator.t()} | {:error, reason()}
  defp route_config({:ok, orch}), do: {:ok, orch}
  defp route_config({:error, :not_found}), do: {:error, :orchestrator_not_found}

  # Map the context's `:not_found` to the tool-layer `:orchestrator_not_found` reason
  # (mirrors `resolve_harness/2`).
  @spec fetch_orchestrator(Ecto.UUID.t()) :: {:ok, Orchestrator.t()} | {:error, reason()}
  defp fetch_orchestrator(orchestrator_id) do
    case Orchestrators.fetch(orchestrator_id) do
      {:ok, orchestrator} -> {:ok, orchestrator}
      {:error, :not_found} -> {:error, :orchestrator_not_found}
    end
  end

  # The EFFECTIVE view of one worker tier: the per-project assignment when set, else the
  # inherited global default. `inherited?` is true when the model came from the default
  # (so the console/MCP caller can show an "inherited" indicator); `assigned` stays true
  # whenever a model resolves at all (project or default), since that is what `create_agent`
  # can spawn into.
  # Inference-only spec — the concrete tier map (with boolean `assigned`/`inherited?`)
  # narrows below a hand-written `map()` spec, which Dialyzer rejects as a supertype under
  # :underspecs (mirrors `provider_config/1`/`available_models/1`).
  defp tier_view(category, orchestrator) do
    {entry, source} = Orchestrators.effective_agent_model(orchestrator, category)
    entry = entry || %{}
    model = blank_to_nil(entry["model"])

    %{
      "harness" => entry["harness"],
      "provider" => entry["provider"],
      "model" => model,
      "assigned" => not is_nil(model),
      "inherited?" => not is_nil(model) and source == :default
    }
  end

  # The available models for the orchestrator's harness: merge the live pi catalog
  # (empty in test/when pi is absent) with the static registry lists per provider.
  # Fail-soft: an empty map is a valid answer.
  @spec available_models(String.t()) :: %{String.t() => %{String.t() => [String.t()]}}
  defp available_models(harness) do
    pi_catalog = PiModels.all()

    providers =
      pi_catalog |> Map.keys() |> Enum.concat(registry_providers(harness)) |> Enum.uniq()

    by_provider =
      Map.new(providers, fn provider ->
        models =
          (Map.get(pi_catalog, provider, []) ++ Registry.orchestrator_models(harness, provider))
          |> Enum.uniq()

        {provider, models}
      end)

    %{harness => by_provider}
  end

  @spec registry_providers(String.t()) :: [String.t()]
  defp registry_providers(harness) do
    harness
    |> Registry.orchestrator_defaults()
    |> Map.get(:models, %{})
    |> Map.keys()
  end

  # --- helpers ---

  @spec ensure_worker_model(Agents.Agent.t()) :: :ok | {:error, reason()}
  defp ensure_worker_model(%{model: model, name: name}) do
    if blank_to_nil(model), do: :ok, else: {:error, "no model selected for #{name}"}
  end

  @spec worker_provider(Agents.Agent.t()) :: String.t() | nil
  defp worker_provider(%{config: config}), do: blank_to_nil(config["provider"])

  # Persist `config["original_ask"]` on a worker's FIRST dispatch (no prior session and
  # none already recorded), so the handover protocol can restate the receipt. Quiet and
  # best-effort — never affects the dispatch result.
  @spec maybe_record_original_ask(Agents.Agent.t(), String.t()) :: :ok
  defp maybe_record_original_ask(%{session_id: nil, config: config} = worker, prompt) do
    case blank_to_nil(config["original_ask"]) do
      nil ->
        _ = Agents.merge_config(worker, %{"original_ask" => prompt})
        :ok

      _present ->
        :ok
    end
  end

  defp maybe_record_original_ask(_worker, _prompt), do: :ok

  @doc """
  The harness session config for an orchestrator-spawned worker: the worker's own
  persisted config plus the autonomous flag.

  Orchestrator workers run headless (no TTY to answer interactive permission
  prompts), so the session is autonomous — the Claude adapter then emits
  `--dangerously-skip-permissions`. The flag is the ATOM key `:autonomous` because
  the adapter's `autonomous?/1` matches atom keys, whereas `worker.config` is JSONB
  with string keys.
  """
  @spec worker_session_config(Agents.Agent.t()) :: map()
  def worker_session_config(%{config: config}), do: Map.put(config, :autonomous, true)

  # The orchestrator's configured working directory (the cwd its workers run in), or
  # nil when unset/unknown — in which case the worker gets an isolated workspace.
  @spec orchestrator_working_dir(Ecto.UUID.t()) :: String.t() | nil
  defp orchestrator_working_dir(orchestrator_id) do
    case Orchestrators.fetch(orchestrator_id) do
      {:ok, orchestrator} -> blank_to_nil(orchestrator.working_dir)
      {:error, :not_found} -> nil
    end
  end

  # The commanding orchestrator's bound project id (orchestrator↔project binding), or nil
  # for a platform orchestrator / unknown id. Stamped onto every worker it spawns.
  @spec orchestrator_project_id(Ecto.UUID.t()) :: Ecto.UUID.t() | nil
  defp orchestrator_project_id(orchestrator_id) do
    case Orchestrators.fetch(orchestrator_id) do
      {:ok, orchestrator} -> orchestrator.project_id
      {:error, :not_found} -> nil
    end
  end

  # Resolve `{cwd, isolation_mode}` for a worker dispatch from the worker's OWN project
  # (stable, drift-proof). An unscoped worker — or one whose project no longer exists —
  # falls back to the orchestrator's working dir with no isolation (back-compat).
  @spec worker_dispatch_location(Agents.Agent.t(), Ecto.UUID.t()) ::
          {String.t() | nil, Project.isolation_mode() | nil}
  defp worker_dispatch_location(%{project_id: project_id}, orchestrator_id)
       when is_binary(project_id) do
    case Projects.get_project(project_id) do
      %Project{root_path: root, isolation_mode: mode} -> {root, mode}
      nil -> {orchestrator_working_dir(orchestrator_id), nil}
    end
  end

  defp worker_dispatch_location(_worker, orchestrator_id) do
    {orchestrator_working_dir(orchestrator_id), nil}
  end

  @spec resolve_harness(Ecto.UUID.t(), map()) :: {:ok, String.t()} | {:error, reason()}
  defp resolve_harness(orchestrator_id, args) do
    case blank_to_nil(args["harness"]) do
      nil ->
        case Orchestrators.fetch(orchestrator_id) do
          {:ok, orchestrator} -> {:ok, orchestrator.harness}
          {:error, :not_found} -> {:error, :orchestrator_not_found}
        end

      harness ->
        {:ok, harness}
    end
  end

  @spec fetch_string(map(), String.t()) :: {:ok, String.t()} | {:error, reason()}
  defp fetch_string(args, key) do
    case args[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "missing required argument: #{key}"}
    end
  end

  # Append the standard reporting clause to a worker's system prompt (issue-2541).
  # Uses the clause alone when the orchestrator passes no prompt.
  # Fold the project's stack contract (stack-layers subsystem) onto the front of a
  # worker's charter so the language/stack guardrail leads. An empty contract (platform
  # orchestrator or a project with no selected layers) returns the prompt unchanged.
  @spec prepend_stack_contract(String.t() | nil, Ecto.UUID.t() | nil) :: String.t() | nil
  defp prepend_stack_contract(prompt, project_id) do
    case StackLayers.Contract.render(project_id) do
      "" -> prompt
      contract when is_binary(prompt) -> contract <> "\n\n" <> prompt
      contract -> contract
    end
  end

  @spec with_reporting_clause(String.t() | nil) :: String.t()
  defp with_reporting_clause(nil), do: String.trim(worker_reporting_clause())

  defp with_reporting_clause(prompt),
    do: prompt <> "\n\n" <> String.trim(worker_reporting_clause())

  # Standard reporting clause appended to every spawned worker's system prompt
  # (issue-2541, overflow path added in this fix). The orchestrator can only read a
  # worker's findings via `check_agent_status`'s `final_message` field — i.e. the
  # worker's final turn — and that field is hard-capped at `@worker_text_cap` chars, so a
  # worker that inlines a long report has its tail silently amputated and there is no
  # second channel to recover it. The clause therefore (a) tells the worker the surfaced
  # window is finite, (b) keeps the final message a concise self-contained summary, and
  # (c) gives an explicit overflow path: write the full result to an `ai_docs/` markdown
  # file in the shared working directory and cite that relative path. `@worker_text_cap`
  # is interpolated so the documented limit can never drift from the enforced one.
  @spec worker_reporting_clause() :: String.t()
  defp worker_reporting_clause do
    """
    ## Reporting results
    Only your FINAL message is surfaced to the coordinator that dispatched you — it is
    read back via the orchestrator's `check_agent_status` tool, which truncates it to the
    first ~#{@worker_text_cap} characters. Keep that final message a concise,
    self-contained summary of your results (what you did, what you found, any
    conclusions). Do not bury the outcome mid-transcript; restate it at the end.

    If your full result would exceed that ~#{@worker_text_cap}-character budget (e.g. a
    multi-section report or detailed analysis), write the complete content to a markdown
    file at `ai_docs/<descriptive-name>.md` inside the working directory and reference
    that relative path (e.g. `ai_docs/elixir-port-report.md`) in your final summary so the
    coordinator can open and read it in full.

    #{Handover.protocol_clause()}

    #{Holding.protocol_clause()}
    """
  end

  # The worker's most recent NON-thinking result text (issue-2541): prefer the latest
  # terminal `:done` payload (`"result"`/`"final_text"`, harness-defensive), else the
  # latest finalized `:text_delta` that is not thinking. `nil` when none exists.
  # Returns the worker's most recent NON-thinking result text together with the source log
  # it came from (the log gives an idempotent spill filename). `nil` when none exists.
  @spec worker_final_message_with_log([Logs.AgentLog.t()]) ::
          {String.t(), Logs.AgentLog.t()} | nil
  defp worker_final_message_with_log(logs) do
    logs
    |> Enum.reverse()
    |> Enum.find_value(fn log ->
      case result_text(log) do
        nil -> nil
        text -> {text, log}
      end
    end)
  end

  @spec full_message_text({String.t(), Logs.AgentLog.t()} | nil) :: String.t() | nil
  defp full_message_text({text, _log}), do: text
  defp full_message_text(nil), do: nil

  # Deterministic, platform-side overflow spill (issue worker-report-truncation): when the
  # worker's FULL final message exceeds `@worker_text_cap`, the surfaced `final_message` is
  # only a capped preview, so write the complete, untruncated text to a markdown file the
  # orchestrator can read and return its path as `report_file`. This removes all dependence
  # on the worker voluntarily writing an `ai_docs/` file (`worker_reporting_clause/0` stays
  # as cooperative guidance, but this is the guarantee). `nil` when no overflow occurred or
  # the write failed — the tool always still returns the preview.
  @spec maybe_spill_report(Ecto.UUID.t(), Agents.Agent.t(), {String.t(), Logs.AgentLog.t()} | nil) ::
          String.t() | nil
  defp maybe_spill_report(orchestrator_id, worker, {text, log}) do
    if String.length(text) > @worker_text_cap,
      do: spill_report(orchestrator_id, worker, text, log),
      else: nil
  end

  defp maybe_spill_report(_orchestrator_id, _worker, nil), do: nil

  # Write the worker's final message to `ai_docs/worker-reports/<worker-slug>-<log_no>.md`
  # under the orchestrator working dir (or platform root when none is set). The `text` comes
  # from the persisted canonical log payload (`result_text/1`), which is stored verbatim —
  # NOT through the 10 KB `Redact` blob cap (issue worker-report-truncation) — so the file
  # carries the worker's complete output, not the 2000-char `final_message` preview. Idempotent:
  # the filename is keyed on the source log, so repeated `check_agent_status` polls overwrite the
  # same path. Returns the path RELATIVE to the working dir when one is set (the orchestrator can
  # `Read ai_docs/worker-reports/...`), ABSOLUTE on the platform-root fallback. Never raises:
  # any write failure yields `nil` so the caller still returns the preview.
  @spec spill_report(Ecto.UUID.t(), Agents.Agent.t(), String.t(), Logs.AgentLog.t()) ::
          String.t() | nil
  defp spill_report(orchestrator_id, worker, text, log) do
    working_dir = orchestrator_working_dir(orchestrator_id)
    root = working_dir || File.cwd!()
    rel = Path.join("ai_docs/worker-reports", report_filename(worker, log))
    abs = Path.join(root, rel)

    with :ok <- File.mkdir_p(Path.dirname(abs)),
         :ok <- File.write(abs, report_body(worker, text)) do
      if working_dir, do: rel, else: abs
    else
      {:error, _reason} -> nil
    end
  end

  @spec report_filename(Agents.Agent.t(), Logs.AgentLog.t()) :: String.t()
  defp report_filename(worker, log) do
    slug =
      worker.name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    slug = if slug == "", do: "worker", else: slug
    "#{slug}-#{log.log_no || log.id}.md"
  end

  @spec report_body(Agents.Agent.t(), String.t()) :: String.t()
  defp report_body(worker, text) do
    "# Worker report: #{worker.name} (#{worker.status})\n\n#{text}\n"
  end

  @spec result_text(Logs.AgentLog.t()) :: String.t() | nil
  defp result_text(%{event_type: :done, payload: payload}) when is_map(payload),
    do: blank_to_nil(payload["result"]) || blank_to_nil(payload["final_text"])

  defp result_text(%{event_type: :text_delta, payload: payload}) when is_map(payload) do
    if payload["thinking"] == true, do: nil, else: blank_to_nil(payload["text"])
  end

  defp result_text(_log), do: nil

  # Codepoint-based so truncation never splits a multibyte UTF-8 char. Inference-only
  # spec (the lone `cap` caller passes the literal @worker_text_cap, narrowing below
  # `pos_integer()`).
  defp truncate_text(text, cap) do
    if String.length(text) <= cap,
      do: text,
      else: String.slice(text, 0, cap) <> truncation_marker(cap)
  end

  # Actionable truncation marker: when `final_message` overflows, the platform spills the
  # full text to a file and returns its path as `report_file` (issue worker-report-
  # truncation) — point the coordinator there rather than at a re-dispatch loop. Kept short
  # so it does not itself bloat the tool result. Inference-only spec (the lone caller passes
  # the literal @worker_text_cap), matching the neighboring `truncate_text/2` form.
  defp truncation_marker(cap),
    do:
      "… (truncated at #{cap} chars — read this result's `report_file` path for the full output, or ask the worker for an ai_docs/ file)"

  defp truncate_or_nil(nil), do: nil
  defp truncate_or_nil(text), do: truncate_text(text, @worker_text_cap)

  # Inference-only spec — the concrete summary map (optionally with a "text" key)
  # narrows below a hand-written `map()` (matches the original inference-only form).
  defp log_summary(log) do
    base = %{"event_type" => to_string(log.event_type), "at" => to_iso(log.inserted_at)}

    case log_summary_text(log) do
      nil -> base
      text -> Map.put(base, "text", truncate_text(text, @worker_text_cap))
    end
  end

  # Content-bearing events surface a text excerpt (issue-2541); others stay compact.
  @spec log_summary_text(Logs.AgentLog.t()) :: String.t() | nil
  defp log_summary_text(%{event_type: :text_delta, payload: payload}) when is_map(payload),
    do: blank_to_nil(payload["text"])

  defp log_summary_text(%{event_type: :done, payload: payload}) when is_map(payload),
    do: blank_to_nil(payload["result"]) || blank_to_nil(payload["final_text"])

  defp log_summary_text(%{event_type: :error, payload: payload}) when is_map(payload),
    do: blank_to_nil(payload["message"])

  defp log_summary_text(_log), do: nil

  @spec to_iso(DateTime.t() | nil) :: String.t() | nil
  defp to_iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp to_iso(_other), do: nil

  @spec changeset_reason(Ecto.Changeset.t()) :: String.t()
  defp changeset_reason(changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {k, v}, acc ->
          String.replace(acc, "%{#{k}}", to_string(v))
        end)
      end)

    case errors do
      %{name: [_ | _]} -> "duplicate or invalid name"
      _ -> "invalid agent: #{inspect(errors)}"
    end
  end

  @spec normalize_reason(term()) :: reason()
  defp normalize_reason(reason) when is_atom(reason) or is_binary(reason), do: reason
  defp normalize_reason(reason), do: inspect(reason)

  @spec blank_to_nil(term()) :: String.t() | nil
  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp blank_to_nil(_value), do: nil

  # Inference-only spec — the lone caller passes the literal default 20, which
  # dialyzer narrows below a hand-written `pos_integer()` second arg.
  defp positive_int(n, _default) when is_integer(n) and n > 0, do: n
  defp positive_int(_n, default), do: default

  # Inference-only spec (mirrors `positive_int/2`): callers pass a literal default,
  # which dialyzer narrows below a hand-written `non_neg_integer()` second arg.
  defp non_neg_int(n, _default) when is_integer(n) and n >= 0, do: n
  defp non_neg_int(_n, default), do: default

  # Collect only the present, non-blank updatable worker fields; an empty change
  # set is rejected so an `update_agent` with only `name` is a no-op error. A `tools`
  # grant change (issue firecrawl-grant) is merged into the worker's existing config
  # under `"tools"`, preserving its other keys (provider/template provenance).
  @spec worker_update_params(map(), Agents.Agent.t(), [String.t()] | nil) ::
          {:ok, %{optional(String.t()) => term()}} | {:error, reason()}
  defp worker_update_params(args, worker, tools) do
    params =
      %{}
      |> put_present("harness", blank_to_nil(args["harness"]))
      |> put_present("model", blank_to_nil(args["model"]))
      |> put_present("system_prompt", blank_to_nil(args["system_prompt"]))
      |> maybe_put_config_tools(worker, tools)

    if params == %{}, do: {:error, "no updatable fields provided"}, else: {:ok, params}
  end

  # `nil` ⇒ the caller passed no `tools` key, so leave config untouched. A list (even
  # the empty list, an explicit revoke) replaces only the `"tools"` key in the worker's
  # existing config so provider/template provenance is preserved.
  @spec maybe_put_config_tools(map(), Agents.Agent.t(), [String.t()] | nil) :: map()
  defp maybe_put_config_tools(params, _worker, nil), do: params

  defp maybe_put_config_tools(params, worker, tools),
    do: Map.put(params, "config", Map.put(worker.config, "tools", tools))

  # Validate an optional `tools` grant against the known research tools. Absent ⇒
  # `{:ok, nil}` (don't touch). Explicit `[]` ⇒ `{:ok, []}` (none / revoke). A
  # non-empty list keeps only the known names (deduped); an all-unknown list errors
  # with the known set. A non-list value is rejected.
  @spec resolve_tools(map()) :: {:ok, [String.t()] | nil} | {:error, reason()}
  defp resolve_tools(args) do
    case Map.get(args, "tools") do
      nil ->
        {:ok, nil}

      [] ->
        {:ok, []}

      list when is_list(list) ->
        known = McpTools.known()
        valid = list |> Enum.filter(&(is_binary(&1) and &1 in known)) |> Enum.uniq()

        if valid == [],
          do: {:error, "unknown tools #{inspect(list)}; available: #{Enum.join(known, ", ")}"},
          else: {:ok, valid}

      _other ->
        {:error, "tools must be an array of tool names"}
    end
  end

  # Fold a non-empty research-tool grant into a worker's config at create time; `nil`
  # or `[]` leaves the config untouched (no grant). Inference-only spec (mirrors
  # `agent_config/2`): the concrete map narrows below a hand-written `map()` spec.
  defp maybe_put_tools(config, tools) when is_list(tools) and tools != [],
    do: Map.put(config, "tools", tools)

  defp maybe_put_tools(config, _tools), do: config

  # Validate an optional `apis` provision against the orchestrator's in-scope registry
  # (issue-external-api-mcp-provisioning). Absent ⇒ `{:ok, []}` (no provision). A list of
  # known names ⇒ `{:ok, [ExternalApi.t()]}` (resolved rows, in request order). An unknown
  # name errors up front, listing the available names. A non-list value is rejected.
  @spec resolve_apis(Ecto.UUID.t() | nil, map()) ::
          {:ok, [ExternalApis.ExternalApi.t()]} | {:error, reason()}
  defp resolve_apis(project_id, args) do
    case Map.get(args, "apis") do
      nil ->
        {:ok, []}

      [] ->
        {:ok, []}

      list when is_list(list) ->
        in_scope = ExternalApis.list_in_scope_for(project_id)
        known = MapSet.new(in_scope, & &1.name)
        requested = list |> Enum.filter(&is_binary/1) |> Enum.uniq()

        case Enum.reject(requested, &MapSet.member?(known, &1)) do
          [] ->
            {:ok, ExternalApis.fetch_by_names(project_id, requested)}

          unknown ->
            available = Enum.map_join(in_scope, ", ", & &1.name)

            {:error,
             "unknown apis #{inspect(unknown)}; available: #{if available == "", do: "(none registered)", else: available}"}
        end

      _other ->
        {:error, "apis must be an array of registered API names"}
    end
  end

  # Fold a non-empty external-API provision into a worker's config as NAMES only (never
  # the secret). `[]` leaves the config untouched. Inference-only spec (mirrors
  # `maybe_put_tools/2`).
  defp maybe_put_apis(config, [_ | _] = apis),
    do: Map.put(config, "apis", Enum.map(apis, & &1.name))

  defp maybe_put_apis(config, _apis), do: config

  # Prepend the provisioned APIs' usage instructions/doc URLs to the worker charter so the
  # worker reads HOW to use each transferred API. `[]` ⇒ the prompt is untouched.
  @spec prepend_api_instructions(String.t() | nil, [ExternalApis.ExternalApi.t()]) ::
          String.t() | nil
  defp prepend_api_instructions(prompt, []), do: prompt

  defp prepend_api_instructions(prompt, apis) do
    case Provisioning.instructions(apis) do
      "" -> prompt
      fragment when is_binary(prompt) and prompt != "" -> fragment <> "\n\n" <> prompt
      fragment -> fragment
    end
  end

  # Inference-only spec — callers pass literal string keys, which dialyzer narrows
  # below a hand-written `String.t()` second arg (mirrors `positive_int/2`).
  defp put_present(params, _key, nil), do: params
  defp put_present(params, key, value), do: Map.put(params, key, value)

  @spec ensure_uuid(String.t()) :: {:ok, Ecto.UUID.t()} | {:error, reason()}
  defp ensure_uuid(raw) do
    case Ecto.UUID.cast(raw) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, "invalid run_id"}
    end
  end

  @spec system_log_summary(Logs.SystemLog.t()) :: map()
  defp system_log_summary(log) do
    %{
      "id" => log.id,
      "level" => to_string(log.level),
      "message" => log.message,
      "at" => to_iso(log.inserted_at)
    }
  end

  # Inference-only spec — the fully-concrete summary map narrows below a hand-written
  # `map()` contract, which Dialyzer rejects as a supertype under :underspecs.
  defp run_summary(run) do
    progress = Workflows.run_progress(run)

    %{
      "run_id" => run.id,
      "status" => to_string(run.status),
      "current_step" => run.current_step,
      # Preserve the unpriced (NULL) vs 0 distinction — nil stays nil, never "0".
      "cost_usd" => decimal_to_string(run.total_cost_usd),
      "artifacts" => run.artifacts,
      # Per-step observability (§9): completed/total progress, the per-step status+cost
      # list, and a recent per-step activity tail over the current/last step.
      "progress" => %{"completed" => progress.completed, "total" => progress.total},
      "steps" => Enum.map(progress.steps, &step_summary/1),
      "tail" => activity_tail(run, progress)
    }
  end

  @spec step_summary(Workflows.step_progress()) :: map()
  defp step_summary(step) do
    %{
      "name" => step.name,
      "status" => to_string(step.status),
      "cost_usd" => step.cost_usd,
      "started_at" => step.started_at,
      "finished_at" => step.finished_at
    }
  end

  # The recent per-step activity tail for the run's current (or last) step, read from
  # `agent_logs` keyed by the canonical step-session agent id. Step sessions broadcast
  # live but persist only when correlated by a UUID owner, so a synthetic step id with
  # no persisted rows yields an empty tail (no crash) — the shape is always present.
  @spec activity_tail(Workflows.WorkflowRun.t(), Workflows.progress()) :: [map()]
  defp activity_tail(run, progress) do
    case current_or_last_step(progress) do
      nil ->
        []

      step_name ->
        run.id
        |> WorkflowEngine.step_agent_id(step_name)
        |> recent_step_events(20)
        |> Enum.map(&log_summary/1)
    end
  end

  @spec current_or_last_step(Workflows.progress()) :: String.t() | nil
  defp current_or_last_step(%{current: current}) when is_binary(current), do: current

  defp current_or_last_step(%{steps: steps}) do
    case List.last(steps) do
      %{name: name} -> name
      _ -> nil
    end
  end

  # Read persisted step events only when the step-session agent id is a real UUID
  # (the `agent_logs.agent_id` column is a binary_id); the synthetic `wf-<run>-<step>`
  # id never is, so this returns `[]` rather than raising a cast error.
  @spec recent_step_events(String.t(), pos_integer()) :: [Logs.AgentLog.t()]
  defp recent_step_events(agent_id, limit) do
    case Ecto.UUID.cast(agent_id) do
      {:ok, uuid} -> Logs.list_recent(uuid, limit)
      :error -> []
    end
  end

  @spec decimal_to_string(Decimal.t() | nil) :: String.t() | nil
  defp decimal_to_string(%Decimal{} = cost), do: Decimal.to_string(cost)
  defp decimal_to_string(_other), do: nil

  @spec generate_session_id() :: String.t()
  defp generate_session_id do
    "worker-" <> (12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
  end

  @spec log_invocation(String.t(), Ecto.UUID.t(), map(), result()) :: :ok
  defp log_invocation(tool, orchestrator_id, args, result) do
    {level, outcome} =
      case result do
        {:ok, _} ->
          {:info, "ok"}

        # Value-based defense-in-depth (issue-per-project-encrypted-secrets-vault): an error
        # reason could embed a worker-supplied secret value, and this message is broadcast
        # live (system_logs). Scrub the orchestrator's project-secret values before it lands.
        {:error, reason} ->
          {:warn, scrub_reason(orchestrator_id, inspect(reason))}
      end

    _ =
      Logs.create_system_log(%{
        level: level,
        message: "orchestrator tool #{tool}: #{outcome}",
        metadata: %{
          "tool" => tool,
          "orchestrator_id" => orchestrator_id,
          "args" => redact_args(args)
        }
      })

    :ok
  rescue
    _error -> :ok
  catch
    _kind, _value -> :ok
  end

  # Keep tool args out of the system log when they could carry a prompt body; we
  # log only the keys present, never the values (§4.1 spirit).
  @spec redact_args(map()) :: [String.t()]
  defp redact_args(args), do: Map.keys(args)

  # Scrub the orchestrator's project-secret values out of an error message before it is
  # persisted/broadcast as a system log. Decrypt-gated via the bound project; `[]` values
  # (no project secrets / unset key) make this an identity pass.
  @spec scrub_reason(Ecto.UUID.t(), String.t()) :: String.t()
  defp scrub_reason(orchestrator_id, message) do
    Redact.scrub_values(message, Secrets.active_values(orchestrator_project_id(orchestrator_id)))
  end
end
