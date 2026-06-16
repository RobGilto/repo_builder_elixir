defmodule RepoBuilderWeb.ConsoleComponents do
  @moduledoc """
  Typed function components for the multi-layered orchestration console
  (BUILD_PROMPT.md §9). Replicates the reference Vue console — the header stat
  bar + glow view toggle, the rich agent rail (card + compact), the filter bar,
  the event row, the chat bubbles, and the global command-input modal — as
  `attr/3`-validated, harness-blind components.

  Every public component carries `@spec component(map()) ::
  Phoenix.LiveView.Rendered.t()`; enums are constrained via `values:`.
  """
  use RepoBuilderWeb, :html

  import RepoBuilderWeb.DashboardComponents, only: [cost_badge: 1]

  # Lifecycle statuses an agent may display. Superset of the closed `Agent.status`
  # enum because the live `statuses` map also tracks terminal outcomes
  # (succeeded/failed) derived from canonical Done/Error events (§4.1).
  @statuses [:idle, :running, :succeeded, :failed, :error, :cancelled, :queued]

  # Canonical-event categories the UI groups events under (the 4 chip categories
  # plus :system for non-chip lifecycle events, which always pass the filter).
  @categories [:response, :tool, :thinking, :hook, :system]

  # --- header ---------------------------------------------------------------

  attr :connected?, :boolean, default: false
  attr :agent_count, :integer, default: 0
  attr :running_count, :integer, default: 0
  attr :log_count, :integer, default: 0
  attr :ws_count, :integer, default: 0
  attr :cost, :any, default: nil
  attr :view_mode, :atom, default: :logs, values: [:logs, :adws]
  attr :orchestrator_harness, :string, default: nil
  attr :orchestrating_harnesses, :list, default: [], doc: "harness keys that can orchestrate"
  attr :orchestrator_provider, :string, default: nil
  attr :orchestrator_model, :string, default: nil

  attr :provider_options, :list,
    default: [],
    doc: "provider names available for the active harness"

  attr :model_options, :list, default: [], doc: "suggested model ids for the active harness"

  @doc """
  Full-bleed header: a live connection dot, the Active/Running/Logs/WS Events/Cost
  stat pills, the orchestrator harness/provider/model selectors, the glowing
  LOGS⇄ADWS view-mode toggle, and the Prompt (⌘K) toggle.
  """
  @spec header_bar(map()) :: Phoenix.LiveView.Rendered.t()
  def header_bar(assigns) do
    ~H"""
    <header
      id="console-header"
      class="flex items-center justify-between gap-4 cns-panel px-4 py-2"
    >
      <div class="flex items-center gap-2 text-sm font-semibold">
        <span
          id="connection-dot"
          class={["inline-block size-2.5 rounded-full", conn_dot_class(@connected?)]}
          title={if @connected?, do: "connected", else: "connecting"}
        />
        <span style="color: var(--cns-cyan)">ORCHESTRATION</span>
        <span style="color: var(--cns-text-1)">CONSOLE</span>
      </div>

      <div class="flex items-center gap-2">
        <.stat_pill id="stat-active" label="Active" value={@agent_count} />
        <.stat_pill id="stat-running" label="Running" value={@running_count} />
        <.stat_pill id="stat-logs" label="Logs" value={@log_count} />
        <.stat_pill id="stat-ws" label="WS Events" value={@ws_count} />
        <span id="stat-cost" class="cns-pill">
          <span class="cns-pill__label">Cost</span>
          <.cost_badge cost={@cost} />
        </span>
      </div>

      <div class="flex items-center gap-3">
        <div
          :if={@orchestrating_harnesses != []}
          id="orchestrator-harness"
          class="cns-toggle"
          title="Orchestrator harness"
        >
          <button
            :for={h <- @orchestrating_harnesses}
            type="button"
            id={"harness-#{h}"}
            phx-click="set_harness"
            phx-value-harness={h}
            class={["cns-toggle__seg", @orchestrator_harness == h && "cns-toggle__seg--active"]}
          >
            {String.upcase(h)}
          </button>
        </div>

        <form
          :if={@provider_options != []}
          id="orchestrator-provider-form"
          phx-change="set_provider"
          title="Orchestrator provider"
        >
          <select id="orchestrator-provider" name="provider" class="cns-chip">
            <option value="" selected={@orchestrator_provider in [nil, ""]}>provider…</option>
            <option
              :for={p <- @provider_options}
              value={p}
              selected={@orchestrator_provider == p}
            >
              {p}
            </option>
          </select>
        </form>

        <form
          id="orchestrator-model-form"
          phx-change="set_model"
          title="Orchestrator model"
        >
          <input
            id="orchestrator-model"
            type="text"
            name="model"
            list="orchestrator-model-options"
            value={@orchestrator_model}
            placeholder="model…"
            class="cns-chip"
            style="width: 9rem"
          />
          <datalist id="orchestrator-model-options">
            <option :for={m <- @model_options} value={m} />
          </datalist>
        </form>

        <div id="view-toggle" class="cns-toggle" phx-click="toggle_view" title="Toggle view (⌘J)">
          <span class={["cns-toggle__seg", @view_mode == :logs && "cns-toggle__seg--active"]}>
            LOGS
          </span>
          <span class={["cns-toggle__seg", @view_mode == :adws && "cns-toggle__seg--active"]}>
            ADWS
          </span>
        </div>
        <button id="prompt-toggle" type="button" phx-click={show_command()} class="cns-chip">
          Prompt ⌘K
        </button>
      </div>
    </header>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true

  @doc "A single header stat pill (label + value)."
  @spec stat_pill(map()) :: Phoenix.LiveView.Rendered.t()
  def stat_pill(assigns) do
    ~H"""
    <span id={@id} class="cns-pill">
      <span class="cns-pill__label">{@label}</span>
      <span class="cns-pill__value">{@value}</span>
    </span>
    """
  end

  # --- agent rail -----------------------------------------------------------

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :status, :atom, required: true, values: @statuses
  attr :harness, :string, default: nil
  attr :model, :string, default: nil
  attr :cost, :any, default: nil
  attr :color, :string, required: true, doc: "the agent's deterministic hex color"
  attr :selected?, :boolean, default: false
  attr :pulse?, :boolean, default: false
  attr :context_tokens, :integer, default: 0
  attr :responses, :integer, default: 0
  attr :tools, :integer, default: 0
  attr :hooks, :integer, default: 0
  attr :thinking, :integer, default: 0

  @doc "Rich left-rail agent card: status badge, context-window bar, category counters, model+cost footer."
  @spec agent_card(map()) :: Phoenix.LiveView.Rendered.t()
  def agent_card(assigns) do
    assigns = assign(assigns, :ctx_pct, context_pct(assigns.context_tokens))

    ~H"""
    <button
      id={"agent-#{@id}"}
      type="button"
      phx-click="select_agent"
      phx-value-id={@id}
      style={"--agent-color: #{@color}; --pulse-color: #{@color}"}
      class={[
        "cns-agent-card w-full text-left",
        @selected? && "cns-agent-card--selected",
        @pulse? && "cns-agent-card--pulse"
      ]}
    >
      <div class="flex items-center justify-between gap-2">
        <span class="truncate text-sm font-semibold" style={"color: #{@color}"}>{@name}</span>
        <span class={["cns-cat", status_cat_class(@status)]}>{@status}</span>
      </div>

      <div class="mt-2">
        <div
          class="flex items-center justify-between text-[0.5625rem]"
          style="color: var(--cns-text-2)"
        >
          <span>CONTEXT WINDOW</span>
          <span>{ktok(@context_tokens)} / 200k</span>
        </div>
        <div class="cns-ctx-bar mt-1">
          <div class="cns-ctx-bar__fill" style={"width: #{@ctx_pct}%"} />
        </div>
      </div>

      <div class="mt-2 flex items-center gap-3 text-[0.625rem]" style="color: var(--cns-text-1)">
        <span title="responses">💬 {@responses}</span>
        <span title="tools">🛠️ {@tools}</span>
        <span title="hooks">🪝 {@hooks}</span>
        <span title="thinking">🧠 {@thinking}</span>
      </div>

      <div
        class="mt-2 flex items-center justify-between text-[0.625rem]"
        style="color: var(--cns-text-2)"
      >
        <span class="truncate">{@model || @harness || "—"}</span>
        <.cost_badge cost={@cost} />
      </div>
    </button>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :status, :atom, required: true, values: @statuses
  attr :color, :string, required: true
  attr :selected?, :boolean, default: false
  attr :pulse?, :boolean, default: false

  @doc "Compact 44px icon-rail agent item: initial + status dot, pulses on activity."
  @spec agent_rail_compact(map()) :: Phoenix.LiveView.Rendered.t()
  def agent_rail_compact(assigns) do
    ~H"""
    <button
      id={"agent-#{@id}"}
      type="button"
      phx-click="select_agent"
      phx-value-id={@id}
      title={@name}
      style={"--agent-color: #{@color}; --pulse-color: #{@color}"}
      class={[
        "relative flex size-11 items-center justify-center rounded font-bold",
        "cns-agent-card",
        @selected? && "cns-agent-card--selected",
        @pulse? && "cns-agent-card--pulse"
      ]}
    >
      <span style={"color: #{@color}"}>{initial(@name)}</span>
      <span class={["absolute bottom-0.5 right-0.5 size-2 rounded-full", status_dot_class(@status)]} />
    </button>
    """
  end

  # --- filter bar -----------------------------------------------------------

  attr :active_categories, :any, required: true, doc: "MapSet of active categories"
  attr :active_agents, :list, default: [], doc: "list of active agent-name filters"
  attr :search, :string, default: ""
  attr :regex?, :boolean, default: false
  attr :auto_follow?, :boolean, default: true

  @doc "The center filter bar: category chips, agent-name pills, regex search, auto-follow, clear-all."
  @spec filter_bar(map()) :: Phoenix.LiveView.Rendered.t()
  def filter_bar(assigns) do
    ~H"""
    <div
      id="filter-bar"
      class="flex flex-wrap items-center gap-2 border-b px-3 py-2"
      style="border-color: var(--cns-border)"
    >
      <.filter_chip
        cat={:response}
        label="RESPONSE"
        active?={MapSet.member?(@active_categories, :response)}
      />
      <.filter_chip cat={:tool} label="TOOL" active?={MapSet.member?(@active_categories, :tool)} />
      <.filter_chip
        cat={:thinking}
        label="THINKING"
        active?={MapSet.member?(@active_categories, :thinking)}
      />
      <.filter_chip cat={:hook} label="HOOK" active?={MapSet.member?(@active_categories, :hook)} />

      <span :for={name <- @active_agents} class="cns-namepill">
        {name}
        <button
          type="button"
          phx-click="toggle_agent_filter"
          phx-value-name={name}
          class="opacity-60 hover:opacity-100"
          aria-label={"Remove #{name} filter"}
        >
          ×
        </button>
      </span>

      <form id="search-form" phx-change="set_search" class="ml-auto flex items-center gap-2">
        <input
          id="search-input"
          type="text"
          name="q"
          value={@search}
          placeholder={if @regex?, do: "/regex/…", else: "search…"}
          phx-debounce="150"
          autocomplete="off"
          class="cns-search w-40"
        />
      </form>

      <button
        id="regex-toggle"
        type="button"
        phx-click="toggle_regex"
        class={["cns-chip", @regex? && "cns-chip--active cns-chip--hook"]}
        title="Toggle regex search"
      >
        .*
      </button>
      <button
        id="auto-follow"
        type="button"
        phx-click="toggle_auto_follow"
        class={["cns-chip", @auto_follow? && "cns-chip--active cns-chip--hook"]}
      >
        AUTO-FOLLOW
      </button>
      <button id="clear-filters" type="button" phx-click="clear_filters" class="cns-chip">
        CLEAR ALL
      </button>
    </div>
    """
  end

  attr :cat, :atom, required: true, values: @categories
  attr :label, :string, required: true
  attr :active?, :boolean, default: false

  @doc "A single category filter chip (colored when active)."
  @spec filter_chip(map()) :: Phoenix.LiveView.Rendered.t()
  def filter_chip(assigns) do
    ~H"""
    <button
      id={"filter-#{@cat}"}
      type="button"
      phx-click="toggle_category"
      phx-value-cat={@cat}
      class={["cns-chip", "cns-chip--#{@cat}", @active? && "cns-chip--active"]}
    >
      {@label}
    </button>
    """
  end

  # --- event row ------------------------------------------------------------

  attr :id, :integer, required: true
  attr :line, :integer, required: true
  attr :agent, :string, required: true
  attr :color, :string, required: true
  attr :category, :atom, required: true, values: @categories
  attr :kind, :string, required: true
  attr :body, :string, required: true
  attr :thinking?, :boolean, default: false
  attr :tokens, :string, default: nil
  attr :time, :string, default: ""
  attr :expanded?, :boolean, default: false

  @doc "One center event-stream row: line# | category badge | agent (colored) | content | meta; expandable."
  @spec event_row(map()) :: Phoenix.LiveView.Rendered.t()
  def event_row(assigns) do
    ~H"""
    <div
      id={"ev-row-#{@id}"}
      phx-click="toggle_event"
      phx-value-id={@id}
      style={"--agent-color: #{@color}"}
      class={["cns-event-row", @thinking? && "cns-event-row--thinking"]}
    >
      <span class="cns-event-row__ln">{@line}</span>
      <span class={["cns-cat", "cns-cat--#{@category}"]}>{category_label(@category)}</span>
      <span class="cns-event-row__agent">{@agent}</span>
      <span class="cns-event-row__body">
        <%= if @expanded? do %>
          <pre class="whitespace-pre-wrap break-all" phx-no-curly-interpolation><%= @body %></pre>
        <% else %>
          {truncate(@body, 160)}
        <% end %>
      </span>
      <span class="cns-event-row__meta">
        <span :if={@tokens}>{@tokens} · </span>{@time}
      </span>
    </div>
    """
  end

  # --- chat -----------------------------------------------------------------

  attr :role, :atom, required: true, values: [:user, :orchestrator]
  attr :label, :string, required: true
  attr :content, :string, required: true
  attr :time, :string, default: ""

  @doc "A chat bubble: user (right) or orchestrator (left)."
  @spec chat_message(map()) :: Phoenix.LiveView.Rendered.t()
  def chat_message(assigns) do
    ~H"""
    <div class={["flex flex-col gap-0.5", @role == :user && "items-end"]}>
      <div class="cns-bubble__label" style="color: var(--cns-text-2)">
        {@label} · {@time}
      </div>
      <div class={["cns-bubble", (@role == :user && "cns-bubble--user") || "cns-bubble--orch"]}>
        {@content}
      </div>
    </div>
    """
  end

  attr :content, :string, required: true
  attr :time, :string, default: ""

  @doc "Orchestrator THINKING bubble (purple, italic mono)."
  @spec thinking_bubble(map()) :: Phoenix.LiveView.Rendered.t()
  def thinking_bubble(assigns) do
    ~H"""
    <div class="flex flex-col gap-0.5">
      <div class="cns-bubble__label" style="color: var(--cns-thinking)">
        🤔 ORCHESTRATOR THINKING · {@time}
      </div>
      <div class="cns-bubble cns-bubble--thinking">{@content}</div>
    </div>
    """
  end

  attr :tool_name, :string, required: true
  attr :params_json, :string, required: true, doc: "pretty-printed JSON params"
  attr :time, :string, default: ""

  @doc "Orchestrator ACTION (tool-use) card (amber, tool name + pretty JSON params)."
  @spec tool_use_card(map()) :: Phoenix.LiveView.Rendered.t()
  def tool_use_card(assigns) do
    ~H"""
    <div class="flex flex-col gap-0.5">
      <div class="cns-bubble__label" style="color: var(--cns-warning)">
        🔧 ORCHESTRATOR ACTION · {@time}
      </div>
      <div class="cns-bubble cns-bubble--tool">
        <div class="font-bold">{@tool_name}</div>
        <pre
          class="mt-1 overflow-x-auto whitespace-pre-wrap break-all text-[0.6875rem]"
          phx-no-curly-interpolation
        ><%= @params_json %></pre>
      </div>
    </div>
    """
  end

  @doc "Three-dot typing indicator."
  @spec typing_indicator(map()) :: Phoenix.LiveView.Rendered.t()
  def typing_indicator(assigns) do
    ~H"""
    <div id="typing-indicator" class="cns-typing">
      <span class="cns-typing__dot" /><span class="cns-typing__dot" /><span class="cns-typing__dot" />
    </div>
    """
  end

  # --- command panel (restyled launch/interrupt/ADW controls) ---------------

  attr :chat_width, :atom, default: :sm, values: [:sm, :md, :lg]
  attr :cost, :any, default: nil
  attr :typing?, :boolean, default: false
  slot :messages, doc: "rendered chat bubbles"

  @doc "Right chat/command panel: chat header (width toggle + cost) + the orchestrator text stream. Input is the ⌘K command modal."
  @spec command_panel(map()) :: Phoenix.LiveView.Rendered.t()
  def command_panel(assigns) do
    ~H"""
    <div id="command-panel" class="flex h-full flex-col gap-3">
      <div
        class="flex items-center justify-between border-b pb-2"
        style="border-color: var(--cns-border)"
      >
        <span class="text-xs font-semibold" style="color: var(--cns-cyan)">ORCHESTRATOR</span>
        <div class="flex items-center gap-2">
          <.cost_badge cost={@cost} />
          <div class="cns-toggle">
            <button
              :for={w <- [:sm, :md, :lg]}
              type="button"
              id={"chat-width-#{w}"}
              phx-click="set_chat_width"
              phx-value-width={w}
              class={["cns-toggle__seg", @chat_width == w && "cns-toggle__seg--active"]}
            >
              {w |> Atom.to_string() |> String.upcase()}
            </button>
          </div>
        </div>
      </div>

      <div
        id="chat-log"
        phx-hook="AutoScroll"
        class="flex min-h-0 flex-1 flex-col gap-2 overflow-y-auto pr-1"
      >
        {render_slot(@messages)}
        <.typing_indicator :if={@typing?} />
      </div>
    </div>
    """
  end

  # --- global command input modal -------------------------------------------

  @doc """
  Open the ⌘K command modal and focus its input — entirely client-side. Because the
  modal is always in the DOM (just hidden), `JS.focus` hits the field synchronously
  with no server round-trip, which is what makes focus-on-open reliable.
  """
  @spec show_command(JS.t()) :: JS.t()
  def show_command(js \\ %JS{}) do
    js
    |> JS.show(to: "#command-input", display: "flex")
    |> JS.focus(to: "#command-textarea")
  end

  @doc "Close the ⌘K command modal (client-side)."
  @spec hide_command(JS.t()) :: JS.t()
  def hide_command(js \\ %JS{}), do: JS.hide(js, to: "#command-input")

  attr :harnesses, :list, default: []
  attr :agents, :list, default: [], doc: "list of agent names"
  attr :example_adw, :string, default: "plan → build → review"

  @doc "Bottom-anchored ⌘K command-input modal with a system-info panel (harnesses/agents/example ADW)."
  @spec global_command_input(map()) :: Phoenix.LiveView.Rendered.t()
  def global_command_input(assigns) do
    ~H"""
    <div
      id="command-input"
      class="cns-cmd-overlay"
      style="display:none"
      phx-window-keydown={hide_command()}
      phx-key="Escape"
    >
      <div class="cns-cmd-panel">
        <div class="mb-2 flex items-center justify-between">
          <span class="text-xs font-semibold" style="color: var(--cns-cyan)">COMMAND (⌘K)</span>
          <button type="button" phx-click={hide_command()} class="cns-chip">Esc</button>
        </div>

        <form id="command-form" phx-submit={JS.push("run_command") |> hide_command()}>
          <textarea
            id="command-textarea"
            name="command"
            rows="3"
            placeholder="Type a command…  (Enter to send · Shift+Enter newline)"
            class="cns-cmd-textarea"
          ></textarea>
        </form>

        <div class="mt-3 grid grid-cols-3 gap-3 text-[0.625rem]">
          <div>
            <div class="mb-1 font-semibold" style="color: var(--cns-text-2)">HARNESSES</div>
            <div class="flex flex-wrap gap-1">
              <button
                :for={h <- @harnesses}
                type="button"
                class="cns-cmd-chip"
                data-copy={h}
                phx-hook="ClipboardCopy"
                id={"cmd-harness-#{h}"}
              >
                {h}
              </button>
            </div>
          </div>
          <div>
            <div class="mb-1 font-semibold" style="color: var(--cns-text-2)">AGENTS</div>
            <div class="flex flex-wrap gap-1">
              <span :for={a <- @agents} class="cns-cmd-chip">{a}</span>
              <span :if={@agents == []} style="color: var(--cns-text-3)">none</span>
            </div>
          </div>
          <div>
            <div class="mb-1 font-semibold" style="color: var(--cns-text-2)">EXAMPLE ADW</div>
            <div class="cns-cmd-chip inline-block">{@example_adw}</div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # --- private helpers ------------------------------------------------------

  @spec conn_dot_class(boolean()) :: String.t()
  defp conn_dot_class(true), do: "bg-emerald-500"
  defp conn_dot_class(false), do: "bg-amber-500 animate-pulse"

  @spec status_cat_class(atom()) :: String.t()
  defp status_cat_class(:running), do: "cns-cat--hook"
  defp status_cat_class(:succeeded), do: "cns-cat--response"
  defp status_cat_class(:failed), do: "cns-cat--tool"
  defp status_cat_class(:error), do: "cns-cat--tool"
  defp status_cat_class(_status), do: "cns-cat--system"

  @spec status_dot_class(atom()) :: String.t()
  defp status_dot_class(:running), do: "bg-blue-500"
  defp status_dot_class(:succeeded), do: "bg-emerald-500"
  defp status_dot_class(:failed), do: "bg-red-500"
  defp status_dot_class(:error), do: "bg-red-500"
  defp status_dot_class(:queued), do: "bg-amber-500"
  defp status_dot_class(_status), do: "bg-gray-500"

  # Inference-only spec — fixed-length string returns supertype under :underspecs.
  defp category_label(:response), do: "RESPONSE"
  defp category_label(:tool), do: "TOOL"
  defp category_label(:thinking), do: "THINKING"
  defp category_label(:hook), do: "HOOK"
  defp category_label(:system), do: "SYS"

  @spec context_pct(non_neg_integer()) :: non_neg_integer()
  defp context_pct(tokens), do: min(100, div(tokens * 100, 200_000))

  @spec ktok(non_neg_integer()) :: String.t()
  defp ktok(tokens), do: "#{div(tokens, 1000)}k"

  @spec initial(String.t()) :: String.t()
  defp initial(""), do: "?"
  defp initial(name), do: name |> String.first() |> String.upcase()

  # Inference-only spec — the single 160 call-site literal supertypes under :underspecs.
  defp truncate(body, max) do
    if String.length(body) > max, do: String.slice(body, 0, max) <> "…", else: body
  end
end
