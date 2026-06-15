defmodule RepoBuilderWeb.ConsoleLive do
  @moduledoc """
  The multi-layered orchestration console (BUILD_PROMPT.md §9) — a single
  full-bleed LiveView reproducing the reference 3-column command console:

    * a header bar (connection dot + Active/Running/Logs/Cost pills + LOGS/ADWS
      toggle + Prompt toggle);
    * a left agent rail (status dot + harness, selectable, with an inline
      "New agent" form);
    * a center column that switches between a live append-only EVENT STREAM and
      ADW SWIMLANES;
    * a right command panel that starts a live session on the selected agent,
      interrupts it, and launches the example ADW.

  The console is harness-blind: it drives the exact `Session.Supervisor` and
  `WorkflowEngine` paths the runtime already uses, so it works identically with
  `fake` (dev), `claude`, and `pi`. It NEVER touches `Repo` directly — every read
  and write flows through an `@spec`'d context. Both feeds use LiveView STREAMS
  with stable dom_ids and negative `limit:` pruning, so server memory stays flat.
  """
  use RepoBuilderWeb, :live_view

  import RepoBuilderWeb.ConsoleComponents
  import RepoBuilderWeb.DashboardComponents, only: [swimlane_row: 1]

  alias RepoBuilder.{Agents, Dashboard, Logs, Session, WorkflowEngine, Workflows}
  alias RepoBuilder.Agents.Agent
  alias RepoBuilder.Harness.Event
  alias RepoBuilder.Harness.Registry, as: HarnessRegistry

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
        page_title: "Orchestration Console",
        agents: [],
        agent_names: %{},
        statuses: %{},
        # per-agent cost (%{agent_id => Decimal.t() | nil}); nil stays unpriced.
        agent_costs: %{},
        selected_agent_id: nil,
        editing_agent_id: nil,
        edit_agent_form: nil,
        view_mode: :logs,
        show_new_agent?: false,
        prompt_open?: true,
        seq: 0,
        log_count: 0,
        ws_count: 0,
        # nil (unpriced) is NEVER coerced to Decimal.new(0): the cost pill renders
        # "—" until a priced amount arrives (§ edge cases).
        cost: nil,
        connected?: connected?(socket),
        harness_options: HarnessRegistry.known(),
        agent_form: new_agent_form(),
        launch_form: to_form(blank_launch_params(default_harness()), as: :launch),
        adw_form: to_form(%{"harness" => default_harness()}, as: :adw)
      )

    socket =
      if connected?(socket) do
        socket
        |> load_agents()
        |> seed_lanes()
        |> seed_cost()
        |> subscribe_feeds()
      else
        socket
      end

    {:ok, socket}
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

  @spec seed_lanes(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp seed_lanes(socket) do
    lanes = agent_lanes(socket.assigns.agents) ++ workflow_lanes()
    Enum.reduce(lanes, socket, &stream_insert(&2, :lanes, &1))
  end

  @spec seed_cost(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp seed_cost(socket) do
    # One pass over the agents: a per-agent rollup feeds both the per-agent cost
    # map (rail badges) and the accumulated global cost (header pill).
    {agent_costs, cost} =
      Enum.reduce(socket.assigns.agents, {%{}, nil}, fn agent, {costs, total} ->
        rollup = rollup_or_nil(Logs.cost_rollup!(agent.id))
        {Map.put(costs, agent.id, rollup), accumulate_cost(total, rollup)}
      end)

    assign(socket, cost: cost, agent_costs: agent_costs)
  end

  # A zero rollup means no priced logs yet — keep it unpriced (nil → "—") rather
  # than rendering "$0.000". A genuine priced amount accumulates as a Decimal.
  @spec rollup_or_nil(Decimal.t()) :: Decimal.t() | nil
  defp rollup_or_nil(%Decimal{} = rollup) do
    if Decimal.equal?(rollup, 0), do: nil, else: rollup
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

  @spec workflow_lanes() :: [Dashboard.lane()]
  defp workflow_lanes do
    Enum.map(Workflows.list_recent_runs(), fn run ->
      %{
        id: "workflow:#{run.id}",
        kind: :workflow,
        label: run.current_step || "workflow",
        status: run.status,
        harness: nil
      }
    end)
  end

  # --- control handlers ---

  @impl true
  def handle_event("toggle_view", _params, socket) do
    next = if socket.assigns.view_mode == :logs, do: :adws, else: :logs
    {:noreply, assign(socket, :view_mode, next)}
  end

  def handle_event("toggle_prompt", _params, socket) do
    {:noreply, assign(socket, :prompt_open?, not socket.assigns.prompt_open?)}
  end

  def handle_event("show_new_agent", _params, socket) do
    {:noreply, assign(socket, :show_new_agent?, true)}
  end

  def handle_event("cancel_new_agent", _params, socket) do
    {:noreply, assign(socket, show_new_agent?: false, agent_form: new_agent_form())}
  end

  def handle_event("select_agent", %{"id" => id}, socket) do
    agent = Enum.find(socket.assigns.agents, &(&1.id == id))
    harness = (agent && agent.harness) || socket.assigns.launch_form.params["harness"]
    model = (agent && agent.model) || socket.assigns.launch_form.params["model"] || ""

    params =
      socket.assigns.launch_form.params
      |> Map.put("harness", harness)
      |> Map.put("model", model)

    {:noreply,
     socket
     |> assign(:selected_agent_id, id)
     |> assign(:launch_form, to_form(params, as: :launch))}
  end

  def handle_event("validate_agent", %{"agent" => params}, socket) do
    form =
      %Agent{}
      |> Agent.changeset(params)
      |> to_form(action: :validate)

    {:noreply, assign(socket, :agent_form, form)}
  end

  def handle_event("create_agent", %{"agent" => params}, socket) do
    case Agents.create_agent(params) do
      {:ok, agent} ->
        {:noreply,
         socket
         |> load_agents()
         |> reseed_agent_lanes()
         |> assign(:selected_agent_id, agent.id)
         |> assign(:launch_form, to_form(blank_launch_params(agent.harness), as: :launch))
         |> assign(:agent_form, new_agent_form())
         |> assign(:show_new_agent?, false)
         |> put_flash(:info, "Created agent #{agent.name}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :agent_form, to_form(changeset))}
    end
  end

  def handle_event("edit_agent", %{"id" => id}, socket) do
    case Agents.fetch_agent(id) do
      {:ok, agent} ->
        {:noreply,
         socket
         |> assign(:editing_agent_id, agent.id)
         |> assign(:edit_agent_form, to_form(Agent.changeset(agent, %{}), as: :agent))}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Agent no longer exists")}
    end
  end

  def handle_event("cancel_edit_agent", _params, socket) do
    {:noreply, assign(socket, editing_agent_id: nil, edit_agent_form: nil)}
  end

  def handle_event("validate_edit_agent", %{"agent" => params}, socket) do
    case socket.assigns.editing_agent_id && Agents.get_agent(socket.assigns.editing_agent_id) do
      %Agent{} = agent ->
        form = agent |> Agent.changeset(params) |> to_form(action: :validate, as: :agent)
        {:noreply, assign(socket, :edit_agent_form, form)}

      _missing ->
        {:noreply, assign(socket, editing_agent_id: nil, edit_agent_form: nil)}
    end
  end

  def handle_event("update_agent", %{"agent" => params}, socket) do
    with id when is_binary(id) <- socket.assigns.editing_agent_id,
         {:ok, agent} <- Agents.fetch_agent(id),
         {:ok, updated} <- Agents.update_agent(agent, params) do
      {:noreply,
       socket
       |> load_agents()
       |> reseed_agent_lanes()
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
         |> put_flash(:error, "Agent no longer exists")}

      nil ->
        {:noreply, assign(socket, editing_agent_id: nil, edit_agent_form: nil)}
    end
  end

  def handle_event("archive_agent", %{"id" => id}, socket) do
    with {:ok, agent} <- Agents.fetch_agent(id),
         {:ok, _archived} <- Agents.archive_agent(agent) do
      {:noreply,
       socket
       |> load_agents()
       |> stream_delete(:lanes, %{id: "agent:#{id}"})
       |> clear_if_target(id)
       |> put_flash(:info, "Archived agent #{agent.name}")}
    else
      {:error, :not_found} ->
        {:noreply, socket |> load_agents() |> put_flash(:error, "Agent no longer exists")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Could not archive agent")}
    end
  end

  def handle_event("validate_launch", %{"launch" => params}, socket) do
    {:noreply, assign(socket, :launch_form, to_form(params, as: :launch))}
  end

  def handle_event("run", %{"launch" => params}, socket) do
    case socket.assigns.selected_agent_id do
      nil ->
        {:noreply, put_flash(socket, :error, "Select an agent before running")}

      agent_id ->
        # Re-fetch through the context: the agent may have been archived or deleted
        # concurrently. An archived agent is not a valid launch target.
        case Agents.fetch_agent(agent_id) do
          {:ok, %Agent{archived: false}} ->
            opts = [
              agent_id: agent_id,
              agent_db_id: agent_id,
              session_id: "console-#{System.unique_integer([:positive])}",
              harness: params["harness"],
              prompt: params["prompt"] || "",
              model: blank_to_nil(params["model"])
            ]

            {:noreply, start_session(socket, opts)}

          _archived_or_missing ->
            {:noreply,
             socket
             |> assign(:selected_agent_id, nil)
             |> put_flash(:error, "That agent is no longer available")}
        end
    end
  end

  def handle_event("interrupt", _params, socket) do
    case socket.assigns.selected_agent_id do
      nil -> {:noreply, put_flash(socket, :error, "Select an agent to interrupt")}
      id -> {:noreply, interrupt_session(socket, id)}
    end
  end

  def handle_event("launch_adw", %{"adw" => %{"harness" => harness}}, socket) do
    name = "console-adw-#{System.unique_integer([:positive])}"

    with {:ok, workflow} <- WorkflowEngine.create_example_workflow(name, harness),
         {:ok, run_id, _pid} <-
           WorkflowEngine.start_workflow(workflow, inputs: %{"input" => "console launch"}) do
      {:noreply,
       socket
       |> assign(:view_mode, :adws)
       |> put_flash(:info, "Launched ADW #{run_id}")}
    else
      _error -> {:noreply, put_flash(socket, :error, "Could not launch ADW")}
    end
  end

  @spec start_session(Phoenix.LiveView.Socket.t(), keyword()) :: Phoenix.LiveView.Socket.t()
  defp start_session(socket, opts) do
    case Session.Supervisor.start_session(opts) do
      {:ok, _pid} -> socket
      {:error, :at_capacity} -> put_flash(socket, :error, "At capacity — wait for a slot to free")
      {:error, _reason} -> put_flash(socket, :error, "Could not start the session")
    end
  end

  @spec interrupt_session(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  defp interrupt_session(socket, agent_id) do
    :ok = Session.Supervisor.interrupt(agent_id)
    socket
  end

  @spec reseed_agent_lanes(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp reseed_agent_lanes(socket) do
    Enum.reduce(agent_lanes(socket.assigns.agents), socket, &stream_insert(&2, :lanes, &1))
  end

  # When the archived agent is the current selection/edit target, clear it so the
  # launch panel and edit form don't point at a gone agent.
  @spec clear_if_target(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  defp clear_if_target(socket, id) do
    socket =
      if socket.assigns.selected_agent_id == id,
        do: assign(socket, :selected_agent_id, nil),
        else: socket

    if socket.assigns.editing_agent_id == id,
      do: assign(socket, editing_agent_id: nil, edit_agent_form: nil),
      else: socket
  end

  # --- event / lane handlers (one clause per canonical variant) ---

  @impl true
  def handle_info({:agent_event, agent_id, %Event.SessionStarted{} = event}, socket) do
    {:noreply,
     socket
     |> set_status(agent_id, :running)
     |> push_event(agent_id, "session", event.session_id, false)}
  end

  def handle_info({:agent_event, agent_id, %Event.TextDelta{} = event}, socket) do
    label = if event.thinking?, do: "thinking", else: "text"
    {:noreply, push_event(socket, agent_id, label, event.text, event.thinking?)}
  end

  def handle_info({:agent_event, agent_id, %Event.ToolCall{} = event}, socket) do
    {:noreply,
     push_event(socket, agent_id, "tool_call", "#{event.name} #{inspect(event.input)}", false)}
  end

  def handle_info({:agent_event, agent_id, %Event.ToolResult{} = event}, socket) do
    {:noreply, push_event(socket, agent_id, "tool_result", inspect(event.content), false)}
  end

  def handle_info({:agent_event, agent_id, %Event.Usage{} = event}, socket) do
    {:noreply,
     socket
     |> add_cost(event.cost_usd)
     |> add_agent_cost(agent_id, event.cost_usd)
     |> push_event(
       agent_id,
       "usage",
       "in=#{event.input_tokens} out=#{event.output_tokens}",
       false
     )}
  end

  def handle_info({:agent_event, agent_id, %Event.Status{} = event}, socket) do
    {:noreply,
     push_event(socket, agent_id, "status", "#{event.kind} #{inspect(event.detail)}", false)}
  end

  def handle_info({:agent_event, agent_id, %Event.Done{} = event}, socket) do
    status = if event.ok, do: :succeeded, else: :failed

    {:noreply,
     socket
     |> set_status(agent_id, status)
     |> add_cost(event.cost_usd)
     |> add_agent_cost(agent_id, event.cost_usd)
     |> push_event(agent_id, "done", "reason=#{event.reason}", false)}
  end

  def handle_info({:agent_event, agent_id, %Event.Error{} = event}, socket) do
    {:noreply,
     socket
     |> set_status(agent_id, :error)
     |> push_event(agent_id, "error", "#{event.reason}: #{event.message}", false)}
  end

  def handle_info({:lane, lane}, socket) do
    # Stable dom_id (lane.id) ⇒ re-inserting the same lane REPLACES the row in place.
    {:noreply, stream_insert(socket, :lanes, lane)}
  end

  @spec push_event(Phoenix.LiveView.Socket.t(), String.t(), String.t(), String.t(), boolean()) ::
          Phoenix.LiveView.Socket.t()
  defp push_event(socket, agent_id, kind, body, thinking?) do
    seq = socket.assigns.seq + 1

    row = %{
      id: seq,
      agent: agent_label(socket, agent_id),
      kind: kind,
      body: to_string(body),
      thinking?: thinking?
    }

    socket
    |> assign(:seq, seq)
    |> assign(:log_count, socket.assigns.log_count + 1)
    |> assign(:ws_count, socket.assigns.ws_count + 1)
    |> stream_insert(:events, row, at: -1, limit: -500)
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
  defp add_agent_cost(socket, agent_id, cost_usd) do
    updated = accumulate_cost(Map.get(socket.assigns.agent_costs, agent_id), cost_usd)
    assign(socket, :agent_costs, Map.put(socket.assigns.agent_costs, agent_id, updated))
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
    ~H"""
    <div class="flex h-screen flex-col bg-base-100 text-base-content">
      <Layouts.flash_group flash={@flash} />

      <.header_bar
        connected?={@connected?}
        agent_count={length(@agents)}
        running_count={running_count(@statuses)}
        log_count={@log_count}
        cost={@cost}
        view_mode={@view_mode}
        prompt_open?={@prompt_open?}
      />

      <div class={[
        "grid min-h-0 flex-1",
        (@prompt_open? && "grid-cols-[16rem_1fr_22rem]") || "grid-cols-[16rem_1fr]"
      ]}>
        <aside class="flex min-h-0 flex-col gap-2 overflow-y-auto border-r border-base-300 p-3">
          <div class="flex items-center justify-between">
            <span class="text-xs font-semibold uppercase text-base-content/60">Agents</span>
            <button
              id="show-new-agent"
              type="button"
              phx-click="show_new_agent"
              class="btn btn-xs btn-ghost"
            >
              + New
            </button>
          </div>

          <div id="agent-rail" class="flex flex-col gap-1">
            <.agent_rail_item
              :for={agent <- @agents}
              id={agent.id}
              name={agent.name}
              status={Map.get(@statuses, agent.id, agent.status)}
              harness={agent.harness}
              model={agent.model}
              cost={Map.get(@agent_costs, agent.id)}
              selected?={@selected_agent_id == agent.id}
            />
            <p :if={@agents == []} class="px-2 py-1 text-xs text-base-content/50">No agents yet.</p>
          </div>

          <div :if={@editing_agent_id} class="mt-2 rounded border border-primary/40 p-2">
            <.form
              for={@edit_agent_form}
              id="edit-agent-form"
              phx-submit="update_agent"
              phx-change="validate_edit_agent"
              class="space-y-1"
            >
              <p class="text-xs font-semibold uppercase text-base-content/60">Edit agent</p>
              <.input field={@edit_agent_form[:name]} type="text" label="Name" />
              <.input
                field={@edit_agent_form[:harness]}
                type="select"
                label="Harness"
                options={@harness_options}
              />
              <.input
                field={@edit_agent_form[:provider]}
                type="select"
                label="Provider"
                options={provider_options()}
              />
              <.input field={@edit_agent_form[:model]} type="text" label="Model (optional)" />
              <.input
                field={@edit_agent_form[:system_prompt]}
                type="textarea"
                label="System prompt (optional)"
                rows="3"
              />
              <div class="flex gap-2">
                <button type="submit" class="btn btn-primary btn-xs flex-1">Save</button>
                <button type="button" phx-click="cancel_edit_agent" class="btn btn-ghost btn-xs">
                  Cancel
                </button>
              </div>
            </.form>
          </div>

          <div :if={@show_new_agent?} class="mt-2 rounded border border-base-300 p-2">
            <.form
              for={@agent_form}
              id="new-agent-form"
              phx-submit="create_agent"
              phx-change="validate_agent"
              class="space-y-1"
            >
              <.input field={@agent_form[:name]} type="text" label="Name" />
              <.input
                field={@agent_form[:harness]}
                type="select"
                label="Harness"
                options={@harness_options}
              />
              <.input
                field={@agent_form[:provider]}
                type="select"
                label="Provider"
                options={provider_options()}
              />
              <.input field={@agent_form[:model]} type="text" label="Model (optional)" />
              <.input
                field={@agent_form[:system_prompt]}
                type="textarea"
                label="System prompt (optional)"
                rows="3"
              />
              <div class="flex gap-2">
                <button type="submit" class="btn btn-primary btn-xs flex-1">Create</button>
                <button type="button" phx-click="cancel_new_agent" class="btn btn-ghost btn-xs">
                  Cancel
                </button>
              </div>
            </.form>
          </div>
        </aside>

        <main class="flex min-h-0 flex-col overflow-hidden">
          <%!-- Both stream containers stay mounted (toggled via `hidden`): a
          `phx-update="stream"` container must exist when items are inserted, else
          rows pushed while it was absent are dropped on the next render cycle. --%>
          <div
            id="event-stream"
            phx-update="stream"
            class={["flex-1 space-y-1 overflow-y-auto p-3", @view_mode != :logs && "hidden"]}
          >
            <div :for={{dom_id, row} <- @streams.events} id={dom_id}>
              <.event_row agent={row.agent} kind={row.kind} body={row.body} thinking?={row.thinking?} />
            </div>
          </div>

          <div
            id="swimlanes"
            phx-update="stream"
            class={["flex-1 space-y-2 overflow-y-auto p-3", @view_mode != :adws && "hidden"]}
          >
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
        </main>

        <aside
          :if={@prompt_open?}
          class="min-h-0 overflow-y-auto border-l border-base-300 p-3"
        >
          <.command_panel
            form={@launch_form}
            adw_form={@adw_form}
            harness_options={@harness_options}
            selected_agent={selected_agent_name(@agents, @selected_agent_id)}
          />
        </aside>
      </div>

      <div class="fixed bottom-3 right-3 z-50">
        <Layouts.theme_toggle />
      </div>
    </div>
    """
  end

  # --- view helpers ---

  @spec running_count(%{optional(String.t()) => atom()}) :: non_neg_integer()
  defp running_count(statuses),
    do: Enum.count(statuses, fn {_id, status} -> status == :running end)

  @spec agent_label(Phoenix.LiveView.Socket.t(), String.t()) :: String.t()
  defp agent_label(socket, agent_id) do
    Map.get(socket.assigns.agent_names, agent_id, short_id(agent_id))
  end

  @spec short_id(String.t()) :: String.t()
  defp short_id(id), do: id |> to_string() |> String.slice(0, 8)

  @spec selected_agent_name([Agent.t()], String.t() | nil) :: String.t() | nil
  defp selected_agent_name(_agents, nil), do: nil

  defp selected_agent_name(agents, id) do
    Enum.find_value(agents, fn agent -> if agent.id == id, do: agent.name end)
  end

  @spec new_agent_form() :: Phoenix.HTML.Form.t()
  defp new_agent_form, do: to_form(Agent.changeset(%Agent{}, %{}))

  @spec blank_launch_params(String.t() | nil) :: %{optional(String.t()) => String.t() | nil}
  defp blank_launch_params(harness), do: %{"prompt" => "", "harness" => harness, "model" => ""}

  @spec default_harness() :: String.t() | nil
  defp default_harness do
    known = HarnessRegistry.known()
    if "fake" in known, do: "fake", else: List.first(known)
  end

  @spec provider_options() :: [{String.t(), String.t()}]
  defp provider_options,
    do: [{"Anthropic", "anthropic"}, {"OpenAI", "openai"}, {"Local", "local"}]

  @spec blank_to_nil(String.t() | nil) :: String.t() | nil
  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)
end
