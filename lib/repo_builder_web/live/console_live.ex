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
  import RepoBuilderWeb.ProjectComponents, only: [switcher: 1]

  import RepoBuilderWeb.DashboardComponents,
    only: [
      adw_card: 1,
      event_detail_panel: 1
    ]

  alias RepoBuilder.{
    Agents,
    Budget,
    Dashboard,
    Definitions,
    Logs,
    Orchestrators,
    Projects,
    Session,
    Settings
  }

  alias RepoBuilder.Agents.Agent
  alias RepoBuilder.Budget.Cap
  alias RepoBuilder.Console.EventPresenter
  alias RepoBuilder.CostCenter.ModelPrice
  alias RepoBuilder.ExternalApis.ImportResult
  alias RepoBuilder.Harness.Event
  alias RepoBuilder.Harness.Pi.Models, as: PiModels
  alias RepoBuilder.Harness.Registry, as: HarnessRegistry
  alias RepoBuilder.Orchestrator.Queue, as: OrchestratorQueue
  alias RepoBuilder.Orchestrator.Workstreams
  alias RepoBuilder.StackLayers.StackLayer
  alias RepoBuilderWeb.AgentColors
  alias RepoBuilderWeb.ConsoleLive.AdwBuilderPanel
  alias RepoBuilderWeb.ConsoleLive.BrainPanel
  alias RepoBuilderWeb.ConsoleLive.CostPanel
  alias RepoBuilderWeb.ConsoleLive.ExternalApisPanel
  alias RepoBuilderWeb.ConsoleLive.LogsPanel
  alias RepoBuilderWeb.ConsoleLive.SettingsPanel
  alias RepoBuilderWeb.ConsoleLive.Shared
  alias RepoBuilderWeb.ConsoleLive.TemplatesPanel

  @external_api_events RepoBuilderWeb.ConsoleLive.ExternalApisPanel.events()
  @cost_events RepoBuilderWeb.ConsoleLive.CostPanel.events()
  @settings_events RepoBuilderWeb.ConsoleLive.SettingsPanel.events()
  @template_events RepoBuilderWeb.ConsoleLive.TemplatesPanel.events()
  @adw_builder_events RepoBuilderWeb.ConsoleLive.AdwBuilderPanel.events()
  @logs_events RepoBuilderWeb.ConsoleLive.LogsPanel.events()
  @brain_events RepoBuilderWeb.ConsoleLive.BrainPanel.events()

  @categories [:response, :tool, :thinking, :hook]
  @buffer_limit 500
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
        orchestrator_name: nil,
        # Autonomy panel (self-healing Phase 6): the active orchestrator's Task/Progress Ledger
        # view (nil ⇒ no goal) + the escalation banner reason (nil ⇒ not escalated).
        ledger: nil,
        # Workstreams panel (orchestration-adw-loop): the active orchestrator's durable
        # workstreams as full records (phases + stage state), [] ⇒ none.
        workstreams: [],
        orchestrator_holding_reason: nil,
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
        # Settings → Default Models tab (issue per-project-agent-models): the operator's
        # global default worker roster new projects inherit. Loaded when the tab opens.
        default_model_rows: [],
        default_model_saved: false,
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
        goal_card_collapsed?: false,
        chat_width: :sm,
        # Operator display timezone for log timestamps; the connected mount reads the
        # persisted value off the orchestrator (this default is for the static render).
        timezone: RepoBuilder.Timezones.default(),
        auto_follow?: true,
        show_thinking?: true,
        # planf3 plan-image policy (spec planf3-html-plans-for-heavy-adw-planner):
        # placeholders ON by default; connected mount reads the persisted setting +
        # whether an OPENAI_API_KEY secret exists in either vault scope.
        planf3_placeholders?: true,
        planf3_key_present?: false,
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
        # Active project's cost report for the Cost Center tab (issue per-project-cost-
        # tracking): %{report, periods} when a project is selected, else nil. Lazily loaded.
        project_report: nil,
        # Cost Center settings tab (issue-cost-center). Lazily loaded when the tab is
        # selected so an ordinary mount never runs the rollup aggregation.
        cost_rollups: [],
        # Time-windowed accounting view (issue-cost-adw-periods); loaded with the tab.
        period_spend: nil,
        price_rows: [],
        price_form: to_form(ModelPrice.changeset(%ModelPrice{}, %{}), as: :model_price),
        editing_price_id: nil,
        # Stack Layers settings tab (stack-layers subsystem). Lazily loaded with the tab.
        stack_layer_rows: [],
        stack_layer_form: to_form(StackLayer.changeset(%StackLayer{}, %{}), as: :stack_layer),
        editing_layer_id: nil,
        # Registered APIs settings tab (issue-external-api-mcp-provisioning): the
        # user-scope (platform) + active-project-scope registrations, the register/edit
        # form, and the masked set of vault secret names (for the "secret present?" hint).
        # Lazily refreshed; safe empty defaults for the disconnected render.
        user_apis: [],
        project_apis: [],
        api_form: ExternalApisPanel.blank_api_form(),
        editing_api_id: nil,
        api_secret_names: MapSet.new(),
        # MCP smart import (issue-external-api-mcp-provisioning): the textarea's status
        # (:idle | :running | {:question, text} | {:error, msg}) + the live async request
        # id, and a staged Deposit-a-secret prefill (name/value the parser extracted from
        # a pasted config — never persisted on the row).
        smart_import: %{status: :idle, request_id: nil},
        api_secret_prefill: %{scope: nil, name: nil, value: nil},
        regex?: false,
        search: "",
        active_categories: MapSet.new(@categories),
        # Toggle for `:system`-category rows in the center event stream (issue
        # filter-sys-logs). Default OFF: lifecycle events (`session_started`, `usage`,
        # `done`, `error`) stay in `event_buffer` and `agent_logs` forever but are
        # hidden from the view. Re-shown via the SYS chip in the filter bar / ADWS
        # header. Independent of the four `active_categories` toggles so CLEAR does
        # not flip it (logs_panel.ex `clear_filters` is intentionally asymmetric).
        show_system?: false,
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
        # Latest context-window occupancy of the orchestrator's OWN turns (its workers
        # track their own on the rail cards). Replace-latest; zeroes when the session is
        # cleared (Clear button / model switch ⇒ a fresh conversation next turn).
        orchestrator_context: 0,
        connected?: connected?(socket),
        harness_options: HarnessRegistry.known(),
        # File-driven prompt palette (issue-prompt-adw-palette): live, file-derived
        # definition lists surfaced as clickable chips. Seeded on the connected mount
        # from RepoBuilder.Definitions and updated live via PubSub broadcasts. Kept
        # distinct from the live-worker `agents` assign (this is `agent_defs`).
        slash_commands: [],
        agent_defs: [],
        adws: [],
        # Active source tab for the file-derived palette (issue palette-source-tabs):
        # :base = platform-repo artifacts; :project = the active working-dir overlay.
        palette_source_tab: :base,
        # Agentic-layer adaptor (Phase 5): the global project switcher. `active_project_id`
        # scopes the rail roster; nil = the unscoped "all / platform" view (current behaviour).
        projects: [],
        active_project_id: nil,
        # Project-scoped log stream (issue-scope-logs-to-active-project): when on AND a
        # project is active, the event stream shows only rows whose `agent_key` is in
        # `project_agent_keys` (the active project's bound orchestrator id ∪ its worker
        # agent ids). Presentation-only — rows always stay in `event_buffer`, so toggling
        # scope off re-reveals the unscoped feed with no reload. Default on; the
        # `PROJECT ONLY` chip is the explicit opt-out. Empty key set ⇒ fail-open (no-op).
        project_scoped?: true,
        project_agent_keys: MapSet.new(),
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
        adw_flavor: :iso,
        harness_names: HarnessRegistry.known(),
        adw_spec: "",
        adw_prompt: "",
        adw_combos: [],
        adw_loadable: [],
        adw_selected_combo: "",
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
        |> assign(:projects, Projects.list_projects())
        |> assign_default_project()
        |> load_agents()
        |> seed_agent_costs()
        |> Shared.seed_context_tokens()
        |> Shared.seed_counters()
        |> seed_lanes()
        |> Shared.seed_workflow_progress()
        |> Shared.seed_budget()
        |> Shared.seed_planf3_image_policy()
        # assign_orchestrator must precede backfill_events: it reads the persisted
        # display timezone into assigns, which backfill_events uses to format row times.
        # It must also precede seed_cost/seed_orchestrator_cost, which read orchestrator_id.
        |> assign_orchestrator()
        |> seed_cost()
        |> seed_orchestrator_cost()
        |> Shared.backfill_events()
        # seed_log_manager / assign_template_rows / load_external_apis are NOT called
        # here: those tabs are closed on mount, so their data is lazy-loaded on tab
        # open (SettingsPanel "select_settings_tab") instead of taxing every mount.
        |> Shared.seed_definitions()
        |> subscribe_feeds()
        |> tap(fn _ -> PiModels.refresh_async() end)
      else
        socket
      end

    {:ok, socket}
  end

  # Resolve the orchestrator for the active project so a prompt with no agent selected has
  # a brain to route to (orchestrator↔project binding): the project's own orchestrator when
  # one is selected, else the platform default. Runs AFTER `active_project_id` is assigned
  # so a deep-linked project starts on the right brain. A failure leaves orchestrator_id nil
  # (the manual path still works).
  # Restore the operator's last-selected project on connect so the console reopens on the
  # same project after navigating away (e.g. to `/projects` and back) or reloading. Falls
  # back to the platform project (repo_builder_elixir — the seeded row whose root_path is the
  # BEAM cwd) when nothing is persisted or the persisted project was since deleted, via
  # `Projects.active_or_default/1`. A nil result (before seeding / no projects) leaves the
  # scope unset.
  @spec assign_default_project(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp assign_default_project(socket) do
    case Projects.active_or_default(Settings.get_active_project_id()) do
      nil -> socket
      project -> assign(socket, :active_project_id, project.id)
    end
  end

  @spec assign_orchestrator(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp assign_orchestrator(socket) do
    case Orchestrators.get_or_create_for_project(socket.assigns[:active_project_id]) do
      {:ok, orchestrator} -> Shared.assign_orchestrator_selection(socket, orchestrator)
      {:error, _reason} -> socket
    end
  end

  # Re-resolve the active orchestrator for the (already-assigned) active project and rebuild
  # all orchestrator-scoped state: header selection + context gauge, the queue subscription
  # (unsubscribe the old brain, subscribe the new), and the cost badges + chat/log history.
  # A resolve failure leaves the current brain in place. Called by `select_project`.
  @spec switch_orchestrator(Phoenix.LiveView.Socket.t(), Ecto.UUID.t() | nil) ::
          Phoenix.LiveView.Socket.t()
  defp switch_orchestrator(socket, previous_id) do
    case Orchestrators.get_or_create_for_project(socket.assigns.active_project_id) do
      {:ok, orchestrator} ->
        socket
        |> Shared.assign_orchestrator_selection(orchestrator)
        |> refresh_definitions_for()
        |> resubscribe_orchestrator_queue(previous_id, orchestrator.id)
        |> seed_cost()
        |> seed_orchestrator_cost()
        |> Shared.backfill_events()

      {:error, _reason} ->
        socket
    end
  end

  # Repoint the global Definitions watcher at the newly-active project's dir and re-seed
  # this console's palette assigns. Mirrors `save_working_dir/2`: refresh/1 updates the
  # watcher's tracked dir + broadcasts to every console; the local re-seed makes this
  # console's chips update without waiting on the round-trip. Must run after
  # `assign_orchestrator_selection/2` (which sets `orchestrator_working_dir`).
  @spec refresh_definitions_for(Phoenix.LiveView.Socket.t()) ::
          Phoenix.LiveView.Socket.t()
  defp refresh_definitions_for(socket) do
    :ok = Definitions.refresh(Shared.nilify_blank(socket.assigns.orchestrator_working_dir))
    Shared.seed_definitions(socket)
  end

  # Move the per-orchestrator queue subscription from the previous brain to the new one when
  # the id actually changes (guards against a redundant double-subscribe). No-op when the
  # project switch resolved to the same orchestrator. Only meaningful on the connected socket.
  @spec resubscribe_orchestrator_queue(
          Phoenix.LiveView.Socket.t(),
          Ecto.UUID.t() | nil,
          Ecto.UUID.t() | nil
        ) :: Phoenix.LiveView.Socket.t()
  defp resubscribe_orchestrator_queue(socket, same, same), do: socket

  defp resubscribe_orchestrator_queue(socket, previous_id, new_id) do
    if connected?(socket) do
      if is_binary(previous_id), do: Dashboard.unsubscribe_orchestrator_queue(previous_id)
      # `new_id` is always a resolved orchestrator id (the equal-args clause above handles
      # the no-change case), so it is subscribed unconditionally.
      Dashboard.subscribe_orchestrator_queue(new_id)
    end

    socket
  end

  @doc "Count of categories that have a non-blank model assigned (see `Shared`)."
  @spec configured_tier_count([map()]) :: non_neg_integer()
  defdelegate configured_tier_count(rows), to: Shared

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

  @spec load_agents(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp load_agents(socket) do
    # Scope the rail roster to the active project (agentic-layer adaptor). A nil active
    # project is the unscoped, back-compatible view — every non-archived agent.
    agents = Agents.list_for_project(socket.assigns[:active_project_id])

    socket
    |> assign(
      agents: agents,
      agent_names: Map.new(agents, &{&1.id, &1.name}),
      statuses: Map.new(agents, &{&1.id, &1.status})
    )
    |> assign(:project_agent_keys, project_agent_keys(socket))
  end

  # The set of "owned" agent keys for the active project's scoped log stream: every
  # worker agent id under the project (`Agents.list_for_project/1`), plus the bare
  # orchestrator UUID (kept harmlessly — orchestrator rows never use the bare form). The
  # bound orchestrator's live/backfill keys are `"orch-<id>…"` and so don't appear here;
  # `project_pass?/2` matches them by the `"orch-<orchestrator_id>"` prefix instead.
  # Normalized to strings because `record_event/4` stores `agent_key: agent_id` and ids
  # are stringified for color keys — the predicate must compare like-for-like. A `nil`
  # active project ⇒ empty set (predicate no-ops).
  @spec project_agent_keys(Phoenix.LiveView.Socket.t()) :: MapSet.t(String.t())
  defp project_agent_keys(socket) do
    case socket.assigns[:active_project_id] do
      nil ->
        MapSet.new()

      project_id ->
        worker_ids = Enum.map(Agents.list_for_project(project_id), & &1.id)
        orchestrator_id = socket.assigns[:orchestrator_id]
        ids = if is_binary(orchestrator_id), do: [orchestrator_id | worker_ids], else: worker_ids
        MapSet.new(ids, &to_string/1)
    end
  end

  @spec seed_agent_costs(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp seed_agent_costs(socket) do
    agent_ids = Enum.map(socket.assigns.agents, & &1.id)
    rollups = Logs.cost_rollup_for_agents!(agent_ids)

    costs =
      Map.new(agent_ids, fn id -> {id, nilify_zero(Map.get(rollups, id, Decimal.new(0)))} end)

    assign(socket, :agent_costs, costs)
  end

  # cost_rollup! returns Decimal-0 for agents with no priced logs; keep the rail
  # footer at "—" (unpriced) in that case rather than showing "$0".
  @spec nilify_zero(Decimal.t()) :: Decimal.t() | nil
  defp nilify_zero(%Decimal{} = d), do: if(Decimal.equal?(d, 0), do: nil, else: d)

  # Only AGENT lanes go into the flat lane stream now; workflow runs render as rich
  # per-step swimlanes from `@workflow_progress` (seeded by `seed_workflow_progress/1`).
  @spec seed_lanes(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp seed_lanes(socket) do
    lanes = agent_lanes(socket.assigns.agents)
    Enum.reduce(lanes, socket, &stream_insert(&2, :lanes, &1))
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
      title: "ADW " <> Shared.short_id(run_id),
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

  # Project switcher: switching the project is a FULL context switch (orchestrator↔project
  # binding) — set the active project, re-resolve the active orchestrator (its own context
  # window/cost/queue), re-point the queue subscription, reload the orchestrator-scoped
  # views, and re-scope the rail roster. A blank id is the unscoped "all / platform" view
  # and restores the platform default orchestrator.
  def handle_event("select_project", %{"project_id" => id}, socket) do
    active = if id == "", do: nil, else: id
    previous_id = socket.assigns.orchestrator_id

    # Persist the selection so it survives navigation (e.g. → /projects → back) and reloads;
    # best-effort — a persistence failure must not block the in-session switch.
    _ = Settings.put_active_project_id(active)

    {:noreply,
     socket
     |> assign(:active_project_id, active)
     |> switch_orchestrator(previous_id)
     |> load_agents()
     |> ExternalApisPanel.load_external_apis()
     |> Shared.restream()}
  end

  # --- Registered APIs settings tab (issue-external-api-mcp-provisioning) ---

  # External-APIs panel (extracted: ConsoleLive.ExternalApisPanel, audit F3 Phase 3).
  def handle_event(event, params, socket) when event in @external_api_events,
    do: ExternalApisPanel.handle_event(event, params, socket)

  # Brain panel (extracted: ConsoleLive.BrainPanel, audit F3 Phase 3): orchestrator
  # harness/provider/model selection, context clear, and the agent-models rosters.
  def handle_event(event, params, socket) when event in @brain_events,
    do: BrainPanel.handle_event(event, params, socket)

  # Cost panel (extracted: ConsoleLive.CostPanel, audit F3 Phase 3): per-project cost
  # clear/restore, model-price catalog CRUD, and budget guardrails.
  def handle_event(event, params, socket) when event in @cost_events,
    do: CostPanel.handle_event(event, params, socket)

  # Settings panel (extracted: ConsoleLive.SettingsPanel, audit F3 Phase 3): system prompt,
  # working dir + directory picker, reasoning effort, timezone, settings tabs, stack layers.
  def handle_event(event, params, socket) when event in @settings_events,
    do: SettingsPanel.handle_event(event, params, socket)

  # --- agent-template settings tab ---

  # Templates panel (extracted: ConsoleLive.TemplatesPanel, audit F3 Phase 3): the
  # agent-template settings tab's new/select/save/restore/delete handlers.
  def handle_event(event, params, socket) when event in @template_events,
    do: TemplatesPanel.handle_event(event, params, socket)

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

  # Bottom orchestrator drawer: collapse/expand the goal card (autonomy + workstreams + queue).
  def handle_event("toggle_goal_card", _params, socket),
    do: {:noreply, assign(socket, :goal_card_collapsed?, not socket.assigns.goal_card_collapsed?)}

  # Command-panel header: a single button that cycles sm → md → lg → sm.
  def handle_event("cycle_chat_width", _params, socket),
    do: {:noreply, assign(socket, :chat_width, next_chat_width(socket.assigns.chat_width))}

  # Settings → Appearance: explicit 3-segment chat-width picker.
  def handle_event("set_chat_width", %{"width" => width}, socket),
    do: {:noreply, assign(socket, :chat_width, to_chat_width(width))}

  # ADW Builder panel (extracted: ConsoleLive.AdwBuilderPanel, audit F3 Phase 3): the
  # builder toggle, palette tab, step editing, launch, and saved-combo handlers.
  def handle_event(event, params, socket) when event in @adw_builder_events,
    do: AdwBuilderPanel.handle_event(event, params, socket)

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

  # Logs panel (extracted: ConsoleLive.LogsPanel, audit F3 Phase 3): event-stream
  # filters/clears, row expand/detail/open-file, multi-select + EXPLAIN/HIDE bulk
  # actions, and the Log Database manager.
  def handle_event(event, params, socket) when event in @logs_events,
    do: LogsPanel.handle_event(event, params, socket)

  # Operator resume from the escalation banner (self-healing Phase 6): clear the holding reason
  # and re-engage the orchestrator with one operator turn so it resumes from the ledger checkpoint.
  def handle_event("resume_orchestrator", _params, socket) do
    case socket.assigns.orchestrator_id do
      nil ->
        {:noreply, socket}

      orchestrator_id ->
        _ = Orchestrators.clear_holding_reason(orchestrator_id)

        socket =
          socket
          |> assign(:orchestrator_holding_reason, nil)
          |> run_orchestrator(
            "Resume driving toward the goal — reassess the ledger and continue."
          )

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("clear_escalation", _params, socket) do
    case socket.assigns.orchestrator_id do
      nil ->
        {:noreply, socket}

      orchestrator_id ->
        _ = Orchestrators.clear_holding_reason(orchestrator_id)
        {:noreply, assign(socket, :orchestrator_holding_reason, nil)}
    end
  end

  # Operator quick-action from the workstreams swimlane board (adws-phase-swimlane): record the
  # outcome of a phase's current stage and advance the state machine. Broadcasts the refreshed
  # records so any open console re-renders immediately.
  @impl true
  def handle_event(
        "record_stage",
        %{"ref" => ref, "stage" => stage, "outcome" => outcome},
        socket
      ) do
    orchestrator_id = socket.assigns.orchestrator_id

    attrs = %{
      stage: String.to_existing_atom(stage),
      outcome: String.to_existing_atom(outcome)
    }

    socket =
      case Workstreams.record_stage(orchestrator_id, ref, attrs) do
        {:ok, _} ->
          records = Workstreams.list_records(orchestrator_id)
          :ok = Dashboard.broadcast_workstreams(orchestrator_id, records)
          assign(socket, :workstreams, records)

        {:error, _reason} ->
          socket
      end

    {:noreply, socket}
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

  @spec push_user_message(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  defp push_user_message(socket, ""), do: socket

  defp push_user_message(socket, prompt) do
    seq = socket.assigns.seq + 1
    msg = %{role: :user, label: "YOU", content: prompt, tool_name: nil, params_json: nil}

    socket
    |> assign(:seq, seq)
    |> assign(
      :messages,
      Shared.append_chat(socket.assigns.messages, msg, seq, socket.assigns.timezone)
    )
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

  # MCP smart-import async reply (issue-external-api-mcp-provisioning): ignore a superseded
  # request; otherwise apply the Fast agent's draft/question exactly like the sync branch.
  @impl true
  def handle_info({:smart_import_result, request_id, result}, socket) do
    if socket.assigns.smart_import.request_id == request_id do
      socket =
        case result do
          {:ok, %ImportResult{} = import_result} ->
            ExternalApisPanel.apply_import_result(socket, import_result)

          {:error, reason} ->
            assign(socket, :smart_import, %{
              status: {:error, ExternalApisPanel.smart_import_error(reason)},
              request_id: nil
            })
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # Budget guardrails: any breaker event re-seeds the snapshot + caps so the panel,
  # banner, and badge re-render live (issue-budget-guardrails).
  def handle_info({:budget_tripped, _cap, _spent}, socket),
    do: {:noreply, Shared.refresh_budget(socket)}

  def handle_info({:budget_warning, _cap, _spent}, socket),
    do: {:noreply, Shared.refresh_budget(socket)}

  def handle_info({:budget_reset, _cap}, socket), do: {:noreply, Shared.refresh_budget(socket)}
  def handle_info({:kill_switch, _state}, socket), do: {:noreply, Shared.refresh_budget(socket)}

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
    # Only the ACTIVE orchestrator's in-flight text feeds the chat streaming buffer;
    # worker partials AND background orchestrators are dropped here (their finalized text
    # still lands in the center stream / is recoverable via backfill on switch).
    if active_orchestrator_event?(socket, agent_id) do
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
      if active_orchestrator_event?(socket, agent_id) do
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
    # A worker HELD pending external input is neither succeeded nor failed — render a
    # distinct :holding status so it is not mislabeled "Succeeded" and stays resumable
    # (issue holding-status-for-blocked-agents).
    status =
      cond do
        event.reason == :held_pending_input -> :holding
        event.ok -> :succeeded
        true -> :failed
      end

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

      socket =
        socket
        |> assign(:agents, socket.assigns.agents ++ [agent])
        |> assign(:agent_names, Map.put(socket.assigns.agent_names, agent.id, agent.name))
        |> assign(:statuses, Map.put(socket.assigns.statuses, agent.id, agent.status))
        |> stream_insert(:lanes, lane)

      # A worker spawned under the active project must enter the scoped stream: recompute
      # the owned-key set off the updated roster and re-filter the buffer.
      {:noreply,
       socket |> assign(:project_agent_keys, project_agent_keys(socket)) |> Shared.restream()}
    end
  end

  def handle_info(:clear_agent_model_saved, socket) do
    {:noreply, assign(socket, :agent_model_saved, false)}
  end

  def handle_info(:clear_default_model_saved, socket) do
    {:noreply, assign(socket, :default_model_saved, false)}
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

  # The active orchestrator's Task/Progress Ledger changed (self-healing Phase 6): refresh the
  # autonomy panel live. Scoped to the active orchestrator; other orchestrators' updates are
  # ignored (matching the queue/agent handlers).
  def handle_info({:ledger_updated, orchestrator_id, view}, socket) do
    if orchestrator_id == socket.assigns.orchestrator_id do
      {:noreply, assign(socket, :ledger, view)}
    else
      {:noreply, socket}
    end
  end

  # The active orchestrator's Workstreams changed (orchestration-adw-loop): refresh the
  # Workstreams panel live. Scoped to the active orchestrator (matching the ledger handler).
  def handle_info({:workstreams_updated, orchestrator_id, records}, socket) do
    if orchestrator_id == socket.assigns.orchestrator_id do
      {:noreply, assign(socket, :workstreams, records)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:orchestrator_updated, orchestrator}, socket) do
    if orchestrator.id == socket.assigns.orchestrator_id do
      # A timezone change from another tab/session must re-format already-rendered rows.
      tz_changed? = Orchestrators.timezone(orchestrator) != socket.assigns.timezone
      socket = Shared.assign_orchestrator_selection(socket, orchestrator)
      socket = if tz_changed?, do: Shared.backfill_events(socket), else: socket
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

    socket =
      socket
      |> assign(
        :agents,
        Enum.map(socket.assigns.agents, fn a -> if a.id == agent.id, do: agent, else: a end)
      )
      |> assign(:statuses, Map.put(socket.assigns.statuses, agent.id, agent.status))
      |> stream_insert(:lanes, lane)

    # A worker reassigned to/from the active project must enter/leave the scoped stream.
    {:noreply,
     socket |> assign(:project_agent_keys, project_agent_keys(socket)) |> Shared.restream()}
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

    socket =
      socket
      |> assign(:agents, Enum.reject(socket.assigns.agents, &(&1.id == agent.id)))
      |> assign(:agent_names, Map.delete(socket.assigns.agent_names, agent.id))
      |> assign(:statuses, Map.delete(socket.assigns.statuses, agent.id))
      |> assign(:cost, subtract_cost(socket.assigns.cost, removed))
      |> assign(:cost_estimate, subtract_cost(socket.assigns.cost_estimate, removed_est))
      |> assign(:agent_costs, Map.delete(socket.assigns.agent_costs, agent.id))
      |> assign(:agent_est_costs, Map.delete(socket.assigns.agent_est_costs, agent.id))
      |> stream_delete(:lanes, %{id: "agent:#{agent.id}"})

    # A worker removed from the active project must leave the scoped stream.
    {:noreply,
     socket |> assign(:project_agent_keys, project_agent_keys(socket)) |> Shared.restream()}
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
      # The workflow stage this event belongs to (`adw_step` on the neutral ADW envelope,
      # carried in `event.raw` ⇒ the row payload). Drives stage-lane grouping; defaults to
      # `"_workflow"` for non-ADW workers. Single source of truth with the backfill path.
      step: Shared.event_step(Map.get(attrs, :payload, %{})),
      body: to_string(attrs.body),
      # The presenter render model drives the structured card; the single source of truth
      # shared with the backfill path (log_to_row) so live + reconnect render identically.
      render: Map.get(attrs, :render, empty_render(attrs)),
      thinking?: Map.get(attrs, :thinking?, false),
      tokens: Map.get(attrs, :tokens),
      time: now_hms(socket.assigns.timezone),
      payload_json: Shared.pretty_json(Map.get(attrs, :payload, %{}))
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
      files: [],
      file_change: nil
    }
  end

  # Inference-only spec — the row map is narrowed to its concrete shape (:underspecs).
  defp maybe_stream_insert(socket, row) do
    if Shared.passes?(row, socket.assigns) do
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
        Shared.append_chat(socket.assigns.messages, chat, seq, socket.assigns.timezone)
      )

  # --- live streaming buffer (partials coalesced per agent + channel) -------

  # The chat pane is scoped to the ACTIVE orchestrator (issue-conversation-history-scope):
  # `orchestrator_event?/1` only tells us a turn came from *some* orchestrator, so a
  # background brain (a second project mid-run) would otherwise stream its text into the
  # chat pane of whatever project is being viewed. This narrows to the active brain by
  # matching the full active id between the `"orch-"` prefix and the `-<n>` suffix
  # (orchestrator/server.ex) — robust against the UUID's own dashes, no UUID parsing.
  # A nil active id matches nothing, so a "no brain selected" pane stays empty.
  @spec active_orchestrator_event?(Phoenix.LiveView.Socket.t(), String.t()) :: boolean()
  defp active_orchestrator_event?(socket, agent_id) do
    case socket.assigns.orchestrator_id do
      active when is_binary(active) ->
        String.starts_with?(to_string(agent_id), "orch-" <> active <> "-")

      _ ->
        false
    end
  end

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
      {Shared.append_chat(messages, stream_chat(channel, text), seq, timezone), seq}
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

  # Route context occupancy by owner (panel parity with cost/estimate): an orchestrator
  # turn's synthetic `"orch-…"` agent_id updates the single replace-latest
  # `:orchestrator_context` (driving the command-panel bar, and keeping per-turn keys out
  # of the per-agent map); a worker's UUID updates its `:context_tokens` rail entry.
  @spec put_context(Phoenix.LiveView.Socket.t(), String.t(), non_neg_integer()) ::
          Phoenix.LiveView.Socket.t()
  defp put_context(socket, agent_id, tokens) do
    if orchestrator_owned?(agent_id),
      do: assign(socket, :orchestrator_context, tokens),
      else:
        assign(socket, :context_tokens, Map.put(socket.assigns.context_tokens, agent_id, tokens))
  end

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
        orchestrating_harnesses={Shared.orchestrator_harness_options()}
        orchestrator_provider={@orchestrator_provider}
        orchestrator_model={@orchestrator_model}
        provider_options={@provider_options}
        model_options={@model_options}
        recent_models={@recent_models}
      />

      <div class="flex items-center gap-3 border-b border-zinc-800 px-3 py-1">
        <.switcher
          projects={@projects}
          active_project_id={@active_project_id}
          orchestrator_name={@orchestrator_name}
          orchestrator_working_dir={@orchestrator_working_dir}
          orchestrator_context={@orchestrator_context}
        />
        <.link navigate={~p"/projects"} class="text-xs text-cyan-400">manage</.link>
        <.link
          navigate={
            if @active_project_id, do: ~p"/plan?project_id=#{@active_project_id}", else: ~p"/plan"
          }
          class="text-xs text-cyan-400"
        >plan a run</.link>
      </div>

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
              project_scoped?={@project_scoped?}
              project_active?={@active_project_id != nil}
              show_system?={@show_system?}
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
                    file_change={row.render[:file_change]}
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
                <button
                  id="adw-cat-system"
                  type="button"
                  phx-click="toggle_system"
                  class={[
                    "cns-chip",
                    "cns-chip--system",
                    @show_system? && "cns-chip--active"
                  ]}
                  title="Toggle the system rows (lifecycle / usage / done / error) in the center stream — sys rows stay in agent_logs, only the view toggles"
                >
                  SYS
                </button>
                <span class="ml-auto text-[0.625rem]" style="color: var(--cns-text-2)">
                  {running_count(@statuses)} running
                </span>
                <button
                  id="clear-workflows"
                  type="button"
                  phx-click="clear_workflows"
                  disabled={not any_finished_workflows?(@workflow_progress)}
                  class="cns-chip disabled:cursor-not-allowed disabled:opacity-40"
                  title="Clear finished workflows from the view; running ones stay. Nothing is deleted — reversible via the settings 'show hidden' toggle."
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
                  step_squares={
                    workflow_step_squares(
                      @event_buffer,
                      view.run_id,
                      @active_categories,
                      @show_system?
                    )
                  }
                />
              </div>

              <div
                :if={@workflow_progress == %{}}
                id="no-adws"
                class="cns-empty p-6 text-center text-sm"
                style="color: var(--cns-text-2)"
              >
                No AI Developer Workflows found.
                <div class="text-[0.6875rem] opacity-70">
                  Start an ADW from the orchestrator chat.
                </div>
              </div>

              <.workstreams_swimlane
                orchestrator_id={@orchestrator_id}
                workstreams={@workstreams}
                context_tokens={@orchestrator_context}
              />
            </div>

            <.event_detail_panel event={@selected_event} />
          </div>
        </main>

        <aside
          aria-label="Orchestrator console"
          class="flex min-h-0 flex-col overflow-hidden border-l p-2"
          style="border-color: var(--cns-border)"
        >
          <div class="min-h-0 flex-1 overflow-hidden">
            <.command_panel
              chat_width={@chat_width}
              cost={@orchestrator_cost}
              estimate={@orchestrator_est_cost}
              context_tokens={@orchestrator_context}
              harness={@orchestrator_harness}
              model={@orchestrator_model}
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
          </div>

          <div :if={goal_card_present?(assigns)} class="flex min-h-0 shrink-0 flex-col">
            <button
              type="button"
              id="toggle-goal-card"
              phx-click="toggle_goal_card"
              aria-expanded={to_string(not @goal_card_collapsed?)}
              title={if @goal_card_collapsed?, do: "Expand goal card", else: "Collapse goal card"}
              class="flex w-full items-center gap-2 border-t px-3 py-1 text-[0.7rem]"
              style="border-color: var(--cns-border)"
            >
              <span aria-hidden="true">{if @goal_card_collapsed?, do: "▲", else: "▼"}</span>
              <.goal_card_summary
                :if={@goal_card_collapsed?}
                ledger={@ledger}
                workstreams={@workstreams}
              />
            </button>
            <div
              :if={not @goal_card_collapsed?}
              class="min-h-0 overflow-y-auto"
              style="max-height: 45vh"
            >
              <.autonomy_panel ledger={@ledger} holding_reason={@orchestrator_holding_reason} />
            </div>
          </div>

          <%!-- Queue status is NOT part of the collapsible goal card: it self-gates on busy/depth
          and must stay visible (the `#orchestrator-queue` "Busy" indicator) regardless of the
          goal-card toggle or whether a goal/workstream exists. --%>
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
        palette_source_tab={@palette_source_tab}
        working_dir={@orchestrator_working_dir}
        uploads={@uploads}
        adw_builder?={@adw_builder?}
        adw_steps={@adw_steps}
        adw_name={@adw_name}
        adw_flavor={@adw_flavor}
        adw_spec={@adw_spec}
        adw_prompt={@adw_prompt}
        adw_combos={@adw_combos}
        adw_loadable={@adw_loadable}
        adw_selected_combo={@adw_selected_combo}
        adw_harness={@adw_harness || ""}
        harness_names={@harness_names}
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
        planf3_placeholders?={@planf3_placeholders?}
        planf3_key_present?={@planf3_key_present?}
        template_rows={@template_rows}
        selected_template={@selected_template}
        template_versions={@template_versions}
        cost_rollups={@cost_rollups}
        period_spend={@period_spend}
        project_report={@project_report}
        price_rows={@price_rows}
        price_form={@price_form}
        editing_price_id={@editing_price_id}
        stack_layer_rows={@stack_layer_rows}
        stack_layer_form={@stack_layer_form}
        editing_layer_id={@editing_layer_id}
        default_model_rows={@default_model_rows}
        default_model_saved={@default_model_saved}
        user_apis={@user_apis}
        project_apis={@project_apis}
        api_form={@api_form}
        editing_api_id={@editing_api_id}
        api_secret_names={@api_secret_names}
        smart_import={@smart_import}
        api_secret_prefill={@api_secret_prefill}
        active_project_id={@active_project_id}
      />
    </div>
    """
  end

  # --- selection / explain helpers (issue-explain) ---

  # The selected rows' raw bodies joined by newlines, for the COPY action's `data-copy`.
  @spec selected_copy_payload([map()], MapSet.t()) :: String.t()
  defp selected_copy_payload(event_buffer, selected_ids) do
    event_buffer
    |> Shared.selected_rows(selected_ids)
    |> Enum.map_join("\n", & &1.body)
  end

  @spec no_fast_agent_message() :: String.t()
  defp no_fast_agent_message, do: Shared.no_fast_agent_message()

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

  # The run's buffered event rows grouped by `:step`, for the matching workflow card's step
  # boxes (squares live under the step that emitted them). Rows are matched to the run by the
  # `wf-<run_id>-<step>` agent-key prefix (WorkflowEngine.step_agent_id/2) or a bare run-id
  # key, then filtered by the active category set + the `show_system?` toggle so the swimlane
  # squares honor the same toggle as the center event stream (issue filter-sys-logs).
  @spec workflow_step_squares([map()], Ecto.UUID.t(), MapSet.t(), boolean()) :: %{
          optional(String.t()) => [map()]
        }
  defp workflow_step_squares(event_buffer, run_id, active, show_system?) do
    prefix = "wf-#{run_id}"

    event_buffer
    |> Enum.filter(fn row ->
      key = to_string(row.agent_key)

      (key == run_id or String.starts_with?(key, prefix)) and
        Shared.category_pass?(row, active, show_system?)
    end)
    |> Enum.group_by(&step_key(to_string(&1.agent_key), run_id, &1.step))
  end

  # Derive a row's step from its `"wf-<run_id>-<step>"` agent key when present, so both
  # the live-broadcast path and the backfilled path (`log_to_row/4` synthesizes
  # `agent_key = log.agent_id || log.session_id`, which for workflow-step rows is the
  # `"wf-<run_id>-<step>"` `session_id` since `agent_id` is nil) group under the named
  # step box — independent of whether the event payload carries `adw_step`. Non-`wf-`
  # keys (orchestrator/Python-ADW rows) fall back to the row's own `:step`.
  @spec step_key(String.t(), Ecto.UUID.t(), String.t()) :: String.t()
  defp step_key(agent_key, run_id, fallback_step) do
    prefix = "wf-#{run_id}-"

    if String.starts_with?(agent_key, prefix) do
      String.replace_prefix(agent_key, prefix, "")
    else
      fallback_step
    end
  end

  @spec counter(map(), String.t(), atom()) :: non_neg_integer()
  defp counter(counters, agent_id, key) do
    counters |> Map.get(agent_id, %{}) |> Map.get(key, 0)
  end

  # Whether the collapsible goal card has anything to show (so the collapse handle only appears
  # when there is a goal card, an open workstream, or an escalation). The queue status renders
  # separately (outside the drawer), so it is deliberately NOT a trigger here.
  @spec goal_card_present?(map()) :: boolean()
  defp goal_card_present?(assigns) do
    assigns.ledger != nil or assigns.workstreams != [] or
      assigns.orchestrator_holding_reason != nil
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
    Map.get(socket.assigns.agent_names, agent_id, Shared.short_id(agent_id))
  end

  @spec default_harness() :: String.t() | nil
  defp default_harness do
    known = HarnessRegistry.known()
    if "fake" in known, do: "fake", else: List.first(known)
  end

  # Cycle the chat-column width sm → md → lg → sm for the single toggle button.
  @spec next_chat_width(:sm | :md | :lg) :: :sm | :md | :lg
  defp next_chat_width(:sm), do: :md
  defp next_chat_width(:md), do: :lg
  defp next_chat_width(_lg), do: :sm

  @spec to_chat_width(String.t()) :: :sm | :md | :lg
  defp to_chat_width("md"), do: :md
  defp to_chat_width("lg"), do: :lg
  defp to_chat_width(_other), do: :sm

  # Live-row timestamp: format the current UTC instant as a full local datetime so
  # live rows match the backfill path (which formats the persisted `inserted_at`).
  @spec now_hms(String.t()) :: String.t()
  defp now_hms(timezone), do: RepoBuilder.Timezones.format_datetime(DateTime.utc_now(), timezone)
end
