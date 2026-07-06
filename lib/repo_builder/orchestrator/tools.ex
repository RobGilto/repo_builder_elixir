defmodule RepoBuilder.Orchestrator.Tools do
  @moduledoc """
  The orchestrator's agent-management tool LOGIC, implemented ONCE in harness-blind
  Elixir (issue-c). Every harness binding — Claude's native MCP, the pi extension,
  the in-process Fake loop — reaches this exact module, so tool behavior is
  identical regardless of harness.

  `call/3` is the single entry point: it dispatches a tool name to its handler,
  NEVER raises (every failure becomes `{:error, reason()}`), and logs each
  invocation as a `system_logs` row. This module is the FAÇADE (audit F3
  decomposition): the handlers live in per-domain modules under
  `RepoBuilder.Orchestrator.Tools.*` —

    * `AgentOps` — worker lifecycle (create/command/check/update/delete …)
    * `Ledger` — leadership goal/progress/reflection + `inspect_repo`
    * `Focus` — focus discipline tools + the pre-dispatch focus gate
    * `WorkstreamOps` — spec-driven phased workstreams + `compact_self`
    * `QualityGate` — the stack-aware five-stage green gate
    * `SelfConfig` — orchestrator/tier self-configuration
    * `Cost` — cost/context reporting + worker compaction/reset
    * `AgentTemplates` — subagent templates
    * `LogLookup` — system-log audit + `log-<n>` lookups
    * `Adw` — ADW workflow launch/progress
    * `Shared` — cross-domain helpers

  Handlers drive only the platform's existing seams: `Agents`,
  `Session.Supervisor`, `WorkflowEngine`, `Logs`, and the `Dashboard` console feed.
  """

  alias RepoBuilder.Harness.Redact
  alias RepoBuilder.Logs

  alias RepoBuilder.Orchestrator.Tools.{
    Adw,
    AgentOps,
    AgentTemplates,
    Cost,
    DesignSystem,
    Focus,
    Ledger,
    LogLookup,
    QualityGate,
    SelfConfig,
    Shared,
    WorkstreamOps
  }

  alias RepoBuilder.Secrets

  # Changeset failures are stringified at the boundary (`Shared.changeset_reason/1`),
  # so a reason that escapes a tool is always an atom or a string.
  @type reason :: Shared.reason()
  @type result :: Shared.result()

  @doc """
  Execute a single orchestrator tool. `tool` is a catalog name; `args` is the
  decoded JSON arguments map (string keys). Returns a normalized tagged tuple and
  never raises.
  """
  @spec call(String.t(), Ecto.UUID.t(), map()) :: result()
  def call(tool, orchestrator_id, args) when is_binary(tool) and is_map(args) do
    result =
      case Focus.gate_block(tool, orchestrator_id, args) do
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

  @doc """
  The harness session config for an orchestrator-spawned worker: the worker's own
  persisted config plus the autonomous flag. See
  `RepoBuilder.Orchestrator.Tools.AgentOps.worker_session_config/1`.
  """
  @spec worker_session_config(RepoBuilder.Agents.Agent.t()) ::
          %{required(:autonomous) => true, optional(term()) => term()}
  defdelegate worker_session_config(worker), to: AgentOps

  # --- dispatch ---

  @spec dispatch(String.t(), Ecto.UUID.t(), map()) :: result()
  defp dispatch("create_agent", orchestrator_id, args),
    do: AgentOps.create_agent(orchestrator_id, args)

  defp dispatch("command_agent", orchestrator_id, args),
    do: AgentOps.command_agent(orchestrator_id, args)

  defp dispatch("list_agents", orchestrator_id, _args), do: AgentOps.list_agents(orchestrator_id)
  defp dispatch("list_apis", orchestrator_id, _args), do: AgentOps.list_apis(orchestrator_id)

  defp dispatch("check_agent_status", orchestrator_id, args),
    do: AgentOps.check_agent_status(orchestrator_id, args)

  defp dispatch("interrupt_agent", orchestrator_id, args),
    do: AgentOps.interrupt_agent(orchestrator_id, args)

  defp dispatch("start_adw", orchestrator_id, args), do: Adw.start_adw(orchestrator_id, args)

  defp dispatch("update_agent", orchestrator_id, args),
    do: AgentOps.update_agent(orchestrator_id, args)

  defp dispatch("delete_agent", orchestrator_id, args),
    do: AgentOps.delete_agent(orchestrator_id, args)

  defp dispatch("read_system_logs", _orchestrator_id, args), do: LogLookup.read_system_logs(args)
  defp dispatch("get_logs", _orchestrator_id, args), do: LogLookup.get_logs(args)

  defp dispatch("check_adw", _orchestrator_id, args), do: Adw.check_adw(args)
  defp dispatch("get_config", orchestrator_id, _args), do: SelfConfig.get_config(orchestrator_id)

  defp dispatch("configure_tier", orchestrator_id, args),
    do: SelfConfig.configure_tier(orchestrator_id, args)

  defp dispatch("set_orchestrator_config", orchestrator_id, args),
    do: SelfConfig.set_orchestrator_config(orchestrator_id, args)

  defp dispatch("report_cost", orchestrator_id, _args), do: Cost.report_cost(orchestrator_id)

  defp dispatch("compact_agent", orchestrator_id, args),
    do: Cost.compact_agent(orchestrator_id, args)

  defp dispatch("clear_context", orchestrator_id, args),
    do: Cost.clear_context(orchestrator_id, args)

  defp dispatch("list_agent_templates", _orchestrator_id, _args),
    do: AgentTemplates.list_agent_templates()

  defp dispatch("get_agent_template", _orchestrator_id, args),
    do: AgentTemplates.get_agent_template(args)

  defp dispatch("save_agent_template", _orchestrator_id, args),
    do: AgentTemplates.save_agent_template(args)

  # Leadership / ledger tools (self-healing Phase 3).
  defp dispatch("set_goal", orchestrator_id, args), do: Ledger.set_goal(orchestrator_id, args)

  defp dispatch("record_progress", orchestrator_id, args),
    do: Ledger.record_progress(orchestrator_id, args)

  defp dispatch("record_reflection", orchestrator_id, args),
    do: Ledger.record_reflection(orchestrator_id, args)

  defp dispatch("get_ledger", orchestrator_id, _args), do: Ledger.get_ledger(orchestrator_id)
  defp dispatch("set_focus", orchestrator_id, args), do: Focus.set_focus(orchestrator_id, args)

  defp dispatch("clear_focus", orchestrator_id, args),
    do: Focus.clear_focus(orchestrator_id, args)

  defp dispatch("report_complete", orchestrator_id, args),
    do: Ledger.report_complete(orchestrator_id, args)

  defp dispatch("inspect_repo", orchestrator_id, args),
    do: Ledger.inspect_repo(orchestrator_id, args)

  # Workstream tools (spec-driven phased orchestration).
  defp dispatch("create_workstream", orchestrator_id, args),
    do: WorkstreamOps.create_workstream(orchestrator_id, args)

  defp dispatch("plan_phases", orchestrator_id, args),
    do: WorkstreamOps.plan_phases(orchestrator_id, args)

  defp dispatch("record_stage", orchestrator_id, args),
    do: WorkstreamOps.record_stage(orchestrator_id, args)

  defp dispatch("list_workstreams", orchestrator_id, _args),
    do: WorkstreamOps.list_workstreams(orchestrator_id)

  defp dispatch("get_workstream", orchestrator_id, args),
    do: WorkstreamOps.get_workstream(orchestrator_id, args)

  defp dispatch("close_workstream", orchestrator_id, args),
    do: WorkstreamOps.close_workstream(orchestrator_id, args)

  defp dispatch("compact_self", orchestrator_id, _args),
    do: WorkstreamOps.compact_self(orchestrator_id)

  defp dispatch("run_quality_gate", orchestrator_id, args),
    do: QualityGate.run_quality_gate(orchestrator_id, args)

  defp dispatch("resolve_design_system", orchestrator_id, args),
    do: DesignSystem.resolve_design_system(orchestrator_id, args)

  defp dispatch(_tool, _orchestrator_id, _args), do: {:error, :unknown_tool}

  # --- invocation audit log ---

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
    Redact.scrub_values(
      message,
      Secrets.active_values(Shared.orchestrator_project_id(orchestrator_id))
    )
  end
end
