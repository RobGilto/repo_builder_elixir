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
      swimlane_row: 1,
      swimlane: 1,
      workflow_swimlane: 1,
      event_square: 1,
      event_detail_panel: 1
    ]

  alias RepoBuilder.{Agents, Dashboard, Logs, Orchestrators, Session, WorkflowEngine, Workflows}
  alias RepoBuilder.Agents.Agent
  alias RepoBuilder.Harness.Event
  alias RepoBuilder.Harness.Pi.Models, as: PiModels
  alias RepoBuilder.Harness.Registry, as: HarnessRegistry
  alias RepoBuilder.Orchestrator.Server, as: OrchestratorServer
  alias RepoBuilder.Orchestrator.Templates
  alias RepoBuilderWeb.AgentColors

  @categories [:response, :tool, :thinking, :hook]
  @buffer_limit 500
  @messages_limit 100
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
        selected_agent_id: nil,
        orchestrator_id: nil,
        orchestrator_harness: nil,
        orchestrator_provider: nil,
        orchestrator_model: nil,
        provider_options: [],
        model_options: [],
        recent_models: [],
        agent_model_rows: [],
        # System-prompt settings: safe defaults for the disconnected render (mount
        # runs twice); the connected socket reflects the orchestrator's real values.
        orchestrator_system_prompt: "",
        orchestrator_system_prompt_mode: :append,
        orchestrator_default_prompt: "",
        orchestrator_reasoning_effort: :default,
        view_mode: :logs,
        rail_collapsed?: false,
        chat_width: :sm,
        auto_follow?: true,
        show_thinking?: true,
        settings_tab: :general,
        # Agent-template settings tab. Defaults are safe for the disconnected render;
        # the connected mount seeds the real rows from the Templates context.
        template_rows: [],
        selected_template: nil,
        template_versions: [],
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
        connected?: connected?(socket),
        harness_options: HarnessRegistry.known(),
        # ADW Builder mode
        adw_builder?: false,
        adw_steps: [],
        adw_name: "",
        adw_harness: nil,
        adw_local?: false
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
        |> seed_lanes()
        |> seed_workflow_progress()
        |> seed_cost()
        |> backfill_events()
        |> assign_orchestrator()
        |> assign_template_rows()
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
    assign(socket,
      orchestrator_id: orchestrator.id,
      orchestrator_harness: orchestrator.harness,
      orchestrator_provider: orchestrator.provider,
      orchestrator_model: orchestrator.model,
      provider_options: provider_options_for(orchestrator.harness),
      model_options: model_options_for(orchestrator.harness, orchestrator.provider),
      recent_models: Orchestrators.recent_models(orchestrator, orchestrator.provider),
      agent_model_rows: agent_model_rows(orchestrator),
      orchestrator_system_prompt: orchestrator.system_prompt || "",
      orchestrator_system_prompt_mode: orchestrator.system_prompt_mode,
      orchestrator_default_prompt: Orchestrators.default_system_prompt(orchestrator),
      orchestrator_reasoning_effort: orchestrator.reasoning_effort
    )
  end

  # Build the per-category roster rows for the agent-models modal: each category's
  # current {harness, provider, model} plus the option lists derived from them.
  @spec agent_model_rows(RepoBuilder.Orchestrator.Orchestrator.t()) :: [map()]
  defp agent_model_rows(orchestrator) do
    roster = Orchestrators.agent_models(orchestrator)
    harnesses = orchestrator_harness_options()

    Enum.map(Orchestrators.agent_categories(), fn category ->
      entry = Map.get(roster, category, %{})
      harness = entry["harness"]
      provider = entry["provider"]

      %{
        category: category,
        harness: harness,
        provider: provider,
        model: entry["model"],
        harness_options: harnesses,
        provider_options: if(harness, do: provider_options_for(harness), else: []),
        model_options: if(harness, do: model_options_for(harness, provider), else: [])
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

  @spec subscribe_feeds(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp subscribe_feeds(socket) do
    :ok = Dashboard.subscribe()
    :ok = Dashboard.subscribe_events()
    socket
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

  @spec seed_agent_costs(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp seed_agent_costs(socket) do
    costs = Map.new(socket.assigns.agents, &{&1.id, nilify_zero(Logs.cost_rollup!(&1.id))})
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

  # Seed the per-step workflow views from the most-recent runs so the ADWS view shows
  # per-step squares on connect (a reconnect backfills rather than starting empty).
  @spec seed_workflow_progress(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp seed_workflow_progress(socket) do
    progress =
      Map.new(Workflows.list_recent_runs(), fn run -> {run.id, workflow_view(run)} end)

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
  # until a lane status says otherwise).
  @spec default_workflow_view(Ecto.UUID.t()) :: map()
  defp default_workflow_view(run_id) do
    %{
      run_id: run_id,
      status: :running,
      current: nil,
      cost: nil,
      completed: 0,
      total: 0,
      steps: []
    }
  end

  # Build a per-step workflow view from a run (seed/refetch path): full status + cost
  # from the row, plus the derived per-step progress (ordered, branching-safe).
  # Inference-only spec — the concrete view map narrows below `map()` under :underspecs.
  defp workflow_view(run) do
    progress = Workflows.run_progress(run)

    %{
      run_id: run.id,
      status: run.status,
      current: run.current_step,
      cost: run.total_cost_usd,
      completed: progress.completed,
      total: progress.total,
      steps: progress.steps
    }
  end

  @spec seed_cost(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp seed_cost(socket) do
    cost =
      Enum.reduce(socket.assigns.agents, nil, fn agent, acc ->
        accumulate_cost(acc, Logs.cost_rollup!(agent.id))
      end)

    assign(socket, :cost, nilify_acc(cost))
  end

  @spec nilify_acc(Decimal.t() | nil) :: Decimal.t() | nil
  defp nilify_acc(nil), do: nil
  defp nilify_acc(%Decimal{} = d), do: if(Decimal.equal?(d, 0), do: nil, else: d)

  # Re-seed the center stream + chat buffer from the most-recent global logs so a
  # reconnect backfills instead of starting empty (§9 reconnect rule).
  @spec backfill_events(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp backfill_events(socket) do
    logs = Logs.list_recent_global(200)

    {rows, messages, seq} =
      Enum.reduce(logs, {[], [], 0}, fn log, {rows, msgs, seq} ->
        seq = seq + 1
        row = log_to_row(log, seq, socket.assigns.agent_names)
        msgs = append_chat(msgs, chat_for_row(row), seq)
        {rows ++ [row], msgs, seq}
      end)

    rows = Enum.take(rows, -@buffer_limit)

    socket
    |> assign(event_buffer: rows, messages: Enum.take(messages, -@messages_limit), seq: seq)
    # A reconnect starts from persisted finalized history only — drop any stale
    # in-flight streaming buffer so no token shards survive the reconnect (§9).
    |> assign(streaming: %{}, stream_pending: %{}, stream_flush_ref: nil)
    |> stream(:events, rows, reset: true)
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

  # Assign a worker category's harness/provider/model (agent-models modal). Cascade:
  # changing the harness clears provider+model; changing the provider clears model.
  def handle_event("set_agent_model", %{"category" => category} = params, socket) do
    attrs = agent_model_attrs(params)

    update_orchestrator(
      socket,
      &Orchestrators.set_agent_model(&1, category, attrs),
      "Could not set agent model"
    )
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

  # Persist the harness-blind reasoning effort immediately (consistent with the other
  # orchestrator settings). The next run_turn spawns with the per-harness flag.
  def handle_event("set_reasoning_effort", %{"effort" => effort}, socket) do
    update_orchestrator(
      socket,
      &Orchestrators.set_reasoning_effort(&1, reasoning_effort(effort)),
      "Could not set reasoning effort"
    )
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

  def handle_event("view:toggle", _params, socket), do: {:noreply, toggle_view(socket)}

  def handle_event("toggle_rail", _params, socket),
    do: {:noreply, assign(socket, :rail_collapsed?, not socket.assigns.rail_collapsed?)}

  def handle_event("set_chat_width", %{"width" => width}, socket),
    do: {:noreply, assign(socket, :chat_width, to_chat_width(width))}

  def handle_event("select_agent", %{"id" => id}, socket) do
    {:noreply, assign(socket, :selected_agent_id, id)}
  end

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
    harness = socket.assigns.adw_harness || socket.assigns.orchestrator_harness || "fake"
    name = if socket.assigns.adw_name == "", do: "custom-adw", else: socket.assigns.adw_name
    name = String.replace(name, " ", "-")

    if steps == [] do
      {:noreply, put_flash(socket, :error, "Add at least one step before launching")}
    else
      step_list =
        steps
        |> Enum.map(fn s ->
          %{
            "name" => s.name,
            "harness" => harness,
            "on_success" => "done",
            "on_failure" => "abort"
          }
        end)
        |> Enum.with_index()
        |> Enum.map(fn {step, i} ->
          next = Enum.at(steps, i + 1)
          if next, do: Map.put(step, "on_success", next.name), else: step
        end)

      case Workflows.create_workflow(%{
             name: "#{name}-#{System.unique_integer([:positive])}",
             type: "custom",
             steps: step_list
           }) do
        {:ok, wf} ->
          case WorkflowEngine.start_workflow(wf, inputs: %{"input" => name}) do
            {:ok, _run_id, _pid} ->
              {:noreply,
               socket
               |> assign(adw_builder?: false, adw_steps: [], adw_name: "")
               |> put_flash(:info, "ADW launched — check the ADWS tab")}

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, "Could not start ADW: #{inspect(reason)}")}
          end

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Could not create workflow: #{inspect(reason)}")}
      end
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

  def handle_event("toggle_agent_filter", %{"name" => name}, socket) do
    active =
      if name in socket.assigns.active_agents,
        do: List.delete(socket.assigns.active_agents, name),
        else: [name | socket.assigns.active_agents]

    {:noreply, socket |> assign(:active_agents, active) |> restream()}
  end

  def handle_event("set_search", %{"q" => q}, socket),
    do: {:noreply, socket |> assign(:search, q) |> restream()}

  def handle_event("toggle_regex", _params, socket),
    do: {:noreply, socket |> assign(:regex?, not socket.assigns.regex?) |> restream()}

  def handle_event("toggle_auto_follow", _params, socket),
    do: {:noreply, assign(socket, :auto_follow?, not socket.assigns.auto_follow?)}

  def handle_event("toggle_thinking", _params, socket),
    do: {:noreply, assign(socket, :show_thinking?, not socket.assigns.show_thinking?)}

  def handle_event("select_settings_tab", %{"tab" => tab}, socket),
    do: {:noreply, assign(socket, :settings_tab, settings_tab(tab))}

  def handle_event("clear_filters", _params, socket) do
    {:noreply,
     socket
     |> assign(
       active_categories: MapSet.new(@categories),
       active_agents: [],
       search: "",
       regex?: false
     )
     |> restream()}
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

  # No selected agent ⇒ route the prompt to the ORCHESTRATOR brain (issue-c): it
  # chooses/creates/dispatches workers. A selected agent keeps the manual
  # single-agent run as an explicit fallback. The hard "select an agent" gate is gone.
  @spec run_prompt(Phoenix.LiveView.Socket.t(), String.t(), String.t() | nil, String.t() | nil) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  defp run_prompt(socket, prompt, harness, model) do
    case socket.assigns.selected_agent_id do
      nil ->
        {:noreply, run_orchestrator(socket, prompt)}

      agent_id ->
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

  @spec run_orchestrator(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  defp run_orchestrator(socket, prompt) do
    socket = push_user_message(socket, prompt)

    case socket.assigns.orchestrator_id do
      nil ->
        put_flash(socket, :error, "No orchestrator available")

      orchestrator_id ->
        case OrchestratorServer.run_turn(orchestrator_id, prompt) do
          {:ok, _agent_id} ->
            socket

          {:error, :not_orchestrator_capable} ->
            put_flash(socket, :error, "Orchestrator harness can't orchestrate")

          {:error, :no_model_selected} ->
            put_flash(socket, :error, "No model selected — pick a model in the header")

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

  # Cascade an agent-models row change: changing harness clears provider+model;
  # changing provider clears model; changing model keeps the row as posted.
  @spec agent_model_attrs(map()) :: %{optional(String.t()) => String.t() | nil}
  defp agent_model_attrs(%{"_target" => ["harness" | _]} = params) do
    %{"harness" => nilify_blank(params["harness"]), "provider" => nil, "model" => nil}
  end

  defp agent_model_attrs(%{"_target" => ["provider" | _]} = params) do
    %{
      "harness" => nilify_blank(params["harness"]),
      "provider" => nilify_blank(params["provider"]),
      "model" => nil
    }
  end

  defp agent_model_attrs(params) do
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
    |> assign(:messages, append_chat(socket.assigns.messages, msg, seq))
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

  @impl true
  def handle_info({:agent_event, agent_id, %Event.SessionStarted{} = event}, socket) do
    {:noreply,
     socket
     |> set_status(agent_id, :running)
     |> record_event(agent_id, %{
       category: :system,
       kind: "session",
       body: "session #{event.session_id}",
       payload: event.raw
     })}
  end

  # Incremental token delta — coalesce into the per-agent streaming buffer (no
  # center-log row, no per-token counter); a throttled flush commits it to render.
  def handle_info({:agent_event, agent_id, %Event.TextDelta{partial?: true} = event}, socket) do
    {:noreply, accumulate_partial(socket, agent_id, channel(event.thinking?), event.text)}
  end

  # Finalized thinking block — clear the in-flight thinking buffer, then record the
  # one permanent thinking message + center row.
  def handle_info({:agent_event, agent_id, %Event.TextDelta{thinking?: true} = event}, socket) do
    socket = finalize_stream_channel(socket, agent_id, :thinking)

    {:noreply,
     record_event(socket, agent_id, %{
       category: :thinking,
       kind: "thinking",
       body: event.text,
       thinking?: true,
       payload: event.raw,
       chat: %{role: :thinking, label: nil, content: event.text, tool_name: nil, params_json: nil}
     })}
  end

  # Finalized text block — clear the in-flight text buffer, then record the one
  # permanent orchestrator message + center row.
  def handle_info({:agent_event, agent_id, %Event.TextDelta{} = event}, socket) do
    socket = finalize_stream_channel(socket, agent_id, :text)

    {:noreply,
     record_event(socket, agent_id, %{
       category: :response,
       kind: "text",
       body: event.text,
       payload: event.raw,
       chat: %{
         role: :orchestrator,
         label: "ORCHESTRATOR",
         content: event.text,
         tool_name: nil,
         params_json: nil
       }
     })}
  end

  # Throttled flush tick: commit accumulated partials into the rendered streaming
  # map (one render), drain pending, and clear the timer so the next partial reschedules.
  def handle_info(:flush_stream, socket) do
    streaming = merge_pending(socket.assigns.streaming, socket.assigns.stream_pending)

    {:noreply, assign(socket, streaming: streaming, stream_pending: %{}, stream_flush_ref: nil)}
  end

  def handle_info({:agent_event, agent_id, %Event.ToolCall{} = event}, socket) do
    {:noreply,
     record_event(socket, agent_id, %{
       category: :tool,
       kind: "tool_call",
       body: "#{event.name} #{inspect(event.input)}",
       payload: event.raw,
       chat: %{
         role: :tool,
         label: event.name,
         content: nil,
         tool_name: event.name,
         params_json: pretty_json(event.input)
       }
     })}
  end

  def handle_info({:agent_event, agent_id, %Event.ToolResult{} = event}, socket) do
    {:noreply,
     record_event(socket, agent_id, %{
       category: :tool,
       kind: "tool_result",
       body: inspect(event.content),
       payload: event.raw
     })}
  end

  def handle_info({:agent_event, agent_id, %Event.Usage{} = event}, socket) do
    {:noreply,
     socket
     |> add_cost(event.cost_usd)
     |> add_agent_cost(agent_id, event.cost_usd)
     |> put_context(agent_id, event.input_tokens + event.output_tokens)
     |> record_event(agent_id, %{
       category: :system,
       kind: "usage",
       body: "in=#{event.input_tokens} out=#{event.output_tokens}",
       tokens: "#{event.input_tokens + event.output_tokens}t",
       payload: event.raw
     })}
  end

  def handle_info({:agent_event, agent_id, %Event.Status{} = event}, socket) do
    {:noreply,
     record_event(socket, agent_id, %{
       category: :hook,
       kind: "status",
       body: "#{event.kind} #{inspect(event.detail)}",
       payload: event.raw
     })}
  end

  def handle_info({:agent_event, agent_id, %Event.Done{} = event}, socket) do
    status = if event.ok, do: :succeeded, else: :failed

    {:noreply,
     socket
     |> flush_streaming_agent(agent_id)
     |> set_status(agent_id, status)
     |> add_cost(event.cost_usd)
     |> add_agent_cost(agent_id, event.cost_usd)
     |> record_event(agent_id, %{
       category: :system,
       kind: "done",
       body: "reason=#{event.reason}",
       payload: event.raw
     })}
  end

  def handle_info({:agent_event, agent_id, %Event.Error{} = event}, socket) do
    {:noreply,
     socket
     |> flush_streaming_agent(agent_id)
     |> set_status(agent_id, :error)
     |> record_event(agent_id, %{
       category: :system,
       kind: "error",
       body: "#{event.reason}: #{event.message}",
       payload: event.raw
     })}
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

  def handle_info({:orchestrator_updated, orchestrator}, socket) do
    if orchestrator.id == socket.assigns.orchestrator_id do
      {:noreply, assign_orchestrator_selection(socket, orchestrator)}
    else
      {:noreply, socket}
    end
  end

  # A worker the orchestrator just deleted (issue agent-CRUD): drop it from the
  # rail roster + the swimlane stream live. Idempotent for an already-absent worker.
  def handle_info({:agent_deleted, %Agent{} = agent}, socket) do
    {:noreply,
     socket
     |> assign(:agents, Enum.reject(socket.assigns.agents, &(&1.id == agent.id)))
     |> assign(:agent_names, Map.delete(socket.assigns.agent_names, agent.id))
     |> assign(:statuses, Map.delete(socket.assigns.statuses, agent.id))
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

  # The single hot path: append to the bounded buffer, bump pills + counters, push
  # into the stream only if the row passes the active filters, and append a chat
  # entry where one applies.
  # Inference-only spec — dialyzer narrows `attrs` to the specific per-variant map
  # shapes, which a hand-written map() spec would supertype under :underspecs.
  defp record_event(socket, agent_id, attrs) do
    seq = socket.assigns.seq + 1

    row = %{
      id: seq,
      line: seq,
      agent: agent_label(socket, agent_id),
      agent_key: agent_id,
      color: AgentColors.hex(to_string(agent_id)),
      category: attrs.category,
      kind: attrs.kind,
      body: to_string(attrs.body),
      thinking?: Map.get(attrs, :thinking?, false),
      tokens: Map.get(attrs, :tokens),
      time: now_hms(),
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
    do: assign(socket, :messages, append_chat(socket.assigns.messages, chat, seq))

  @spec append_chat([map()], map() | nil, pos_integer()) :: [map()]
  defp append_chat(messages, nil, _seq), do: messages

  defp append_chat(messages, chat, seq) do
    entry = Map.merge(chat, %{id: seq, time: now_hm()})
    Enum.take(messages ++ [entry], -@messages_limit)
  end

  # --- live streaming buffer (partials coalesced per agent + channel) -------

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

    {messages, seq} =
      {socket.assigns.messages, socket.assigns.seq}
      |> promote_channel(leftover.text, :text)
      |> promote_channel(leftover.thinking, :thinking)

    socket
    |> assign(:messages, messages)
    |> assign(:seq, seq)
    |> assign(:streaming, Map.delete(socket.assigns.streaming, agent_id))
    |> assign(:stream_pending, Map.delete(socket.assigns.stream_pending, agent_id))
  end

  @spec promote_channel({[map()], non_neg_integer()}, String.t(), :text | :thinking) ::
          {[map()], non_neg_integer()}
  defp promote_channel({messages, seq}, text, channel) do
    if String.trim(text) == "" do
      {messages, seq}
    else
      seq = seq + 1
      {append_chat(messages, stream_chat(channel, text), seq), seq}
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
  defp agent_pass?(row, active), do: row.agent in active

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

  # nil never coerced to 0 (preserves the unpriced distinction); a float crosses the
  # float→Decimal boundary here, a Decimal (seed rollup) accumulates directly.
  @spec accumulate_cost(Decimal.t() | nil, Decimal.t() | float() | nil) :: Decimal.t() | nil
  defp accumulate_cost(current, nil), do: current

  defp accumulate_cost(current, %Decimal{} = cost),
    do: Decimal.add(current || Decimal.new(0), cost)

  defp accumulate_cost(current, cost) when is_float(cost),
    do: accumulate_cost(current, Decimal.from_float(cost))

  # --- render ---

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :swimlanes, agent_swimlanes(assigns))

    ~H"""
    <div class="console flex h-screen flex-col" data-theme="dark">
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

      <div
        class="grid min-h-0 flex-1"
        style={"grid-template-columns: #{rail_width(@rail_collapsed?)} 1fr #{chat_col(@chat_width)}"}
      >
        <aside
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
                  selected?={@selected_agent_id == agent.id}
                  pulse?={@pulsed_id == agent.id}
                  active?={Map.get(@statuses, agent.id, agent.status) == :running}
                />
              <% else %>
                <.agent_card
                  id={agent.id}
                  name={agent.name}
                  status={Map.get(@statuses, agent.id, agent.status)}
                  harness={agent.harness}
                  cost={Map.get(@agent_costs, agent.id)}
                  color={AgentColors.hex(agent.id)}
                  selected?={@selected_agent_id == agent.id}
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
          <div class={["flex min-h-0 flex-1 flex-col", @view_mode != :logs && "hidden"]}>
            <.filter_bar
              active_categories={@active_categories}
              active_agents={@active_agents}
              search={@search}
              regex?={@regex?}
              auto_follow?={@auto_follow?}
            />
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
                  agent={row.agent}
                  color={row.color}
                  category={row.category}
                  kind={row.kind}
                  body={row.body}
                  thinking?={row.thinking?}
                  tokens={row.tokens}
                  time={row.time}
                  expanded?={MapSet.member?(@expanded_ids, row.id)}
                />
              </div>
            </div>
          </div>

          <div id="swimlanes" class={["flex min-h-0 flex-1", @view_mode != :adws && "hidden"]}>
            <div class="flex min-h-0 flex-1 flex-col gap-2 overflow-y-auto p-2">
              <div id="workflow-runs" class="flex flex-col gap-2">
                <.workflow_swimlane
                  :for={view <- workflow_views(@workflow_progress)}
                  id={"workflow-#{view.run_id}"}
                  label={view.current || view.run_id}
                  status={view.status}
                  completed={view.completed}
                  total={view.total}
                  cost={view.cost}
                  steps={view.steps}
                />
              </div>

              <div id="agent-lanes" phx-update="stream" class="flex flex-col gap-2">
                <div :for={{dom_id, lane} <- @streams.lanes} id={dom_id}>
                  <.swimlane_row
                    id={lane.id}
                    label={lane.label}
                    status={lane.status}
                    kind={lane.kind}
                    harness={lane.harness}
                  />
                </div>
              </div>

              <.swimlane
                :for={lane <- @swimlanes}
                id={"swimlane-#{lane.key}"}
                label={lane.name}
                status={lane.status}
                kind={:agent}
              >
                <div :for={col <- lane.columns} class="flex flex-col items-center gap-1">
                  <span class="text-[0.5rem] uppercase" style="color: var(--cns-text-3)">{col.kind}</span>
                  <div class="flex flex-wrap gap-1" style="max-width: 6rem">
                    <.event_square
                      :for={row <- col.rows}
                      event_id={row.id}
                      category={row.category}
                      summary={"#{row.kind}: #{row.body}"}
                    />
                  </div>
                </div>
              </.swimlane>
            </div>

            <.event_detail_panel event={@selected_event} />
          </div>
        </main>

        <aside class="min-h-0 overflow-hidden border-l p-2" style="border-color: var(--cns-border)">
          <.command_panel
            chat_width={@chat_width}
            cost={@cost}
            typing?={@typing? || Map.get(@statuses, @orchestrator_id) == :running}
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
        </aside>
      </div>

      <.global_command_input
        harnesses={@harness_options}
        agents={Enum.map(@agents, & &1.name)}
        uploads={@uploads}
        adw_builder?={@adw_builder?}
        adw_steps={@adw_steps}
        adw_name={@adw_name}
        adw_local?={@adw_local?}
      />

      <.agent_models_modal rows={@agent_model_rows} />

      <.settings_modal
        settings_tab={@settings_tab}
        view_mode={@view_mode}
        chat_width={@chat_width}
        auto_follow?={@auto_follow?}
        show_thinking?={@show_thinking?}
        harnesses={@harness_options}
        system_prompt={@orchestrator_system_prompt}
        system_prompt_mode={@orchestrator_system_prompt_mode}
        default_system_prompt={@orchestrator_default_prompt}
        reasoning_effort={@orchestrator_reasoning_effort}
        reasoning_efforts={Orchestrators.reasoning_efforts()}
        template_rows={@template_rows}
        selected_template={@selected_template}
        template_versions={@template_versions}
      />
    </div>
    """
  end

  # --- view helpers ---

  # The per-step workflow views as a stable, ordered list for rendering (the assign is
  # a run_id-keyed map; sort by run_id so live updates don't reshuffle the column).
  @spec workflow_views(%{optional(Ecto.UUID.t()) => map()}) :: [map()]
  defp workflow_views(workflow_progress) do
    workflow_progress |> Map.values() |> Enum.sort_by(& &1.run_id)
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
  @spec log_to_row(Logs.AgentLog.t(), pos_integer(), %{optional(String.t()) => String.t()}) ::
          map()
  defp log_to_row(log, seq, names) do
    category = category_for_type(log.event_type)

    %{
      id: seq,
      line: seq,
      agent: Map.get(names, log.agent_id, short_id(log.agent_id)),
      agent_key: log.agent_id,
      color: AgentColors.hex(to_string(log.agent_id)),
      category: category,
      kind: to_string(log.event_type),
      body: log_body(log),
      # Persisted text_delta rows carry the thinking flag (Logs.event_payload), so
      # backfill can route reasoning to the thinking pane like the live path does.
      thinking?: log.payload["thinking"] == true,
      tokens: nil,
      time: log_time(log),
      payload_json: pretty_json(log.payload)
    }
  end

  @spec category_for_type(Logs.AgentLog.event_type() | nil) :: atom()
  defp category_for_type(:text_delta), do: :response
  defp category_for_type(:tool_call), do: :tool
  defp category_for_type(:tool_result), do: :tool
  defp category_for_type(:status), do: :hook
  defp category_for_type(_other), do: :system

  @spec log_body(Logs.AgentLog.t()) :: String.t()
  defp log_body(%{payload: %{"text" => text}}) when is_binary(text), do: text
  defp log_body(%{event_type: type, payload: payload}), do: "#{type} #{inspect(payload)}"

  @spec log_time(Logs.AgentLog.t()) :: String.t()
  defp log_time(%{inserted_at: %DateTime{} = at}), do: Calendar.strftime(at, "%H:%M:%S")
  defp log_time(_log), do: ""

  # Convert a backfilled row into the chat entry it maps to (text → orchestrator
  # message). Backfilled rows never carry the in-flight thinking? distinction.
  # (Inference-only spec — a hand-written one would be a supertype under :underspecs.)
  defp chat_for_row(%{category: :response, thinking?: true, body: body}),
    do: %{role: :thinking, label: nil, content: body, tool_name: nil, params_json: nil}

  defp chat_for_row(%{category: :response, body: body}),
    do: %{
      role: :orchestrator,
      label: "ORCHESTRATOR",
      content: body,
      tool_name: nil,
      params_json: nil
    }

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

  @spec settings_tab(String.t()) :: :general | :appearance | :about | :prompt | :templates
  defp settings_tab("appearance"), do: :appearance
  defp settings_tab("about"), do: :about
  defp settings_tab("prompt"), do: :prompt
  defp settings_tab("templates"), do: :templates
  defp settings_tab(_other), do: :general

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

  @spec now_hms() :: String.t()
  defp now_hms, do: Calendar.strftime(Time.utc_now(), "%H:%M:%S")

  @spec now_hm() :: String.t()
  defp now_hm, do: Calendar.strftime(Time.utc_now(), "%H:%M")
end
