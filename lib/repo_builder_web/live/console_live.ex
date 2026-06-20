defmodule RepoBuilderWeb.ConsoleLive do
  @moduledoc """
  The multi-layered orchestration console (BUILD_PROMPT.md §9) — a single
  full-bleed LiveView reproducing the reference 3-pane command console:

    * a header bar (connection dot + Active/Running/Logs/WS Events/Cost pills +
      glowing LOGS⇄ADWS toggle + Prompt ⌘K toggle);
    * a left agent rail of rich agent cards (status badge, context-window bar,
      per-category counters, model+cost footer), collapsible to a 44px icon rail,
      pulsing on activity;
    * a center column that switches between a filterable live EVENT STREAM and ADW
      SWIMLANES with per-event squares + a click-to-open detail panel;
    * a right chat/command panel rendering canonical events as chat bubbles
      (text→message, thinking→thinking bubble, tool_call→tool-use card) above the
      launch / Interrupt / Launch-ADW controls;
    * a bottom ⌘K global command-input modal with a harness/agent system-info panel.

  The console is harness-blind: it drives the exact `Session.Supervisor` and
  `WorkflowEngine` paths the runtime already uses, so it works identically with
  `fake` (dev), `claude`, and `pi`. It NEVER touches `Repo` directly — every read
  and write flows through an `@spec`'d context. The center feed uses a LiveView
  STREAM backed by a bounded in-assign `event_buffer` so filtering can re-stream
  with `reset: true` (streams are not enumerable); server memory stays flat.
  """
  use RepoBuilderWeb, :live_view

  import RepoBuilderWeb.ConsoleComponents

  import RepoBuilderWeb.DashboardComponents,
    only: [
      adw_card: 1,
      adw_agent_card: 1,
      event_square: 1,
      event_detail_panel: 1
    ]

  alias RepoBuilder.{
    Agents,
    Budget,
    CostCenter,
    Dashboard,
    Definitions,
    Explain,
    Logs,
    Orchestrators,
    Session,
    WorkflowEngine,
    Workflows
  }

  alias RepoBuilder.Agents.Agent
  alias RepoBuilder.Budget.Cap
  alias RepoBuilder.Console.EventPresenter
  alias RepoBuilder.CostCenter.ModelPrice
  alias RepoBuilder.FileBrowser
  alias RepoBuilder.Harness.Event
  alias RepoBuilder.Harness.Pi.Models, as: PiModels
  alias RepoBuilder.Harness.Registry, as: HarnessRegistry
  alias RepoBuilder.Orchestrator.Queue, as: OrchestratorQueue
  alias RepoBuilder.Orchestrator.Templates
  alias RepoBuilder.Workflows.TitleHumanizer
  alias RepoBuilderWeb.AgentColors

  @categories [:response, :tool, :thinking, :hook]
  @buffer_limit 500
  @messages_limit 100
  # Terminal workflow run statuses (WorkflowRun.status): clearable from the ADWS view.
  @finished_workflow_statuses [:succeeded, :failed, :cancelled]
  # Throttle the live streaming assign to ≤ one render per tick (~20 fps) so a fast
  # provider streaming thousands of token deltas/sec can't flood the WebSocket.
  @stream_flush_ms 50

  # --- mount / streams / subscriptions ---

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> stream_configure(:events, dom_id: &"ev-#{&1.id}")
      |> stream_configure(:lanes, dom_id: &"lane-#{&1.id}")
      |> stream(:events, [])
      |> stream(:lanes, [])
      |> assign(
        agents: [],
        agent_names: %{},
        statuses: %{},
        agent_costs: %{},
        # Per-agent live cost ESTIMATE (token-derived, display-only, REPLACE-latest — NOT
        # additive into `agent_costs`). nil ⇒ unpriced/no estimate yet. Superseded by the
        # authoritative `agent_costs` value when the harness reports the billed amount.
        agent_est_costs: %{},
        orchestrator_id: nil,
        # FIFO turn-queue snapshot (issue message-queue): busy?/current/queued/depth.
        # Safe idle default for the disconnected render; reseeded on the connected mount.
        orchestrator_queue: %{busy?: false, current: nil, queued: [], depth: 0},
        orchestrator_harness: nil,
        orchestrator_provider: nil,
        orchestrator_model: nil,
        provider_options: [],
        model_options: [],
        recent_models: [],
        agent_model_rows: [],
        configured_tier_count: 0,
        agent_models_updated_at: nil,
        agent_model_saved: false,
        # System-prompt settings: safe defaults for the disconnected render (mount
        # runs twice); the connected socket reflects the orchestrator's real values.
        orchestrator_system_prompt: "",
        orchestrator_system_prompt_mode: :append,
        orchestrator_default_prompt: "",
        orchestrator_reasoning_effort: :default,
        orchestrator_working_dir: "",
        dir_picker_open?: false,
        dir_picker_path: "",
        dir_picker_parent: nil,
        dir_picker_dirs: [],
        view_mode: :logs,
        rail_collapsed?: false,
        # Operator-facing agent CRUD (issue agent-CRUD): console-created/edited agents
        # are orchestrator-OWNED workers (create_worker/update_worker) so the
        # orchestrator manages them. These drive the rail's New/Edit forms.
        show_new_agent?: false,
        agent_form: new_agent_form(),
        editing_agent_id: nil,
        edit_agent_form: nil,
        chat_width: :sm,
        # Operator display timezone for log timestamps; the connected mount reads the
        # persisted value off the orchestrator (this default is for the static render).
        timezone: RepoBuilder.Timezones.default(),
        auto_follow?: true,
        show_thinking?: true,
        # Reveal logs/workflows soft-hidden by CLEAR (settings troubleshooting toggle).
        show_hidden?: false,
        # Transient "Released N rows" confirmation for the Release action (nil ⇒ none).
        release_notice: nil,
        settings_tab: :general,
        # Agent-template settings tab. Defaults are safe for the disconnected render;
        # the connected mount seeds the real rows from the Templates context.
        template_rows: [],
        selected_template: nil,
        template_versions: [],
        # Cost Center settings tab (issue-cost-center). Lazily loaded when the tab is
        # selected so an ordinary mount never runs the rollup aggregation.
        cost_rollups: [],
        # Time-windowed accounting view (issue-cost-adw-periods); loaded with the tab.
        period_spend: nil,
        price_rows: [],
        price_form: to_form(ModelPrice.changeset(%ModelPrice{}, %{}), as: :model_price),
        editing_price_id: nil,
        regex?: false,
        search: "",
        active_categories: MapSet.new(@categories),
        active_agents: [],
        expanded_ids: MapSet.new(),
        counters: %{},
        context_tokens: %{},
        messages: [],
        # Live token-by-token streaming buffers (per agent_id), kept out of the
        # `@messages` list and the center stream until finalized (§ streaming).
        streaming: %{},
        stream_pending: %{},
        stream_flush_ref: nil,
        event_buffer: [],
        # Reusable multi-select over the event stream (issue-explain): a transient set
        # of selected row ids the bulk-action bar (EXPLAIN/HIDE/COPY) acts on. Never
        # persisted; cleared on CLEAR / disconnect / backfill re-stream.
        selected_ids: MapSet.new(),
        # Ephemeral explain-logs modal state: :idle | :running | {:ready, text} |
        # {:error, msg}. Discarded on close; nothing survives a reconnect.
        explain: %{status: :idle, request_id: nil, count: 0},
        # Per-step ADW observability (§9): run_id => a per-step progress view
        # (status/completed/total/current/cost/steps). Seeded from recent runs,
        # updated live on the lanes topic's workflow broadcasts.
        workflow_progress: %{},
        selected_event: nil,
        pulsed_id: nil,
        typing?: false,
        seq: 0,
        log_count: 0,
        ws_count: 0,
        # nil (unpriced) is NEVER coerced to Decimal.new(0): the cost pill renders
        # "—" until a priced amount arrives (§ edge cases).
        cost: nil,
        # Global live cost ESTIMATE: sum of per-agent latest estimates (display-only,
        # REPLACE-latest). Shown as "~$…" until the authoritative `cost` lands.
        cost_estimate: nil,
        # The orchestrator's OWN spend (its own turns only, distinct from the workers it
        # owns) — feeds the ORCHESTRATOR panel badge so `Σ workers + orchestrator == total`.
        # nil (unpriced/no signal) renders "—".
        orchestrator_cost: nil,
        orchestrator_est_cost: nil,
        connected?: connected?(socket),
        harness_options: HarnessRegistry.known(),
        # File-driven prompt palette (issue-prompt-adw-palette): live, file-derived
        # definition lists surfaced as clickable chips. Seeded on the connected mount
        # from RepoBuilder.Definitions and updated live via PubSub broadcasts. Kept
        # distinct from the live-worker `agents` assign (this is `agent_defs`).
        slash_commands: [],
        agent_defs: [],
        adws: [],
        # Budget guardrails (issue-budget-guardrails): live breaker snapshot + caps + form.
        # Safe disconnected defaults; reseeded from Budget.Guard.snapshot/0 on connect and
        # updated live over the "budget:events" topic.
        budget_state: %{kill_switch?: false, caps: []},
        budget_caps: [],
        # The form's selected scope drives whether the scope_id picker shows (hidden for
        # "global"); scope_targets feeds that picker with live orchestrator/workflow ids.
        budget_scope: "global",
        budget_scope_targets: %{},
        budget_editing?: false,
        budget_form: to_form(Cap.changeset(%Cap{}, %{}), as: :budget),
        # ADW Builder mode
        adw_builder?: false,
        adw_steps: [],
        adw_name: "",
        adw_harness: nil,
        adw_local?: false,
        # Log Database manager (issue-log-db-manager): a paginated, filterable DB browser
        # over `agent_logs`. Selection is a MapSet of `id` UUID STRINGS (distinct from the
        # live view's integer `selected_ids`) so it persists across pages and never collides
        # with the live-stream selection. Safe disconnected defaults; seeded on connect.
        log_mgr_filter: :all,
        log_mgr_rows: [],
        log_mgr_total: 0,
        log_mgr_limit: 50,
        log_mgr_offset: 0,
        log_mgr_selected: MapSet.new()
      )

    socket =
      allow_upload(socket, :attachments,
        accept: ~w(.jpg .jpeg .png .gif .webp .pdf .txt .md .csv .json .ex .exs),
        max_entries: 5,
        max_file_size: 10_000_000
      )

    socket =
      if connected?(socket) do
        socket
        |> load_agents()
        |> seed_agent_costs()
        |> seed_context_tokens()
        |> seed_counters()
        |> seed_lanes()
        |> seed_workflow_progress()
        |> seed_budget()
        # assign_orchestrator must precede backfill_events: it reads the persisted
        # display timezone into assigns, which backfill_events uses to format row times.
        # It must also precede seed_cost/seed_orchestrator_cost, which read orchestrator_id.
        |> assign_orchestrator()
        |> seed_cost()
        |> seed_orchestrator_cost()
        |> backfill_events()
        |> seed_log_manager()
        |> assign_template_rows()
        |> seed_definitions()
        |> subscribe_feeds()
        |> tap(fn _ -> PiModels.refresh_async() end)
      else
        socket
      end

    {:ok, socket}
  end

  # Resolve the default orchestrator so a prompt with no agent selected has a brain
  # to route to. A failure leaves orchestrator_id nil (the manual path still works).
  @spec assign_orchestrator(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp assign_orchestrator(socket) do
    case Orchestrators.get_or_create_default() do
      {:ok, orchestrator} -> assign_orchestrator_selection(socket, orchestrator)
      {:error, _reason} -> socket
    end
  end

  # Reflect an orchestrator's full selection (harness + provider + model) and the
  # per-harness option lists (from the registry) in the header assigns.
  @spec assign_orchestrator_selection(
          Phoenix.LiveView.Socket.t(),
          RepoBuilder.Orchestrator.Orchestrator.t()
        ) :: Phoenix.LiveView.Socket.t()
  defp assign_orchestrator_selection(socket, orchestrator) do
    rows = agent_model_rows(orchestrator)

    assign(socket,
      orchestrator_id: orchestrator.id,
      orchestrator_queue: OrchestratorQueue.snapshot(orchestrator.id),
      orchestrator_harness: orchestrator.harness,
      orchestrator_provider: orchestrator.provider,
      orchestrator_model: orchestrator.model,
      provider_options: provider_options_for(orchestrator.harness),
      model_options: model_options_for(orchestrator.harness, orchestrator.provider),
      recent_models: Orchestrators.recent_models(orchestrator, orchestrator.provider),
      agent_model_rows: rows,
      configured_tier_count: configured_tier_count(rows),
      agent_models_updated_at: agent_models_updated_at(orchestrator),
      orchestrator_system_prompt: orchestrator.system_prompt || "",
      orchestrator_system_prompt_mode: orchestrator.system_prompt_mode,
      orchestrator_default_prompt: Orchestrators.default_system_prompt(orchestrator),
      orchestrator_reasoning_effort: orchestrator.reasoning_effort,
      orchestrator_working_dir: orchestrator.working_dir || "",
      timezone: Orchestrators.timezone(orchestrator)
    )
  end

  @spec agent_models_updated_at(RepoBuilder.Orchestrator.Orchestrator.t()) :: String.t() | nil
  defp agent_models_updated_at(%RepoBuilder.Orchestrator.Orchestrator{metadata: metadata}) do
    metadata
    |> Map.get("agent_models", %{})
    |> Enum.find_value(fn {_cat, entry} -> entry["_updated_at"] end)
  end

  # Build the per-category roster rows for the agent-models modal: each category's
  # current {harness, provider, model} plus the option lists derived from them.
  @spec agent_model_rows(RepoBuilder.Orchestrator.Orchestrator.t()) :: [map()]
  def agent_model_rows(orchestrator) do
    roster = Orchestrators.agent_models(orchestrator)
    harnesses = orchestrator_harness_options()

    Enum.map(Orchestrators.agent_categories(), fn category ->
      entry = Map.get(roster, category, %{})
      harness = entry["harness"]
      provider = entry["provider"]
      model = entry["model"]

      # The orchestrator assigns concrete model ids (e.g. `claude-sonnet-4-5`) that the
      # registry's curated tier-alias list (`opus`/`sonnet`/`haiku`) omits. Prepend the
      # assigned id so the `<select>` can mark it selected — mirroring the header
      # dropdown's `model_extra` "Current" handling — instead of falling back to blank.
      base = if(harness, do: model_options_for(harness, provider), else: [])
      model_options = if(model in [nil, "" | base], do: base, else: [model | base])

      %{
        category: category,
        harness: harness,
        provider: provider,
        model: model,
        harness_options: harnesses,
        provider_options: if(harness, do: provider_options_for(harness), else: []),
        model_options: model_options
      }
    end)
  end

  @doc "Count of categories that have a non-blank model assigned."
  @spec configured_tier_count([map()]) :: non_neg_integer()
  def configured_tier_count(rows) do
    Enum.count(rows, fn row -> not is_nil(row.model) and row.model != "" end)
  end

  @spec provider_options_for(String.t()) :: [String.t()]
  defp provider_options_for(harness) do
    defaults = HarnessRegistry.orchestrator_defaults(harness)

    case defaults[:providers] do
      [_ | _] = providers -> providers
      _ -> [defaults[:default_provider]] |> Enum.reject(&is_nil/1)
    end
  end

  # Prefer pi's LIVE model catalog (`pi --list-models`, cached) so the dropdown
  # tracks new releases (e.g. MiniMax-M3); fall back to the static registry list
  # when pi is unavailable or hasn't a live entry for this provider.
  @spec model_options_for(String.t(), String.t() | nil) :: [String.t()]
  defp model_options_for("pi", provider) do
    case PiModels.list(provider) do
      [] -> HarnessRegistry.orchestrator_models("pi", provider)
      live -> live
    end
  end

  defp model_options_for(harness, provider) do
    HarnessRegistry.orchestrator_models(harness, provider)
  end

  @spec subscribe_feeds(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp subscribe_feeds(socket) do
    :ok = Dashboard.subscribe()
    :ok = Dashboard.subscribe_events()
    # The per-orchestrator queue topic (issue message-queue): re-render the queued
    # strip live. assign_orchestrator runs before this, so orchestrator_id is set.
    _ =
      if id = socket.assigns.orchestrator_id, do: Dashboard.subscribe_orchestrator_queue(id)

    # File-driven prompt palette: receive {:definitions_changed, category, list}.
    :ok = Definitions.subscribe()

    # Budget guardrails: receive {:budget_tripped, ...} / {:budget_warning, ...} /
    # {:budget_reset, ...} / {:kill_switch, ...} to re-render the panel/banner/badge live.
    :ok = Phoenix.PubSub.subscribe(RepoBuilder.PubSub, Budget.Guard.topic())

    socket
  end

  # Seed the budget breaker snapshot + caps on the connected mount (and on reconnect,
  # §9). The snapshot reads the live Guard; caps read the durable context.
  @spec seed_budget(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp seed_budget(socket) do
    snapshot = Budget.Guard.snapshot()

    assign(socket,
      budget_state: snapshot,
      budget_caps: budget_rows(snapshot, Budget.list_caps()),
      budget_scope_targets: budget_scope_targets(socket)
    )
  end

  # Merge the durable DB caps (authoritative + editable) with the live Guard snapshot
  # (spend/state), keyed by cap id. DB caps anchor the editable rows; snapshot-only caps
  # (a not-yet-reconciled memory cap) still surface so no cap is unreachable. A DB cap with
  # no live row yet renders at zero spend / :ok.
  @spec budget_rows(map(), [Cap.t()]) :: [map()]
  defp budget_rows(%{caps: live_rows}, db_caps) do
    by_id = Map.new(live_rows, &{&1.cap.id, &1})

    from_db =
      Enum.map(db_caps, fn cap ->
        Map.get(by_id, cap.id, %{cap: cap, spent: Decimal.new(0), ratio: 0.0, state: :ok})
      end)

    db_ids = MapSet.new(db_caps, & &1.id)
    ghosts = Enum.reject(live_rows, &MapSet.member?(db_ids, &1.cap.id))

    from_db ++ ghosts
  end

  defp budget_rows(_snapshot, db_caps) do
    Enum.map(db_caps, &%{cap: &1, spent: Decimal.new(0), ratio: 0.0, state: :ok})
  end

  # Live id pickers for scoped caps: the console's own orchestrator and the recent
  # workflow runs, labelled for humans so the operator never hand-types a raw UUID.
  @spec budget_scope_targets(Phoenix.LiveView.Socket.t()) :: %{
          String.t() => [{String.t(), String.t()}]
        }
  defp budget_scope_targets(socket) do
    orchestrators =
      case socket.assigns[:orchestrator_id] do
        id when is_binary(id) -> [{"This console", id}]
        _ -> []
      end

    workflows =
      for run <- Workflows.list_recent_runs(20) do
        {"#{run.current_step || "run"} · #{String.slice(run.id, 0, 8)} (#{run.status})", run.id}
      end

    %{"orchestrator" => orchestrators, "workflow" => workflows}
  end

  # Re-read the live snapshot + durable caps after a breaker event or operator action.
  @spec refresh_budget(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp refresh_budget(socket), do: seed_budget(socket)

  # Re-query the Log Database manager page (rows + total) for the current filter/offset,
  # clamping the offset down if the active filter shrank below it (e.g. after a purge or a
  # visibility change moved rows out of the filtered set). Single source of truth for the
  # manager's table state, shared by the connected mount and every mutating action.
  @spec seed_log_manager(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp seed_log_manager(socket) do
    %{log_mgr_filter: filter, log_mgr_limit: limit, log_mgr_offset: offset} = socket.assigns
    total = Logs.count_agent_logs(filter)
    offset = clamp_page_offset(offset, limit, total)
    rows = Logs.query_agent_logs(filter, limit, offset)

    assign(socket, log_mgr_rows: rows, log_mgr_total: total, log_mgr_offset: offset)
  end

  @spec refresh_log_manager(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp refresh_log_manager(socket), do: seed_log_manager(socket)

  # Largest valid offset is the start of the last page; clamp into `[0, last_page_start]`.
  @spec clamp_page_offset(integer(), pos_integer(), non_neg_integer()) :: non_neg_integer()
  defp clamp_page_offset(offset, limit, total) do
    max_offset = if total == 0, do: 0, else: div(max(total - 1, 0), limit) * limit
    offset |> max(0) |> min(max_offset)
  end

  # Seed the three file-derived palette assigns from the merged (app + working-dir)
  # root for the orchestrator's current working dir. Re-run when the working dir
  # changes so the overlay updates immediately.
  @spec seed_definitions(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp seed_definitions(socket) do
    %{slash_command: slash, agent: agents, adw: adws} =
      Definitions.all(nilify_blank(socket.assigns.orchestrator_working_dir))

    assign(socket, slash_commands: slash, agent_defs: agents, adws: adws)
  end

  @spec load_agents(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp load_agents(socket) do
    agents = Agents.list_agents()

    assign(socket,
      agents: agents,
      agent_names: Map.new(agents, &{&1.id, &1.name}),
      statuses: Map.new(agents, &{&1.id, &1.status})
    )
  end

  # A blank create-agent form. Console-created agents are orchestrator-owned workers,
  # so the form is backed by `worker_changeset/2` (casts model/system_prompt; harness
  # stays open). `orchestrator_id` is injected at persist time by `create_worker/2`.
  @spec new_agent_form() :: Phoenix.HTML.Form.t()
  defp new_agent_form, do: to_form(Agent.worker_changeset(%Agent{}, %{}), as: :agent)

  # Inject the active orchestrator id so a create-form validation reflects the same
  # ownership `create_worker/2` will persist (its `validate_required(:orchestrator_id)`).
  @spec worker_params(Phoenix.LiveView.Socket.t(), map()) :: map()
  defp worker_params(socket, params),
    do: Map.put(params, "orchestrator_id", socket.assigns.orchestrator_id)

  # Reflect a newly-created worker in the rail roster + ADWS lane stream live, without a
  # full reseed: reload the agent list (rail) and insert its lane (idempotent dom_id).
  @spec insert_agent(Phoenix.LiveView.Socket.t(), Agent.t()) :: Phoenix.LiveView.Socket.t()
  defp insert_agent(socket, %Agent{} = agent) do
    lane = %{
      id: "agent:#{agent.id}",
      kind: :agent,
      label: agent.name,
      status: agent.status,
      harness: agent.harness
    }

    socket
    |> load_agents()
    |> stream_insert(:lanes, lane)
  end

  @spec seed_agent_costs(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp seed_agent_costs(socket) do
    costs = Map.new(socket.assigns.agents, &{&1.id, nilify_zero(Logs.cost_rollup!(&1.id))})
    assign(socket, :agent_costs, costs)
  end

  # cost_rollup! returns Decimal-0 for agents with no priced logs; keep the rail
  # footer at "—" (unpriced) in that case rather than showing "$0".
  @spec nilify_zero(Decimal.t()) :: Decimal.t() | nil
  defp nilify_zero(%Decimal{} = d), do: if(Decimal.equal?(d, 0), do: nil, else: d)

  # Seed each agent card's CONTEXT WINDOW bar from the latest persisted `usage` row,
  # mirroring `seed_agent_costs/1`. Without this an agent whose work predates the
  # mount (or any reconnect) shows an empty bar even though its logs are backfilled.
  @spec seed_context_tokens(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp seed_context_tokens(socket) do
    assign(socket, :context_tokens, Logs.context_tokens_by_agent())
  end

  # Seed the per-card category counters (responses/tools/hooks/thinking) from
  # persisted logs so a reconnect restores them; the seeded shape matches what
  # `bump_counter/3` expects, so later live increments merge cleanly.
  @spec seed_counters(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp seed_counters(socket) do
    assign(socket, :counters, Logs.event_counts_by_agent())
  end

  # Only AGENT lanes go into the flat lane stream now; workflow runs render as rich
  # per-step swimlanes from `@workflow_progress` (seeded by `seed_workflow_progress/1`).
  @spec seed_lanes(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp seed_lanes(socket) do
    lanes = agent_lanes(socket.assigns.agents)
    Enum.reduce(lanes, socket, &stream_insert(&2, :lanes, &1))
  end

  # Seed the per-step workflow views from the most-recent runs so the ADWS view shows
  # per-step squares on connect (a reconnect backfills rather than starting empty).
  @spec seed_workflow_progress(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp seed_workflow_progress(socket) do
    progress =
      Workflows.list_recent_runs(50, socket.assigns.show_hidden?)
      |> Map.new(fn run -> {run.id, workflow_view(run)} end)

    assign(socket, :workflow_progress, progress)
  end

  # Merge a workflow lane's status/current step into the run's per-step view (creating
  # a minimal view if the run was launched after mount).
  @spec update_workflow_status(Phoenix.LiveView.Socket.t(), map()) ::
          Phoenix.LiveView.Socket.t()
  defp update_workflow_status(socket, %{id: "workflow:" <> run_id, status: status, label: label}) do
    view =
      socket.assigns.workflow_progress
      |> Map.get(run_id, default_workflow_view(run_id))
      |> Map.merge(%{status: status, current: label})

    assign(socket, :workflow_progress, Map.put(socket.assigns.workflow_progress, run_id, view))
  end

  defp update_workflow_status(socket, _lane), do: socket

  # Merge a per-step progress map (total/completed/current/steps) into the run's view.
  @spec update_workflow_steps(Phoenix.LiveView.Socket.t(), Ecto.UUID.t(), map()) ::
          Phoenix.LiveView.Socket.t()
  defp update_workflow_steps(socket, run_id, progress) do
    view =
      socket.assigns.workflow_progress
      |> Map.get(run_id, default_workflow_view(run_id))
      |> Map.merge(%{
        completed: progress.completed,
        total: progress.total,
        current: progress.current,
        steps: progress.steps
      })

    assign(socket, :workflow_progress, Map.put(socket.assigns.workflow_progress, run_id, view))
  end

  # A minimal view for a run first seen via a live broadcast (assume it is running
  # until a lane status says otherwise). No workflow loaded yet ⇒ title falls back to
  # the never-a-UUID `"ADW <short>"` form until a refetch fills it in.
  @spec default_workflow_view(Ecto.UUID.t()) :: map()
  defp default_workflow_view(run_id) do
    %{
      run_id: run_id,
      workflow_id: nil,
      title: "ADW " <> short_id(run_id),
      type: nil,
      duration: nil,
      status: :running,
      current: nil,
      cost: nil,
      completed: 0,
      total: 0,
      steps: []
    }
  end

  # Build a per-step workflow view from a run (seed/refetch path): full status + cost
  # from the row, the derived per-step progress (ordered, branching-safe), a derived
  # duration, and a human-friendly `title` (loaded from the run's `Workflow`).
  # Inference-only spec — the concrete view map narrows below `map()` under :underspecs.
  defp workflow_view(run) do
    progress = Workflows.run_progress(run)
    workflow = run.workflow_id && Workflows.get_workflow(run.workflow_id)

    %{
      run_id: run.id,
      workflow_id: run.workflow_id,
      title: workflow_title(run, workflow),
      type: workflow && workflow.type,
      duration: workflow_duration(run),
      status: run.status,
      current: run.current_step,
      cost: run.total_cost_usd,
      completed: progress.completed,
      total: progress.total,
      steps: progress.steps
    }
  end

  # The card title: the humanized `metadata["title"]` wins; else a non-machine-looking
  # workflow name; else the humanized type; else the live step; else a short, never-raw
  # `"ADW <short>"`. A bare UUID is never the title.
  @spec workflow_title(Workflows.WorkflowRun.t(), Workflows.Workflow.t() | nil) :: String.t()
  defp workflow_title(run, workflow) do
    meta_title(workflow) || human_name(workflow) || human_type(workflow) ||
      step_title(run) || "ADW " <> short_id(run.id)
  end

  @spec meta_title(Workflows.Workflow.t() | nil) :: String.t() | nil
  defp meta_title(%{metadata: %{"title" => title}}) when is_binary(title), do: presence(title)
  defp meta_title(_workflow), do: nil

  # A workflow name only when it is human-friendly (a machine-looking name is skipped
  # so the card shows the humanized type until the Fast-tier title arrives).
  @spec human_name(Workflows.Workflow.t() | nil) :: String.t() | nil
  defp human_name(%{name: name}) when is_binary(name) do
    if TitleHumanizer.machine_name?(name), do: nil, else: presence(name)
  end

  defp human_name(_workflow), do: nil

  @spec human_type(Workflows.Workflow.t() | nil) :: String.t() | nil
  defp human_type(%{type: type}) when is_binary(type) and type != "",
    do: presence(humanize_type(type))

  defp human_type(_workflow), do: nil

  @spec step_title(Workflows.WorkflowRun.t()) :: String.t() | nil
  defp step_title(%{current_step: step}) when is_binary(step), do: presence(step)
  defp step_title(_run), do: nil

  @spec presence(String.t()) :: String.t() | nil
  defp presence(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  # Slug → Title Case ("plan_build" → "Plan Build").
  @spec humanize_type(String.t()) :: String.t()
  defp humanize_type(type) do
    type
    |> String.split(~r/[-_\s]+/, trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  # A display duration for the run: finished ⇒ inserted_at→updated_at; running ⇒
  # inserted_at→now. `nil` when timestamps are absent.
  @spec workflow_duration(Workflows.WorkflowRun.t()) :: String.t() | nil
  defp workflow_duration(%{inserted_at: %DateTime{} = started} = run) do
    finished =
      case run do
        %{status: status, updated_at: %DateTime{} = up}
        when status in [:succeeded, :failed, :cancelled] ->
          up

        _ ->
          DateTime.utc_now()
      end

    format_duration(DateTime.diff(finished, started, :second))
  end

  defp workflow_duration(_run), do: nil

  @spec format_duration(integer()) :: String.t()
  defp format_duration(seconds) when seconds < 0, do: "0s"
  defp format_duration(seconds) when seconds < 60, do: "#{seconds}s"

  defp format_duration(seconds) do
    "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  end

  # The header grand total = Σ worker-own spend + the orchestrator's OWN spend. The
  # orchestrator term was previously omitted, so a reconnect under-counted by the
  # orchestrator's own turns until new live events arrived.
  @spec seed_cost(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp seed_cost(socket) do
    workers =
      Enum.reduce(socket.assigns.agents, nil, fn agent, acc ->
        accumulate_cost(acc, Logs.cost_rollup!(agent.id))
      end)

    cost = accumulate_cost(workers, orchestrator_own_cost(socket))
    assign(socket, :cost, nilify_acc(cost))
  end

  # The orchestrator's OWN spend (`agent_logs` keyed by `orchestrator_id`, not
  # `agent_id`) — disjoint from the worker rollups, distinct from the whole-tree budget
  # scope. Feeds the ORCHESTRATOR panel badge so the three badges reconcile.
  @spec seed_orchestrator_cost(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp seed_orchestrator_cost(socket) do
    assign(socket, :orchestrator_cost, nilify_acc(orchestrator_own_cost(socket)))
  end

  @spec orchestrator_own_cost(Phoenix.LiveView.Socket.t()) :: Decimal.t() | nil
  defp orchestrator_own_cost(socket) do
    case socket.assigns.orchestrator_id do
      id when is_binary(id) -> Logs.orchestrator_cost_rollup!(id)
      _ -> nil
    end
  end

  @spec nilify_acc(Decimal.t() | nil) :: Decimal.t() | nil
  defp nilify_acc(nil), do: nil
  defp nilify_acc(%Decimal{} = d), do: if(Decimal.equal?(d, 0), do: nil, else: d)

  # Re-seed the center stream + chat buffer from the most-recent global logs so a
  # reconnect backfills instead of starting empty (§9 reconnect rule).
  @spec backfill_events(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp backfill_events(socket) do
    logs = Logs.list_recent_global(200, socket.assigns.show_hidden?)

    timezone = socket.assigns.timezone

    {rows, seq} =
      Enum.reduce(logs, {[], 0}, fn log, {rows, seq} ->
        seq = seq + 1
        row = log_to_row(log, seq, socket.assigns.agent_names, timezone)
        # Operator chat turns are chat-pane-only (parity with the live path, where
        # push_user_message/2 writes no center-stream row) — keep them out of the
        # center stream (issue-operator-persist-operator-chat-messages). The chat pane
        # is still seeded from backfill_messages/2 below.
        if row.chat_role == "operator", do: {rows, seq}, else: {rows ++ [row], seq}
      end)

    rows = Enum.take(rows, -@buffer_limit)

    # Seed the chat pane from a dedicated orchestrator-scoped query rather than the
    # worker-dominated global slice above (issue-chat-history-backfill): orchestrator
    # rows fall out of the global most-recent-200 window once workers dominate, so the
    # chat would otherwise backfill empty on restart. A SEPARATE `chat_seq` keeps chat
    # entry ids from colliding with the center-stream `seq`.
    messages = backfill_messages(socket, timezone)

    socket
    |> assign(event_buffer: rows, messages: messages, seq: seq)
    # A reconnect starts from persisted finalized history only — drop any stale
    # in-flight streaming buffer so no token shards survive the reconnect (§9), and
    # drop any selection referencing the now-reset row ids (issue-explain).
    |> assign(streaming: %{}, stream_pending: %{}, stream_flush_ref: nil)
    |> assign(selected_ids: MapSet.new())
    # Re-seed the per-card context bar + counters from persisted logs so a reconnect
    # restores them alongside the re-streamed history (issue-per-agent token/context).
    |> seed_context_tokens()
    |> seed_counters()
    |> stream(:events, rows, reset: true)
  end

  # Build the chat pane's `@messages` from the orchestrator-scoped backfill query
  # (issue-chat-history-backfill) so the conversation survives a restart even when
  # worker rows dominate the global stream. Reuses the live path's
  # `log_to_row/4` → `chat_for_row/1` → `append_chat/3` helpers (single source of
  # truth) with its OWN `seq` so chat entry ids never collide with the center stream.
  @spec backfill_messages(Phoenix.LiveView.Socket.t(), String.t()) :: [map()]
  defp backfill_messages(socket, timezone) do
    Logs.list_recent_orchestrator_messages(@messages_limit, socket.assigns.show_hidden?)
    |> Enum.reduce({[], 0}, fn log, {msgs, seq} ->
      seq = seq + 1
      row = log_to_row(log, seq, socket.assigns.agent_names, timezone)
      {append_chat(msgs, chat_for_row(row), seq, timezone), seq}
    end)
    |> elem(0)
    |> Enum.take(-@messages_limit)
  end

  @spec agent_lanes([Agent.t()]) :: [Dashboard.lane()]
  defp agent_lanes(agents) do
    Enum.map(agents, fn agent ->
      %{
        id: "agent:#{agent.id}",
        kind: :agent,
        label: agent.name,
        status: agent.status,
        harness: agent.harness
      }
    end)
  end

  # --- control handlers ---

  @impl true
  def handle_event("toggle_view", _params, socket), do: {:noreply, toggle_view(socket)}

  # Switch the orchestrator's harness (Claude ⇄ pi ⇄ …). Applies that harness's
  # provider/model defaults (Claude ⇒ anthropic/opus; pi ⇒ operator-chosen), so the
  # header reflects the full selection. The next run_turn picks it up.
  def handle_event("set_harness", %{"harness" => harness}, socket) do
    update_orchestrator(
      socket,
      &Orchestrators.set_harness(&1, harness),
      "Could not switch harness"
    )
  end

  # Set the orchestrator's provider (open identity). An empty selection clears it.
  def handle_event("set_provider", %{"provider" => provider}, socket) do
    provider = nilify_blank(provider)

    update_orchestrator(
      socket,
      &Orchestrators.set_provider(&1, provider),
      "Could not set provider"
    )
  end

  # Set the orchestrator's model (free text / suggested). Empty clears it.
  def handle_event("set_model", %{"model" => model}, socket) do
    model = nilify_blank(model)
    update_orchestrator(socket, &Orchestrators.set_model(&1, model), "Could not set model")
  end

  # Re-fetch the orchestrator from the DB when the user opens the agent-models modal
  # so the panel always shows live state (including out-of-band mutations).
  def handle_event("open_agent_models", _params, socket) do
    case socket.assigns.orchestrator_id do
      nil ->
        {:noreply, socket}

      id ->
        case Orchestrators.fetch(id) do
          {:ok, orchestrator} ->
            {:noreply, assign_orchestrator_selection(socket, orchestrator)}

          {:error, _} ->
            {:noreply, socket}
        end
    end
  end

  # Assign a worker category's harness/provider/model (agent-models modal). Cascade:
  # changing the harness clears provider+model; changing the provider clears model.
  # On success: transiently set `agent_model_saved: true` for the "Saved ✓" chip.
  def handle_event("set_agent_model", %{"category" => category} = params, socket) do
    stored = Enum.find(socket.assigns.agent_model_rows, %{}, &(&1.category == category))
    attrs = agent_model_attrs(params, stored)

    case socket.assigns.orchestrator_id do
      nil ->
        {:noreply, put_flash(socket, :error, "No orchestrator available")}

      id ->
        case Orchestrators.set_agent_model(id, category, attrs) do
          {:ok, orchestrator} ->
            Process.send_after(self(), :clear_agent_model_saved, 2_000)

            {:noreply,
             socket
             |> assign_orchestrator_selection(orchestrator)
             |> assign(:agent_model_saved, true)}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Could not set agent model")}
        end
    end
  end

  # Save the custom system prompt + mode. Blank text persists as nil (spawn falls
  # back to the generated default). The mode comes from the hidden field (current
  # toggle state); never `String.to_atom/1` on operator input.
  def handle_event("save_system_prompt", %{"system_prompt" => text} = params, socket) do
    mode = system_prompt_mode(params["mode"])

    update_orchestrator(
      socket,
      &Orchestrators.set_system_prompt(&1, nilify_blank(text), mode),
      "Could not save system prompt"
    )
  end

  # Persist the append/replace mode immediately (consistent with the other settings),
  # keeping the current stored prompt text unchanged.
  def handle_event("set_system_prompt_mode", %{"mode" => mode}, socket) do
    mode = system_prompt_mode(mode)
    text = nilify_blank(socket.assigns.orchestrator_system_prompt)

    update_orchestrator(
      socket,
      &Orchestrators.set_system_prompt(&1, text, mode),
      "Could not set prompt mode"
    )
  end

  # Reset to the generated default (clears the override, restores :append).
  def handle_event("reset_system_prompt", _params, socket) do
    update_orchestrator(
      socket,
      &Orchestrators.reset_system_prompt(&1),
      "Could not reset system prompt"
    )
  end

  # Persist the orchestrator + worker working directory. Blank clears it (back to an
  # isolated per-session workspace); a non-blank value must be an absolute path to an
  # existing directory, validated before it is stored (no silent un-runnable cwd).
  def handle_event("save_working_dir", %{"working_dir" => dir}, socket) do
    save_working_dir(socket, dir)
  end

  # Clear the working dir (blank ⇒ each agent gets an isolated scratch workspace).
  def handle_event("clear_working_dir", _params, socket) do
    save_working_dir(socket, "")
  end

  # Open the directory picker, starting at the current working dir when it is a valid
  # directory, otherwise the project root (the default).
  def handle_event("open_dir_picker", _params, socket) do
    start =
      case nilify_blank(socket.assigns.orchestrator_working_dir) do
        path when is_binary(path) ->
          if File.dir?(path), do: path, else: FileBrowser.project_root()

        nil ->
          FileBrowser.project_root()
      end

    {:noreply, socket |> assign(:dir_picker_open?, true) |> load_dir_picker(start)}
  end

  def handle_event("dir_picker_browse", %{"path" => path}, socket) do
    {:noreply, load_dir_picker(socket, path)}
  end

  # Browse straight to a typed/pasted absolute path. Blank ⇒ no-op (no flash spam);
  # otherwise reuse load_dir_picker/2 (expands, lists, flashes + keeps prior view on error).
  def handle_event("dir_picker_goto", %{"path" => path}, socket) do
    case String.trim(path) do
      "" -> {:noreply, socket}
      trimmed -> {:noreply, load_dir_picker(socket, trimmed)}
    end
  end

  def handle_event("close_dir_picker", _params, socket) do
    {:noreply, assign(socket, :dir_picker_open?, false)}
  end

  # Commit the currently-browsed directory as the orchestrator cwd, then close the picker.
  def handle_event("dir_picker_select", _params, socket) do
    {:noreply, socket} = save_working_dir(socket, socket.assigns.dir_picker_path)
    {:noreply, assign(socket, :dir_picker_open?, false)}
  end

  # Persist the harness-blind reasoning effort immediately (consistent with the other
  # orchestrator settings). The next run_turn spawns with the per-harness flag.
  def handle_event("set_reasoning_effort", %{"effort" => effort}, socket) do
    update_orchestrator(
      socket,
      &Orchestrators.set_reasoning_effort(&1, reasoning_effort(effort)),
      "Could not set reasoning effort"
    )
  end

  # Persist the operator's display timezone and re-render the center stream in the new
  # zone (the select snaps back to @timezone on an invalid/failed write — no-op here).
  def handle_event("set_timezone", %{"timezone" => zone}, socket) do
    case socket.assigns.orchestrator_id do
      nil ->
        {:noreply, put_flash(socket, :error, "No orchestrator available")}

      id ->
        case Orchestrators.set_timezone(id, zone) do
          {:ok, orchestrator} ->
            socket =
              socket
              |> assign_orchestrator_selection(orchestrator)
              |> backfill_events()
              |> refresh_cost_center_on_tz()

            {:noreply, socket}

          {:error, _reason} ->
            {:noreply, socket}
        end
    end
  end

  # --- agent-template settings tab ---

  # Start a blank new-template form (clears the selection + version history).
  def handle_event("new_template", _params, socket) do
    {:noreply, assign(socket, selected_template: nil, template_versions: [])}
  end

  # Load a template (current version) into the editor + its version history.
  def handle_event("select_template", %{"name" => name}, socket) do
    {:noreply, select_template(socket, name)}
  end

  # Save a new version of a template (author: operator) and re-select it.
  def handle_event("save_agent_template", params, socket) do
    attrs = %{
      "name" => params["name"],
      "description" => params["description"],
      "body" => params["system_prompt"],
      "model" => nilify_blank(params["model"] || ""),
      "category" => nilify_blank(params["category"] || ""),
      "author" => :operator
    }

    case Templates.save(attrs) do
      {:ok, template} ->
        {:noreply,
         socket
         |> assign_template_rows()
         |> select_template(template.name)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not save template (check name/fields)")}
    end
  end

  # Promote an old version to a fresh current one (non-destructive restore).
  def handle_event("restore_template", %{"name" => name, "version" => version}, socket) do
    case Integer.parse(version) do
      {k, _rest} ->
        case Templates.restore(name, k) do
          {:ok, _template} ->
            {:noreply, socket |> assign_template_rows() |> select_template(name)}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Could not restore version")}
        end

      :error ->
        {:noreply, put_flash(socket, :error, "Invalid version")}
    end
  end

  # Delete a writable template's history; built-ins are read-only.
  def handle_event("delete_template", %{"name" => name}, socket) do
    case Templates.delete(name) do
      :ok ->
        {:noreply,
         socket
         |> assign(selected_template: nil, template_versions: [])
         |> assign_template_rows()}

      {:error, :builtin} ->
        {:noreply, put_flash(socket, :error, "Built-in templates are read-only")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not delete template")}
    end
  end

  # Cancel a still-queued operator/auto-resume turn before it runs (issue message-queue);
  # the in-flight turn is never affected (use interrupt for that). The queue broadcasts a
  # fresh snapshot on success, so the strip updates via the queue handle_info.
  def handle_event("cancel_queued", %{"id" => id}, socket) do
    case socket.assigns.orchestrator_id do
      nil ->
        {:noreply, socket}

      orchestrator_id ->
        case OrchestratorQueue.cancel(orchestrator_id, id) do
          {:ok, snapshot} -> {:noreply, assign(socket, :orchestrator_queue, snapshot)}
          {:error, :not_found} -> {:noreply, socket}
        end
    end
  end

  def handle_event("view:toggle", _params, socket), do: {:noreply, toggle_view(socket)}

  def handle_event("toggle_rail", _params, socket),
    do: {:noreply, assign(socket, :rail_collapsed?, not socket.assigns.rail_collapsed?)}

  def handle_event("set_chat_width", %{"width" => width}, socket),
    do: {:noreply, assign(socket, :chat_width, to_chat_width(width))}

  def handle_event("toggle_adw_builder", _params, socket) do
    {:noreply, assign(socket, adw_builder?: !socket.assigns.adw_builder?)}
  end

  def handle_event("adw_add_step", %{"step" => step}, socket) do
    steps = socket.assigns.adw_steps
    id = if steps == [], do: 1, else: Enum.max_by(steps, & &1.id).id + 1
    new_step = %{id: id, name: step, expanded: false}
    {:noreply, assign(socket, adw_steps: steps ++ [new_step])}
  end

  def handle_event("adw_remove_step", %{"id" => id}, socket) do
    id = String.to_integer(id)
    {:noreply, assign(socket, adw_steps: Enum.reject(socket.assigns.adw_steps, &(&1.id == id)))}
  end

  def handle_event("adw_move_step", %{"id" => id, "dir" => dir}, socket) do
    id = String.to_integer(id)
    steps = socket.assigns.adw_steps
    idx = Enum.find_index(steps, &(&1.id == id))
    new_idx = if dir == "up", do: idx - 1, else: idx + 1

    if new_idx < 0 or new_idx >= length(steps) do
      {:noreply, socket}
    else
      {item, rest} = List.pop_at(steps, idx)
      {:noreply, assign(socket, adw_steps: List.insert_at(rest, new_idx, item))}
    end
  end

  def handle_event("adw_toggle_step", %{"id" => id}, socket) do
    id = String.to_integer(id)

    steps =
      Enum.map(socket.assigns.adw_steps, fn s ->
        if s.id == id, do: %{s | expanded: !s.expanded}, else: s
      end)

    {:noreply, assign(socket, adw_steps: steps)}
  end

  def handle_event("adw_set_name", %{"name" => name}, socket) do
    {:noreply, assign(socket, adw_name: name)}
  end

  def handle_event("adw_toggle_local", _params, socket) do
    {:noreply, assign(socket, adw_local?: !socket.assigns.adw_local?)}
  end

  def handle_event("run_adw_builder", _params, socket) do
    steps = socket.assigns.adw_steps

    if steps == [] do
      {:noreply, put_flash(socket, :error, "Add at least one step before launching")}
    else
      harness = socket.assigns.adw_harness || socket.assigns.orchestrator_harness || "fake"

      name =
        socket.assigns.adw_name
        |> then(&if(&1 == "", do: "custom-adw", else: &1))
        |> String.replace(" ", "-")

      {:noreply, launch_adw_builder(steps, name, harness, socket)}
    end
  end

  # The ⌘K command modal is the sole prompt input: it routes to the orchestrator
  # (or the manually selected agent, if any) via run_prompt/4. The modal hides
  # itself client-side (hide_command/0) on submit.
  def handle_event("run_command", %{"command" => command}, socket) do
    upload_dir = Path.join("/tmp/repo_builder_uploads", Ecto.UUID.generate())
    File.mkdir_p!(upload_dir)

    attachment_lines =
      consume_uploaded_entries(socket, :attachments, fn %{path: tmp_path}, entry ->
        dest = Path.join(upload_dir, entry.client_name)
        File.cp!(tmp_path, dest)
        kind = if String.match?(entry.client_type, ~r/^image\//), do: "image", else: "file"
        {:ok, "- #{kind}: #{dest}"}
      end)

    full_command =
      if attachment_lines == [] do
        command
      else
        lines = Enum.join(attachment_lines, "\n")
        "#{command}\n\n[Attachments]\n#{lines}"
      end

    run_prompt(socket, full_command, default_harness(), nil)
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :attachments, ref)}
  end

  # Required for `allow_upload`: LiveView only tracks selected/pasted files when the
  # upload input's form carries a `phx-change`. The validation itself is handled by
  # the upload config (accept/max_*), so this is a no-op acknowledgement.
  def handle_event("validate_attachments", _params, socket), do: {:noreply, socket}

  # --- filter handlers (re-stream from the bounded buffer; streams aren't filterable) ---

  def handle_event("toggle_category", %{"cat" => cat}, socket) do
    case to_category(cat) do
      nil ->
        {:noreply, socket}

      category ->
        active = toggle_member(socket.assigns.active_categories, category)
        {:noreply, socket |> assign(:active_categories, active) |> restream()}
    end
  end

  def handle_event("toggle_agent_filter", %{"id" => id}, socket) do
    active =
      if id in socket.assigns.active_agents,
        do: List.delete(socket.assigns.active_agents, id),
        else: [id | socket.assigns.active_agents]

    {:noreply, socket |> assign(:active_agents, active) |> restream()}
  end

  # Soft-archive a manual agent from the rail (issue agent-CRUD): hide it from the
  # roster (it is excluded from `list_agents/0`) while preserving its row + cost
  # history. Reconcile the live total exactly as the reconnect path would (a reseed
  # uses `list_agents/0`, which now drops the archived agent's spend) and drop it from
  # the active-filter set / lane stream so the view matches a fresh mount.
  def handle_event("archive_agent", %{"id" => id}, socket) do
    with {:ok, agent} <- Agents.fetch_agent(id),
         {:ok, _archived} <- Agents.archive_agent(agent) do
      removed = Map.get(socket.assigns.agent_costs, id)
      removed_est = Map.get(socket.assigns.agent_est_costs, id)

      {:noreply,
       socket
       |> assign(:agents, Enum.reject(socket.assigns.agents, &(&1.id == id)))
       |> assign(:active_agents, List.delete(socket.assigns.active_agents, id))
       |> assign(:agent_names, Map.delete(socket.assigns.agent_names, id))
       |> assign(:statuses, Map.delete(socket.assigns.statuses, id))
       |> assign(:cost, subtract_cost(socket.assigns.cost, removed))
       |> assign(:cost_estimate, subtract_cost(socket.assigns.cost_estimate, removed_est))
       |> assign(:agent_costs, Map.delete(socket.assigns.agent_costs, id))
       |> assign(:agent_est_costs, Map.delete(socket.assigns.agent_est_costs, id))
       |> stream_delete(:lanes, %{id: "agent:#{id}"})
       |> restream()
       |> put_flash(:info, "Archived agent #{agent.name}")}
    else
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Agent no longer exists")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Could not archive agent")}
    end
  end

  # --- operator-facing agent CRUD (issue agent-CRUD) ---------------------------
  # Console-created/edited agents are orchestrator-OWNED workers (create_worker/
  # update_worker), so the active orchestrator can list + command them.

  def handle_event("show_new_agent", _params, socket) do
    {:noreply, assign(socket, show_new_agent?: true, agent_form: new_agent_form())}
  end

  def handle_event("cancel_new_agent", _params, socket) do
    {:noreply, assign(socket, show_new_agent?: false, agent_form: new_agent_form())}
  end

  def handle_event("validate_agent", %{"agent" => params}, socket) do
    form =
      %Agent{}
      |> Agent.worker_changeset(worker_params(socket, params))
      |> to_form(action: :validate, as: :agent)

    {:noreply, assign(socket, :agent_form, form)}
  end

  def handle_event("create_agent", %{"agent" => params}, socket) do
    case Agents.create_worker(socket.assigns.orchestrator_id, params) do
      {:ok, agent} ->
        {:noreply,
         socket
         |> insert_agent(agent)
         |> assign(show_new_agent?: false, agent_form: new_agent_form())
         |> put_flash(:info, "Created agent #{agent.name}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :agent_form, to_form(changeset, as: :agent))}
    end
  end

  def handle_event("edit_agent", %{"id" => id}, socket) do
    case Agents.fetch_agent(id) do
      {:ok, agent} ->
        {:noreply,
         assign(socket,
           editing_agent_id: agent.id,
           edit_agent_form: to_form(Agent.worker_changeset(agent, %{}), as: :agent)
         )}

      {:error, :not_found} ->
        {:noreply, socket |> load_agents() |> put_flash(:error, "Agent no longer exists")}
    end
  end

  def handle_event("cancel_edit_agent", _params, socket) do
    {:noreply, assign(socket, editing_agent_id: nil, edit_agent_form: nil)}
  end

  def handle_event("validate_edit_agent", %{"agent" => params}, socket) do
    case socket.assigns.editing_agent_id && Agents.get_agent(socket.assigns.editing_agent_id) do
      %Agent{} = agent ->
        form = agent |> Agent.worker_changeset(params) |> to_form(action: :validate, as: :agent)
        {:noreply, assign(socket, :edit_agent_form, form)}

      _missing ->
        {:noreply, assign(socket, editing_agent_id: nil, edit_agent_form: nil)}
    end
  end

  def handle_event("update_agent", %{"agent" => params}, socket) do
    with id when is_binary(id) <- socket.assigns.editing_agent_id,
         {:ok, agent} <- Agents.fetch_agent(id),
         {:ok, updated} <- Agents.update_worker(agent, params) do
      {:noreply,
       socket
       |> load_agents()
       |> assign(editing_agent_id: nil, edit_agent_form: nil)
       |> put_flash(:info, "Updated agent #{updated.name}")}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket, :edit_agent_form, to_form(changeset, action: :validate, as: :agent))}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> assign(editing_agent_id: nil, edit_agent_form: nil)
         |> load_agents()
         |> put_flash(:error, "Agent no longer exists")}

      nil ->
        {:noreply, assign(socket, editing_agent_id: nil, edit_agent_form: nil)}
    end
  end

  def handle_event("set_search", %{"q" => q}, socket),
    do: {:noreply, socket |> assign(:search, q) |> restream()}

  def handle_event("toggle_regex", _params, socket),
    do: {:noreply, socket |> assign(:regex?, not socket.assigns.regex?) |> restream()}

  def handle_event("toggle_auto_follow", _params, socket),
    do: {:noreply, assign(socket, :auto_follow?, not socket.assigns.auto_follow?)}

  def handle_event("toggle_thinking", _params, socket),
    do: {:noreply, assign(socket, :show_thinking?, not socket.assigns.show_thinking?)}

  # Troubleshooting: reveal (or re-hide) rows soft-hidden by CLEAR. Flip the flag, then
  # re-seed the log stream + workflow swimlanes from the DB honoring the new flag.
  def handle_event("toggle_show_hidden", _params, socket) do
    socket = assign(socket, :show_hidden?, not socket.assigns.show_hidden?)
    {:noreply, socket |> backfill_events() |> seed_workflow_progress()}
  end

  # Durable reveal: permanently un-hide every row soft-hidden by CLEAR (the inverse of
  # CLEAR). Unlike the troubleshooting peek, this persists hidden=false so the rows stay
  # visible across reconnects without holding a flag on. Re-seed the streams from the
  # now-visible DB and flash a transient "Released N rows" confirmation.
  def handle_event("release_hidden", _params, socket) do
    released = Logs.release_hidden_logs() + Workflows.release_hidden_runs()
    Process.send_after(self(), :clear_release_notice, 2_000)

    {:noreply,
     socket
     |> assign(:release_notice, released)
     |> backfill_events()
     |> seed_workflow_progress()}
  end

  def handle_event("select_settings_tab", %{"tab" => tab}, socket) do
    selected = settings_tab(tab)
    socket = assign(socket, :settings_tab, selected)
    socket = if selected == :cost_center, do: load_cost_center(socket), else: socket
    {:noreply, socket}
  end

  # Save a catalog price (issue-cost-center). Routes to `update_price/2` when an edit is in
  # flight (identity key fields dropped so the row can never be repointed, §key-immutability)
  # or `upsert_price/1` when creating. On success re-derive the catalog + rollup and reset
  # to create mode; on a validation error re-render the form with the changeset (staying in
  # edit mode); a stale id (row deleted concurrently) falls back to create mode.
  def handle_event("save_price", %{"model_price" => params}, socket) do
    result =
      case socket.assigns.editing_price_id do
        nil ->
          CostCenter.upsert_price(params)

        id ->
          case CostCenter.get_price(id) do
            nil -> {:error, :not_found}
            price -> CostCenter.update_price(price, Map.drop(params, ~w(harness provider model)))
          end
      end

    case result do
      {:ok, _price} ->
        {:noreply, socket |> load_cost_center() |> reset_price_form()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :price_form, to_form(changeset, as: :model_price))}

      {:error, :not_found} ->
        {:noreply, socket |> load_cost_center() |> reset_price_form()}
    end
  end

  # Load a catalog row into the form and flip into edit mode. A stale id (concurrent
  # delete) no-ops rather than crashing.
  def handle_event("edit_price", %{"id" => id}, socket) do
    case CostCenter.get_price(id) do
      nil ->
        {:noreply, socket}

      %ModelPrice{} = price ->
        {:noreply,
         assign(socket,
           editing_price_id: price.id,
           price_form: to_form(ModelPrice.changeset(price, %{}), as: :model_price)
         )}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, reset_price_form(socket)}
  end

  def handle_event("delete_price", %{"id" => id}, socket) do
    _ = CostCenter.delete_price(id)
    socket = load_cost_center(socket)

    socket =
      if socket.assigns.editing_price_id == id, do: reset_price_form(socket), else: socket

    {:noreply, socket}
  end

  # --- budget guardrails (issue-budget-guardrails) ---

  # Track the form's selected scope as the operator changes it, so the scope_id picker can
  # show/hide (and swap orchestrator-vs-workflow targets) without a submit. Rebuild the form
  # from the in-flight params so typed values survive the re-render.
  def handle_event("budget_form_change", %{"budget" => params}, socket) do
    changeset = Cap.changeset(%Cap{}, params)

    {:noreply,
     assign(socket,
       budget_form: to_form(changeset, as: :budget),
       budget_scope: params["scope"] || "global",
       # Recompute live targets so the picker reflects orchestrators/workflows present
       # right now (the mount seed runs before orchestrator assignment / before new runs).
       budget_scope_targets: budget_scope_targets(socket)
     )}
  end

  # Load an existing cap (from the merged DB+live rows, so even a not-yet-reconciled cap is
  # editable) into the form. Submitting upserts it, which also reconciles any memory-vs-DB
  # drift by writing the row back.
  def handle_event("edit_budget", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.budget_caps, &(&1.cap.id == id)) do
      %{cap: cap} ->
        {:noreply,
         assign(socket,
           budget_form: to_form(Cap.changeset(cap, %{}), as: :budget),
           budget_scope: to_string(cap.scope),
           budget_scope_targets: budget_scope_targets(socket),
           budget_editing?: true
         )}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_edit_budget", _params, socket) do
    {:noreply, reset_budget_form(socket)}
  end

  def handle_event("save_budget", %{"budget" => params}, socket) do
    case Budget.upsert_cap(params) do
      {:ok, _cap} ->
        # A new/edited cap changes the live policy; force the Guard to reload + reconcile.
        _ = Budget.Guard.refresh()
        {:noreply, socket |> refresh_budget() |> reset_budget_form()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :budget_form, to_form(changeset, as: :budget))}
    end
  end

  def handle_event("delete_budget", %{"id" => id}, socket) do
    _ = Budget.delete_cap(id)
    _ = Budget.Guard.refresh()
    {:noreply, refresh_budget(socket)}
  end

  def handle_event("reset_budget", %{"id" => id}, socket) do
    _ = Budget.Guard.reset_cap(id)
    {:noreply, refresh_budget(socket)}
  end

  def handle_event("toggle_kill_switch", _params, socket) do
    if socket.assigns.budget_state.kill_switch? do
      _ = Budget.Guard.release_all()
    else
      _ = Budget.Guard.engage_kill_switch()
    end

    {:noreply, refresh_budget(socket)}
  end

  # Reset every filter AND clear the log view. Empties the in-memory event buffer + the
  # rendered stream (and collapses expanded rows) AND soft-hides the persisted rows, so
  # the cleared state survives a reconnect. Nothing is deleted — the settings "show
  # hidden" toggle reveals it again. When troubleshooting (show_hidden?), skip the
  # persist so CLEAR stays a view-only reset.
  def handle_event("clear_filters", _params, socket) do
    # Discard the hidden-row count: the persist is a side effect, not a return value.
    _ = unless socket.assigns.show_hidden?, do: Logs.hide_all_logs()

    {:noreply,
     socket
     |> assign(
       active_categories: MapSet.new(@categories),
       active_agents: [],
       search: "",
       regex?: false,
       event_buffer: [],
       expanded_ids: MapSet.new(),
       selected_ids: MapSet.new(),
       log_count: 0
     )
     |> stream(:events, [], reset: true)}
  end

  # Clear finished (succeeded/failed/cancelled) workflows AND non-running agent swimlanes
  # from the ADWS view. Soft-hides the persisted data so the cleared state survives a
  # reconnect. Running/queued work stays; nothing is deleted (reversible via the settings
  # "show hidden" toggle). When troubleshooting (show_hidden?), skip the persist so CLEAR
  # stays a view-only reset.
  def handle_event("clear_workflows", _params, socket) do
    # Existing: drop finished workflow cards and persist cleared state.
    _ = unless socket.assigns.show_hidden?, do: Workflows.hide_finished_runs()

    kept =
      socket.assigns.workflow_progress
      |> Enum.reject(fn {_run_id, view} -> view.status in @finished_workflow_statuses end)
      |> Map.new()

    # New: derive clearable agent_key set from event_buffer + statuses (@swimlanes is a
    # render-time derived assign computed in render/1 — not in socket.assigns directly).
    # Any key whose current status is not :running is clearable.
    clearable_keys =
      socket.assigns.event_buffer
      |> Enum.map(& &1.agent_key)
      |> Enum.uniq()
      |> Enum.reject(fn k -> Map.get(socket.assigns.statuses, k, :idle) == :running end)
      |> MapSet.new()

    # Trim event_buffer; @swimlanes auto-recomputes from it in render/1 (line 2847).
    {cleared_rows, kept_buffer} =
      Enum.split_with(socket.assigns.event_buffer, fn row ->
        MapSet.member?(clearable_keys, row.agent_key)
      end)

    # Drop clearable keys from @statuses so running_count/1 badge stays accurate.
    kept_statuses =
      Map.reject(socket.assigns.statuses, fn {k, _} -> MapSet.member?(clearable_keys, k) end)

    # Durable: soft-hide worker swimlanes (UUID-shaped agent_key) in the DB so the clear
    # survives a reconnect (backfill_events reads list_recent_global which respects hidden).
    # Orchestrator-derived lanes ("orch-…" keys) are cleared view-only; persisting those
    # is governed by the orchestrator/chat backfill path and is out of scope here.
    _ =
      unless socket.assigns.show_hidden? do
        worker_keys =
          clearable_keys
          |> Enum.filter(fn k -> match?({:ok, _}, Ecto.UUID.cast(k)) end)

        Logs.hide_logs_for_agents(worker_keys)
      end

    socket =
      socket
      |> assign(:workflow_progress, kept)
      |> assign(:event_buffer, kept_buffer)
      |> assign(:statuses, kept_statuses)

    # stream_delete each cleared row from :events (mirrors hide_selected, lines 1728-1734).
    socket = Enum.reduce(cleared_rows, socket, &stream_delete(&2, :events, &1))

    {:noreply, socket}
  end

  def handle_event("toggle_event", %{"id" => id}, socket) do
    id = String.to_integer(id)
    expanded = toggle_member(socket.assigns.expanded_ids, id)
    socket = assign(socket, :expanded_ids, expanded)

    case Enum.find(socket.assigns.event_buffer, &(&1.id == id)) do
      nil -> {:noreply, socket}
      row -> {:noreply, stream_insert(socket, :events, row)}
    end
  end

  def handle_event("open_event", %{"id" => id}, socket) do
    id = String.to_integer(id)

    {:noreply,
     assign(socket, :selected_event, Enum.find(socket.assigns.event_buffer, &(&1.id == id)))}
  end

  def handle_event("close_event", _params, socket),
    do: {:noreply, assign(socket, :selected_event, nil)}

  # --- reusable event-stream selection + bulk actions (issue-explain) ---

  # Toggle one row's membership in the action-agnostic selection. Re-stream the row so
  # its checkbox reflects the new state (the stream only re-renders changed items).
  def handle_event("toggle_select", %{"id" => id}, socket) do
    id = String.to_integer(id)
    selected = toggle_member(socket.assigns.selected_ids, id)
    socket = assign(socket, :selected_ids, selected)

    case Enum.find(socket.assigns.event_buffer, &(&1.id == id)) do
      nil -> {:noreply, socket}
      row -> {:noreply, stream_insert(socket, :events, row)}
    end
  end

  # Range selection committed by the DragSelect JS hook (issue drag-select): ADD or
  # REMOVE the dragged ids (additive/subtractive over the existing selection, honoring
  # `mode`) in a SINGLE round-trip, then re-stream only the rows whose membership actually
  # changed so authoritative checkbox state reconciles the hook's optimistic paint.
  def handle_event("select_drag", %{"ids" => ids, "mode" => mode}, socket) do
    {:noreply, apply_drag_selection(socket, parse_ids(ids), normalize_mode(mode))}
  end

  def handle_event("clear_selection", _params, socket),
    do: {:noreply, clear_selection(socket)}

  # --- Log Database manager (issue-log-db-manager) ---
  # A paginated, filterable DB browser over `agent_logs`. Its selection is a MapSet of
  # `id` UUID STRINGS, persisting across pages so a purge/visibility action can span them.

  # Re-query the manager's current filter/page when it opens (its assigns are seeded on
  # mount, but rows may have changed since; this keeps the first paint authoritative).
  def handle_event("open_log_manager", _params, socket),
    do: {:noreply, refresh_log_manager(socket)}

  # Switch the All/Visible/Hidden filter: reset to page 1, clear the selection (so stale,
  # off-page ids can't apply to a different filtered set), and re-query.
  def handle_event("select_log_filter", %{"filter" => filter}, socket) do
    socket =
      socket
      |> assign(:log_mgr_filter, log_filter(filter))
      |> assign(:log_mgr_offset, 0)
      |> assign(:log_mgr_selected, MapSet.new())
      |> refresh_log_manager()

    {:noreply, socket}
  end

  def handle_event("log_page_next", _params, socket) do
    %{log_mgr_offset: offset, log_mgr_limit: limit} = socket.assigns
    socket = socket |> assign(:log_mgr_offset, offset + limit) |> refresh_log_manager()
    {:noreply, socket}
  end

  def handle_event("log_page_prev", _params, socket) do
    %{log_mgr_offset: offset, log_mgr_limit: limit} = socket.assigns
    socket = socket |> assign(:log_mgr_offset, max(offset - limit, 0)) |> refresh_log_manager()
    {:noreply, socket}
  end

  def handle_event("log_toggle_select", %{"id" => id}, socket) do
    {:noreply,
     assign(socket, :log_mgr_selected, toggle_member(socket.assigns.log_mgr_selected, id))}
  end

  # Range selection committed by the LogDragSelect JS hook: union/difference the dragged
  # ids (UUID strings — no integer parse) into the manager selection in one round-trip.
  def handle_event("log_select_drag", %{"ids" => ids, "mode" => mode}, socket) do
    current = socket.assigns.log_mgr_selected
    delta = MapSet.new(Enum.filter(List.wrap(ids), &is_binary/1))

    next =
      case normalize_mode(mode) do
        :select -> MapSet.union(current, delta)
        :deselect -> MapSet.difference(current, delta)
      end

    {:noreply, assign(socket, :log_mgr_selected, next)}
  end

  def handle_event("clear_log_selection", _params, socket),
    do: {:noreply, assign(socket, :log_mgr_selected, MapSet.new())}

  def handle_event("log_make_visible", _params, socket),
    do: {:noreply, mutate_log_selection(socket, &Logs.unhide_logs/1)}

  def handle_event("log_make_invisible", _params, socket),
    do: {:noreply, mutate_log_selection(socket, &Logs.hide_logs/1)}

  def handle_event("log_purge_selected", _params, socket),
    do: {:noreply, mutate_log_selection(socket, &Logs.purge_logs/1)}

  # Guarded purge-EVERYTHING (also reachable from the Log Database settings tab). Resets
  # the manager to page 1, clears the selection, and re-queries (now empty).
  def handle_event("purge_all_logs", _params, socket) do
    _ = Logs.purge_all_logs()

    socket =
      socket
      |> assign(:log_mgr_offset, 0)
      |> assign(:log_mgr_selected, MapSet.new())
      |> refresh_log_manager()

    {:noreply, socket}
  end

  # EXPLAIN: gather the selected rows (order-preserving), resolve the Fast tier, and
  # start the ephemeral runner. The modal is shown client-side by the button's JS; this
  # only flips the assign to :running (or to an actionable error when no Fast agent).
  def handle_event("explain_selected", _params, socket) do
    rows = selected_rows(socket.assigns.event_buffer, socket.assigns.selected_ids)

    if rows == [] do
      {:noreply, socket}
    else
      explain_selected(socket, rows)
    end
  end

  # HIDE: soft-hide the selected rows from the view (declutter), then clear the
  # selection. View-only — persisted history is untouched (reconnect re-backfills).
  def handle_event("hide_selected", _params, socket) do
    rows = selected_rows(socket.assigns.event_buffer, socket.assigns.selected_ids)
    ids = MapSet.new(rows, & &1.id)
    buffer = Enum.reject(socket.assigns.event_buffer, &MapSet.member?(ids, &1.id))

    socket =
      socket
      |> assign(event_buffer: buffer, selected_ids: MapSet.new())

    socket = Enum.reduce(rows, socket, &stream_delete(&2, :events, &1))
    {:noreply, socket}
  end

  def handle_event("close_explain", _params, socket),
    do: {:noreply, assign(socket, :explain, %{status: :idle, request_id: nil, count: 0})}

  defp launch_adw_builder(steps, name, harness, socket) do
    step_list =
      steps
      |> Enum.map(fn s ->
        %{"name" => s.name, "harness" => harness, "on_success" => "done", "on_failure" => "abort"}
      end)
      |> Enum.with_index()
      |> Enum.map(fn {step, i} ->
        next = Enum.at(steps, i + 1)
        if next, do: Map.put(step, "on_success", next.name), else: step
      end)

    with {:ok, wf} <-
           Workflows.create_workflow(%{
             name: "#{name}-#{System.unique_integer([:positive])}",
             type: "custom",
             steps: step_list
           }),
         {:ok, _run_id, _pid} <- WorkflowEngine.start_workflow(wf, inputs: %{"input" => name}) do
      # Fire-and-forget Fast-tier title humanization (machine-looking name ⇒ friendly).
      _ = TitleHumanizer.maybe_humanize_async(wf, socket.assigns.orchestrator_id)

      socket
      |> assign(adw_builder?: false, adw_steps: [], adw_name: "")
      |> put_flash(:info, "ADW launched — check the ADWS tab")
    else
      {:error, reason} -> put_flash(socket, :error, "Could not launch ADW: #{inspect(reason)}")
    end
  end

  # Routing is derived from the agent-filter set: exactly one active filter ⇒ route the
  # prompt to that single agent (the manual single-agent run); zero or multiple active
  # filters ⇒ route to the ORCHESTRATOR brain (issue-c), which chooses/creates/dispatches
  # workers. The hard "select an agent" gate is gone.
  @spec run_prompt(Phoenix.LiveView.Socket.t(), String.t(), String.t() | nil, String.t() | nil) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  defp run_prompt(socket, prompt, harness, model) do
    case single_active_agent(socket.assigns.active_agents) do
      nil ->
        {:noreply, run_orchestrator(socket, prompt)}

      agent_id ->
        run_selected_agent(socket, agent_id, prompt, harness, model)
    end
  end

  # Dispatch a single-agent run, but refuse a target that has been archived or removed
  # (issue agent-CRUD): a stale selection (archived in another tab/session) must not
  # start a session. Re-fetch at dispatch time so the guard reflects the DB, not the
  # possibly-stale rail.
  @spec run_selected_agent(
          Phoenix.LiveView.Socket.t(),
          String.t(),
          String.t(),
          String.t() | nil,
          String.t() | nil
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  defp run_selected_agent(socket, agent_id, prompt, harness, model) do
    case Agents.fetch_agent(agent_id) do
      {:ok, %Agent{archived: true} = agent} ->
        {:noreply,
         put_flash(socket, :error, "Agent #{agent.name} is archived and no longer available")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Agent is no longer available")}

      {:ok, %Agent{}} ->
        opts = [
          agent_id: agent_id,
          agent_db_id: agent_id,
          session_id: "console-#{System.unique_integer([:positive])}",
          harness: harness,
          prompt: prompt,
          model: model
        ]

        socket =
          socket
          |> push_user_message(prompt)
          |> start_session(opts)

        {:noreply, socket}
    end
  end

  # The lone active agent-filter id drives single-agent routing; zero or multiple
  # active filters fall back to the orchestrator (returns nil).
  @spec single_active_agent([String.t()]) :: String.t() | nil
  defp single_active_agent([id]), do: id
  defp single_active_agent(_active), do: nil

  @spec run_orchestrator(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  defp run_orchestrator(socket, prompt) do
    socket = push_user_message(socket, prompt)

    case socket.assigns.orchestrator_id do
      nil ->
        put_flash(socket, :error, "No orchestrator available")

      orchestrator_id ->
        case OrchestratorQueue.enqueue(orchestrator_id, prompt) do
          {:ok, :started, _agent_id} ->
            socket

          {:ok, :queued, position} ->
            put_flash(socket, :info, "Queued — will run next (position #{position})")

          {:error, :not_orchestrator_capable} ->
            put_flash(socket, :error, "Orchestrator harness can't orchestrate")

          {:error, :no_model_selected} ->
            put_flash(socket, :error, "No model selected — pick a model in the header")

          {:error, :queue_full} ->
            put_flash(socket, :error, "Message queue is full — wait for it to drain")

          {:error, _reason} ->
            put_flash(socket, :error, "Could not start the orchestrator")
        end
    end
  end

  # Run an orchestrator mutation (set_harness/provider/model) and re-reflect the full
  # selection in the header on success; flash on error. Shared by the three setters.
  @spec update_orchestrator(
          Phoenix.LiveView.Socket.t(),
          (Ecto.UUID.t() ->
             {:ok, RepoBuilder.Orchestrator.Orchestrator.t()} | {:error, term()}),
          String.t()
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  defp update_orchestrator(socket, mutate, error_message) do
    case socket.assigns.orchestrator_id do
      nil ->
        {:noreply, put_flash(socket, :error, "No orchestrator available")}

      id ->
        case mutate.(id) do
          {:ok, orchestrator} ->
            {:noreply, assign_orchestrator_selection(socket, orchestrator)}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, error_message)}
        end
    end
  end

  @spec assign_template_rows(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp assign_template_rows(socket), do: assign(socket, :template_rows, Templates.list())

  # Load a template's current version + version history into the editor assigns.
  # A missing template falls back to the blank-form state (flash on error).
  @spec select_template(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  defp select_template(socket, name) do
    case Templates.fetch(name) do
      {:ok, template} ->
        assign(socket, selected_template: template, template_versions: Templates.versions(name))

      {:error, _reason} ->
        socket
        |> assign(selected_template: nil, template_versions: [])
        |> put_flash(:error, "Template not found")
    end
  end

  @spec nilify_blank(String.t()) :: String.t() | nil
  defp nilify_blank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  # Validate + persist a working directory on the orchestrator (shared by the prompt
  # modal's CWD button, the Clear button, and the directory picker's "Use" action).
  @spec save_working_dir(Phoenix.LiveView.Socket.t(), String.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  defp save_working_dir(socket, dir) do
    case validate_working_dir(dir) do
      {:ok, working_dir} ->
        {:noreply, socket} =
          update_orchestrator(
            socket,
            &Orchestrators.set_working_dir(&1, working_dir),
            "Could not save working directory"
          )

        # Re-resolve the merged definitions for the new working dir: refresh/1 updates
        # the watcher's tracked dir + broadcasts to every console; the local re-seed
        # makes this console's chips update without waiting on the round-trip.
        :ok = Definitions.refresh(working_dir)
        {:noreply, seed_definitions(socket)}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  # Load one directory's listing into the picker assigns; flash + keep the prior view
  # on an unreadable/missing path so the picker never lands in a broken state.
  @spec load_dir_picker(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  defp load_dir_picker(socket, path) do
    case FileBrowser.list(path) do
      {:ok, listing} ->
        socket
        |> assign(:dir_picker_path, listing.path)
        |> assign(:dir_picker_parent, listing.parent)
        |> assign(:dir_picker_dirs, listing.dirs)

      {:error, _reason} ->
        put_flash(socket, :error, "Cannot open directory: #{path}")
    end
  end

  # Validate an operator-supplied working directory: blank ⇒ {:ok, nil} (clear it);
  # otherwise it must be an ABSOLUTE path to an EXISTING directory before we store it,
  # so a turn never spawns into a missing/relative cwd.
  @spec validate_working_dir(String.t()) :: {:ok, String.t() | nil} | {:error, String.t()}
  defp validate_working_dir(dir) when is_binary(dir) do
    case nilify_blank(dir) do
      nil ->
        {:ok, nil}

      path ->
        cond do
          not absolute_path?(path) ->
            {:error, "Working directory must be an absolute path"}

          not File.dir?(path) ->
            {:error, "Working directory does not exist: #{path}"}

          true ->
            {:ok, Path.expand(path)}
        end
    end
  end

  @spec absolute_path?(String.t()) :: boolean()
  defp absolute_path?(path), do: Path.type(path) == :absolute

  # Cascade an agent-models row change, driven by an *actual* value change against
  # the tier's currently-stored entry (`stored`) — not merely by which input fired.
  # Changing the harness clears provider+model; changing the provider clears model;
  # a no-op `change` event (LiveView reconnect reconciliation, or re-picking the same
  # option) preserves the stored downstream fields so a saved model is never wiped.
  @spec agent_model_attrs(map(), map()) :: %{optional(String.t()) => String.t() | nil}
  defp agent_model_attrs(%{"_target" => ["harness" | _]} = params, stored) do
    submitted = nilify_blank(params["harness"])

    if submitted == stored[:harness] do
      # Harness unchanged: spurious cascade. Keep the stored row intact.
      %{
        "harness" => stored[:harness],
        "provider" => stored[:provider],
        "model" => stored[:model]
      }
    else
      %{"harness" => submitted, "provider" => nil, "model" => nil}
    end
  end

  defp agent_model_attrs(%{"_target" => ["provider" | _]} = params, stored) do
    submitted = nilify_blank(params["provider"])

    %{
      "harness" => nilify_blank(params["harness"]),
      "provider" => submitted,
      # Provider unchanged: keep the stored model; otherwise clear the now-invalid model.
      "model" => if(submitted == stored[:provider], do: stored[:model], else: nil)
    }
  end

  defp agent_model_attrs(params, _stored) do
    %{
      "harness" => nilify_blank(params["harness"]),
      "provider" => nilify_blank(params["provider"]),
      "model" => nilify_blank(params["model"])
    }
  end

  @spec push_user_message(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  defp push_user_message(socket, ""), do: socket

  defp push_user_message(socket, prompt) do
    seq = socket.assigns.seq + 1
    msg = %{role: :user, label: "YOU", content: prompt, tool_name: nil, params_json: nil}

    socket
    |> assign(:seq, seq)
    |> assign(:messages, append_chat(socket.assigns.messages, msg, seq, socket.assigns.timezone))
  end

  @spec start_session(Phoenix.LiveView.Socket.t(), keyword()) :: Phoenix.LiveView.Socket.t()
  defp start_session(socket, opts) do
    case Session.Supervisor.start_session(opts) do
      {:ok, _pid} -> socket
      {:error, :at_capacity} -> put_flash(socket, :error, "At capacity — wait for a slot to free")
      {:error, _reason} -> put_flash(socket, :error, "Could not start the session")
    end
  end

  @spec toggle_view(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp toggle_view(socket) do
    assign(socket, :view_mode, if(socket.assigns.view_mode == :logs, do: :adws, else: :logs))
  end

  # --- event / lane handlers (one clause per canonical variant) ---

  # Ephemeral explain result (issue-explain): ignore a superseded request (a second
  # EXPLAIN issued while one was running); otherwise flip the modal to its result.
  @impl true
  def handle_info({:explain_result, request_id, result}, socket) do
    if socket.assigns.explain.request_id == request_id do
      status =
        case result do
          {:ok, text} -> {:ready, text}
          {:error, reason} -> {:error, explain_error_message(reason)}
        end

      {:noreply, assign(socket, :explain, %{socket.assigns.explain | status: status})}
    else
      {:noreply, socket}
    end
  end

  # Budget guardrails: any breaker event re-seeds the snapshot + caps so the panel,
  # banner, and badge re-render live (issue-budget-guardrails).
  def handle_info({:budget_tripped, _cap, _spent}, socket), do: {:noreply, refresh_budget(socket)}
  def handle_info({:budget_warning, _cap, _spent}, socket), do: {:noreply, refresh_budget(socket)}
  def handle_info({:budget_reset, _cap}, socket), do: {:noreply, refresh_budget(socket)}
  def handle_info({:kill_switch, _state}, socket), do: {:noreply, refresh_budget(socket)}

  def handle_info({:agent_event, agent_id, %Event.SessionStarted{} = event, log_no}, socket) do
    {:noreply,
     socket
     |> set_status(agent_id, :running)
     |> record_event(
       agent_id,
       %{
         category: :system,
         kind: "session",
         body: "session #{event.session_id}",
         render: EventPresenter.from_event(event),
         payload: event.raw
       },
       log_no
     )}
  end

  # Incremental token delta — coalesce into the per-agent streaming buffer (no
  # center-log row, no per-token counter); a throttled flush commits it to render.
  def handle_info(
        {:agent_event, agent_id, %Event.TextDelta{partial?: true} = event, _log_no},
        socket
      ) do
    # Only the orchestrator's in-flight text feeds the chat streaming buffer; worker
    # partials are dropped here (their finalized text still lands in the center stream).
    if orchestrator_event?(agent_id) do
      {:noreply, accumulate_partial(socket, agent_id, channel(event.thinking?), event.text)}
    else
      {:noreply, socket}
    end
  end

  # Finalized thinking block — clear the in-flight thinking buffer, then record the
  # one permanent thinking message + center row.
  def handle_info(
        {:agent_event, agent_id, %Event.TextDelta{thinking?: true} = event, log_no},
        socket
      ) do
    socket = finalize_stream_channel(socket, agent_id, :thinking)

    {:noreply,
     record_event(
       socket,
       agent_id,
       %{
         category: :thinking,
         kind: "thinking",
         body: event.text,
         render: EventPresenter.from_event(event),
         thinking?: true,
         payload: event.raw
       },
       log_no
     )}
  end

  # Finalized text block — clear the in-flight text buffer, then record the one
  # permanent orchestrator message + center row.
  def handle_info({:agent_event, agent_id, %Event.TextDelta{} = event, log_no}, socket) do
    socket = finalize_stream_channel(socket, agent_id, :text)

    chat =
      if orchestrator_event?(agent_id) do
        %{
          role: :orchestrator,
          label: "ORCHESTRATOR",
          content: event.text,
          tool_name: nil,
          params_json: nil
        }
      end

    {:noreply,
     record_event(
       socket,
       agent_id,
       %{
         category: :response,
         kind: "text",
         body: event.text,
         render: EventPresenter.from_event(event),
         payload: event.raw,
         chat: chat
       },
       log_no
     )}
  end

  # Throttled flush tick: commit accumulated partials into the rendered streaming
  # map (one render), drain pending, and clear the timer so the next partial reschedules.
  def handle_info(:flush_stream, socket) do
    streaming = merge_pending(socket.assigns.streaming, socket.assigns.stream_pending)

    {:noreply, assign(socket, streaming: streaming, stream_pending: %{}, stream_flush_ref: nil)}
  end

  def handle_info({:agent_event, agent_id, %Event.ToolCall{} = event, log_no}, socket) do
    render = EventPresenter.from_event(event)

    {:noreply,
     record_event(
       socket,
       agent_id,
       %{
         category: :tool,
         kind: "tool_call",
         body: EventPresenter.search_text(render),
         render: render,
         payload: event.raw
       },
       log_no
     )}
  end

  def handle_info({:agent_event, agent_id, %Event.ToolResult{} = event, log_no}, socket) do
    render = EventPresenter.from_event(event)

    {:noreply,
     record_event(
       socket,
       agent_id,
       %{
         category: :tool,
         kind: "tool_result",
         body: EventPresenter.search_text(render),
         render: render,
         payload: event.raw
       },
       log_no
     )}
  end

  def handle_info({:agent_event, agent_id, %Event.Usage{} = event, log_no}, socket) do
    {:noreply,
     socket
     |> add_cost(event.cost_usd)
     |> add_owned_cost(agent_id, event.cost_usd)
     |> put_owned_estimate(agent_id, event.estimated_cost_usd)
     |> put_context(agent_id, context_size(event))
     |> record_event(
       agent_id,
       %{
         category: :system,
         kind: "usage",
         body: "in=#{event.input_tokens} out=#{event.output_tokens}",
         render: EventPresenter.from_event(event),
         tokens: "#{event.input_tokens + event.output_tokens}t",
         payload: event.raw
       },
       log_no
     )}
  end

  def handle_info({:agent_event, agent_id, %Event.Status{} = event, log_no}, socket) do
    render = EventPresenter.from_event(event)

    {:noreply,
     record_event(
       socket,
       agent_id,
       %{
         category: :hook,
         kind: "status",
         body: EventPresenter.search_text(render),
         render: render,
         payload: event.raw
       },
       log_no
     )}
  end

  def handle_info({:agent_event, agent_id, %Event.Done{} = event, log_no}, socket) do
    status = if event.ok, do: :succeeded, else: :failed

    {:noreply,
     socket
     |> flush_streaming_agent(agent_id)
     |> set_status(agent_id, status)
     |> add_cost(event.cost_usd)
     |> add_owned_cost(agent_id, event.cost_usd)
     |> record_event(
       agent_id,
       %{
         category: :system,
         kind: "done",
         body: "reason=#{event.reason}",
         render: EventPresenter.from_event(event),
         payload: event.raw
       },
       log_no
     )}
  end

  def handle_info({:agent_event, agent_id, %Event.Error{} = event, log_no}, socket) do
    {:noreply,
     socket
     |> flush_streaming_agent(agent_id)
     |> set_status(agent_id, :error)
     |> record_event(
       agent_id,
       %{
         category: :system,
         kind: "error",
         body: "#{event.reason}: #{event.message}",
         render: EventPresenter.from_event(event),
         payload: event.raw
       },
       log_no
     )}
  end

  # A worker the orchestrator just created (issue-c): add it to the rail roster +
  # the swimlane stream live. Additive seam — not a canonical Event variant.
  def handle_info({:agent_created, %Agent{} = agent}, socket) do
    if Enum.any?(socket.assigns.agents, &(&1.id == agent.id)) do
      {:noreply, socket}
    else
      lane = %{
        id: "agent:#{agent.id}",
        kind: :agent,
        label: agent.name,
        status: agent.status,
        harness: agent.harness
      }

      {:noreply,
       socket
       |> assign(:agents, socket.assigns.agents ++ [agent])
       |> assign(:agent_names, Map.put(socket.assigns.agent_names, agent.id, agent.name))
       |> assign(:statuses, Map.put(socket.assigns.statuses, agent.id, agent.status))
       |> stream_insert(:lanes, lane)}
    end
  end

  def handle_info(:clear_agent_model_saved, socket) do
    {:noreply, assign(socket, :agent_model_saved, false)}
  end

  def handle_info(:clear_release_notice, socket) do
    {:noreply, assign(socket, :release_notice, nil)}
  end

  # Live queue snapshot (issue message-queue): re-render the queued strip in place.
  def handle_info({:orchestrator_queue, id, snapshot}, socket) do
    if id == socket.assigns.orchestrator_id do
      {:noreply, assign(socket, :orchestrator_queue, snapshot)}
    else
      {:noreply, socket}
    end
  end

  # File-driven prompt palette: a watched definition file was added/edited/removed.
  # Update only the single matching assign so an open console re-renders that chip
  # row with no restart and no panel re-open.
  def handle_info({:definitions_changed, :slash_command, list}, socket) do
    {:noreply, assign(socket, :slash_commands, list)}
  end

  def handle_info({:definitions_changed, :agent, list}, socket) do
    {:noreply, assign(socket, :agent_defs, list)}
  end

  def handle_info({:definitions_changed, :adw, list}, socket) do
    {:noreply, assign(socket, :adws, list)}
  end

  def handle_info({:orchestrator_updated, orchestrator}, socket) do
    if orchestrator.id == socket.assigns.orchestrator_id do
      # A timezone change from another tab/session must re-format already-rendered rows.
      tz_changed? = Orchestrators.timezone(orchestrator) != socket.assigns.timezone
      socket = assign_orchestrator_selection(socket, orchestrator)
      socket = if tz_changed?, do: backfill_events(socket), else: socket
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # A worker the orchestrator updated in place (e.g. `clear_context` reset it to
  # idle): refresh its status in the rail roster + swimlane row live. Idempotent for
  # an unknown worker (the lane is re-inserted by stable id).
  def handle_info({:agent_updated, %Agent{} = agent}, socket) do
    lane = %{
      id: "agent:#{agent.id}",
      kind: :agent,
      label: agent.name,
      status: agent.status,
      harness: agent.harness
    }

    {:noreply,
     socket
     |> assign(
       :agents,
       Enum.map(socket.assigns.agents, fn a -> if a.id == agent.id, do: agent, else: a end)
     )
     |> assign(:statuses, Map.put(socket.assigns.statuses, agent.id, agent.status))
     |> stream_insert(:lanes, lane)}
  end

  # A worker the orchestrator just deleted (issue agent-CRUD): drop it from the
  # rail roster + the swimlane stream live. Idempotent for an already-absent worker.
  def handle_info({:agent_deleted, %Agent{} = agent}, socket) do
    # A worker delete is a hard `Repo.delete`; the `agent_logs.agent_id` FK is
    # `on_delete: :delete_all`, so the durable side cascade-removes the worker's spend.
    # Reconcile the live total to match (Option A): subtract the worker's cost/estimate
    # and drop its per-agent entries, so `Σ workers + orchestrator == total` stays equal
    # to what a reconnect/reseed would compute. The orchestrator-own assign is unaffected.
    removed = Map.get(socket.assigns.agent_costs, agent.id)
    removed_est = Map.get(socket.assigns.agent_est_costs, agent.id)

    {:noreply,
     socket
     |> assign(:agents, Enum.reject(socket.assigns.agents, &(&1.id == agent.id)))
     |> assign(:agent_names, Map.delete(socket.assigns.agent_names, agent.id))
     |> assign(:statuses, Map.delete(socket.assigns.statuses, agent.id))
     |> assign(:cost, subtract_cost(socket.assigns.cost, removed))
     |> assign(:cost_estimate, subtract_cost(socket.assigns.cost_estimate, removed_est))
     |> assign(:agent_costs, Map.delete(socket.assigns.agent_costs, agent.id))
     |> assign(:agent_est_costs, Map.delete(socket.assigns.agent_est_costs, agent.id))
     |> stream_delete(:lanes, %{id: "agent:#{agent.id}"})}
  end

  # Workflow lanes drive the per-step swimlane (status/current step), not the flat
  # lane stream. Update the matching `@workflow_progress` view in place.
  def handle_info({:lane, %{kind: :workflow} = lane}, socket) do
    {:noreply, update_workflow_status(socket, lane)}
  end

  def handle_info({:lane, lane}, socket) do
    # Stable dom_id (lane.id) ⇒ re-inserting the same lane REPLACES the row in place.
    {:noreply, stream_insert(socket, :lanes, lane)}
  end

  # Per-step progress for a run (from BOTH the live Runner and the durable
  # StepWorker, via the shared engine seam): merge the per-step view in place.
  def handle_info({:workflow_step, run_id, progress}, socket) do
    {:noreply, update_workflow_steps(socket, run_id, progress)}
  end

  # Fast-tier humanized title for every view of `workflow_id`: swap the heuristic card
  # title for the friendly one in place (issue-unified-adw-swimlane-cards).
  def handle_info({:workflow_title, workflow_id, title}, socket) do
    progress =
      Map.new(socket.assigns.workflow_progress, fn {run_id, view} ->
        if view.workflow_id == workflow_id,
          do: {run_id, Map.put(view, :title, title)},
          else: {run_id, view}
      end)

    {:noreply, assign(socket, :workflow_progress, progress)}
  end

  # The single hot path: append to the bounded buffer, bump pills + counters, push
  # into the stream only if the row passes the active filters, and append a chat
  # entry where one applies.
  # Inference-only spec — dialyzer narrows `attrs` to the specific per-variant map
  # shapes, which a hand-written map() spec would supertype under :underspecs.
  # `log_no` is the persisted row's DURABLE `log-<n>` number (nil for non-persisted
  # shards), distinct from the in-memory per-socket `seq` that ids/orders the stream row.
  defp record_event(socket, agent_id, attrs, log_no) do
    seq = socket.assigns.seq + 1

    row = %{
      id: seq,
      line: seq,
      log_no: log_no,
      agent: agent_label(socket, agent_id),
      agent_key: agent_id,
      color: AgentColors.hex(to_string(agent_id)),
      category: attrs.category,
      kind: attrs.kind,
      body: to_string(attrs.body),
      # The presenter render model drives the structured card; the single source of truth
      # shared with the backfill path (log_to_row) so live + reconnect render identically.
      render: Map.get(attrs, :render, empty_render(attrs)),
      thinking?: Map.get(attrs, :thinking?, false),
      tokens: Map.get(attrs, :tokens),
      time: now_hms(socket.assigns.timezone),
      payload_json: pretty_json(Map.get(attrs, :payload, %{}))
    }

    buffer = Enum.take(socket.assigns.event_buffer ++ [row], -@buffer_limit)

    socket =
      socket
      |> assign(:seq, seq)
      |> assign(:event_buffer, buffer)
      |> assign(:log_count, socket.assigns.log_count + 1)
      |> assign(:ws_count, socket.assigns.ws_count + 1)
      |> assign(:pulsed_id, agent_id)
      |> bump_counter(agent_id, attrs.category)
      |> maybe_stream_insert(row)
      |> maybe_chat(Map.get(attrs, :chat), seq)

    socket
  end

  # Defensive fallback render model for a row whose attrs omit `:render` (every live
  # handler supplies one; this keeps a missing key from crashing the stream).
  # Inference-only spec — dialyzer narrows `attrs` to the concrete per-variant map shape,
  # which a hand-written `map()` spec would supertype under :underspecs.
  defp empty_render(attrs) do
    %{
      summary: to_string(Map.get(attrs, :body, "")),
      preview: nil,
      detail: nil,
      tool_name: nil,
      error?: false,
      files: []
    }
  end

  # Inference-only spec — the row map is narrowed to its concrete shape (:underspecs).
  defp maybe_stream_insert(socket, row) do
    if passes?(row, socket.assigns) do
      stream_insert(socket, :events, row, at: -1, limit: -@buffer_limit)
    else
      socket
    end
  end

  @spec maybe_chat(Phoenix.LiveView.Socket.t(), map() | nil, pos_integer()) ::
          Phoenix.LiveView.Socket.t()
  defp maybe_chat(socket, nil, _seq), do: socket

  defp maybe_chat(socket, chat, seq),
    do:
      assign(
        socket,
        :messages,
        append_chat(socket.assigns.messages, chat, seq, socket.assigns.timezone)
      )

  @spec append_chat([map()], map() | nil, pos_integer(), String.t()) :: [map()]
  defp append_chat(messages, nil, _seq, _timezone), do: messages

  defp append_chat(messages, chat, seq, timezone) do
    entry = Map.merge(chat, %{id: seq, time: now_hm(timezone)})
    Enum.take(messages ++ [entry], -@messages_limit)
  end

  # --- live streaming buffer (partials coalesced per agent + channel) -------

  # The chat pane is orchestrator ↔ user only. Orchestrator turns broadcast under an
  # `"orch-#{orchestrator_id}-#{n}"` agent_id (orchestrator/server.ex:85,113); worker
  # DB agents broadcast under their Ecto UUID (never `"orch-"`). Gate every chat-pane
  # surface on this so worker text stays in the center event stream, not the chat.
  @spec orchestrator_event?(String.t()) :: boolean()
  defp orchestrator_event?(agent_id), do: String.starts_with?(to_string(agent_id), "orch-")

  @spec channel(boolean()) :: :text | :thinking
  defp channel(true), do: :thinking
  defp channel(false), do: :text

  # Append an incremental token to the agent's pending buffer for `channel` and
  # ensure a flush tick is scheduled.
  @spec accumulate_partial(
          Phoenix.LiveView.Socket.t(),
          String.t(),
          :text | :thinking,
          String.t()
        ) :: Phoenix.LiveView.Socket.t()
  defp accumulate_partial(socket, agent_id, channel, text) do
    pending = socket.assigns.stream_pending
    agent = Map.get(pending, agent_id, %{text: "", thinking: ""})
    agent = Map.update!(agent, channel, &(&1 <> text))

    socket
    |> assign(:stream_pending, Map.put(pending, agent_id, agent))
    |> schedule_flush()
  end

  @spec schedule_flush(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp schedule_flush(socket) do
    if socket.assigns.stream_flush_ref do
      socket
    else
      ref = Process.send_after(self(), :flush_stream, @stream_flush_ms)
      assign(socket, :stream_flush_ref, ref)
    end
  end

  # Fold each agent's pending text/thinking onto the already-rendered streaming map.
  @spec merge_pending(map(), map()) :: map()
  defp merge_pending(streaming, pending) do
    Enum.reduce(pending, streaming, fn {agent_id, p}, acc ->
      cur = Map.get(acc, agent_id, %{text: "", thinking: ""})
      Map.put(acc, agent_id, %{text: cur.text <> p.text, thinking: cur.thinking <> p.thinking})
    end)
  end

  # The finalized block for a channel arrived: drop that channel from both the
  # rendered and pending buffers (removing the agent entirely once both are empty),
  # so the live bubble vanishes and only the finalized message remains.
  @spec finalize_stream_channel(Phoenix.LiveView.Socket.t(), String.t(), :text | :thinking) ::
          Phoenix.LiveView.Socket.t()
  defp finalize_stream_channel(socket, agent_id, channel) do
    socket
    |> clear_stream_channel(:streaming, agent_id, channel)
    |> clear_stream_channel(:stream_pending, agent_id, channel)
  end

  @spec clear_stream_channel(
          Phoenix.LiveView.Socket.t(),
          :streaming | :stream_pending,
          String.t(),
          :text | :thinking
        ) :: Phoenix.LiveView.Socket.t()
  defp clear_stream_channel(socket, key, agent_id, channel) do
    map = Map.fetch!(socket.assigns, key)

    case Map.get(map, agent_id) do
      nil ->
        socket

      agent ->
        cleared = Map.put(agent, channel, "")

        map =
          if cleared.text == "" and cleared.thinking == "",
            do: Map.delete(map, agent_id),
            else: Map.put(map, agent_id, cleared)

        assign(socket, key, map)
    end
  end

  # Safety net for a partial-only stream (no finalizing block): on Done/Error,
  # promote any leftover buffered text/thinking into `@messages` once, then clear
  # the agent's buffers so no orphan streaming bubble lingers.
  @spec flush_streaming_agent(Phoenix.LiveView.Socket.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  defp flush_streaming_agent(socket, agent_id) do
    s = Map.get(socket.assigns.streaming, agent_id, %{text: "", thinking: ""})
    p = Map.get(socket.assigns.stream_pending, agent_id, %{text: "", thinking: ""})
    leftover = %{text: s.text <> p.text, thinking: s.thinking <> p.thinking}

    timezone = socket.assigns.timezone

    {messages, seq} =
      {socket.assigns.messages, socket.assigns.seq}
      |> promote_channel(leftover.text, :text, timezone)
      |> promote_channel(leftover.thinking, :thinking, timezone)

    socket
    |> assign(:messages, messages)
    |> assign(:seq, seq)
    |> assign(:streaming, Map.delete(socket.assigns.streaming, agent_id))
    |> assign(:stream_pending, Map.delete(socket.assigns.stream_pending, agent_id))
  end

  @spec promote_channel({[map()], non_neg_integer()}, String.t(), :text | :thinking, String.t()) ::
          {[map()], non_neg_integer()}
  defp promote_channel({messages, seq}, text, channel, timezone) do
    if String.trim(text) == "" do
      {messages, seq}
    else
      seq = seq + 1
      {append_chat(messages, stream_chat(channel, text), seq, timezone), seq}
    end
  end

  # Inference-only spec — the fixed-shape chat map narrows below a hand-written
  # `map()` spec, which Dialyzer rejects as a supertype under :underspecs.
  defp stream_chat(:text, text),
    do: %{
      role: :orchestrator,
      label: "ORCHESTRATOR",
      content: text,
      tool_name: nil,
      params_json: nil
    }

  defp stream_chat(:thinking, text),
    do: %{role: :thinking, label: nil, content: text, tool_name: nil, params_json: nil}

  @spec restream(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp restream(socket) do
    filtered = Enum.filter(socket.assigns.event_buffer, &passes?(&1, socket.assigns))
    stream(socket, :events, filtered, reset: true)
  end

  @spec passes?(map(), map()) :: boolean()
  defp passes?(row, assigns) do
    category_pass?(row, assigns.active_categories) and
      agent_pass?(row, assigns.active_agents) and
      search_pass?(row.body, assigns.search, assigns.regex?)
  end

  @spec category_pass?(map(), MapSet.t()) :: boolean()
  defp category_pass?(%{category: :system}, _active), do: true
  defp category_pass?(%{category: category}, active), do: MapSet.member?(active, category)

  @spec agent_pass?(map(), [String.t()]) :: boolean()
  defp agent_pass?(_row, []), do: true
  defp agent_pass?(row, active), do: row.agent_key in active

  @spec search_pass?(String.t(), String.t(), boolean()) :: boolean()
  defp search_pass?(_body, "", _regex?), do: true

  defp search_pass?(body, query, true) do
    case Regex.compile(query, "i") do
      {:ok, re} -> Regex.match?(re, body)
      {:error, _reason} -> substring?(body, query)
    end
  end

  defp search_pass?(body, query, false), do: substring?(body, query)

  @spec substring?(String.t(), String.t()) :: boolean()
  defp substring?(body, query),
    do: String.contains?(String.downcase(body), String.downcase(query))

  @spec bump_counter(Phoenix.LiveView.Socket.t(), String.t(), atom()) ::
          Phoenix.LiveView.Socket.t()
  defp bump_counter(socket, agent_id, category) when category in @categories do
    counters = socket.assigns.counters
    current = Map.get(counters, agent_id, %{responses: 0, tools: 0, thinking: 0, hooks: 0})
    key = counter_key(category)
    updated = Map.update!(current, key, &(&1 + 1))
    assign(socket, :counters, Map.put(counters, agent_id, updated))
  end

  defp bump_counter(socket, _agent_id, _category), do: socket

  @spec counter_key(:response | :tool | :thinking | :hook) ::
          :responses | :tools | :thinking | :hooks
  defp counter_key(:response), do: :responses
  defp counter_key(:tool), do: :tools
  defp counter_key(:thinking), do: :thinking
  defp counter_key(:hook), do: :hooks

  # Context-window occupancy of a live usage event: the prompt side only
  # (`input + cache_read + cache_creation`, nil-safe). `cache_read` dominates a
  # resumed Claude prompt, so counting only `input+output` left the bar dead for
  # exactly the long sessions where it matters. Mirrors `Logs.context_size/1`.
  @spec context_size(Event.Usage.t()) :: non_neg_integer()
  defp context_size(%Event.Usage{} = event) do
    nz(event.input_tokens) + nz(event.cache_read) + nz(event.cache_creation)
  end

  # Nil-safe non-negative-integer coalesce; the guard keeps the sum integral so the
  # context bar's `non_neg_integer()` contract holds (cache fields may be nil).
  @spec nz(integer() | nil) :: non_neg_integer()
  defp nz(n) when is_integer(n) and n >= 0, do: n
  defp nz(_n), do: 0

  @spec put_context(Phoenix.LiveView.Socket.t(), String.t(), non_neg_integer()) ::
          Phoenix.LiveView.Socket.t()
  defp put_context(socket, agent_id, tokens),
    do: assign(socket, :context_tokens, Map.put(socket.assigns.context_tokens, agent_id, tokens))

  @spec set_status(Phoenix.LiveView.Socket.t(), String.t(), atom()) :: Phoenix.LiveView.Socket.t()
  defp set_status(socket, agent_id, status) do
    assign(socket, :statuses, Map.put(socket.assigns.statuses, agent_id, status))
  end

  @spec add_cost(Phoenix.LiveView.Socket.t(), float() | nil) :: Phoenix.LiveView.Socket.t()
  defp add_cost(socket, cost_usd) do
    assign(socket, :cost, accumulate_cost(socket.assigns.cost, cost_usd))
  end

  @spec add_agent_cost(Phoenix.LiveView.Socket.t(), String.t(), float() | nil) ::
          Phoenix.LiveView.Socket.t()
  defp add_agent_cost(socket, _agent_id, nil), do: socket

  defp add_agent_cost(socket, agent_id, cost_usd) do
    costs = socket.assigns.agent_costs
    updated = accumulate_cost(Map.get(costs, agent_id), cost_usd)
    assign(socket, :agent_costs, Map.put(costs, agent_id, updated))
  end

  # Route owner-scoped cost accumulation: an orchestrator's own turn carries the
  # synthetic `"orch-<id>-<n>"` agent_id (minted in `Orchestrator.Server.do_start_turn/2`,
  # server.ex:153), so it accumulates into the single `:orchestrator_cost` assign; a real
  # worker (UUID agent_id) accumulates into its `:agent_costs` entry. The grand-total
  # `add_cost/2` still runs for every event upstream.
  @spec add_owned_cost(Phoenix.LiveView.Socket.t(), String.t(), float() | nil) ::
          Phoenix.LiveView.Socket.t()
  defp add_owned_cost(socket, agent_id, cost_usd) do
    if orchestrator_owned?(agent_id),
      do: add_orchestrator_cost(socket, cost_usd),
      else: add_agent_cost(socket, agent_id, cost_usd)
  end

  @spec add_orchestrator_cost(Phoenix.LiveView.Socket.t(), float() | nil) ::
          Phoenix.LiveView.Socket.t()
  defp add_orchestrator_cost(socket, nil), do: socket

  defp add_orchestrator_cost(socket, cost_usd) do
    assign(
      socket,
      :orchestrator_cost,
      accumulate_cost(socket.assigns.orchestrator_cost, cost_usd)
    )
  end

  # An orchestrator-owned live event keys off the `"orch-"` agent_id prefix
  # (`Orchestrator.Server`, server.ex:101/:153). A worker's binary-id agent_id is a UUID
  # and never starts with `"orch-"`, so this predicate is unambiguous.
  @spec orchestrator_owned?(String.t()) :: boolean()
  defp orchestrator_owned?(agent_id) when is_binary(agent_id),
    do: String.starts_with?(agent_id, "orch-")

  defp orchestrator_owned?(_agent_id), do: false

  # nil never coerced to 0 (preserves the unpriced distinction); a float crosses the
  # float→Decimal boundary here, a Decimal (seed rollup) accumulates directly.
  @spec accumulate_cost(Decimal.t() | nil, Decimal.t() | float() | nil) :: Decimal.t() | nil
  defp accumulate_cost(current, nil), do: current

  defp accumulate_cost(current, %Decimal{} = cost),
    do: Decimal.add(current || Decimal.new(0), cost)

  defp accumulate_cost(current, cost) when is_float(cost),
    do: accumulate_cost(current, Decimal.from_float(cost))

  # Record an agent's latest live cost ESTIMATE (REPLACE-latest, NOT additive — the
  # estimate is a running snapshot, never summed into `agent_costs`). A nil estimate
  # (unpriced model) leaves the prior estimate untouched. Recomputes the global estimate
  # as the sum of all per-agent latest estimates.
  @spec put_agent_estimate(Phoenix.LiveView.Socket.t(), String.t(), float() | nil) ::
          Phoenix.LiveView.Socket.t()
  defp put_agent_estimate(socket, _agent_id, nil), do: socket

  defp put_agent_estimate(socket, agent_id, estimate) when is_float(estimate) do
    estimates = Map.put(socket.assigns.agent_est_costs, agent_id, Decimal.from_float(estimate))

    global =
      Enum.reduce(estimates, nil, fn {_id, est}, acc -> accumulate_cost(acc, est) end)

    socket
    |> assign(:agent_est_costs, estimates)
    |> assign(:cost_estimate, global)
  end

  # Route the live ESTIMATE by owner (panel parity): an orchestrator turn updates the
  # orchestrator-own replace-latest estimate; a worker turn the per-agent map. This stops
  # each unique synthetic `"orch-…"` key from leaving stale per-turn entries that would
  # over-sum the worker estimate.
  @spec put_owned_estimate(Phoenix.LiveView.Socket.t(), String.t(), float() | nil) ::
          Phoenix.LiveView.Socket.t()
  defp put_owned_estimate(socket, agent_id, estimate) do
    if orchestrator_owned?(agent_id),
      do: put_orchestrator_estimate(socket, estimate),
      else: put_agent_estimate(socket, agent_id, estimate)
  end

  # The orchestrator's latest own estimate (REPLACE-latest Decimal; nil leaves the prior
  # untouched, mirroring `put_agent_estimate/3`).
  @spec put_orchestrator_estimate(Phoenix.LiveView.Socket.t(), float() | nil) ::
          Phoenix.LiveView.Socket.t()
  defp put_orchestrator_estimate(socket, nil), do: socket

  defp put_orchestrator_estimate(socket, estimate) when is_float(estimate) do
    assign(socket, :orchestrator_est_cost, Decimal.from_float(estimate))
  end

  # Subtract a removed worker's contribution from a running total (mirrors
  # `accumulate_cost/2`): nil subtrahend ⇒ no-op; a residual <= 0 collapses back to nil to
  # preserve the unpriced "—" convention (consistent with `nilify_acc/1`).
  @spec subtract_cost(Decimal.t() | nil, Decimal.t() | nil) :: Decimal.t() | nil
  defp subtract_cost(current, nil), do: current
  defp subtract_cost(nil, %Decimal{}), do: nil

  defp subtract_cost(%Decimal{} = current, %Decimal{} = amount) do
    result = Decimal.sub(current, amount)
    if Decimal.compare(result, 0) == :gt, do: result, else: nil
  end

  # --- render ---

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :swimlanes, agent_swimlanes(assigns))

    ~H"""
    <div class="console flex h-screen flex-col" data-theme="dark">
      <h1 class="sr-only">Repo Builder orchestration console</h1>
      <Layouts.flash_group flash={@flash} />

      <.header_bar
        connected?={@connected?}
        agent_count={length(@agents)}
        running_count={running_count(@statuses)}
        log_count={@log_count}
        ws_count={@ws_count}
        cost={@cost}
        view_mode={@view_mode}
        orchestrator_harness={@orchestrator_harness}
        orchestrating_harnesses={orchestrator_harness_options()}
        orchestrator_provider={@orchestrator_provider}
        orchestrator_model={@orchestrator_model}
        provider_options={@provider_options}
        model_options={@model_options}
        recent_models={@recent_models}
      />

      <.budget_banner state={@budget_state} />

      <div
        class="grid min-h-0 flex-1"
        style={"grid-template-columns: #{rail_width(@rail_collapsed?)} 1fr #{chat_col(@chat_width)}"}
      >
        <aside
          aria-label="Agents"
          class="flex min-h-0 flex-col gap-2 overflow-y-auto border-r p-2"
          style="border-color: var(--cns-border)"
        >
          <div class="flex items-center justify-between">
            <span class="text-[0.625rem] font-semibold uppercase" style="color: var(--cns-text-2)">
              Agents · {length(@agents)}
            </span>
            <div class="flex items-center gap-1">
              <button
                id="show-new-agent"
                type="button"
                phx-click="show_new_agent"
                class="cns-chip"
                title="Create a new agent (owned by this orchestrator)"
              >
                + New
              </button>
              <button
                id="toggle-rail"
                type="button"
                phx-click="toggle_rail"
                class="cns-chip"
                title="Collapse"
              >
                {if @rail_collapsed?, do: "»", else: "«"}
              </button>
            </div>
          </div>

          <.agent_form
            :if={@show_new_agent?}
            id="new-agent-form"
            form={@agent_form}
            submit="create_agent"
            change="validate_agent"
            cancel="cancel_new_agent"
            title="New agent"
            submit_label="Create"
            harness_options={@harness_options}
          />

          <.agent_form
            :if={@editing_agent_id}
            id="edit-agent-form"
            form={@edit_agent_form}
            submit="update_agent"
            change="validate_edit_agent"
            cancel="cancel_edit_agent"
            title="Edit agent"
            submit_label="Save"
            harness_options={@harness_options}
          />

          <div id="agent-rail" class="flex flex-col gap-2">
            <%= for agent <- @agents do %>
              <%= if @rail_collapsed? do %>
                <.agent_rail_compact
                  id={agent.id}
                  name={agent.name}
                  status={Map.get(@statuses, agent.id, agent.status)}
                  color={AgentColors.hex(agent.id)}
                  selected?={agent.id in @active_agents}
                  pulse?={@pulsed_id == agent.id}
                  active?={Map.get(@statuses, agent.id, agent.status) == :running}
                />
              <% else %>
                <.agent_card
                  id={agent.id}
                  name={agent.name}
                  status={Map.get(@statuses, agent.id, agent.status)}
                  harness={agent.harness}
                  model={agent.model}
                  cost={Map.get(@agent_costs, agent.id)}
                  estimate={Map.get(@agent_est_costs, agent.id)}
                  color={AgentColors.hex(agent.id)}
                  selected?={agent.id in @active_agents}
                  pulse?={@pulsed_id == agent.id}
                  active?={Map.get(@statuses, agent.id, agent.status) == :running}
                  context_tokens={Map.get(@context_tokens, agent.id, 0)}
                  responses={counter(@counters, agent.id, :responses)}
                  tools={counter(@counters, agent.id, :tools)}
                  hooks={counter(@counters, agent.id, :hooks)}
                  thinking={counter(@counters, agent.id, :thinking)}
                />
              <% end %>
            <% end %>
            <p :if={@agents == []} class="px-1 py-1 text-xs" style="color: var(--cns-text-3)">
              No agents yet.
            </p>
          </div>
        </aside>

        <main class="flex min-h-0 flex-col overflow-hidden">
          <%!-- Both stream containers stay mounted (toggled via `hidden`): a
          `phx-update="stream"` container must exist when items are inserted, else
          rows pushed while it was absent are dropped on the next render cycle. --%>
          <%!-- LogCopy hosts here (not on #event-stream-wrap, which already owns the
          single permitted phx-hook DragSelect): it delegates from `.cns-event-row__ln`
          cells via document listeners, so a stable ancestor of the stream suffices. --%>
          <div
            id="logs-pane"
            phx-hook="LogCopy"
            class={["flex min-h-0 flex-1 flex-col", @view_mode != :logs && "hidden"]}
          >
            <.filter_bar
              active_categories={@active_categories}
              active_agents={@active_agents}
              agent_names={@agent_names}
              search={@search}
              regex?={@regex?}
              auto_follow?={@auto_follow?}
            />
            <.selection_bar
              selected_count={MapSet.size(@selected_ids)}
              copy_payload={selected_copy_payload(@event_buffer, @selected_ids)}
            />
            <%!-- DragSelect owns this STABLE wrapper (display:contents), not the
              phx-update="stream" node: one phx-hook per element, and AutoScroll must keep
              #event-stream. The hook reads row ids from each checkbox's data-row-id. --%>
            <div id="event-stream-wrap" phx-hook="DragSelect" class="contents">
              <div
                id="event-stream"
                phx-update="stream"
                phx-hook="AutoScroll"
                data-auto-follow={to_string(@auto_follow?)}
                class="min-h-0 flex-1 overflow-y-auto"
              >
                <div :for={{dom_id, row} <- @streams.events} id={dom_id}>
                  <.event_row
                    id={row.id}
                    line={row.line}
                    log_no={row.log_no}
                    agent={row.agent}
                    color={row.color}
                    category={row.category}
                    kind={row.kind}
                    body={row.body}
                    summary={row.render.summary}
                    preview={row.render.preview}
                    detail={row.render.detail}
                    tool_name={row.render.tool_name}
                    error?={row.render.error?}
                    files={row.render.files}
                    thinking?={row.thinking?}
                    tokens={row.tokens}
                    time={row.time}
                    expanded?={MapSet.member?(@expanded_ids, row.id)}
                    selected?={MapSet.member?(@selected_ids, row.id)}
                  />
                </div>
              </div>
            </div>
          </div>

          <div id="swimlanes" class={["flex min-h-0 flex-1", @view_mode != :adws && "hidden"]}>
            <div class="flex min-h-0 flex-1 flex-col gap-2 overflow-y-auto p-2">
              <%!-- One header: category-filter chips + a folded running-worker count + CLEAR. --%>
              <div
                id="adw-controls"
                class="flex flex-wrap items-center gap-2 border-b pb-2"
                style="border-color: var(--cns-border)"
              >
                <%!-- Distinct ids from the LOGS filter bar (both views stay mounted). --%>
                <button
                  :for={
                    {cat, label} <- [
                      response: "RESPONSE",
                      tool: "TOOL",
                      thinking: "THINKING",
                      hook: "HOOK"
                    ]
                  }
                  id={"adw-cat-#{cat}"}
                  type="button"
                  phx-click="toggle_category"
                  phx-value-cat={cat}
                  class={[
                    "cns-chip",
                    "cns-chip--#{cat}",
                    MapSet.member?(@active_categories, cat) && "cns-chip--active"
                  ]}
                >
                  {label}
                </button>
                <span class="ml-auto text-[0.625rem]" style="color: var(--cns-text-2)">
                  {running_count(@statuses)} running
                </span>
                <button
                  id="clear-workflows"
                  type="button"
                  phx-click="clear_workflows"
                  disabled={
                    not (any_finished_workflows?(@workflow_progress) or
                           any_clearable_swimlanes?(@swimlanes))
                  }
                  class="cns-chip disabled:cursor-not-allowed disabled:opacity-40"
                  title="Clear finished workflows and non-running agent cards from the view; running ones stay. Nothing is deleted — reversible via the settings 'show hidden' toggle."
                >
                  CLEAR
                </button>
              </div>

              <div id="workflow-runs" class="flex flex-col gap-2">
                <.adw_card
                  :for={view <- workflow_views(@workflow_progress)}
                  id={"workflow-#{view.run_id}"}
                  title={view.title}
                  type={view.type}
                  status={view.status}
                  completed={view.completed}
                  total={view.total}
                  cost={view.cost}
                  duration={view.duration}
                  current={view.current}
                  steps={view.steps}
                />
              </div>

              <div
                :if={@workflow_progress == %{} and @swimlanes == []}
                id="no-adws"
                class="cns-empty p-6 text-center text-sm"
                style="color: var(--cns-text-2)"
              >
                No AI Developer Workflows found.
                <div class="text-[0.6875rem] opacity-70">
                  Start an ADW from the orchestrator chat.
                </div>
              </div>

              <div :if={@swimlanes != []} id="agent-cards" class="mt-1 flex flex-col gap-2">
                <span class="cns-card__key">AGENTS</span>
                <.adw_agent_card
                  :for={lane <- @swimlanes}
                  id={"swimlane-#{lane.key}"}
                  label={lane.name}
                  status={lane.status}
                >
                  <div
                    :for={col <- visible_columns(lane.columns, @active_categories)}
                    class="flex flex-col items-center gap-1"
                  >
                    <span class="text-[0.5rem] uppercase" style="color: var(--cns-text-3)">
                      {col.kind}
                    </span>
                    <div class="flex flex-wrap gap-1" style="max-width: 8rem">
                      <.event_square
                        :for={row <- col.rows}
                        event_id={row.id}
                        category={row.category}
                        summary={"#{row.kind}: #{row.body}"}
                      />
                    </div>
                  </div>
                </.adw_agent_card>
              </div>
            </div>

            <.event_detail_panel event={@selected_event} />
          </div>
        </main>

        <aside
          aria-label="Orchestrator console"
          class="min-h-0 overflow-hidden border-l p-2"
          style="border-color: var(--cns-border)"
        >
          <.command_panel
            chat_width={@chat_width}
            cost={@orchestrator_cost}
            estimate={@orchestrator_est_cost}
            typing?={
              @orchestrator_queue.busy? || @typing? ||
                Map.get(@statuses, @orchestrator_id) == :running
            }
            auto_follow?={@auto_follow?}
          >
            <:messages>
              <%= for msg <- @messages, msg.role != :thinking or @show_thinking? do %>
                <%= case msg.role do %>
                  <% :thinking -> %>
                    <.thinking_bubble content={msg.content} time={msg.time} />
                  <% :tool -> %>
                    <.tool_use_card
                      tool_name={msg.tool_name}
                      params_json={msg.params_json}
                      time={msg.time}
                    />
                  <% role -> %>
                    <.chat_message
                      role={role}
                      label={msg.label}
                      content={msg.content}
                      time={msg.time}
                    />
                <% end %>
              <% end %>
              <%!-- In-flight streaming buffers: one growing bubble per agent/channel,
              rendered after the finalized history; replaced by a finalized message
              once the authoritative block (or Done/Error flush) arrives. --%>
              <%= for {agent_id, buf} <- @streaming do %>
                <.streaming_bubble
                  :if={buf.text != ""}
                  id={"streaming-text-#{agent_id}"}
                  content={buf.text}
                />
                <.streaming_bubble
                  :if={@show_thinking? and buf.thinking != ""}
                  id={"streaming-think-#{agent_id}"}
                  thinking?={true}
                  content={buf.thinking}
                />
              <% end %>
            </:messages>
          </.command_panel>

          <.queued_messages
            busy?={@orchestrator_queue.busy?}
            depth={@orchestrator_queue.depth}
            queued={@orchestrator_queue.queued}
          />
        </aside>
      </div>

      <.global_command_input
        slash_commands={@slash_commands}
        agent_defs={@agent_defs}
        adws={@adws}
        working_dir={@orchestrator_working_dir}
        uploads={@uploads}
        adw_builder?={@adw_builder?}
        adw_steps={@adw_steps}
        adw_name={@adw_name}
        adw_local?={@adw_local?}
        agents={@agents}
        statuses={@statuses}
      />

      <.dir_picker_modal
        open?={@dir_picker_open?}
        path={@dir_picker_path}
        parent={@dir_picker_parent}
        dirs={@dir_picker_dirs}
      />

      <.agent_models_modal
        rows={@agent_model_rows}
        saved={@agent_model_saved}
        configured_count={@configured_tier_count}
        updated_at={@agent_models_updated_at}
      />

      <.explain_modal status={@explain.status} count={@explain.count} />

      <.budget_modal
        state={@budget_state}
        caps={@budget_caps}
        form={@budget_form}
        scope={@budget_scope}
        scope_targets={@budget_scope_targets}
        editing?={@budget_editing?}
      />

      <.log_manager_modal
        filter={@log_mgr_filter}
        rows={@log_mgr_rows}
        total={@log_mgr_total}
        limit={@log_mgr_limit}
        offset={@log_mgr_offset}
        selected={@log_mgr_selected}
        timezone={@timezone}
      />

      <.settings_modal
        settings_tab={@settings_tab}
        view_mode={@view_mode}
        chat_width={@chat_width}
        auto_follow?={@auto_follow?}
        show_thinking?={@show_thinking?}
        show_hidden?={@show_hidden?}
        release_notice={@release_notice}
        harnesses={@harness_options}
        system_prompt={@orchestrator_system_prompt}
        system_prompt_mode={@orchestrator_system_prompt_mode}
        default_system_prompt={@orchestrator_default_prompt}
        reasoning_effort={@orchestrator_reasoning_effort}
        reasoning_efforts={Orchestrators.reasoning_efforts()}
        timezone={@timezone}
        timezones={RepoBuilder.Timezones.list()}
        template_rows={@template_rows}
        selected_template={@selected_template}
        template_versions={@template_versions}
        cost_rollups={@cost_rollups}
        period_spend={@period_spend}
        price_rows={@price_rows}
        price_form={@price_form}
        editing_price_id={@editing_price_id}
      />
    </div>
    """
  end

  # --- selection / explain helpers (issue-explain) ---

  # Selected rows in buffer order (so the prompt reads top-to-bottom, not click order).
  @spec selected_rows([map()], MapSet.t()) :: [map()]
  defp selected_rows(event_buffer, selected_ids) do
    Enum.filter(event_buffer, &MapSet.member?(selected_ids, &1.id))
  end

  # The selected rows' raw bodies joined by newlines, for the COPY action's `data-copy`.
  @spec selected_copy_payload([map()], MapSet.t()) :: String.t()
  defp selected_copy_payload(event_buffer, selected_ids) do
    event_buffer
    |> selected_rows(selected_ids)
    |> Enum.map_join("\n", & &1.body)
  end

  # Reset the selection and re-stream the formerly-selected rows so their checkboxes
  # clear (the stream only re-renders items it is handed).
  @spec clear_selection(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp clear_selection(socket) do
    rows = selected_rows(socket.assigns.event_buffer, socket.assigns.selected_ids)
    socket = assign(socket, :selected_ids, MapSet.new())
    Enum.reduce(rows, socket, &stream_insert(&2, :events, &1))
  end

  # Apply a drag-committed range to the selection and re-stream ONLY the rows whose
  # membership actually flipped (symmetric difference of old vs new), mirroring the
  # single-row `toggle_select` re-stream pattern.
  @spec apply_drag_selection(
          Phoenix.LiveView.Socket.t(),
          [non_neg_integer()],
          :select | :deselect
        ) ::
          Phoenix.LiveView.Socket.t()
  defp apply_drag_selection(socket, [], _mode), do: socket

  defp apply_drag_selection(socket, ids, mode) do
    current = socket.assigns.selected_ids
    delta = MapSet.new(ids)

    next =
      case mode do
        :select -> MapSet.union(current, delta)
        :deselect -> MapSet.difference(current, delta)
      end

    changed = MapSet.symmetric_difference(current, next)
    socket = assign(socket, :selected_ids, next)

    socket.assigns.event_buffer
    |> Enum.filter(&MapSet.member?(changed, &1.id))
    |> Enum.reduce(socket, &stream_insert(&2, :events, &1))
  end

  # Guarded parse of the drag payload's ids: keep only well-formed non-negative integers,
  # dropping any non-numeric/stale entries.
  @spec parse_ids(term()) :: [non_neg_integer()]
  defp parse_ids(ids) when is_list(ids), do: Enum.flat_map(ids, &parse_one_id/1)
  defp parse_ids(_ids), do: []

  @spec parse_one_id(term()) :: [non_neg_integer()]
  defp parse_one_id(id) when is_integer(id) and id >= 0, do: [id]

  defp parse_one_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} when n >= 0 -> [n]
      _ -> []
    end
  end

  defp parse_one_id(_id), do: []

  @spec normalize_mode(term()) :: :select | :deselect
  defp normalize_mode("deselect"), do: :deselect
  defp normalize_mode(_mode), do: :select

  # Apply a context mutation (`hide`/`unhide`/`purge`) to the manager's selected ids, then
  # clear the selection and re-query so the table, total, and pagination stay correct (the
  # offset clamps via `seed_log_manager/1` if the last page shrank below it).
  @spec mutate_log_selection(Phoenix.LiveView.Socket.t(), ([Ecto.UUID.t()] -> non_neg_integer())) ::
          Phoenix.LiveView.Socket.t()
  defp mutate_log_selection(socket, fun) do
    _ = fun.(MapSet.to_list(socket.assigns.log_mgr_selected))

    socket
    |> assign(:log_mgr_selected, MapSet.new())
    |> refresh_log_manager()
  end

  # Guarded string→atom for the manager's visibility filter (never `String.to_atom/1` on
  # input, AGENTS.md); an unknown value falls back to `:all`.
  @spec log_filter(term()) :: Logs.log_filter()
  defp log_filter("visible"), do: :visible
  defp log_filter("hidden"), do: :hidden
  defp log_filter(_filter), do: :all

  @spec explain_selected(Phoenix.LiveView.Socket.t(), [map()]) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  defp explain_selected(socket, rows) do
    count = length(rows)

    with id when is_binary(id) <- socket.assigns.orchestrator_id,
         {:ok, orchestrator} <- Orchestrators.fetch(id),
         {:ok, request_id} <- Explain.explain(orchestrator, rows) do
      {:noreply,
       assign(socket, :explain, %{status: :running, request_id: request_id, count: count})}
    else
      {:error, :no_fast_agent} ->
        {:noreply,
         assign(socket, :explain, %{
           status: {:error, no_fast_agent_message()},
           request_id: nil,
           count: count
         })}

      _ ->
        {:noreply,
         assign(socket, :explain, %{
           status: {:error, "Could not start the explanation — no orchestrator available."},
           request_id: nil,
           count: count
         })}
    end
  end

  @spec no_fast_agent_message() :: String.t()
  defp no_fast_agent_message do
    "No Fast agent configured — pick a harness + model for the Fast tier under Agents…"
  end

  @spec explain_error_message(term()) :: String.t()
  defp explain_error_message(:no_fast_agent), do: no_fast_agent_message()
  defp explain_error_message(:timeout), do: "The Fast agent timed out before replying."

  defp explain_error_message(reason),
    do: "The explanation run failed: #{inspect(reason)}"

  # --- view helpers ---

  # The per-step workflow views as a stable, ordered list for rendering (the assign is
  # a run_id-keyed map; sort by run_id so live updates don't reshuffle the column).
  @spec workflow_views(%{optional(Ecto.UUID.t()) => map()}) :: [map()]
  defp workflow_views(workflow_progress) do
    workflow_progress |> Map.values() |> Enum.sort_by(& &1.run_id)
  end

  @spec any_finished_workflows?(map()) :: boolean()
  defp any_finished_workflows?(workflow_progress) do
    Enum.any?(workflow_progress, fn {_run_id, view} ->
      view.status in @finished_workflow_statuses
    end)
  end

  @spec any_clearable_swimlanes?([map()]) :: boolean()
  defp any_clearable_swimlanes?(swimlanes) do
    Enum.any?(swimlanes, fn lane -> lane.status != :running end)
  end

  @spec agent_swimlanes(map()) :: [map()]
  defp agent_swimlanes(assigns) do
    assigns.event_buffer
    |> Enum.group_by(& &1.agent_key)
    |> Enum.map(fn {key, rows} ->
      %{
        key: key,
        name: Map.get(assigns.agent_names, key, short_id(key)),
        status: Map.get(assigns.statuses, key, :idle),
        columns:
          rows
          |> Enum.group_by(& &1.kind)
          |> Enum.map(fn {kind, krows} -> %{kind: kind, rows: krows} end)
      }
    end)
  end

  # The agent-card columns whose squares pass the active category filter (empty columns
  # dropped). `:system` events always pass (lifecycle), matching the LOGS view.
  @spec visible_columns([map()], MapSet.t()) :: [map()]
  defp visible_columns(columns, active) do
    for col <- columns,
        rows = Enum.filter(col.rows, &category_pass?(&1, active)),
        rows != [],
        do: %{kind: col.kind, rows: rows}
  end

  @spec counter(map(), String.t(), atom()) :: non_neg_integer()
  defp counter(counters, agent_id, key) do
    counters |> Map.get(agent_id, %{}) |> Map.get(key, 0)
  end

  @spec rail_width(boolean()) :: String.t()
  defp rail_width(true), do: "3.5rem"
  defp rail_width(false), do: "15rem"

  # Inference-only spec — the three equal-length returns narrow to a fixed-size
  # binary, which String.t() would supertype under :underspecs.
  defp chat_col(:sm), do: "20rem"
  defp chat_col(:md), do: "26rem"
  defp chat_col(:lg), do: "34rem"

  @spec running_count(%{optional(String.t()) => atom()}) :: non_neg_integer()
  defp running_count(statuses),
    do: Enum.count(statuses, fn {_id, status} -> status == :running end)

  @spec agent_label(Phoenix.LiveView.Socket.t(), String.t()) :: String.t()
  defp agent_label(socket, agent_id) do
    Map.get(socket.assigns.agent_names, agent_id, short_id(agent_id))
  end

  @spec short_id(String.t()) :: String.t()
  defp short_id(id), do: id |> to_string() |> String.slice(0, 8)

  # Convert one persisted log row into an event-stream row for reconnect backfill.
  @spec log_to_row(
          Logs.AgentLog.t(),
          pos_integer(),
          %{optional(String.t()) => String.t()},
          String.t()
        ) :: map()
  defp log_to_row(log, seq, names, timezone) do
    category = category_for_type(log.event_type)
    # Worker rows carry an `agent_id` (UUID). Orchestrator rows carry `agent_id: nil`
    # and an `orchestrator_id`; their `session_id` is the harness session UUID — NOT
    # the live `"orch-…"` broadcast key. Synthesize the `"orch-#{orchestrator_id}"` key
    # for those rows so the backfill agent_key matches the live path and the chat gate
    # (`orchestrator_event?/1`) recognizes orchestrator text on reconnect/restart
    # (issue-chat-history-backfill). Worker rows keep their UUID agent_id.
    agent_key =
      case log.orchestrator_id do
        nil -> log.agent_id || log.session_id
        orch_id -> "orch-#{orch_id}"
      end

    # Same presenter as the live path (single source of truth) so reconnect backfill
    # renders the identical structured card; best-effort for variants whose persisted
    # payload is the raw wire frame (see EventPresenter.from_payload/2).
    render = EventPresenter.from_payload(log.event_type, log.payload)

    %{
      id: seq,
      line: seq,
      log_no: log.log_no,
      agent: Map.get(names, log.agent_id, short_id(agent_key)),
      agent_key: agent_key,
      color: AgentColors.hex(to_string(agent_key)),
      category: category,
      kind: to_string(log.event_type),
      body: EventPresenter.search_text(render),
      render: render,
      # Persisted text_delta rows carry the thinking flag (Logs.event_payload), so
      # backfill can route reasoning to the thinking pane like the live path does.
      thinking?: log.payload["thinking"] == true,
      # Operator chat turns are orchestrator-scoped text_delta rows marked
      # `payload["role"] == "operator"` (issue-operator-persist-operator-chat-messages);
      # carry the marker so chat_for_row/1 routes them to the :user bubble and
      # backfill_events/1 keeps them out of the center stream.
      chat_role: log.payload["role"],
      tokens: nil,
      time: log_time(log, timezone),
      payload_json: pretty_json(log.payload)
    }
  end

  @spec category_for_type(Logs.AgentLog.event_type() | nil) :: atom()
  defp category_for_type(:text_delta), do: :response
  defp category_for_type(:tool_call), do: :tool
  defp category_for_type(:tool_result), do: :tool
  defp category_for_type(:status), do: :hook
  defp category_for_type(_other), do: :system

  @spec log_time(Logs.AgentLog.t(), String.t()) :: String.t()
  defp log_time(%{inserted_at: %DateTime{} = at}, timezone),
    do: RepoBuilder.Timezones.format_datetime(at, timezone)

  defp log_time(_log, _timezone), do: ""

  # Convert a backfilled row into the chat entry it maps to (text → orchestrator
  # message). Only finalized orchestrator text reaches the chat; thinking and tool
  # activity stay in the center event stream (mirrors the live path and the tac-14
  # chat/events separation), so reasoning rows fall through to nil here.
  # (Inference-only spec — a hand-written one would be a supertype under :underspecs.)
  defp chat_for_row(%{category: :response, thinking?: true}), do: nil

  # An operator-marked orchestrator text row is the human side of the transcript:
  # render it as the distinct :user bubble ("YOU"), not the orchestrator bubble
  # (issue-operator-persist-operator-chat-messages).
  defp chat_for_row(%{category: :response, chat_role: "operator", body: body}) do
    %{role: :user, label: "YOU", content: body, tool_name: nil, params_json: nil}
  end

  defp chat_for_row(%{category: :response, body: body, agent_key: agent_key}) do
    if orchestrator_event?(agent_key) do
      %{
        role: :orchestrator,
        label: "ORCHESTRATOR",
        content: body,
        tool_name: nil,
        params_json: nil
      }
    end
  end

  defp chat_for_row(_row), do: nil

  @spec default_harness() :: String.t() | nil
  defp default_harness do
    known = HarnessRegistry.known()
    if "fake" in known, do: "fake", else: List.first(known)
  end

  # Real harnesses for the orchestrator toggle — the keyless `fake` harness is a
  # dev/test stand-in, not an operator choice.
  @spec orchestrator_harness_options() :: [String.t()]
  defp orchestrator_harness_options,
    do: Enum.reject(HarnessRegistry.orchestrating_harnesses(), &(&1 == "fake"))

  @spec to_category(String.t()) :: atom() | nil
  defp to_category("response"), do: :response
  defp to_category("tool"), do: :tool
  defp to_category("thinking"), do: :thinking
  defp to_category("hook"), do: :hook
  defp to_category(_other), do: nil

  @spec to_chat_width(String.t()) :: :sm | :md | :lg
  defp to_chat_width("md"), do: :md
  defp to_chat_width("lg"), do: :lg
  defp to_chat_width(_other), do: :sm

  @spec settings_tab(String.t()) ::
          :general | :appearance | :about | :prompt | :templates | :cost_center | :logs
  defp settings_tab("appearance"), do: :appearance
  defp settings_tab("about"), do: :about
  defp settings_tab("prompt"), do: :prompt
  defp settings_tab("templates"), do: :templates
  defp settings_tab("cost_center"), do: :cost_center
  defp settings_tab("logs"), do: :logs
  defp settings_tab(_other), do: :general

  # Re-derive the Cost Center tab's data from the DB (no reliance on socket state, so a
  # reconnect re-renders correctly). Cheap enough to run on each tab open.
  # The period-spend windows are timezone-relative — recompute them when the operator
  # changes timezone WHILE looking at the Cost Center tab so the numbers track the new zone.
  @spec refresh_cost_center_on_tz(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp refresh_cost_center_on_tz(%{assigns: %{settings_tab: :cost_center}} = socket),
    do: load_cost_center(socket)

  defp refresh_cost_center_on_tz(socket), do: socket

  @spec load_cost_center(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp load_cost_center(socket) do
    assign(socket,
      cost_rollups: CostCenter.rollup(include_hidden?: socket.assigns.show_hidden?),
      period_spend: CostCenter.period_spend(timezone: socket.assigns.timezone),
      price_rows: CostCenter.list_prices()
    )
  end

  @spec reset_price_form(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp reset_price_form(socket) do
    assign(socket,
      editing_price_id: nil,
      price_form: to_form(ModelPrice.changeset(%ModelPrice{}, %{}), as: :model_price)
    )
  end

  @spec reset_budget_form(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp reset_budget_form(socket) do
    assign(socket,
      budget_form: to_form(Cap.changeset(%Cap{}, %{}), as: :budget),
      budget_scope: "global",
      budget_editing?: false
    )
  end

  # Guard operator-supplied mode string into the closed atom set (never
  # String.to_atom/1 on input). Anything but "replace" defaults to :append.
  @spec system_prompt_mode(String.t() | nil) :: :append | :replace
  defp system_prompt_mode("replace"), do: :replace
  defp system_prompt_mode(_other), do: :append

  # Guard operator-supplied effort string into the closed atom set (never
  # String.to_atom/1 on input). Anything unrecognized defaults to :default (no flag).
  @spec reasoning_effort(String.t() | nil) :: RepoBuilder.Orchestrator.Orchestrator.effort()
  defp reasoning_effort("off"), do: :off
  defp reasoning_effort("low"), do: :low
  defp reasoning_effort("medium"), do: :medium
  defp reasoning_effort("high"), do: :high
  defp reasoning_effort("max"), do: :max
  defp reasoning_effort(_other), do: :default

  # Inference-only spec — a `term()` member would be a supertype under :underspecs.
  defp toggle_member(set, member) do
    if MapSet.member?(set, member),
      do: MapSet.delete(set, member),
      else: MapSet.put(set, member)
  end

  @spec pretty_json(term()) :: String.t()
  defp pretty_json(value) do
    case Jason.encode(value, pretty: true) do
      {:ok, json} -> json
      {:error, _reason} -> inspect(value, pretty: true)
    end
  end

  # Live-row timestamp: format the current UTC instant as a full local datetime so
  # live rows match the backfill path (which formats the persisted `inserted_at`).
  @spec now_hms(String.t()) :: String.t()
  defp now_hms(timezone), do: RepoBuilder.Timezones.format_datetime(DateTime.utc_now(), timezone)

  # Chat-entry timestamp: compact local time-of-day.
  @spec now_hm(String.t()) :: String.t()
  defp now_hm(timezone), do: RepoBuilder.Timezones.format_time(DateTime.utc_now(), timezone)
end
