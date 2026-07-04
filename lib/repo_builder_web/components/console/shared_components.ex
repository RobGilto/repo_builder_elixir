defmodule RepoBuilderWeb.Console.SharedComponents do
  @moduledoc """
  Cross-panel console components: the header stat bar, the rich/compact agent
  rail cards, the activity orb + typing indicator, the directory-picker modal,
  and every client-side `JS` show/hide toggle for the console's modals.

  Extracted verbatim from `RepoBuilderWeb.ConsoleComponents` (audit F3 task 3.2);
  that module remains the façade and delegates here.
  """
  use RepoBuilderWeb, :html

  import RepoBuilderWeb.DashboardComponents, only: [cost_badge: 1]

  alias RepoBuilder.Orchestrator.ContextWindow

  # Lifecycle statuses an agent may display. Superset of the closed `Agent.status`
  # enum because the live `statuses` map also tracks terminal outcomes
  # (succeeded/failed) derived from canonical Done/Error events (§4.1).
  @statuses [:idle, :running, :succeeded, :failed, :error, :cancelled, :queued, :holding]

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

  attr :model_options, :list,
    default: [],
    doc: "available model ids for the active harness+provider (latest first)"

  attr :recent_models, :list,
    default: [],
    doc: "recently-selected models for the active provider (shown first)"

  @doc """
  Full-bleed header: a live connection dot, the Active/Running/Logs/WS Events/Cost
  stat pills, the orchestrator harness/provider/model selectors, the glowing
  LOGS⇄ADWS view-mode toggle, and the Prompt (⌘K) toggle.
  """
  @spec header_bar(map()) :: Phoenix.LiveView.Rendered.t()
  def header_bar(assigns) do
    # Dedup the model dropdown so each option appears once and exactly one is
    # `selected`: recents first, then the remaining available models, plus the
    # current value if it is a custom string not present in either list.
    available = Enum.reject(assigns.model_options, &(&1 in assigns.recent_models))
    current = assigns.orchestrator_model

    extra =
      if current not in [nil, ""] and current not in assigns.recent_models and
           current not in available,
         do: [current],
         else: []

    assigns = assign(assigns, model_available: available, model_extra: extra)

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
        <button
          type="button"
          id="stat-cost"
          phx-click={show_budget()}
          class="cns-pill"
          style="cursor: pointer"
          title="Budget guardrails"
        >
          <span class="cns-pill__label">Cost</span>
          <.cost_badge cost={@cost} />
        </button>
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
          <select
            id="orchestrator-provider"
            name="provider"
            class="cns-chip"
            aria-label="Orchestrator provider"
          >
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

        <form id="orchestrator-model-form" phx-change="set_model" title="Orchestrator model">
          <select
            id="orchestrator-model"
            name="model"
            class="cns-chip"
            style="width: 11rem"
            aria-label="Orchestrator model"
          >
            <option value="" selected={@orchestrator_model in [nil, ""]}>model…</option>
            <optgroup :if={@model_extra != []} label="Current">
              <option :for={m <- @model_extra} value={m} selected>{m}</option>
            </optgroup>
            <optgroup :if={@recent_models != []} label="Recently selected">
              <option :for={m <- @recent_models} value={m} selected={@orchestrator_model == m}>
                {m}
              </option>
            </optgroup>
            <optgroup :if={@model_available != []} label="Models">
              <option :for={m <- @model_available} value={m} selected={@orchestrator_model == m}>
                {m}
              </option>
            </optgroup>
          </select>
        </form>

        <button
          id="agent-models-toggle"
          type="button"
          phx-click={JS.push("open_agent_models") |> show_agent_models()}
          class="cns-chip"
          title="Configure the harness/provider/model the orchestrator spawns workers into"
        >
          Agents…
        </button>

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
        <button
          id="settings-toggle"
          type="button"
          phx-click={show_settings()}
          class="cns-chip flex items-center"
          title="Settings"
          aria-label="Settings"
        >
          <span class="text-lg leading-none">⚙</span>
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
  attr :estimate, :any, default: nil, doc: "token-derived live cost estimate (display-only)"
  attr :color, :string, required: true, doc: "the agent's deterministic hex color"
  attr :selected?, :boolean, default: false
  attr :pulse?, :boolean, default: false

  attr :active?, :boolean,
    default: false,
    doc: "live status is :running (drives the activity orb)"

  attr :context_tokens, :integer, default: 0
  attr :responses, :integer, default: 0
  attr :tools, :integer, default: 0
  attr :hooks, :integer, default: 0
  attr :thinking, :integer, default: 0

  @doc "Rich left-rail agent card: status badge, context-window bar, category counters, model+cost footer."
  @spec agent_card(map()) :: Phoenix.LiveView.Rendered.t()
  def agent_card(assigns) do
    window = ContextWindow.size(assigns.harness || "", assigns.model)

    assigns =
      assigns
      |> assign(:window, window)
      |> assign(:ctx_pct, context_pct(assigns.context_tokens, window))

    ~H"""
    <div
      id={"agent-row-#{@id}"}
      style={"--agent-color: #{@color}; --pulse-color: #{@color}"}
      class={[
        "cns-agent-card relative w-full",
        @selected? && "cns-agent-card--selected",
        @pulse? && "cns-agent-card--pulse"
      ]}
    >
      <button
        id={"agent-#{@id}"}
        type="button"
        phx-click="toggle_agent_filter"
        phx-value-id={@id}
        class="block w-full text-left"
      >
        <div class="flex items-center justify-between gap-2 pr-5">
          <span class="truncate text-sm font-semibold" style={"color: #{@color}"}>{@name}</span>
          <span class="flex items-center gap-1.5">
            <.activity_orb variant={:agent} color={@color} active?={@active?} />
            <span class={["cns-cat", status_cat_class(@status)]}>{@status}</span>
          </span>
        </div>

        <div class="mt-2">
          <div
            class="flex items-center justify-between text-[0.5625rem]"
            style="color: var(--cns-text-2)"
          >
            <span>CONTEXT WINDOW</span>
            <span>{ktok(@context_tokens)} / {ktok(@window)}</span>
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
          <.cost_badge cost={@cost} estimated={@estimate} />
        </div>
      </button>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :status, :atom, required: true, values: @statuses
  attr :color, :string, required: true
  attr :selected?, :boolean, default: false
  attr :pulse?, :boolean, default: false

  attr :active?, :boolean,
    default: false,
    doc: "live status is :running (drives the activity orb)"

  @doc "Compact 44px icon-rail agent item: initial + status dot, pulses on activity."
  @spec agent_rail_compact(map()) :: Phoenix.LiveView.Rendered.t()
  def agent_rail_compact(assigns) do
    ~H"""
    <button
      id={"agent-#{@id}"}
      type="button"
      phx-click="toggle_agent_filter"
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
      <span :if={@active?} class="absolute -top-0.5 -right-0.5">
        <.activity_orb variant={:agent} color={@color} active?={@active?} />
      </span>
      <span class={["absolute bottom-0.5 right-0.5 size-2 rounded-full", status_dot_class(@status)]} />
    </button>
    """
  end

  attr :active?, :boolean, default: false
  attr :variant, :atom, default: :agent, values: [:agent, :orchestrator, :adw]
  attr :color, :string, default: nil, doc: "agent hex; falls back to the variant token"
  attr :title, :string, default: "working"

  @doc """
  Continuous "processing" indicator: a pulsing core ringed by orbiting dots, pure
  CSS. Renders nothing when `active?` is false. Reused harness-blind across the
  agent rail, the orchestrator panel, and ADW swimlanes; tied to lifecycle status,
  not per-event blips — it composes with the momentary `cns-agent-card--pulse` flash.
  """
  @spec activity_orb(map()) :: Phoenix.LiveView.Rendered.t()
  def activity_orb(assigns) do
    ~H"""
    <span
      :if={@active?}
      data-orb
      data-active="true"
      class={["cns-orb", "cns-orb--#{@variant}"]}
      style={@color && "--orb-color: #{@color}"}
      title={@title}
      aria-label={@title}
    >
      <span class="cns-orb__core" />
      <span class="cns-orb__ring">
        <span class="cns-orb__dot" /><span class="cns-orb__dot" />
      </span>
      <span class="cns-orb__ring cns-orb__ring--rev">
        <span class="cns-orb__dot" />
      </span>
    </span>
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

  attr :open?, :boolean, default: false
  attr :path, :string, default: ""
  attr :parent, :any, default: nil, doc: "parent dir path, or nil at the filesystem root"
  attr :dirs, :list, default: [], doc: "child directory names of @path"

  @doc """
  Dialog modal directory picker for the working directory. Server-driven (the listing
  is loaded over `open_dir_picker`/`dir_picker_browse`); rendered on top of the command
  modal. Picking commits the browsed path as the orchestrator cwd.
  """
  @spec dir_picker_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def dir_picker_modal(assigns) do
    ~H"""
    <div
      :if={@open?}
      id="dir-picker"
      class="cns-cmd-overlay"
      style="display:flex; z-index: 60"
      phx-window-keydown="close_dir_picker"
      phx-key="Escape"
    >
      <div class="cns-cmd-panel">
        <div class="mb-2 flex items-center justify-between">
          <span class="text-xs font-semibold" style="color: var(--cns-cyan)">
            SELECT WORKING DIRECTORY
          </span>
          <button type="button" id="dir-picker-close" phx-click="close_dir_picker" class="cns-chip">
            Esc
          </button>
        </div>

        <form phx-submit="dir_picker_goto" class="mb-2 flex items-center gap-2">
          <input
            type="text"
            name="path"
            id="dir-picker-path"
            value={@path}
            title={@path}
            autocomplete="off"
            spellcheck="false"
            class="min-w-0 flex-1 rounded border p-2 font-mono text-xs"
            style="border-color: var(--cns-border); color: var(--cns-text-1); background: transparent"
          />
          <button type="submit" class="cns-chip">Go</button>
        </form>

        <div
          class="max-h-64 overflow-y-auto rounded border"
          style="border-color: var(--cns-border)"
        >
          <button
            :if={@parent}
            type="button"
            id="dir-picker-up"
            phx-click="dir_picker_browse"
            phx-value-path={@parent}
            class="flex w-full items-center gap-2 px-3 py-1.5 text-left font-mono text-xs hover:bg-white/5"
          >
            <span>⬆️</span> ..
          </button>
          <button
            :for={dir <- @dirs}
            type="button"
            phx-click="dir_picker_browse"
            phx-value-path={Path.join(@path, dir)}
            class="flex w-full items-center gap-2 px-3 py-1.5 text-left font-mono text-xs hover:bg-white/5"
            style="color: var(--cns-text-1)"
          >
            <span>📁</span> {dir}
          </button>
          <p
            :if={@dirs == [] and is_nil(@parent)}
            class="px-3 py-2 text-xs"
            style="color: var(--cns-text-3)"
          >
            No subdirectories.
          </p>
          <p
            :if={@dirs == [] and not is_nil(@parent)}
            class="px-3 py-2 text-xs"
            style="color: var(--cns-text-3)"
          >
            No subdirectories here.
          </p>
        </div>

        <div class="mt-3 flex items-center justify-end gap-2">
          <button type="button" phx-click="close_dir_picker" class="cns-chip">Cancel</button>
          <button
            type="button"
            id="dir-picker-select"
            phx-click="dir_picker_select"
            class="cns-chip cns-chip--active cns-chip--hook"
          >
            Use this directory
          </button>
        </div>
      </div>
    </div>
    """
  end

  # --- agent-models modal ---------------------------------------------------

  @doc "Open the agent-models modal (client-side; always in the DOM, just hidden)."
  @spec show_agent_models(JS.t()) :: JS.t()
  def show_agent_models(js \\ %JS{}), do: JS.show(js, to: "#agent-models-modal", display: "flex")

  @doc "Close the agent-models modal (client-side)."
  @spec hide_agent_models(JS.t()) :: JS.t()
  def hide_agent_models(js \\ %JS{}), do: JS.hide(js, to: "#agent-models-modal")

  @doc "Open the ephemeral explain-logs modal (client-side; always in the DOM, just hidden)."
  @spec show_explain(JS.t()) :: JS.t()
  def show_explain(js \\ %JS{}), do: JS.show(js, to: "#explain-modal", display: "flex")

  @doc "Close the explain-logs modal (client-side)."
  @spec hide_explain(JS.t()) :: JS.t()
  def hide_explain(js \\ %JS{}), do: JS.hide(js, to: "#explain-modal")

  @doc "Open the settings modal (client-side; always in the DOM, just hidden)."
  @spec show_settings(JS.t()) :: JS.t()
  def show_settings(js \\ %JS{}), do: JS.show(js, to: "#settings-modal", display: "flex")

  @doc "Close the settings modal (client-side)."
  @spec hide_settings(JS.t()) :: JS.t()
  def hide_settings(js \\ %JS{}), do: JS.hide(js, to: "#settings-modal")

  @doc "Open the budget modal (client-side; always in the DOM, just hidden)."
  @spec show_budget(JS.t()) :: JS.t()
  def show_budget(js \\ %JS{}), do: JS.show(js, to: "#budget-modal", display: "flex")

  @doc "Close the budget modal (client-side)."
  @spec hide_budget(JS.t()) :: JS.t()
  def hide_budget(js \\ %JS{}), do: JS.hide(js, to: "#budget-modal")

  @doc "Open the log-manager modal (client-side; always in the DOM, just hidden)."
  @spec show_log_manager(JS.t()) :: JS.t()
  def show_log_manager(js \\ %JS{}),
    do: JS.show(js, to: "#log-manager-modal", display: "flex")

  @doc "Close the log-manager modal (client-side)."
  @spec hide_log_manager(JS.t()) :: JS.t()
  def hide_log_manager(js \\ %JS{}), do: JS.hide(js, to: "#log-manager-modal")

  @spec conn_dot_class(boolean()) :: String.t()
  defp conn_dot_class(true), do: "bg-emerald-500"
  defp conn_dot_class(false), do: "bg-amber-500 animate-pulse"

  @spec status_cat_class(atom()) :: String.t()
  defp status_cat_class(:running), do: "cns-cat--hook"
  defp status_cat_class(:succeeded), do: "cns-cat--response"
  defp status_cat_class(:failed), do: "cns-cat--tool"
  defp status_cat_class(:error), do: "cns-cat--tool"
  # A held worker (blocked pending external input) gets its own thinking-tinted badge,
  # distinct from the emerald "succeeded" (issue holding-status-for-blocked-agents).
  defp status_cat_class(:holding), do: "cns-cat--thinking"
  defp status_cat_class(_status), do: "cns-cat--system"

  @spec status_dot_class(atom()) :: String.t()
  defp status_dot_class(:running), do: "bg-blue-500"
  defp status_dot_class(:succeeded), do: "bg-emerald-500"
  defp status_dot_class(:failed), do: "bg-red-500"
  defp status_dot_class(:error), do: "bg-red-500"
  defp status_dot_class(:queued), do: "bg-amber-500"
  # Amber dot, clearly different from the emerald "succeeded" dot.
  defp status_dot_class(:holding), do: "bg-amber-500"
  defp status_dot_class(_status), do: "bg-gray-500"

  @spec context_pct(non_neg_integer(), pos_integer()) :: non_neg_integer()
  defp context_pct(tokens, window), do: min(100, div(tokens * 100, max(window, 1)))

  @spec ktok(non_neg_integer()) :: String.t()
  defp ktok(tokens), do: "#{div(tokens, 1000)}k"

  @spec initial(String.t()) :: String.t()
  defp initial(""), do: "?"
  defp initial(name), do: name |> String.first() |> String.upcase()
end
