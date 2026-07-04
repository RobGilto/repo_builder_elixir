defmodule RepoBuilder.Orchestrator.Tools.Adw do
  @moduledoc """
  ADW workflow tools: `start_adw` (the portable Python shell-out adapter path and
  the in-app WorkflowEngine catalog fallback) and `check_adw` (per-step progress
  for either mode). Extracted verbatim from the monolithic `Orchestrator.Tools`
  (audit F3) — behaviour is byte-identical.
  """

  import RepoBuilder.Orchestrator.Tools.Shared,
    only: [
      blank_to_nil: 1,
      changeset_reason: 1,
      decimal_to_string: 1,
      fetch_string: 2,
      log_summary: 1,
      normalize_reason: 1,
      orchestrator_project_id: 1,
      orchestrator_working_dir: 1,
      put_present: 3,
      resolve_harness: 2,
      worker_provider: 1
    ]

  alias RepoBuilder.Agents
  alias RepoBuilder.Commands
  alias RepoBuilder.Definitions
  alias RepoBuilder.Logs
  alias RepoBuilder.Orchestrator.Tools.Shared
  alias RepoBuilder.Projects
  alias RepoBuilder.Projects.Project
  alias RepoBuilder.Session
  alias RepoBuilder.WorkflowEngine
  alias RepoBuilder.WorkflowEngine.Catalog
  alias RepoBuilder.Workflows
  alias RepoBuilder.Workflows.TitleHumanizer

  @type reason :: Shared.reason()
  @type result :: Shared.result()

  # The registry key for the portable-Python-ADW shell-out harness (issue-the-adw-gap).
  # `start_adw` routes to the real ADW adapter when the resolved harness is this; every
  # other harness keeps the in-app WorkflowEngine catalog path (Fake-testable fallback).
  @adw_harness "adw"

  @spec start_adw(Ecto.UUID.t(), map()) :: result()
  def start_adw(orchestrator_id, args) do
    with {:ok, input} <- fetch_string(args, "input"),
         {:ok, harness} <- resolve_harness(orchestrator_id, args) do
      if harness == @adw_harness do
        start_adw_via_adapter(orchestrator_id, harness, input, args)
      else
        start_adw_via_engine(orchestrator_id, harness, input, args)
      end
    end
  end

  @spec check_adw(map()) :: result()
  def check_adw(args) do
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

  @spec ensure_uuid(String.t()) :: {:ok, Ecto.UUID.t()} | {:error, reason()}
  defp ensure_uuid(raw) do
    case Ecto.UUID.cast(raw) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, "invalid run_id"}
    end
  end
end
