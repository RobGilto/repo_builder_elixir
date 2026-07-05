defmodule RepoBuilderWeb.ConsoleLive.Shared do
  @moduledoc """
  Cross-panel helpers for the decomposed `ConsoleLive` (docs/audit-2026-07.md F3,
  Phase 3): functions used by more than one console panel module live here as public,
  `@spec`'d functions. Panel-local helpers stay private in their panel module.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, stream: 4]

  alias Phoenix.LiveView.Socket
  alias RepoBuilder.Adw.Combos
  alias RepoBuilder.{Budget, CostCenter, Definitions, Logs, Orchestrators, Projects, Workflows}
  alias RepoBuilder.Budget.Cap
  alias RepoBuilder.Console.EventPresenter
  alias RepoBuilder.Harness.Pi.Models, as: PiModels
  alias RepoBuilder.Harness.Registry, as: HarnessRegistry
  alias RepoBuilder.Orchestrator.Ledgers
  alias RepoBuilder.Orchestrator.Queue, as: OrchestratorQueue
  alias RepoBuilder.Orchestrator.Templates
  alias RepoBuilder.Orchestrator.Workstreams
  alias RepoBuilder.Settings
  alias RepoBuilder.Workflows.TitleHumanizer
  alias RepoBuilderWeb.AgentColors

  @buffer_limit 500
  @messages_limit 100

  @doc "Operator-facing message when no Fast-tier agent is configured (smart import, explain)."
  @spec no_fast_agent_message() :: String.t()
  def no_fast_agent_message do
    "No Fast agent configured — pick a harness + model for the Fast tier under Agents…"
  end

  # --- Cost Center tab (issue-cost-center / per-project-cost-tracking) ---

  @doc """
  Re-derive the Cost Center tab's data from the DB (no reliance on socket state, so a
  reconnect re-renders correctly). Cheap enough to run on each tab open.
  """
  @spec load_cost_center(Socket.t()) :: Socket.t()
  def load_cost_center(socket) do
    assign(socket,
      cost_rollups: CostCenter.rollup(include_hidden?: socket.assigns.show_hidden?),
      period_spend: CostCenter.period_spend(timezone: socket.assigns.timezone),
      price_rows: CostCenter.list_prices(),
      project_report: project_report_for(socket)
    )
  end

  # The active project's lifetime cost report + period strip for the Cost Center tab
  # (issue per-project-cost-tracking). `nil` when no project is selected (platform view).
  @spec project_report_for(Socket.t()) ::
          %{report: CostCenter.ProjectReport.t(), periods: map()} | nil
  defp project_report_for(socket) do
    case socket.assigns[:active_project_id] do
      id when is_binary(id) ->
        %{
          report: CostCenter.project_spend(id),
          periods: CostCenter.project_period_spend(id, timezone: socket.assigns.timezone)
        }

      _ ->
        nil
    end
  end

  # --- budget guardrails (issue-budget-guardrails) ---

  @doc """
  Seed the budget breaker snapshot + caps on the connected mount (and on reconnect,
  §9). The snapshot reads the live Guard; caps read the durable context.
  """
  @spec seed_budget(Socket.t()) :: Socket.t()
  def seed_budget(socket) do
    snapshot = Budget.Guard.snapshot()

    assign(socket,
      budget_state: snapshot,
      budget_caps: budget_rows(snapshot, Budget.list_caps()),
      budget_scope_targets: budget_scope_targets(socket)
    )
  end

  @doc """
  Seed the planf3 plan-image policy assigns (spec planf3-html-plans-for-heavy-adw-planner,
  Phase 5): the persisted placeholders toggle (default ON — zero image spend) and whether
  an `OPENAI_API_KEY` secret exists in either vault scope (project or platform, masked
  names only) so the General tab can warn when generation is enabled without a key.
  """
  @spec seed_planf3_image_policy(Socket.t()) :: Socket.t()
  def seed_planf3_image_policy(socket) do
    assign(socket,
      planf3_placeholders?: Settings.planf3_image_placeholders?(),
      planf3_key_present?: planf3_key_present?(socket.assigns[:active_project_id])
    )
  end

  @doc "Whether an OPENAI_API_KEY secret exists at project or platform scope (names only)."
  @spec planf3_key_present?(String.t() | nil) :: boolean()
  def planf3_key_present?(project_id) do
    (RepoBuilder.Secrets.list_names(project_id) ++ RepoBuilder.Secrets.list_names(nil))
    |> Enum.any?(&(&1.name == "OPENAI_API_KEY"))
  end

  # Merge the durable DB caps (authoritative + editable) with the live Guard snapshot
  # (spend/state), keyed by cap id. DB caps anchor the editable rows; snapshot-only caps
  # (a not-yet-reconciled memory cap) still surface so no cap is unreachable. A DB cap with
  # no live row yet renders at zero spend / :ok.
  @spec budget_rows(%{caps: [map()], kill_switch?: boolean()}, [Cap.t()]) :: [map()]
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

  @doc """
  Live id pickers for scoped caps: the console's own orchestrator and the recent
  workflow runs, labelled for humans so the operator never hand-types a raw UUID.
  """
  @spec budget_scope_targets(Socket.t()) :: %{
          String.t() => [{String.t(), String.t()}]
        }
  def budget_scope_targets(socket) do
    orchestrators =
      case socket.assigns[:orchestrator_id] do
        id when is_binary(id) -> [{"This console", id}]
        _ -> []
      end

    workflows =
      for run <- Workflows.list_recent_runs(20) do
        {"#{run.current_step || "run"} · #{String.slice(run.id, 0, 8)} (#{run.status})", run.id}
      end

    projects = for project <- Projects.list_projects(), do: {project.name, project.id}

    %{"orchestrator" => orchestrators, "workflow" => workflows, "project" => projects}
  end

  @doc "Re-read the live snapshot + durable caps after a breaker event or operator action."
  @spec refresh_budget(Socket.t()) :: Socket.t()
  def refresh_budget(socket), do: seed_budget(socket)

  # --- orchestrator selection / mutation ---

  @doc """
  Run an orchestrator mutation (set_harness/provider/model) and re-reflect the full
  selection in the header on success; flash on error. Shared by the setters.
  """
  @spec update_orchestrator(
          Socket.t(),
          (Ecto.UUID.t() ->
             {:ok, RepoBuilder.Orchestrator.Orchestrator.t()} | {:error, term()}),
          String.t()
        ) :: {:noreply, Socket.t()}
  def update_orchestrator(socket, mutate, error_message) do
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

  @doc """
  Reflect an orchestrator's full selection (harness + provider + model) and the
  per-harness option lists (from the registry) in the header assigns.
  """
  @spec assign_orchestrator_selection(
          Socket.t(),
          RepoBuilder.Orchestrator.Orchestrator.t()
        ) :: Socket.t()
  def assign_orchestrator_selection(socket, orchestrator) do
    rows = agent_model_rows(orchestrator)

    assign(socket,
      orchestrator_id: orchestrator.id,
      orchestrator_name: orchestrator.name,
      orchestrator_queue: OrchestratorQueue.snapshot(orchestrator.id),
      orchestrator_harness: orchestrator.harness,
      orchestrator_provider: orchestrator.provider,
      orchestrator_model: orchestrator.model,
      orchestrator_context: orchestrator_context_for(orchestrator),
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
      timezone: Orchestrators.timezone(orchestrator),
      ledger: Ledgers.view(orchestrator.id),
      workstreams: Workstreams.list_records(orchestrator.id),
      orchestrator_holding_reason: Orchestrators.holding_reason(orchestrator)
    )
  end

  @spec agent_models_updated_at(RepoBuilder.Orchestrator.Orchestrator.t()) :: String.t() | nil
  defp agent_models_updated_at(%RepoBuilder.Orchestrator.Orchestrator{metadata: metadata}) do
    metadata
    |> Map.get("agent_models", %{})
    |> Enum.find_value(fn {_cat, entry} -> entry["_updated_at"] end)
  end

  @doc """
  Build the per-category roster rows for the agent-models modal: each category's
  current {harness, provider, model} plus the option lists derived from them.
  """
  @spec agent_model_rows(RepoBuilder.Orchestrator.Orchestrator.t()) :: [map()]
  def agent_model_rows(orchestrator) do
    harnesses = orchestrator_harness_options()

    project_models = Orchestrators.agent_models(orchestrator)

    Enum.map(Orchestrators.agent_categories(), fn category ->
      # Show the EFFECTIVE tier: the per-project assignment when set, else the inherited
      # global default. `inherited?` drives the "inherited" badge + "reset" affordance.
      {effective_entry, source} = Orchestrators.effective_agent_model(orchestrator, category)
      effective_entry = effective_entry || %{}

      # When the project has explicitly chosen a harness (even without a model yet),
      # use the project entry for display and option computation. The effective_entry
      # would otherwise fall back to the global default (a different harness), which
      # would show the wrong provider/model options for the chosen harness.
      project_entry = Map.get(project_models, category, %{})
      project_harness = project_entry["harness"]

      {harness, provider, model} =
        if project_harness do
          {project_harness, project_entry["provider"], project_entry["model"]}
        else
          {effective_entry["harness"], effective_entry["provider"], effective_entry["model"]}
        end

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
        inherited?: is_nil(project_harness) and not is_nil(model) and source == :default,
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

  @doc """
  Rows for the Settings → Default Models tab: one per worker category, reading the
  operator's GLOBAL default roster (`RepoBuilder.Settings.default_agent_models/0`) — not
  any orchestrator. Same `{harness, provider, model}` + option-list shape as
  `agent_model_rows/1` so the same row component renders it.
  """
  @spec default_model_rows() :: [map()]
  def default_model_rows do
    roster = Settings.default_agent_models()
    harnesses = orchestrator_harness_options()

    Enum.map(Orchestrators.agent_categories(), fn category ->
      entry = Map.get(roster, category, %{})
      harness = entry["harness"]
      provider = entry["provider"]
      model = entry["model"]

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

  @doc """
  Real harnesses for the orchestrator toggle — the keyless `fake` harness is a
  dev/test stand-in, not an operator choice.
  """
  @spec orchestrator_harness_options() :: [String.t()]
  def orchestrator_harness_options,
    do: Enum.reject(HarnessRegistry.orchestrating_harnesses(), &(&1 == "fake"))

  # Seed the command-panel context bar: 0 when there's no resumable session (a cleared
  # or never-started conversation), else the orchestrator's latest persisted own-usage
  # occupancy. A model/provider/harness/cwd switch clears `session_id`, so this returns
  # 0 right after — the bar zeroes out exactly when the next turn will start fresh.
  @spec orchestrator_context_for(RepoBuilder.Orchestrator.Orchestrator.t()) :: non_neg_integer()
  defp orchestrator_context_for(%{session_id: nil}), do: 0

  defp orchestrator_context_for(orchestrator),
    do: Logs.orchestrator_context_tokens(orchestrator.id)

  # --- small cross-panel utilities ---

  @doc "Trim a string to nil when blank, else the trimmed value. A nil in is a nil out."
  @spec nilify_blank(String.t() | nil) :: String.t() | nil
  def nilify_blank(nil), do: nil

  def nilify_blank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  @doc "First 8 characters of an id, for compact display."
  @spec short_id(String.t()) :: String.t()
  def short_id(id), do: id |> to_string() |> String.slice(0, 8)

  @doc "Pretty-encode a payload for the detail panel (inspect fallback on encode error)."
  @spec pretty_json(term()) :: String.t()
  def pretty_json(value) do
    case Jason.encode(value, pretty: true) do
      {:ok, json} -> json
      {:error, _reason} -> inspect(value, pretty: true)
    end
  end

  @doc """
  The workflow stage of one event row: the envelope's `adw_step` when present, else the
  `"_workflow"` fallback (mirrors the reference's `event.adw_step || '_workflow'`).
  """
  @spec event_step(map()) :: String.t()
  def event_step(payload) when is_map(payload) do
    case payload["adw_step"] do
      step when is_binary(step) and step != "" -> step
      _ -> "_workflow"
    end
  end

  def event_step(_payload), do: "_workflow"

  @doc """
  Append a chat entry (nil ⇒ no-op) to the bounded chat-pane message list, stamping the
  entry's id (`seq`) and compact local time.
  """
  @spec append_chat([map()], map() | nil, pos_integer(), String.t()) :: [map()]
  def append_chat(messages, nil, _seq, _timezone), do: messages

  def append_chat(messages, chat, seq, timezone) do
    entry = Map.merge(chat, %{id: seq, time: now_hm(timezone)})
    Enum.take(messages ++ [entry], -@messages_limit)
  end

  # Chat-entry timestamp: compact local time-of-day.
  @spec now_hm(String.t()) :: String.t()
  defp now_hm(timezone), do: RepoBuilder.Timezones.format_time(DateTime.utc_now(), timezone)

  @doc "Seed the agent-template settings tab's rows from the Templates context."
  @spec assign_template_rows(Socket.t()) :: Socket.t()
  def assign_template_rows(socket), do: assign(socket, :template_rows, Templates.list())

  # --- definitions palette ---

  @doc """
  Seed the three file-derived palette assigns from the merged (app + working-dir)
  root for the orchestrator's current working dir. Re-run when the working dir
  changes so the overlay updates immediately.
  """
  @spec seed_definitions(Socket.t()) :: Socket.t()
  def seed_definitions(socket) do
    working_dir = nilify_blank(socket.assigns.orchestrator_working_dir)

    %{slash_command: slash, agent: agents, adw: adws} =
      Definitions.all(working_dir)

    assign(socket,
      slash_commands: slash,
      agent_defs: agents,
      adws: adws,
      adw_combos: Combos.list(working_dir),
      adw_loadable: Combos.loadable(working_dir)
    )
  end

  # --- reconnect backfill (event stream + chat pane) ---

  @doc """
  Seed each agent card's CONTEXT WINDOW bar from the latest persisted `usage` row,
  mirroring `seed_agent_costs/1`. Without this an agent whose work predates the
  mount (or any reconnect) shows an empty bar even though its logs are backfilled.
  """
  @spec seed_context_tokens(Socket.t()) :: Socket.t()
  def seed_context_tokens(socket) do
    assign(socket, :context_tokens, Logs.context_tokens_by_agent())
  end

  @doc """
  Seed the per-card category counters (responses/tools/hooks/thinking) from
  persisted logs so a reconnect restores them; the seeded shape matches what
  `bump_counter/3` expects, so later live increments merge cleanly.
  """
  @spec seed_counters(Socket.t()) :: Socket.t()
  def seed_counters(socket) do
    assign(socket, :counters, Logs.event_counts_by_agent())
  end

  @doc """
  Re-seed the center stream + chat buffer from the most-recent global logs so a
  reconnect backfills instead of starting empty (§9 reconnect rule).
  """
  @spec backfill_events(Socket.t()) :: Socket.t()
  def backfill_events(socket) do
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

    # Filter the buffered rows through the active filter chain BEFORE pushing to the
    # stream so the on-mount view honors every LiveView assign (including the new
    # `@show_system?` toggle, issue filter-sys-logs). The full `event_buffer` keeps
    # every row so a future toggle ON reveals them without a DB round-trip; only the
    # rendered stream is narrowed here, mirroring `restream/1`.
    stream_rows = Enum.filter(rows, &passes?(&1, socket.assigns))

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
    |> stream(:events, stream_rows, reset: true)
  end

  # Build the chat pane's `@messages` from the ACTIVE orchestrator's scoped backfill
  # query (issue-conversation-history-scope) so the conversation follows the project
  # switcher and survives a restart even when worker rows dominate the global stream.
  # Reuses the live path's `log_to_row/4` → `chat_for_row/1` → `append_chat/3` helpers
  # (single source of truth) with its OWN `seq` so chat entry ids never collide with the
  # center stream. A nil active orchestrator (deep-link/disconnected edge) yields an
  # empty pane — the correct "no brain selected" state, never a global mix.
  @spec backfill_messages(Socket.t(), String.t()) :: [map()]
  defp backfill_messages(socket, timezone) do
    socket.assigns.orchestrator_id
    |> scoped_orchestrator_messages(socket.assigns.show_hidden?)
    |> Enum.reduce({[], 0}, fn log, {msgs, seq} ->
      seq = seq + 1
      row = log_to_row(log, seq, socket.assigns.agent_names, timezone)
      {append_chat(msgs, chat_for_row(row), seq, timezone), seq}
    end)
    |> elem(0)
    |> Enum.take(-@messages_limit)
  end

  # Scoped chat backfill: the active orchestrator's own conversation rows, or `[]`
  # when no brain is selected (nil active id). Keeps the `Repo` access behind the
  # `Logs` context (§8) and the nil-edge handling out of the reduce above.
  @spec scoped_orchestrator_messages(Ecto.UUID.t() | nil, boolean()) :: [Logs.AgentLog.t()]
  defp scoped_orchestrator_messages(orchestrator_id, show_hidden?)
       when is_binary(orchestrator_id) do
    Logs.list_orchestrator_messages(orchestrator_id, @messages_limit, show_hidden?)
  end

  defp scoped_orchestrator_messages(_orchestrator_id, _show_hidden?), do: []

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
      # Stage from the persisted payload's `adw_step` (reconnect path) — identical to the
      # live `record_event/4` derivation so backfill groups into the same stage lanes.
      step: event_step(log.payload),
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

  # The chat pane is orchestrator ↔ user only. Orchestrator turns broadcast under an
  # `"orch-#{orchestrator_id}-#{n}"` agent_id (orchestrator/server.ex:85,113); worker
  # DB agents broadcast under their Ecto UUID (never `"orch-"`). Gate every chat-pane
  # surface on this so worker text stays in the center event stream, not the chat.
  @spec orchestrator_event?(String.t()) :: boolean()
  defp orchestrator_event?(agent_id), do: String.starts_with?(to_string(agent_id), "orch-")

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

  # --- event-stream filtering (re-stream from the bounded buffer) ---

  @doc "Re-filter the bounded event buffer through the active filters and reset the stream."
  @spec restream(Socket.t()) :: Socket.t()
  def restream(socket) do
    filtered = Enum.filter(socket.assigns.event_buffer, &passes?(&1, socket.assigns))
    stream(socket, :events, filtered, reset: true)
  end

  @doc "Whether a buffered row passes the active category/agent/project/search filters."
  @spec passes?(map(), map()) :: boolean()
  def passes?(row, assigns) do
    category_pass?(row, assigns.active_categories, assigns.show_system?) and
      agent_pass?(row, assigns.active_agents) and
      project_pass?(row, assigns) and
      search_pass?(row.body, assigns.search, assigns.regex?)
  end

  # Project-scope predicate (issue-scope-logs-to-active-project): when scope is on, a
  # project is active, and the owned-key set is non-empty, require the row's `agent_key`
  # to belong to the active project's orchestrator + workers. Otherwise no-op — scope
  # off, no active project, or an empty (unresolved) set all fail-open to the global feed.
  #
  # Worker rows carry a bare worker UUID `agent_key`, which matches `project_agent_keys`
  # exactly. The bound orchestrator, however, broadcasts its identity in three formats
  # that all share the `"orch-<orchestrator_id>"` prefix but never equal the bare UUID:
  # live turn keys `"orch-<id>-<int>"` (server.ex), live op keys `"orch-<id>-op-<int>"`
  # (logs.ex), and backfill keys `"orch-<id>"` (log_to_row). An exact-string membership
  # test therefore drops every orchestrator row. Match orchestrator ownership by the
  # `"orch-<orchestrator_id>"` prefix off the single active `orchestrator_id` so all three
  # formats — live and backfill — are accepted at this one site.
  @spec project_pass?(map(), map()) :: boolean()
  defp project_pass?(row, assigns) do
    if assigns.project_scoped? and assigns.active_project_id != nil and
         MapSet.size(assigns.project_agent_keys) > 0 do
      key = to_string(row.agent_key)

      MapSet.member?(assigns.project_agent_keys, key) or
        orchestrator_owned?(key, assigns[:orchestrator_id])
    else
      true
    end
  end

  # Orchestrator-ownership check for project scope: all of the bound orchestrator's
  # `agent_key` formats share the `"orch-<orchestrator_id>"` prefix, and worker UUIDs
  # (Ecto `binary_id`/UUIDv4, hex+hyphen) can never carry an `"orch-"` prefix, so a prefix
  # test against the single active `orchestrator_id` is correct and cannot misclassify a
  # worker row. A nil active orchestrator owns nothing.
  @spec orchestrator_owned?(String.t(), String.t() | nil) :: boolean()
  defp orchestrator_owned?(_key, nil), do: false

  defp orchestrator_owned?(key, orchestrator_id),
    do: String.starts_with?(key, "orch-#{orchestrator_id}")

  # Category filter predicate. The `:system` clause short-circuits on `show_system?` —
  # the only categories field-toggled by the operator remain the four
  # `:response | :tool | :thinking | :hook` entries in `active_categories`. Keeping the
  # system predicate as a fail-fast FIRST conjunct of `passes?/2` means an off-toggle
  # never re-surfaces system rows via the agent / project / search predicates
  # (issue filter-sys-logs).
  @spec category_pass?(map(), MapSet.t(), boolean()) :: boolean()
  def category_pass?(%{category: :system}, _active, false), do: false
  def category_pass?(%{category: :system}, _active, true), do: true

  def category_pass?(%{category: category}, active, _show_system?),
    do: MapSet.member?(active, category)

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

  # --- event-stream selection ---

  @doc "Selected rows in buffer order (so bulk actions read top-to-bottom, not click order)."
  @spec selected_rows([map()], MapSet.t()) :: [map()]
  def selected_rows(event_buffer, selected_ids) do
    Enum.filter(event_buffer, &MapSet.member?(selected_ids, &1.id))
  end

  # --- Log Database manager (issue-log-db-manager) ---

  @doc """
  Re-query the Log Database manager page (rows + total) for the current filter/offset,
  clamping the offset down if the active filter shrank below it (e.g. after a purge or a
  visibility change moved rows out of the filtered set). Single source of truth for the
  manager's table state, shared by the connected mount and every mutating action.
  """
  @spec seed_log_manager(Socket.t()) :: Socket.t()
  def seed_log_manager(socket) do
    %{log_mgr_filter: filter, log_mgr_limit: limit, log_mgr_offset: offset} = socket.assigns
    total = Logs.count_agent_logs(filter)
    offset = clamp_page_offset(offset, limit, total)
    rows = Logs.query_agent_logs(filter, limit, offset)

    assign(socket, log_mgr_rows: rows, log_mgr_total: total, log_mgr_offset: offset)
  end

  @doc "Alias of `seed_log_manager/1` for post-action refreshes."
  @spec refresh_log_manager(Socket.t()) :: Socket.t()
  def refresh_log_manager(socket), do: seed_log_manager(socket)

  # Largest valid offset is the start of the last page; clamp into `[0, last_page_start]`.
  @spec clamp_page_offset(integer(), pos_integer(), non_neg_integer()) :: non_neg_integer()
  defp clamp_page_offset(offset, limit, total) do
    max_offset = if total == 0, do: 0, else: div(max(total - 1, 0), limit) * limit
    offset |> max(0) |> min(max_offset)
  end

  # --- workflow swimlane views ---

  @doc """
  Seed the per-step workflow views from the most-recent runs so the ADWS view shows
  per-step squares on connect (a reconnect backfills rather than starting empty).
  """
  @spec seed_workflow_progress(Socket.t()) :: Socket.t()
  def seed_workflow_progress(socket) do
    runs = Workflows.list_recent_runs(50, socket.assigns.show_hidden?)

    # One batched lookup for every run's Workflow (title/type) — previously a
    # per-run Repo.get, i.e. up to 50 sequential queries on every mount
    # (console-mount-seed-optimization Phase 2 N+1 fix).
    workflows_by_id =
      runs
      |> Enum.map(& &1.workflow_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Workflows.get_workflows_by_ids()

    progress = Map.new(runs, fn run -> {run.id, workflow_view(run, workflows_by_id)} end)

    assign(socket, :workflow_progress, progress)
  end

  # Build a per-step workflow view from a run (seed/refetch path): full status + cost
  # from the row, the derived per-step progress (ordered, branching-safe), a derived
  # duration, and a human-friendly `title` (from the pre-fetched workflows map — the
  # seed loop batches the lookups; a per-run Repo.get here would be an N+1).
  # Inference-only spec — the concrete view map narrows below `map()` under :underspecs.
  defp workflow_view(run, workflows_by_id) do
    progress = Workflows.run_progress(run)
    workflow = run.workflow_id && Map.get(workflows_by_id, run.workflow_id)

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
    # First non-blank candidate wins; the `fallback_title/1` tail is always a binary, so
    # the title is never nil. Expressed as `Enum.find/2` over the candidates rather than a
    # 5-deep `||` chain — Dialyzer loses the `nil`-narrowing across the long chain and would
    # otherwise infer a spurious `nil` in the return range (missing_range false positive).
    candidates = [
      meta_title(workflow),
      human_name(workflow),
      human_type(workflow),
      step_title(run)
    ]

    case Enum.find(candidates, &is_binary/1) do
      title when is_binary(title) -> title
      nil -> fallback_title(run)
    end
  end

  # The guaranteed non-nil tail of the title resolution: a short, never-raw `"ADW <short>"`.
  @spec fallback_title(Workflows.WorkflowRun.t()) :: String.t()
  defp fallback_title(run), do: "ADW " <> short_id(run.id)

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
end
