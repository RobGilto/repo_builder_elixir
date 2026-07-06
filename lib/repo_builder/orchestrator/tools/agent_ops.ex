defmodule RepoBuilder.Orchestrator.Tools.AgentOps do
  @moduledoc """
  Agent lifecycle tools: create/command/list/check/interrupt/update/delete
  workers, plus the external-API + research-tool provisioning, budget/breaker
  guards, and the worker-report spill path that back those tools. Extracted
  verbatim from the monolithic `Orchestrator.Tools` (audit F3) — behaviour is
  byte-identical.
  """

  import RepoBuilder.Orchestrator.Tools.Shared,
    only: [
      blank_to_nil: 1,
      changeset_reason: 1,
      fetch_string: 2,
      log_summary: 1,
      normalize_reason: 1,
      orchestrator_project_id: 1,
      orchestrator_working_dir: 1,
      positive_int: 2,
      put_present: 3,
      resolve_harness: 2,
      truncate_text: 2,
      worker_provider: 1,
      worker_text_cap: 0
    ]

  alias RepoBuilder.Agents
  alias RepoBuilder.Agents.Handover
  alias RepoBuilder.Agents.Holding
  alias RepoBuilder.Budget
  alias RepoBuilder.Budget.Scope
  alias RepoBuilder.Dashboard
  alias RepoBuilder.ExternalApis
  alias RepoBuilder.ExternalApis.Provisioning
  alias RepoBuilder.Harness.McpTools
  alias RepoBuilder.Harness.ModelResolver
  alias RepoBuilder.Logs
  alias RepoBuilder.Orchestrator.Breaker
  alias RepoBuilder.Orchestrator.DesignContract
  alias RepoBuilder.Orchestrator.Queue
  alias RepoBuilder.Orchestrator.Template
  alias RepoBuilder.Orchestrator.Templates
  alias RepoBuilder.Orchestrator.Tools.AgentTemplates
  alias RepoBuilder.Orchestrator.Tools.Shared
  alias RepoBuilder.Orchestrator.Workstreams
  alias RepoBuilder.Orchestrators
  alias RepoBuilder.Projects
  alias RepoBuilder.Projects.Project
  alias RepoBuilder.Session
  alias RepoBuilder.StackLayers

  @type reason :: Shared.reason()
  @type result :: Shared.result()

  @spec create_agent(Ecto.UUID.t(), map()) :: result()
  def create_agent(orchestrator_id, args) do
    with {:ok, name} <- fetch_string(args, "name"),
         {:ok, template} <- resolve_template(args),
         {:ok, tools} <- resolve_tools(args),
         {:ok, isolation} <- validate_isolation(args),
         {:ok, worktree_run_id} <- validate_worktree_run_id(args),
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
          |> prepend_design_contract(project_id)
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
          |> maybe_put_isolation(isolation)
          |> maybe_put_worktree_run_id(worktree_run_id)
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

  @spec command_agent(Ecto.UUID.t(), map()) :: result()
  def command_agent(orchestrator_id, args) do
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
        isolation_mode: isolation_mode,
        # Takeover key (issue worktree-takeover): when set, the session lands in the
        # EXISTING adw/<run_id> worktree/branch instead of one keyed on this worker's id.
        # nil ⇒ the session runtime's existing agent_id fallback (byte-identical to before).
        run_id: worktree_run_id(worker)
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

  @spec list_agents(Ecto.UUID.t()) :: result()
  def list_agents(orchestrator_id) do
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

  @doc """
  The external APIs in scope for this orchestrator (platform + project)
  (issue-external-api-mcp-provisioning). Name-only auth exposure: the `secret_name` is
  surfaced (so the brain knows a credential is referenced) but never any token value.
  """
  @spec list_apis(Ecto.UUID.t()) :: result()
  def list_apis(orchestrator_id) do
    apis =
      orchestrator_id
      |> orchestrator_project_id()
      |> ExternalApis.list_in_scope_for()
      |> Enum.map(&api_summary/1)

    {:ok, %{"apis" => apis, "count" => length(apis)}}
  end

  @spec check_agent_status(Ecto.UUID.t(), map()) :: result()
  def check_agent_status(orchestrator_id, args) do
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

  @spec interrupt_agent(Ecto.UUID.t(), map()) :: result()
  def interrupt_agent(orchestrator_id, args) do
    with {:ok, name} <- fetch_string(args, "name"),
         {:ok, worker} <- Agents.get_by_name_for_orchestrator(orchestrator_id, name) do
      :ok = Session.Supervisor.interrupt(worker.id)
      {:ok, %{"status" => "interrupted", "name" => worker.name}}
    end
  end

  @spec update_agent(Ecto.UUID.t(), map()) :: result()
  def update_agent(orchestrator_id, args) do
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
  def delete_agent(orchestrator_id, args) do
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

  @doc """
  The harness session config for an orchestrator-spawned worker: the worker's own
  persisted config plus the autonomous flag.

  Orchestrator workers run headless (no TTY to answer interactive permission
  prompts), so the session is autonomous — the Claude adapter then emits
  `--dangerously-skip-permissions`. The flag is the ATOM key `:autonomous` because
  the adapter's `autonomous?/1` matches atom keys, whereas `worker.config` is JSONB
  with string keys.
  """
  @spec worker_session_config(Agents.Agent.t()) ::
          %{required(:autonomous) => true, optional(term()) => term()}
  def worker_session_config(%{config: config}), do: Map.put(config, :autonomous, true)

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
          {:error, :not_found} -> {:error, AgentTemplates.template_not_found(name)}
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

  @spec ensure_worker_model(Agents.Agent.t()) :: :ok | {:error, reason()}
  defp ensure_worker_model(%{model: model, name: name}) do
    if blank_to_nil(model), do: :ok, else: {:error, "no model selected for #{name}"}
  end

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

  # Resolve `{cwd, isolation_mode}` for a worker dispatch from the worker's OWN project
  # (stable, drift-proof). An unscoped worker — or one whose project no longer exists —
  # falls back to the orchestrator's working dir with no isolation (back-compat).
  @spec worker_dispatch_location(Agents.Agent.t(), Ecto.UUID.t()) ::
          {String.t() | nil, Project.isolation_mode() | nil}
  # Isolation resolution (worktree-panel-and-gc plan): explicit per-worker arg
  # (config["isolation"], set at create time) → the bound project's isolation_mode
  # (a stored :direct is an explicit operator choice) → Projects.default_isolation()
  # (ships :worktree). Non-git cwds fall through to direct in the session runtime,
  # which is what keeps the :worktree default fail-safe for managed workspaces.
  defp worker_dispatch_location(worker, orchestrator_id) do
    {cwd, project_mode} = project_dispatch_location(worker, orchestrator_id)
    {cwd, Projects.resolve_worker_isolation(worker.config, project_mode)}
  end

  # The takeover key persisted at create time (issue worktree-takeover), or nil. A nil key
  # keeps the session runtime's existing `agent_id`-based worktree derivation unchanged.
  @spec worktree_run_id(Agents.Agent.t()) :: String.t() | nil
  defp worktree_run_id(%{config: %{"worktree_run_id" => id}}) when is_binary(id), do: id
  defp worktree_run_id(_worker), do: nil

  defp project_dispatch_location(%{project_id: project_id}, orchestrator_id)
       when is_binary(project_id) do
    case Projects.get_project(project_id) do
      %Project{root_path: root, isolation_mode: mode} -> {root, mode}
      nil -> {orchestrator_working_dir(orchestrator_id), nil}
    end
  end

  defp project_dispatch_location(_worker, orchestrator_id) do
    {orchestrator_working_dir(orchestrator_id), nil}
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

  # Fold the project's design contract (design-system subsystem) onto the front of a UI
  # worker's charter so the component vocabulary + tokens + paradigm lead. Sits BETWEEN the
  # stack contract and the task body (stack → design → task). Empty for non-UI projects
  # (generic base) ⇒ the prompt is unchanged (back-compatible).
  @spec prepend_design_contract(String.t() | nil, Ecto.UUID.t() | nil) :: String.t() | nil
  defp prepend_design_contract(prompt, project_id) do
    case DesignContract.render(project_id) do
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
  # worker's final turn — and that field is hard-capped at `Shared.worker_text_cap/0`
  # chars, so a worker that inlines a long report has its tail silently amputated and
  # there is no second channel to recover it. The clause therefore (a) tells the worker
  # the surfaced window is finite, (b) keeps the final message a concise self-contained
  # summary, and (c) gives an explicit overflow path: write the full result to an
  # `ai_docs/` markdown file in the shared working directory and cite that relative path.
  # The cap is interpolated so the documented limit can never drift from the enforced one.
  @spec worker_reporting_clause() :: String.t()
  defp worker_reporting_clause do
    """
    ## Reporting results
    Only your FINAL message is surfaced to the coordinator that dispatched you — it is
    read back via the orchestrator's `check_agent_status` tool, which truncates it to the
    first ~#{worker_text_cap()} characters. Keep that final message a concise,
    self-contained summary of your results (what you did, what you found, any
    conclusions). Do not bury the outcome mid-transcript; restate it at the end.

    If your full result would exceed that ~#{worker_text_cap()}-character budget (e.g. a
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
  # worker's FULL final message exceeds the shared cap, the surfaced `final_message` is
  # only a capped preview, so write the complete, untruncated text to a markdown file the
  # orchestrator can read and return its path as `report_file`. This removes all dependence
  # on the worker voluntarily writing an `ai_docs/` file (`worker_reporting_clause/0` stays
  # as cooperative guidance, but this is the guarantee). `nil` when no overflow occurred or
  # the write failed — the tool always still returns the preview.
  @spec maybe_spill_report(Ecto.UUID.t(), Agents.Agent.t(), {String.t(), Logs.AgentLog.t()} | nil) ::
          String.t() | nil
  defp maybe_spill_report(orchestrator_id, worker, {text, log}) do
    if String.length(text) > worker_text_cap(),
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

  defp truncate_or_nil(nil), do: nil
  defp truncate_or_nil(text), do: truncate_text(text, worker_text_cap())

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

  # Validate the optional per-worker `isolation` override (worktree-panel-and-gc plan).
  # Absent ⇒ `{:ok, nil}` (resolve from project mode / config default at dispatch time);
  # anything but the two modes is rejected up front.
  @spec validate_isolation(map()) :: {:ok, String.t() | nil} | {:error, reason()}
  defp validate_isolation(args) do
    case Map.get(args, "isolation") do
      nil -> {:ok, nil}
      mode when mode in ["direct", "worktree"] -> {:ok, mode}
      other -> {:error, "isolation must be \"direct\" or \"worktree\", got: #{inspect(other)}"}
    end
  end

  # Persist an explicit isolation choice on the worker's config; it wins over the
  # project mode and the configured default at every dispatch. Inference-only spec
  # (mirrors `maybe_put_tools/2`).
  defp maybe_put_isolation(config, mode) when mode in ["direct", "worktree"],
    do: Map.put(config, "isolation", mode)

  defp maybe_put_isolation(config, _mode), do: config

  # Validate the optional `worktree_run_id` takeover key (issue worktree-takeover). It
  # becomes both a scratch-dir segment and a git branch suffix, so it is charset-guarded at
  # this WireType boundary and treated as opaque after. Absent ⇒ `{:ok, nil}`.
  @worktree_run_id_re ~r/^[A-Za-z0-9._-]+$/
  @spec validate_worktree_run_id(map()) :: {:ok, String.t() | nil} | {:error, reason()}
  defp validate_worktree_run_id(args) do
    case Map.get(args, "worktree_run_id") do
      nil ->
        {:ok, nil}

      id when is_binary(id) ->
        if Regex.match?(@worktree_run_id_re, id) do
          {:ok, id}
        else
          {:error,
           "worktree_run_id must match #{inspect(@worktree_run_id_re.source)} (path/branch-safe), got: #{inspect(id)}"}
        end

      other ->
        {:error, "worktree_run_id must be a string, got: #{inspect(other)}"}
    end
  end

  # Persist the takeover key on the worker's config; threaded into the session as `run_id`
  # at dispatch so the session runtime lands in the existing adw/<id> worktree. Inference-only
  # spec (mirrors `maybe_put_isolation/2`).
  defp maybe_put_worktree_run_id(config, id) when is_binary(id),
    do: Map.put(config, "worktree_run_id", id)

  defp maybe_put_worktree_run_id(config, _id), do: config

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

  @spec generate_session_id() :: String.t()
  defp generate_session_id do
    "worker-" <> (12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
  end
end
