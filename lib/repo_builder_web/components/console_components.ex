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

  alias RepoBuilder.Agents.Agent
  alias RepoBuilder.Orchestrator.ContextWindow
  alias RepoBuilder.StackLayers.StackLayer

  # A normalized prompt-palette chip. `:status` is optional — file-derived chips
  # (slash/agents/adws) omit it; live-agent chips carry the worker's runtime status
  # so the row can render a status dot.
  @type chip :: %{
          required(:token) => String.t(),
          required(:label) => String.t(),
          required(:source) => atom(),
          required(:description) => String.t() | nil,
          optional(:status) => atom()
        }

  # Lifecycle statuses an agent may display. Superset of the closed `Agent.status`
  # enum because the live `statuses` map also tracks terminal outcomes
  # (succeeded/failed) derived from canonical Done/Error events (§4.1).
  @statuses [:idle, :running, :succeeded, :failed, :error, :cancelled, :queued, :holding]

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

  # --- filter bar -----------------------------------------------------------

  attr :active_categories, :any, required: true, doc: "MapSet of active categories"
  attr :active_agents, :list, default: [], doc: "list of active agent-id filters"
  attr :agent_names, :map, default: %{}, doc: "agent id => display name map for pill labels"
  attr :search, :string, default: ""
  attr :regex?, :boolean, default: false
  attr :auto_follow?, :boolean, default: true

  attr :project_scoped?, :boolean,
    default: true,
    doc: "whether the stream is scoped to the project"

  attr :project_active?, :boolean, default: false, doc: "whether a project is active (chip shown)"

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

      <span :for={id <- @active_agents} class="cns-namepill">
        {Map.get(@agent_names, id, id)}
        <button
          type="button"
          phx-click="toggle_agent_filter"
          phx-value-id={id}
          class="opacity-60 hover:opacity-100"
          aria-label={"Remove #{Map.get(@agent_names, id, id)} filter"}
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
      <button
        :if={@project_active?}
        id="project-scope"
        type="button"
        phx-click="toggle_project_scope"
        class={["cns-chip", @project_scoped? && "cns-chip--active cns-chip--hook"]}
        title="Scope the log stream to the active project's orchestrator and its worker agents"
      >
        PROJECT ONLY
      </button>
      <button
        id="clear-filters"
        type="button"
        phx-click="clear_filters"
        class="cns-chip"
        title="Reset all filters and clear the log view (does not delete persisted history; reconnect re-backfills)"
      >
        CLEAR
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

  attr :log_no, :integer,
    default: nil,
    doc: "durable persisted log number (nil for non-persisted shards ⇒ falls back to line#)"

  attr :agent, :string, required: true
  attr :color, :string, required: true
  attr :category, :atom, required: true, values: @categories
  attr :kind, :string, required: true
  attr :body, :string, required: true, doc: "plain-text projection (search/copy fallback)"
  attr :summary, :string, required: true, doc: "one-line card headline (presenter render model)"
  attr :preview, :string, default: nil, doc: "clean collapsed content preview (nil ⇒ none)"

  attr :detail, :string,
    default: nil,
    doc: "full body revealed on expand (nil ⇒ falls back to preview)"

  attr :tool_name, :string, default: nil, doc: "drives the tool pill (nil ⇒ no pill)"
  attr :error?, :boolean, default: false, doc: "tool-result error ⇒ red accent"
  attr :files, :list, default: [], doc: "consumed/written files ⇒ \"Consumed N files\" card"

  attr :file_change, :map,
    default: nil,
    doc: "presenter file_change sub-model (nil ⇒ generic preview/detail card)"

  attr :thinking?, :boolean, default: false
  attr :tokens, :string, default: nil
  attr :time, :string, default: ""
  attr :expanded?, :boolean, default: false

  attr :selected?, :boolean,
    default: false,
    doc: "reusable multi-select state (action-agnostic — EXPLAIN/HIDE/COPY act on the selection)"

  @doc "One center event-stream row rendered as a structured card: select | log# | category badge | agent (colored) | card | meta; expandable."
  @spec event_row(map()) :: Phoenix.LiveView.Rendered.t()
  def event_row(assigns) do
    ~H"""
    <div
      id={"ev-row-#{@id}"}
      phx-click="toggle_event"
      phx-value-id={@id}
      style={"--agent-color: #{@color}"}
      class={[
        "cns-event-row",
        @thinking? && "cns-event-row--thinking",
        @selected? && "cns-event-row--selected"
      ]}
    >
      <%!-- Reusable selection toggle: its own phx-click means LiveView fires
      `toggle_select` for the closest element and NOT the row's `toggle_event`. --%>
      <input
        type="checkbox"
        class="cns-event-row__select"
        checked={@selected?}
        phx-click="toggle_select"
        phx-value-id={@id}
        data-row-id={@id}
        aria-label={"Select log row #{@id}"}
      />
      <%!-- Fixed-width log chip: the visible text truncates (CSS), but the full
      `log-#{@log_no}` rides on `data-log` (for the LogCopy hook) and `title` (hover).
      Emit `data-log` only for real log numbers so the hook ignores `@line` fallbacks. --%>
      <span
        class="cns-event-row__ln"
        data-log={if @log_no, do: "log-#{@log_no}"}
        title={if @log_no, do: "log-#{@log_no}", else: "durable log number"}
      >
        {if @log_no, do: "log-#{@log_no}", else: @line}
      </span>
      <span class={["cns-cat", "cns-cat--#{@category}"]}>{category_label(@category)}</span>
      <span class="cns-event-row__agent">{@agent}</span>
      <div class={["cns-event-row__body cns-event-card", @error? && "cns-event-card--error"]}>
        <div class="cns-event-card__summary">
          <span>{@summary}</span>
          <span :if={@tool_name} class="cns-tool-pill">{@tool_name}</span>
        </div>
        <%= if @file_change do %>
          <.file_change_card file_change={@file_change} expanded?={@expanded?} open_enabled?={true} />
        <% else %>
          <%= cond do %>
            <% @expanded? and (@detail || @preview) -> %>
              <pre
                class="cns-event-preview cns-event-preview--full whitespace-pre-wrap break-all"
                phx-no-curly-interpolation
              ><%= @detail || @preview %></pre>
            <% @preview -> %>
              <div class="cns-event-preview">{truncate(@preview, 200)}</div>
            <% true -> %>
          <% end %>
        <% end %>
        <.consumed_files :if={@files != []} files={@files} />
      </div>
      <span class="cns-event-row__meta">
        <span :if={@tokens}>{@tokens} · </span>{@time}
      </span>
    </div>
    """
  end

  attr :files, :list,
    required: true,
    doc: "presenter file_activity entries: %{path, action, bytes}"

  @doc ~S"""
  "Consumed N files" sub-card (issue polished-event-stream-cards): a header plus one row
  per file (path + byte count) surfaced from a response/tool-result's file activity.
  """
  @spec consumed_files(map()) :: Phoenix.LiveView.Rendered.t()
  def consumed_files(assigns) do
    ~H"""
    <div class="cns-consumed">
      <div class="cns-consumed__header">
        Consumed {length(@files)} {if length(@files) == 1, do: "file", else: "files"}
      </div>
      <div :for={file <- @files} class="cns-consumed__file">
        <span class="cns-consumed__action">{file.action}</span>
        <span class="cns-consumed__path">{file.path}</span>
        <span :if={file.bytes} class="cns-consumed__bytes">{format_bytes(file.bytes)}</span>
      </div>
    </div>
    """
  end

  # Human-readable byte count for the consumed-files card (B / KB / MB).
  @spec format_bytes(non_neg_integer()) :: String.t()
  defp format_bytes(bytes) when bytes < 1_024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1_024, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  # --- file-change card (issue file-diff-event-cards) -----------------------

  attr :file_change, :map, required: true, doc: "presenter file_change sub-model"
  attr :expanded?, :boolean, default: false, doc: "show the full colored diff"
  attr :open_enabled?, :boolean, default: true, doc: "show the Open button for absolute paths"

  @doc ~S"""
  Polished file-change card for `Write`/`Edit`/`MultiEdit` tool-call events.

  Collapsed (default): status badge (`✓ Created` / `✎ Modified`) + `+N`/`-N` line stats
  + file path (monospace, selectable) + **Open** button (absolute paths only, when enabled).
  Expanded (`@expanded?`): adds an inline colored diff (green = added, red = removed,
  gray = context) + a truncation note when the diff was capped at 600 lines.

  The **Open** button fires the `"open_file"` LiveView event handled by `RepoBuilder.Editor`;
  editor integration may be disabled in config (test/CI) in which case it flashes an error
  instead of shelling out.
  """
  @spec file_change_card(map()) :: Phoenix.LiveView.Rendered.t()
  def file_change_card(assigns) do
    ~H"""
    <div class="cns-file-change">
      <div class="cns-file-change__header">
        <span class={["cns-file-badge", file_badge_class(@file_change.status)]}>
          {file_badge_label(@file_change.status)}
        </span>
        <span class="cns-file-change__stats">
          <span class="cns-file-change__added">+{@file_change.added}</span>
          <span class="cns-file-change__removed">-{@file_change.removed}</span>
        </span>
        <span class="cns-file-change__path" title={@file_change.path}>
          {@file_change.path}
        </span>
        <button
          :if={@open_enabled? and @file_change.absolute?}
          type="button"
          class="cns-file-change__open cns-chip"
          phx-click="open_file"
          phx-value-path={@file_change.path}
          title={"Open #{@file_change.path} in editor"}
        >
          Open
        </button>
      </div>
      <div :if={@expanded?} class="cns-diff">
        <div
          :for={line <- @file_change.diff.lines}
          class={["cns-diff__line", diff_line_class(line.op)]}
        >
          {diff_prefix(line.op)}{line.text}
        </div>
        <div :if={@file_change.diff.truncated?} class="cns-diff__truncated">
          diff truncated at {length(@file_change.diff.lines)} lines
        </div>
      </div>
    </div>
    """
  end

  @spec file_badge_class(:created | :modified) :: String.t()
  defp file_badge_class(:created), do: "cns-file-badge--created"
  defp file_badge_class(:modified), do: "cns-file-badge--modified"

  @spec file_badge_label(:created | :modified) :: String.t()
  defp file_badge_label(:created), do: "✓ Created"
  defp file_badge_label(:modified), do: "✎ Modified"

  @spec diff_line_class(:eq | :ins | :del) :: String.t()
  defp diff_line_class(:ins), do: "cns-diff__line--add"
  defp diff_line_class(:del), do: "cns-diff__line--del"
  defp diff_line_class(:eq), do: "cns-diff__line--ctx"

  @spec diff_prefix(:eq | :ins | :del) :: String.t()
  defp diff_prefix(:ins), do: "+ "
  defp diff_prefix(:del), do: "- "
  defp diff_prefix(:eq), do: "  "

  # --- selection action bar -------------------------------------------------

  attr :selected_count, :integer, default: 0
  attr :copy_payload, :string, default: "", doc: "selected rows' raw bodies joined by newlines"

  @doc """
  Bulk-action bar over the reusable event-stream selection (issue-explain).

  Renders only when ≥1 row is selected. EXPLAIN is wired end-to-end; HIDE and COPY
  are sibling actions over the SAME `selected_ids` set — each "one button + one
  handler", with no Explain-specific coupling, so a new bulk action slots in here
  without reworking the selection primitive.
  """
  @spec selection_bar(map()) :: Phoenix.LiveView.Rendered.t()
  def selection_bar(assigns) do
    ~H"""
    <div
      :if={@selected_count > 0}
      id="selection-bar"
      class="flex flex-wrap items-center gap-2 border-b px-3 py-2"
      style="border-color: var(--cns-border); background: var(--cns-bg-2, rgba(255,255,255,0.02))"
    >
      <span class="text-xs font-semibold" style="color: var(--cns-cyan)">
        {@selected_count} selected
      </span>
      <button
        id="explain-selected"
        type="button"
        phx-click={JS.push("explain_selected") |> show_explain()}
        class="cns-chip cns-chip--active cns-chip--hook"
        title="Explain the selected log line(s) with the Fast agent"
      >
        EXPLAIN ✦ ({@selected_count})
      </button>
      <button
        id="hide-selected"
        type="button"
        phx-click="hide_selected"
        class="cns-chip"
        title="Hide the selected rows from the view (does not delete persisted history)"
      >
        HIDE
      </button>
      <button
        id="copy-selected"
        type="button"
        phx-hook="ClipboardCopy"
        data-copy={@copy_payload}
        class="cns-chip"
        title="Copy the selected rows' raw bodies to the clipboard"
      >
        COPY
      </button>
      <button
        id="clear-selection"
        type="button"
        phx-click="clear_selection"
        class="cns-chip ml-auto"
        title="Clear the current selection"
      >
        Clear selection
      </button>
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

  attr :content, :string, required: true
  attr :thinking?, :boolean, default: false
  attr :label, :string, default: "ORCHESTRATOR"
  attr :time, :string, default: ""
  attr :id, :string, default: nil

  @doc """
  In-progress streaming bubble: the live token-by-token buffer for one harness
  turn, with a blinking caret. `thinking?: true` renders the reasoning variant.
  Coalesces partials in place; replaced by a finalized `chat_message`/`thinking_bubble`.
  """
  @spec streaming_bubble(map()) :: Phoenix.LiveView.Rendered.t()
  def streaming_bubble(assigns) do
    ~H"""
    <div id={@id} class="flex flex-col gap-0.5">
      <div
        class="cns-bubble__label"
        style={"color: var(#{(@thinking? && "--cns-thinking") || "--cns-text-2"})"}
      >
        {(@thinking? && "🤔 ORCHESTRATOR THINKING") || @label} · {@time}
      </div>
      <div class={[
        "cns-bubble cns-bubble--streaming",
        (@thinking? && "cns-bubble--thinking") || "cns-bubble--orch"
      ]}>
        {@content}<span class="cns-caret">▋</span>
      </div>
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

  # --- command panel (restyled launch/interrupt/ADW controls) ---------------

  attr :chat_width, :atom, default: :sm, values: [:sm, :md, :lg]
  attr :cost, :any, default: nil
  attr :estimate, :any, default: nil, doc: "token-derived live cost estimate (display-only)"

  attr :context_tokens, :integer,
    default: 0,
    doc: "the orchestrator's own context-window occupancy"

  attr :harness, :string, default: nil, doc: "the orchestrator's harness (drives window sizing)"
  attr :model, :string, default: nil, doc: "the orchestrator's model (drives window sizing)"

  attr :typing?, :boolean, default: false
  attr :auto_follow?, :boolean, default: true
  slot :messages, doc: "rendered chat bubbles"

  @doc "Right chat/command panel: chat header (context bar + clear + width toggle + cost) + the orchestrator text stream. Input is the ⌘K command modal."
  @spec command_panel(map()) :: Phoenix.LiveView.Rendered.t()
  def command_panel(assigns) do
    window = ContextWindow.size(assigns.harness || "", assigns.model)

    assigns =
      assigns
      |> assign(:window, window)
      |> assign(:ctx_pct, context_pct(assigns.context_tokens, window))

    ~H"""
    <div id="command-panel" class="flex h-full flex-col gap-3">
      <div class="flex flex-col gap-2 border-b pb-2" style="border-color: var(--cns-border)">
        <div class="flex items-center justify-between">
          <span
            class="flex items-center gap-1.5 text-xs font-semibold"
            style="color: var(--cns-cyan)"
          >
            ORCHESTRATOR <.activity_orb variant={:orchestrator} active?={@typing?} />
          </span>
          <div class="flex items-center gap-2">
            <.cost_badge cost={@cost} estimated={@estimate} />
            <div class="cns-toggle">
              <button
                type="button"
                id="chat-width"
                phx-click="cycle_chat_width"
                class="cns-toggle__seg cns-toggle__seg--active"
                title="Chat width — click to cycle SM / MD / LG"
              >
                {@chat_width |> Atom.to_string() |> String.upcase()}
              </button>
            </div>
          </div>
        </div>

        <div class="flex items-center gap-2">
          <div class="min-w-0 flex-1">
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
          <button
            type="button"
            id="clear-orchestrator-context"
            phx-click="clear_orchestrator_context"
            class="cns-chip shrink-0"
            title="Clear the orchestrator's conversation context — the next turn starts fresh"
          >
            Clear
          </button>
        </div>
      </div>

      <div
        id="chat-log"
        phx-hook="AutoScroll"
        data-auto-follow={to_string(@auto_follow?)}
        tabindex="0"
        role="log"
        aria-label="Chat log"
        class="flex min-h-0 flex-1 flex-col gap-2 overflow-y-auto pr-1"
      >
        {render_slot(@messages)}
        <.typing_indicator :if={@typing?} />
      </div>
    </div>
    """
  end

  # --- autonomy panel (self-healing Phase 6) --------------------------------

  attr :ledger, :map, default: nil, doc: "the Orchestrator.Ledgers.view/1 map, or nil"
  attr :holding_reason, :string, default: nil, doc: "escalation banner reason, or nil"

  @doc """
  The autonomy panel (self-healing Phase 6): the active orchestrator's goal, definition-of-done,
  lifecycle status, stall gauge, and latest progress — plus a loud "Escalated — awaiting human"
  banner with a one-click resume when the leader has escalated. Renders nothing when there is no
  goal and no escalation (back-compatible).
  """
  @spec autonomy_panel(map()) :: Phoenix.LiveView.Rendered.t()
  def autonomy_panel(assigns) do
    ~H"""
    <div
      :if={@ledger || @holding_reason}
      id="autonomy-panel"
      class="space-y-1 border-t px-3 py-2 text-[0.7rem]"
      style="border-color: var(--cns-border)"
    >
      <div
        :if={@holding_reason}
        id="escalation-banner"
        class="rounded px-2 py-1 font-semibold"
        style="background: #f6dede; color: #b23b3b"
      >
        ⚠ Escalated — awaiting human: {@holding_reason}
        <button
          type="button"
          id="resume-orchestrator"
          phx-click="resume_orchestrator"
          class="ml-2 underline"
        >
          Resume
        </button>
      </div>
      <div :if={@ledger}>
        <div id="ledger-goal" class="font-semibold" style="color: var(--cns-text)">
          Goal: {@ledger.goal}
        </div>
        <div id="ledger-dod" style="color: var(--cns-text-2)">
          Done when: {@ledger.definition_of_done}
        </div>
        <div class="flex items-center gap-2">
          <span id="ledger-status" class="cns-chip">{to_string(@ledger.status)}</span>
          <span id="ledger-stall" class="cns-chip">stall {@ledger.stall_count}</span>
        </div>
        <div :if={@ledger.progress} id="ledger-progress" style="color: var(--cns-text-2)">
          Last: {@ledger.progress.summary || "(no summary)"}
        </div>
      </div>
    </div>
    """
  end

  # --- orchestrator message queue strip -------------------------------------

  attr :busy?, :boolean, default: false, doc: "a turn is currently in flight"
  attr :depth, :integer, default: 0, doc: "number of queued operator/auto-resume turns"

  attr :queued, :list,
    default: [],
    doc: "pending items: %{id, preview, kind} maps, in FIFO order"

  @doc """
  The pending-message strip (issue message-queue): a busy/queued badge plus one chip
  per queued turn with a cancel button. Hidden entirely when the orchestrator is idle
  with an empty queue, so it never takes vertical space in the common case.
  """
  @spec queued_messages(map()) :: Phoenix.LiveView.Rendered.t()
  def queued_messages(assigns) do
    ~H"""
    <div
      :if={@busy? or @depth > 0}
      id="orchestrator-queue"
      class="flex flex-wrap items-center gap-1.5 border-t px-3 py-1.5"
      style="border-color: var(--cns-border)"
    >
      <span
        id="queue-badge"
        class="text-[0.625rem] font-semibold uppercase"
        style="color: var(--cns-text-2)"
      >
        {if @busy?, do: "Busy", else: "Idle"} · {@depth} queued
      </span>
      <span
        :for={item <- @queued}
        id={"queued-#{item.id}"}
        class="cns-chip flex items-center gap-1"
        title={item.preview}
      >
        <span :if={item.kind == :auto_resume} class="text-[0.625rem]" style="color: var(--cns-text-3)">
          auto
        </span>
        <span class="max-w-[14rem] truncate">{item.preview}</span>
        <button
          type="button"
          id={"cancel-queued-#{item.id}"}
          phx-click="cancel_queued"
          phx-value-id={item.id}
          class="font-bold"
          title="Cancel"
          aria-label="Cancel queued message"
        >
          ×
        </button>
      </span>
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

  attr :settings_tab, :atom,
    default: :general,
    values: [
      :general,
      :appearance,
      :about,
      :prompt,
      :templates,
      :cost_center,
      :default_models,
      :logs
    ]

  attr :view_mode, :atom, default: :logs
  attr :chat_width, :atom, default: :sm
  attr :auto_follow?, :boolean, default: true
  attr :show_thinking?, :boolean, default: true
  attr :show_hidden?, :boolean, default: false
  attr :release_notice, :any, default: nil
  attr :harnesses, :list, default: []
  attr :system_prompt, :string, default: ""
  attr :system_prompt_mode, :atom, default: :append, values: [:append, :replace]
  attr :default_system_prompt, :string, default: ""

  attr :reasoning_effort, :atom,
    default: :default,
    values: [:default, :off, :low, :medium, :high, :max]

  attr :reasoning_efforts, :list, default: []
  attr :timezone, :string, default: "UTC"
  attr :timezones, :list, default: []
  attr :template_rows, :list, default: []
  attr :selected_template, :any, default: nil
  attr :template_versions, :list, default: []
  attr :cost_rollups, :list, default: []
  attr :period_spend, :any, default: nil
  attr :project_report, :any, default: nil
  attr :price_rows, :list, default: []
  attr :price_form, :any, default: nil
  attr :editing_price_id, :any, default: nil
  attr :stack_layer_rows, :list, default: []
  attr :stack_layer_form, :any, default: nil
  attr :editing_layer_id, :any, default: nil
  attr :default_model_rows, :list, default: []
  attr :default_model_saved, :boolean, default: false

  @doc """
  Settings modal with a vertical tab rail (General / Appearance / About). Shown and
  hidden client-side like the other modals; the active tab is server-driven via the
  `select_settings_tab` event. Controls reuse the existing toggle events (new element
  ids) so there is no duplicate-id conflict with the header controls.
  """
  @spec settings_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def settings_modal(assigns) do
    ~H"""
    <div
      id="settings-modal"
      class="cns-cmd-overlay"
      style="display:none; align-items: center"
      phx-window-keydown={hide_settings()}
      phx-key="Escape"
    >
      <div
        class="cns-cmd-panel flex flex-col"
        style="max-width: 48rem; height: 80vh; margin-bottom: 0; overflow: hidden"
      >
        <div class="mb-3 flex shrink-0 items-center justify-between">
          <span class="text-xs font-semibold" style="color: var(--cns-cyan)">SETTINGS</span>
          <button type="button" phx-click={hide_settings()} class="cns-chip">Done</button>
        </div>

        <div class="flex min-h-0 flex-1 gap-4" style="min-height: 16rem">
          <nav
            class="cns-no-scrollbar flex w-36 shrink-0 flex-col gap-1 overflow-y-auto border-r pr-2"
            style="border-color: var(--cns-border)"
          >
            <.settings_tab_button tab={:general} active={@settings_tab} label="General" />
            <.settings_tab_button tab={:appearance} active={@settings_tab} label="Appearance" />
            <.settings_tab_button tab={:prompt} active={@settings_tab} label="System Prompt" />
            <.settings_tab_button tab={:templates} active={@settings_tab} label="Agent Templates" />
            <.settings_tab_button tab={:cost_center} active={@settings_tab} label="Cost Center" />
            <.settings_tab_button
              tab={:stack_layers}
              active={@settings_tab}
              label="Stack Layers"
            />
            <.settings_tab_button
              tab={:default_models}
              active={@settings_tab}
              label="Default Models"
            />
            <.settings_tab_button tab={:logs} active={@settings_tab} label="Log Database" />
            <.settings_tab_button tab={:about} active={@settings_tab} label="About" />
          </nav>

          <div class="cns-no-scrollbar min-w-0 flex-1 overflow-y-auto pr-1">
            <div :if={@settings_tab == :general} class="flex flex-col gap-4">
              <.settings_field label="View mode">
                <div id="settings-view-toggle" class="cns-toggle" phx-click="toggle_view">
                  <span class={["cns-toggle__seg", @view_mode == :logs && "cns-toggle__seg--active"]}>
                    LOGS
                  </span>
                  <span class={["cns-toggle__seg", @view_mode == :adws && "cns-toggle__seg--active"]}>
                    ADWS
                  </span>
                </div>
              </.settings_field>

              <.settings_field label="Auto-follow chat & stream">
                <button
                  id="settings-auto-follow"
                  type="button"
                  phx-click="toggle_auto_follow"
                  class={["cns-chip", @auto_follow? && "cns-chip--active cns-chip--hook"]}
                >
                  {if @auto_follow?, do: "ON", else: "OFF"}
                </button>
              </.settings_field>

              <.settings_field label="Show orchestrator thinking">
                <button
                  id="settings-thinking"
                  type="button"
                  phx-click="toggle_thinking"
                  class={["cns-chip", @show_thinking? && "cns-chip--active cns-chip--hook"]}
                >
                  {if @show_thinking?, do: "ON", else: "OFF"}
                </button>
              </.settings_field>

              <.settings_field label="Reasoning effort">
                <div id="settings-reasoning-effort" class="cns-toggle">
                  <button
                    :for={e <- @reasoning_efforts}
                    type="button"
                    id={"settings-reasoning-effort-#{e}"}
                    phx-click="set_reasoning_effort"
                    phx-value-effort={e}
                    class={["cns-toggle__seg", @reasoning_effort == e && "cns-toggle__seg--active"]}
                  >
                    {e |> Atom.to_string() |> String.upcase()}
                  </button>
                </div>
                <p class="mt-1 text-[0.625rem]" style="color: var(--cns-text-2)">
                  How hard the orchestrator's model reasons. DEFAULT keeps each harness's
                  own default (no flag); MAX maps to each harness's top level.
                </p>
              </.settings_field>

              <.settings_field label="Timezone">
                <form id="settings-timezone-form" phx-change="set_timezone" title="Display timezone">
                  <select id="settings-timezone" name="timezone" class="cns-chip" style="width: 12rem">
                    <option :for={tz <- @timezones} value={tz} selected={@timezone == tz}>
                      {tz}
                    </option>
                  </select>
                </form>
                <p class="mt-1 text-[0.625rem]" style="color: var(--cns-text-2)">
                  Log timestamps render in this timezone (YYYY-MM-DD HH:MM:SS). The
                  setting persists across sessions.
                </p>
              </.settings_field>
            </div>

            <div :if={@settings_tab == :logs} class="flex flex-col gap-4">
              <.settings_field label="Release hidden logs & workflows">
                <div class="flex items-center gap-2">
                  <button
                    id="settings-release-hidden"
                    type="button"
                    phx-click="release_hidden"
                    class="cns-chip"
                  >
                    Release
                  </button>
                  <span
                    :if={@release_notice != nil}
                    id="settings-release-notice"
                    class="text-[0.625rem]"
                    style="color: var(--cns-text-2)"
                  >
                    Released {@release_notice} {if @release_notice == 1, do: "row", else: "rows"}
                  </span>
                </div>
                <div class="text-[0.625rem]" style="color: var(--cns-text-2)">
                  Permanently un-hides everything cleared by the CLEAR actions (the inverse of CLEAR);
                  released rows stay visible across reconnects.
                </div>
              </.settings_field>

              <.settings_field label="Temporarily show cleared rows (peek)">
                <button
                  id="settings-show-hidden"
                  type="button"
                  phx-click="toggle_show_hidden"
                  class={["cns-chip", @show_hidden? && "cns-chip--active cns-chip--hook"]}
                >
                  {if @show_hidden?, do: "ON", else: "OFF"}
                </button>
              </.settings_field>

              <.settings_field label="Manage log rows">
                <button
                  id="open-log-manager"
                  type="button"
                  phx-click={JS.push("open_log_manager") |> show_log_manager()}
                  class="cns-chip cns-chip--active cns-chip--hook"
                >
                  Manage log rows…
                </button>
                <p class="mt-1 text-[0.625rem]" style="color: var(--cns-text-2)">
                  Open a paginated, filterable inspector to select rows and make them
                  visible/invisible or purge them permanently.
                </p>
              </.settings_field>

              <.settings_field label="Purge ALL log rows (danger)">
                <button
                  id="settings-purge-all-logs"
                  type="button"
                  phx-click="purge_all_logs"
                  data-confirm="Permanently DELETE every log row? This cannot be undone and also clears Cost Center history."
                  class="cns-chip"
                >
                  Purge ALL log rows
                </button>
                <p class="mt-1 text-[0.625rem]" style="color: var(--cns-text-2)">
                  Hard-deletes every <code>agent_logs</code>
                  row. This is permanent and also removes the cost history those rows feed into Cost Center.
                </p>
              </.settings_field>
            </div>

            <div :if={@settings_tab == :appearance} class="flex flex-col gap-4">
              <.settings_field label="Chat width">
                <div class="cns-toggle">
                  <button
                    :for={w <- [:sm, :md, :lg]}
                    type="button"
                    id={"settings-chat-width-#{w}"}
                    phx-click="set_chat_width"
                    phx-value-width={w}
                    class={["cns-toggle__seg", @chat_width == w && "cns-toggle__seg--active"]}
                  >
                    {w |> Atom.to_string() |> String.upcase()}
                  </button>
                </div>
              </.settings_field>
            </div>

            <div :if={@settings_tab == :prompt} class="flex flex-col gap-4">
              <.form
                id="settings-system-prompt-form"
                for={%{}}
                phx-submit="save_system_prompt"
                class="flex flex-col gap-4"
              >
                <.settings_field label="Apply mode">
                  <div class="cns-toggle">
                    <button
                      :for={m <- [:append, :replace]}
                      type="button"
                      id={"settings-system-prompt-mode-#{m}"}
                      phx-click="set_system_prompt_mode"
                      phx-value-mode={m}
                      class={[
                        "cns-toggle__seg",
                        @system_prompt_mode == m && "cns-toggle__seg--active"
                      ]}
                    >
                      {m |> Atom.to_string() |> String.upcase()}
                    </button>
                  </div>
                  <input type="hidden" name="mode" value={@system_prompt_mode} />
                  <p class="mt-1 text-[0.625rem]" style="color: var(--cns-text-2)">
                    APPEND adds your prompt onto the harness default. REPLACE swaps the
                    harness's default coding-agent prompt out entirely — including its
                    built-in tool/safety guidance.
                  </p>
                </.settings_field>

                <.settings_field label="Custom system prompt (blank = generated default)">
                  <textarea
                    id="settings-system-prompt"
                    name="system_prompt"
                    rows="8"
                    class="w-full rounded border bg-transparent p-2 font-mono text-xs"
                    style="border-color: var(--cns-border)"
                    phx-debounce="300"
                  ><%= @system_prompt %></textarea>
                </.settings_field>

                <div class="flex gap-2">
                  <button
                    type="submit"
                    id="settings-system-prompt-save"
                    class="cns-chip cns-chip--active cns-chip--hook"
                  >
                    Save
                  </button>
                  <button
                    type="button"
                    id="settings-system-prompt-reset"
                    phx-click="reset_system_prompt"
                    class="cns-chip"
                  >
                    Reset to default
                  </button>
                </div>
              </.form>

              <.settings_field label="Generated default (preview)">
                <pre
                  id="settings-system-prompt-default"
                  class="max-h-48 overflow-auto whitespace-pre-wrap break-words rounded border p-2 font-mono text-[0.625rem]"
                  style="border-color: var(--cns-border); color: var(--cns-text-2)"
                  phx-no-curly-interpolation
                ><%= @default_system_prompt %></pre>
              </.settings_field>
            </div>

            <div :if={@settings_tab == :templates} class="flex gap-3">
              <div
                class="flex w-40 shrink-0 flex-col gap-1 border-r pr-2"
                style="border-color: var(--cns-border)"
              >
                <button
                  type="button"
                  id="agent-template-new"
                  phx-click="new_template"
                  class={[
                    "cns-chip text-left",
                    is_nil(@selected_template) && "cns-chip--active cns-chip--hook"
                  ]}
                >
                  + New template
                </button>
                <button
                  :for={row <- @template_rows}
                  type="button"
                  id={"agent-template-row-#{row.name}"}
                  phx-click="select_template"
                  phx-value-name={row.name}
                  class={[
                    "cns-chip text-left",
                    template_name(@selected_template) == row.name && "cns-chip--active cns-chip--hook"
                  ]}
                >
                  {row.name} · v{row.version}
                </button>
                <p
                  :if={@template_rows == []}
                  class="text-[0.625rem]"
                  style="color: var(--cns-text-2)"
                >
                  No templates yet.
                </p>
              </div>

              <div class="flex min-w-0 flex-1 flex-col gap-3">
                <.form
                  id="agent-template-form"
                  for={%{}}
                  phx-submit="save_agent_template"
                  class="flex flex-col gap-3"
                >
                  <.settings_field label="Name (kebab-case)">
                    <input
                      id="agent-template-name"
                      name="name"
                      value={template_field(@selected_template, :name)}
                      class="w-full rounded border bg-transparent p-2 font-mono text-xs"
                      style="border-color: var(--cns-border)"
                    />
                  </.settings_field>

                  <.settings_field label="Description">
                    <input
                      id="agent-template-description"
                      name="description"
                      value={template_field(@selected_template, :description)}
                      class="w-full rounded border bg-transparent p-2 text-xs"
                      style="border-color: var(--cns-border)"
                    />
                  </.settings_field>

                  <div class="flex gap-3">
                    <.settings_field label="Model (optional)">
                      <input
                        id="agent-template-model"
                        name="model"
                        value={template_field(@selected_template, :model)}
                        class="w-full rounded border bg-transparent p-2 font-mono text-xs"
                        style="border-color: var(--cns-border)"
                      />
                    </.settings_field>

                    <.settings_field label="Category (optional)">
                      <select
                        id="agent-template-category"
                        name="category"
                        class="w-full rounded border bg-transparent p-2 text-xs"
                        style="border-color: var(--cns-border)"
                      >
                        <option
                          value=""
                          selected={template_field(@selected_template, :category) == ""}
                        >
                          —
                        </option>
                        <option
                          :for={c <- ~w(fast main heavy leader)}
                          value={c}
                          selected={template_field(@selected_template, :category) == c}
                        >
                          {c}
                        </option>
                      </select>
                    </.settings_field>
                  </div>

                  <.settings_field label="System prompt (worker body)">
                    <textarea
                      id="agent-template-body"
                      name="system_prompt"
                      rows="8"
                      class="w-full rounded border bg-transparent p-2 font-mono text-xs"
                      style="border-color: var(--cns-border)"
                    ><%= template_field(@selected_template, :body) %></textarea>
                  </.settings_field>

                  <div class="flex gap-2">
                    <button
                      type="submit"
                      id="agent-template-save"
                      class="cns-chip cns-chip--active cns-chip--hook"
                    >
                      Save new version
                    </button>
                    <button
                      :if={not is_nil(@selected_template)}
                      type="button"
                      id="agent-template-delete"
                      phx-click="delete_template"
                      phx-value-name={template_name(@selected_template)}
                      data-confirm="Delete this template and all its versions?"
                      class="cns-chip"
                    >
                      Delete
                    </button>
                  </div>
                </.form>

                <.settings_field :if={@template_versions != []} label="Version history">
                  <div class="flex flex-col gap-1">
                    <div
                      :for={v <- @template_versions}
                      class="flex items-center justify-between text-xs"
                    >
                      <span style="color: var(--cns-text-2)">v{v.version} · {v.author}</span>
                      <button
                        type="button"
                        id={"agent-template-restore-#{v.version}"}
                        phx-click="restore_template"
                        phx-value-name={template_name(@selected_template)}
                        phx-value-version={v.version}
                        class="cns-chip"
                      >
                        Restore
                      </button>
                    </div>
                  </div>
                </.settings_field>
              </div>
            </div>

            <div :if={@settings_tab == :cost_center} class="flex flex-col gap-4">
              <.project_cost_panel :if={@project_report} report={@project_report} />
              <.spend_summary_table :if={@period_spend} summary={@period_spend} />
              <.cost_rollup_table rollups={@cost_rollups} />
              <.price_catalog_table
                rows={@price_rows}
                form={@price_form}
                editing_price_id={@editing_price_id}
              />
            </div>

            <div :if={@settings_tab == :stack_layers} class="flex flex-col gap-4">
              <.stack_layers_table
                rows={@stack_layer_rows}
                form={@stack_layer_form}
                editing_layer_id={@editing_layer_id}
              />
            </div>

            <div :if={@settings_tab == :default_models} class="flex flex-col gap-3">
              <div class="flex items-center justify-between">
                <span class="text-xs font-semibold" style="color: var(--cns-cyan)">
                  DEFAULT MODELS — what new projects inherit
                </span>
                <span
                  :if={@default_model_saved}
                  class="cns-chip"
                  style="color: var(--cns-green, #4ade80)"
                >
                  Saved ✓
                </span>
              </div>

              <p class="text-[0.625rem]" style="color: var(--cns-text-2)">
                Set the global default harness/provider/model per worker tier. A newly
                registered project's orchestrator is seeded from this roster, and any tier a
                project leaves unset inherits it. Per-project overrides always win.
              </p>

              <form
                :for={row <- @default_model_rows}
                id={"default-model-#{row.category}"}
                phx-change="set_default_agent_model"
                class="flex items-center gap-2"
              >
                <input type="hidden" name="category" value={row.category} />
                <span
                  class="w-16 text-xs font-semibold uppercase"
                  style="color: var(--cns-text-1)"
                >
                  {row.category}
                </span>

                <select name="harness" class="cns-chip" style="width: 8rem">
                  <option value="" selected={row.harness in [nil, ""]}>harness…</option>
                  <option :for={h <- row.harness_options} value={h} selected={row.harness == h}>
                    {h}
                  </option>
                </select>

                <select
                  name="provider"
                  class="cns-chip"
                  style="width: 9rem"
                  disabled={row.harness in [nil, ""]}
                >
                  <option value="" selected={row.provider in [nil, ""]}>provider…</option>
                  <option :for={p <- row.provider_options} value={p} selected={row.provider == p}>
                    {p}
                  </option>
                </select>

                <select
                  name="model"
                  class="cns-chip"
                  style="width: 13rem"
                  disabled={row.harness in [nil, ""]}
                >
                  <option value="" selected={row.model in [nil, ""]}>no default…</option>
                  <option :for={m <- row.model_options} value={m} selected={row.model == m}>
                    {m}
                  </option>
                </select>
              </form>
            </div>

            <div :if={@settings_tab == :about} class="flex flex-col gap-2 text-xs">
              <div
                class="text-[0.625rem] font-semibold uppercase"
                style="color: var(--cns-text-2)"
              >
                Registered harnesses
              </div>
              <div class="flex flex-wrap gap-1">
                <span :for={h <- @harnesses} class="cns-chip">{h}</span>
              </div>
              <p class="mt-2 text-[0.625rem]" style="color: var(--cns-text-2)">
                Orchestration Console — repo_builder. Deterministic orchestration of
                supervised AI harness CLIs.
              </p>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :tab, :atom, required: true
  attr :active, :atom, required: true
  attr :label, :string, required: true

  @doc "One button in the settings vertical tab rail."
  @spec settings_tab_button(map()) :: Phoenix.LiveView.Rendered.t()
  def settings_tab_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="select_settings_tab"
      phx-value-tab={@tab}
      class={["cns-chip text-left", @tab == @active && "cns-chip--active cns-chip--hook"]}
    >
      {@label}
    </button>
    """
  end

  attr :label, :string, required: true
  slot :inner_block, required: true

  @doc "A labeled settings row (label above its control)."
  @spec settings_field(map()) :: Phoenix.LiveView.Rendered.t()
  def settings_field(assigns) do
    ~H"""
    <div class="flex flex-col gap-1">
      <div class="text-[0.625rem] font-semibold uppercase" style="color: var(--cns-text-2)">
        {@label}
      </div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :report, :any, required: true

  @doc """
  Per-project cost panel (issue per-project-cost-tracking): the active project's lifetime
  total, a session/today/week/month period strip, a by-model breakdown, and Clear/Restore
  controls. `@report` is `%{report: ProjectReport.t(), periods: map()}`. The lifetime total
  is the *display* total (cleared rows excluded); a "N cleared (restorable)" marker shows
  when soft-hidden rows exist.
  """
  @spec project_cost_panel(map()) :: Phoenix.LiveView.Rendered.t()
  def project_cost_panel(assigns) do
    ~H"""
    <div
      id="project-cost-panel"
      class="flex flex-col gap-3 rounded border p-3"
      style="border-color: var(--cns-border)"
    >
      <div class="flex items-center justify-between">
        <div class="text-[0.625rem] font-semibold uppercase" style="color: var(--cns-text-2)">
          This project — lifetime
        </div>
        <div class="flex items-center gap-2">
          <button
            type="button"
            phx-click="clear_project_costs"
            data-confirm="Clear this project's cost rows? They're hidden, not deleted (restorable)."
            class="cns-chip text-[0.625rem]"
          >
            Clear
          </button>
          <button
            :if={@report.report.hidden?}
            type="button"
            phx-click="restore_project_costs"
            class="cns-chip text-[0.625rem]"
          >
            Restore
          </button>
        </div>
      </div>

      <div class="flex items-baseline gap-2">
        <span id="project-cost-total" class="text-lg font-semibold" style="color: var(--cns-text-1)">
          {cost_str(@report.report.total_usd)}
        </span>
        <span :if={@report.report.estimated?} class="cns-chip text-[0.625rem]">incl. est.</span>
        <span
          :if={@report.report.hidden?}
          class="text-[0.625rem]"
          style="color: var(--cns-text-2)"
        >
          some rows cleared (restorable)
        </span>
      </div>

      <div class="flex flex-wrap gap-3 text-[0.6875rem]" style="color: var(--cns-text-2)">
        <span>session {cost_str(@report.periods.session)}</span>
        <span>today {cost_str(@report.periods.today)}</span>
        <span>week {cost_str(@report.periods.week)}</span>
        <span>month {cost_str(@report.periods.month)}</span>
      </div>

      <div
        :if={@report.report.by_model == []}
        class="text-[0.625rem]"
        style="color: var(--cns-text-2)"
      >
        No spend recorded for this project yet.
      </div>

      <table
        :if={@report.report.by_model != []}
        id="project-cost-by-model"
        class="w-full text-[0.6875rem]"
      >
        <thead>
          <tr style="color: var(--cns-text-2)">
            <th class="py-1 pr-2 text-left font-medium">Model</th>
            <th class="py-1 pr-2 text-right font-medium">Cost</th>
            <th class="py-1 pr-2 text-right font-medium">In</th>
            <th class="py-1 pr-2 text-right font-medium">Out</th>
            <th class="py-1 pr-2 text-right font-medium">Events</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={r <- @report.report.by_model} style="border-top: 1px solid var(--cns-border)">
            <td class="py-1 pr-2">{cost_dim(r.key)}</td>
            <td class="py-1 pr-2 text-right"><.spend_cost row={r} /></td>
            <td class="py-1 pr-2 text-right">{r.input_tokens}</td>
            <td class="py-1 pr-2 text-right">{r.output_tokens}</td>
            <td class="py-1 pr-2 text-right">{r.event_count}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :summary, :any, required: true

  @doc """
  Time-windowed spend summary (issue-cost-adw-periods): Today / This week / This month,
  each broken down by harness and by provider. This is the **accounting** view — it counts
  all activity regardless of visibility (cleared/hidden logs included), so it stays put when
  CLEAR is pressed. Estimates are marked `est.` exactly as in the all-time rollup.
  """
  @spec spend_summary_table(map()) :: Phoenix.LiveView.Rendered.t()
  def spend_summary_table(assigns) do
    ~H"""
    <div class="flex flex-col gap-3">
      <div class="text-[0.625rem] font-semibold uppercase" style="color: var(--cns-text-2)">
        Spend by period
      </div>
      <p class="text-[0.625rem]" style="color: var(--cns-text-2)">
        All activity in {@summary.timezone} — includes cleared logs (accounting view, not the
        console buffer).
      </p>
      <.spend_period id="spend-today" label="Today" tz={@summary.timezone} period={@summary.today} />
      <.spend_period
        id="spend-week"
        label="This week"
        tz={@summary.timezone}
        period={@summary.week}
      />
      <.spend_period
        id="spend-month"
        label="This month"
        tz={@summary.timezone}
        period={@summary.month}
      />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :tz, :string, required: true
  attr :period, :any, required: true

  # One period block: a heading with its local start boundary, plus the by-harness and
  # by-provider sub-tables.
  @spec spend_period(map()) :: Phoenix.LiveView.Rendered.t()
  defp spend_period(assigns) do
    ~H"""
    <div id={@id} class="flex flex-col gap-2">
      <div class="text-[0.6875rem] font-semibold">
        {@label}
        <span class="font-normal" style="color: var(--cns-text-2)">
          · since {RepoBuilder.Timezones.format_datetime(@period.since, @tz)}
        </span>
      </div>
      <.spend_breakdown id={"#{@id}-harness"} title="By harness" rows={@period.by_harness} />
      <.spend_breakdown id={"#{@id}-provider"} title="By provider" rows={@period.by_provider} />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :rows, :list, required: true

  # One dimension breakdown table (harness or provider) for a single period.
  @spec spend_breakdown(map()) :: Phoenix.LiveView.Rendered.t()
  defp spend_breakdown(assigns) do
    ~H"""
    <div class="flex flex-col gap-1">
      <div class="text-[0.625rem] uppercase" style="color: var(--cns-text-2)">{@title}</div>
      <div :if={@rows == []} class="text-[0.625rem]" style="color: var(--cns-text-2)">
        No spend.
      </div>
      <table :if={@rows != []} id={@id} class="w-full text-[0.6875rem]">
        <thead>
          <tr style="color: var(--cns-text-2)">
            <th class="py-1 pr-2 text-left font-medium">Name</th>
            <th class="py-1 pr-2 text-right font-medium">Cost</th>
            <th class="py-1 pr-2 text-right font-medium">In</th>
            <th class="py-1 pr-2 text-right font-medium">Out</th>
            <th class="py-1 pr-2 text-right font-medium">Events</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={r <- @rows} style="border-top: 1px solid var(--cns-border)">
            <td class="py-1 pr-2">{cost_dim(r.key)}</td>
            <td class="py-1 pr-2 text-right"><.spend_cost row={r} /></td>
            <td class="py-1 pr-2 text-right">{r.input_tokens}</td>
            <td class="py-1 pr-2 text-right">{r.output_tokens}</td>
            <td class="py-1 pr-2 text-right">{r.event_count}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :row, :any, required: true

  # Cost cell for a spend row: the billed amount (hidden when a bucket is purely an
  # estimate) plus an `est.`-marked catalog estimate when any unpriced portion exists.
  @spec spend_cost(map()) :: Phoenix.LiveView.Rendered.t()
  defp spend_cost(assigns) do
    ~H"""
    <span>
      <.cost_badge :if={spend_show_actual?(@row)} cost={@row.actual_cost_usd} />
      <span
        :if={@row.estimated_cost_usd}
        class="cns-chip"
        title="estimated from the price catalog"
      >
        {cost_str(@row.estimated_cost_usd)} <span style="color: var(--cns-text-2)">est.</span>
      </span>
    </span>
    """
  end

  attr :rollups, :list, required: true

  @doc """
  Recent-spend rollup grouped by `(harness, provider, model)`, most-recent first.
  Unpriced dimensions that the catalog can price show an `est.`-labelled estimate
  rather than a billed amount (issue-cost-center).
  """
  @spec cost_rollup_table(map()) :: Phoenix.LiveView.Rendered.t()
  def cost_rollup_table(assigns) do
    ~H"""
    <div class="flex flex-col gap-1">
      <div class="text-[0.625rem] font-semibold uppercase" style="color: var(--cns-text-2)">
        Recent spend
      </div>
      <div
        :if={@rollups == []}
        class="text-[0.625rem]"
        style="color: var(--cns-text-2)"
      >
        No cost recorded yet.
      </div>
      <table :if={@rollups != []} id="cost-rollup-table" class="w-full text-[0.6875rem]">
        <thead>
          <tr style="color: var(--cns-text-2)">
            <th class="py-1 pr-2 text-left font-medium">Harness</th>
            <th class="py-1 pr-2 text-left font-medium">Provider</th>
            <th class="py-1 pr-2 text-left font-medium">Model</th>
            <th class="py-1 pr-2 text-right font-medium">Cost</th>
            <th class="py-1 pr-2 text-right font-medium">In</th>
            <th class="py-1 pr-2 text-right font-medium">Out</th>
            <th class="py-1 pr-2 text-right font-medium">Events</th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={r <- @rollups}
            id={cost_rollup_row_id(r)}
            style="border-top: 1px solid var(--cns-border)"
          >
            <td class="py-1 pr-2">{r.harness}</td>
            <td class="py-1 pr-2">{cost_dim(r.provider)}</td>
            <td class="py-1 pr-2">{cost_dim(r.model)}</td>
            <td class="py-1 pr-2 text-right">
              <span :if={r.estimated?} class="cns-chip" title="estimated from the price catalog">
                {cost_str(r.estimated_cost_usd)} <span style="color: var(--cns-text-2)">est.</span>
              </span>
              <.cost_badge :if={not r.estimated?} cost={r.actual_cost_usd} />
            </td>
            <td class="py-1 pr-2 text-right">{r.input_tokens}</td>
            <td class="py-1 pr-2 text-right">{r.output_tokens}</td>
            <td class="py-1 pr-2 text-right">{r.event_count}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :rows, :list, required: true
  attr :form, :any, required: true
  attr :editing_price_id, :any, default: nil

  @doc """
  Editable price catalog (issue-cost-center): a create/edit form plus the current rows
  with per-row Edit + (confirmed) Delete. When `:editing_price_id` is set the form is in
  edit mode — its identity key inputs are locked (readonly) so an edit can never repoint
  the `(harness, provider, model)` key. Operator edits persist to `model_prices` and
  override config rates.
  """
  @spec price_catalog_table(map()) :: Phoenix.LiveView.Rendered.t()
  def price_catalog_table(assigns) do
    ~H"""
    <div class="flex flex-col gap-2">
      <div class="text-[0.625rem] font-semibold uppercase" style="color: var(--cns-text-2)">
        Price catalog (USD / Mtok)
      </div>

      <.form
        :if={@form}
        id="price-form"
        for={@form}
        phx-submit="save_price"
        class="flex flex-wrap items-end gap-2"
      >
        <div
          class="w-full text-[0.625rem] font-semibold uppercase"
          style="color: var(--cns-text-2)"
        >
          <span :if={@editing_price_id}>Editing {@form[:harness].value}/{@form[:model].value}</span>
          <span :if={!@editing_price_id}>New price</span>
        </div>
        <.input :if={@editing_price_id} field={@form[:id]} type="hidden" />
        <.input
          field={@form[:harness]}
          label="Harness"
          class="cns-input w-24"
          readonly={@editing_price_id != nil}
        />
        <.input
          field={@form[:provider]}
          label="Provider"
          class="cns-input w-24"
          readonly={@editing_price_id != nil}
        />
        <.input
          field={@form[:model]}
          label="Model"
          class="cns-input w-40"
          readonly={@editing_price_id != nil}
        />
        <.input
          field={@form[:input_price_per_mtok]}
          label="Input"
          type="number"
          step="any"
          class="cns-input w-20"
        />
        <.input
          field={@form[:output_price_per_mtok]}
          label="Output"
          type="number"
          step="any"
          class="cns-input w-20"
        />
        <button id="price-form-submit" type="submit" class="cns-chip">Save</button>
        <button
          :if={@editing_price_id}
          id="price-cancel"
          type="button"
          phx-click="cancel_edit"
          class="cns-chip"
        >
          Cancel
        </button>
      </.form>

      <table id="price-catalog-table" class="w-full text-[0.6875rem]">
        <thead>
          <tr style="color: var(--cns-text-2)">
            <th class="py-1 pr-2 text-left font-medium">Harness</th>
            <th class="py-1 pr-2 text-left font-medium">Provider</th>
            <th class="py-1 pr-2 text-left font-medium">Model</th>
            <th class="py-1 pr-2 text-right font-medium">In</th>
            <th class="py-1 pr-2 text-right font-medium">Out</th>
            <th class="py-1 pr-2 text-right font-medium">Source</th>
            <th class="py-1"><span class="sr-only">Actions</span></th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={p <- @rows}
            id={"price-row-#{p.id}"}
            style="border-top: 1px solid var(--cns-border)"
          >
            <td class="py-1 pr-2">{p.harness}</td>
            <td class="py-1 pr-2">{cost_dim(p.provider)}</td>
            <td class="py-1 pr-2">{p.model}</td>
            <td class="py-1 pr-2 text-right">{price_str(p.input_price_per_mtok)}</td>
            <td class="py-1 pr-2 text-right">{price_str(p.output_price_per_mtok)}</td>
            <td class="py-1 pr-2 text-right">{p.source}</td>
            <td class="py-1 text-right">
              <button
                type="button"
                id={"price-edit-#{p.id}"}
                phx-click="edit_price"
                phx-value-id={p.id}
                class="cns-chip"
              >
                Edit
              </button>
              <button
                type="button"
                id={"price-delete-#{p.id}"}
                phx-click="delete_price"
                phx-value-id={p.id}
                data-confirm="Delete this price? Manual rates are not restored by re-seed."
                class="cns-chip"
              >
                ✕
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  # --- stack layers catalog (stack-layers subsystem) ---

  attr :rows, :list, required: true
  attr :form, :any, required: true
  attr :editing_layer_id, :any, default: nil

  @doc """
  Editable Stack Layers catalog (stack-layers subsystem): a create/edit form plus the
  current typed layers with per-row Edit + (confirmed) Delete. Each layer's `reasoning`
  is the worker-facing guardrail injected into the stack contract. Operator edits persist
  to `stack_layers` and mark the row `:manual` (preserved across re-seed).
  """
  @spec stack_layers_table(map()) :: Phoenix.LiveView.Rendered.t()
  def stack_layers_table(assigns) do
    ~H"""
    <div class="flex flex-col gap-2">
      <div class="text-[0.625rem] font-semibold uppercase" style="color: var(--cns-text-2)">
        Stack layers (typed, mix &amp; match per project)
      </div>

      <.form
        :if={@form}
        id="stack-layer-form"
        for={@form}
        phx-submit="save_layer"
        class="flex flex-wrap items-end gap-2"
      >
        <div
          class="w-full text-[0.625rem] font-semibold uppercase"
          style="color: var(--cns-text-2)"
        >
          <span :if={@editing_layer_id}>Editing {@form[:name].value}</span>
          <span :if={!@editing_layer_id}>New layer</span>
        </div>
        <.input :if={@editing_layer_id} field={@form[:id]} type="hidden" />
        <.input
          field={@form[:layer_type]}
          label="Type"
          type="select"
          options={layer_type_options()}
          class="cns-input w-28"
        />
        <.input field={@form[:name]} label="Name" class="cns-input w-36" />
        <.input field={@form[:language]} label="Language" class="cns-input w-28" />
        <.input
          field={@form[:reasoning]}
          label="Reasoning (worker guardrail)"
          type="textarea"
          class="cns-input w-full"
        />
        <button id="stack-layer-form-submit" type="submit" class="cns-chip">Save</button>
        <button
          :if={@editing_layer_id}
          id="stack-layer-cancel"
          type="button"
          phx-click="cancel_layer_edit"
          class="cns-chip"
        >
          Cancel
        </button>
      </.form>

      <table id="stack-layers-table" class="w-full text-[0.6875rem]">
        <thead>
          <tr style="color: var(--cns-text-2)">
            <th class="py-1 pr-2 text-left font-medium">Type</th>
            <th class="py-1 pr-2 text-left font-medium">Name</th>
            <th class="py-1 pr-2 text-left font-medium">Language</th>
            <th class="py-1 pr-2 text-left font-medium">Reasoning</th>
            <th class="py-1 pr-2 text-right font-medium">Source</th>
            <th class="py-1"><span class="sr-only">Actions</span></th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={l <- @rows}
            id={"stack-layer-row-#{l.id}"}
            style="border-top: 1px solid var(--cns-border)"
          >
            <td class="py-1 pr-2">{l.layer_type}</td>
            <td class="py-1 pr-2">{l.name}</td>
            <td class="py-1 pr-2">{l.language}</td>
            <td class="py-1 pr-2">{reasoning_excerpt(l.reasoning)}</td>
            <td class="py-1 pr-2 text-right">{l.source}</td>
            <td class="py-1 text-right">
              <button
                type="button"
                id={"stack-layer-edit-#{l.id}"}
                phx-click="edit_layer"
                phx-value-id={l.id}
                class="cns-chip"
              >
                Edit
              </button>
              <button
                type="button"
                id={"stack-layer-delete-#{l.id}"}
                phx-click="delete_layer"
                phx-value-id={l.id}
                data-confirm="Delete this layer? It is removed from every project that selected it."
                class="cns-chip"
              >
                ✕
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @spec layer_type_options() :: [{String.t(), String.t()}]
  defp layer_type_options do
    Enum.map(StackLayer.layer_types(), fn type ->
      {type |> Atom.to_string() |> String.capitalize(), Atom.to_string(type)}
    end)
  end

  @spec reasoning_excerpt(String.t() | nil) :: String.t()
  defp reasoning_excerpt(nil), do: ""

  defp reasoning_excerpt(reasoning) when is_binary(reasoning) do
    if String.length(reasoning) > 80, do: String.slice(reasoning, 0, 80) <> "…", else: reasoning
  end

  # --- budget guardrails (issue-budget-guardrails) ---

  attr :state, :map, required: true, doc: "Budget.Guard.snapshot/0 result"

  @doc "Compact spend/cap budget badge — color-coded by the worst breaker state."
  @spec budget_badge(map()) :: Phoenix.LiveView.Rendered.t()
  def budget_badge(assigns) do
    assigns = assign(assigns, :worst, budget_worst_state(assigns.state))

    ~H"""
    <span
      id="budget-badge"
      class="badge badge-outline"
      data-budget-state={to_string(@worst)}
      title="Budget guardrails"
    >
      <%= case @worst do %>
        <% :tripped -> %>
          ⛔ budget
        <% :warning -> %>
          ⚠ budget
        <% _ -> %>
          ✓ budget
      <% end %>
    </span>
    """
  end

  attr :state, :map, required: true

  @doc """
  Tripped/kill-switch banner — rendered only when the kill switch is engaged or a cap is
  tripped. Names the offending cap(s) and offers a per-cap reset affordance.
  """
  @spec budget_banner(map()) :: Phoenix.LiveView.Rendered.t()
  def budget_banner(assigns) do
    assigns = assign(assigns, :tripped, Enum.filter(assigns.state.caps, &(&1.state == :tripped)))

    ~H"""
    <div
      :if={@state.kill_switch? or @tripped != []}
      id="budget-banner"
      class="flex flex-col gap-1 border px-3 py-2 text-[0.75rem]"
      style="border-color: #b91c1c; background: rgba(185,28,28,0.12); color: #fca5a5"
    >
      <div :if={@state.kill_switch?} class="font-semibold">
        🛑 KILL SWITCH ENGAGED — all new spend is blocked and live sessions were interrupted.
      </div>
      <div :for={row <- @tripped} class="flex items-center justify-between gap-2">
        <span>
          ⛔ {budget_scope_label(row.cap)} budget tripped — spent {budget_cost(row.spent)} of {budget_cost(
            row.cap.limit_usd
          )} ({budget_action_label(row.cap.action)})
        </span>
        <button
          type="button"
          id={"budget-reset-#{row.cap.id}"}
          phx-click="reset_budget"
          phx-value-id={row.cap.id}
          class="cns-chip"
        >
          Reset
        </button>
      </div>
    </div>
    """
  end

  attr :state, :map, required: true

  @doc "The manual global kill-switch button (engage / release)."
  @spec kill_switch(map()) :: Phoenix.LiveView.Rendered.t()
  def kill_switch(assigns) do
    ~H"""
    <button
      type="button"
      id="kill-switch"
      phx-click="toggle_kill_switch"
      data-engaged={to_string(@state.kill_switch?)}
      class="cns-chip"
      style={if @state.kill_switch?, do: "color: #fca5a5; border-color: #b91c1c", else: ""}
    >
      {if @state.kill_switch?, do: "Release kill switch", else: "🛑 Kill switch"}
    </button>
    """
  end

  attr :state, :map, required: true
  attr :caps, :list, required: true, doc: "merged DB+live rows for the editable list"
  attr :form, :any, required: true
  attr :scope, :string, default: "global", doc: "the form's currently-selected scope"

  attr :scope_targets, :map,
    default: %{},
    doc:
      ~S(`%{"orchestrator" => [{label, id}], "workflow" => [{label, id}]}` for the scope_id picker)

  attr :editing?, :boolean, default: false, doc: "true when the form is editing an existing cap"

  @doc """
  Budget guardrails as a popup modal (opened from the header `#stat-cost` pill). Shown
  and hidden client-side like the other console modals; wraps the existing live
  `budget_badge` + `budget_panel` so there is a single source of truth for the markup.
  """
  @spec budget_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def budget_modal(assigns) do
    ~H"""
    <div
      id="budget-modal"
      class="cns-cmd-overlay"
      style="display:none"
      phx-window-keydown={hide_budget()}
      phx-key="Escape"
    >
      <div class="cns-cmd-panel" style="max-width: 40rem">
        <div class="mb-3 flex items-center justify-between">
          <span class="text-xs font-semibold" style="color: var(--cns-cyan)">BUDGET</span>
          <div class="flex items-center gap-2">
            <.budget_badge state={@state} />
            <button type="button" phx-click={hide_budget()} class="cns-chip">Done</button>
          </div>
        </div>

        <.budget_panel
          state={@state}
          caps={@caps}
          form={@form}
          scope={@scope}
          scope_targets={@scope_targets}
          editing?={@editing?}
        />
      </div>
    </div>
    """
  end

  attr :filter, :atom, default: :all, values: [:all, :visible, :hidden]
  attr :rows, :list, default: [], doc: "current page of `AgentLog.t()` rows (newest-first)"
  attr :total, :integer, default: 0, doc: "total rows for the active filter"
  attr :limit, :integer, default: 50
  attr :offset, :integer, default: 0
  attr :selected, :any, default: %MapSet{}, doc: "MapSet of selected `agent_logs.id` strings"
  attr :timezone, :string, default: "UTC"

  @doc """
  Log Database manager popup (issue-log-db-manager). A paginated, drag-selectable table
  of `agent_logs` rows with an All / Visible / Hidden filter, a selection action bar
  (make visible/invisible, purge selected), and Prev/Next pagination. Shown and hidden
  client-side like the other console modals (always in the DOM). The drag-select gesture
  is owned by a dedicated `LogDragSelect` JS hook on the stable table host so the live
  main-view `DragSelect` is untouched.
  """
  @spec log_manager_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def log_manager_modal(assigns) do
    assigns =
      assign(assigns,
        selected_count: MapSet.size(assigns.selected),
        range_lo: if(assigns.total == 0, do: 0, else: assigns.offset + 1),
        range_hi: min(assigns.offset + length(assigns.rows), assigns.total)
      )

    ~H"""
    <div
      id="log-manager-modal"
      class="cns-cmd-overlay"
      style="display:none"
      phx-window-keydown={hide_log_manager()}
      phx-key="Escape"
    >
      <div
        class="cns-cmd-panel flex flex-col"
        style="max-width: 56rem; height: 80vh; overflow: hidden"
      >
        <div class="mb-3 flex shrink-0 items-center justify-between">
          <span class="text-xs font-semibold" style="color: var(--cns-cyan)">LOG DATABASE</span>
          <button type="button" phx-click={hide_log_manager()} class="cns-chip">Done</button>
        </div>

        <div class="mb-2 flex shrink-0 items-center gap-2">
          <div class="cns-toggle">
            <button
              :for={{seg, label} <- [{:all, "All"}, {:visible, "Visible"}, {:hidden, "Hidden"}]}
              type="button"
              id={"log-filter-#{seg}"}
              phx-click="select_log_filter"
              phx-value-filter={seg}
              class={["cns-toggle__seg", @filter == seg && "cns-toggle__seg--active"]}
            >
              {label}
            </button>
          </div>
        </div>

        <div
          :if={@selected_count > 0}
          id="log-manager-selection-bar"
          class="mb-2 flex shrink-0 flex-wrap items-center gap-2 rounded border px-3 py-2"
          style="border-color: var(--cns-border); background: var(--cns-bg-2, rgba(255,255,255,0.02))"
        >
          <span class="text-xs font-semibold" style="color: var(--cns-cyan)">
            {@selected_count} selected
          </span>
          <button id="log-make-visible" type="button" phx-click="log_make_visible" class="cns-chip">
            Make visible
          </button>
          <button
            id="log-make-invisible"
            type="button"
            phx-click="log_make_invisible"
            class="cns-chip"
          >
            Make invisible
          </button>
          <button
            id="log-purge-selected"
            type="button"
            phx-click="log_purge_selected"
            data-confirm="Permanently DELETE the selected log rows? This cannot be undone and also clears their Cost Center history."
            class="cns-chip"
          >
            Purge selected
          </button>
          <button
            id="log-clear-selection"
            type="button"
            phx-click="clear_log_selection"
            class="cns-chip ml-auto"
          >
            Clear selection
          </button>
        </div>

        <div class="cns-no-scrollbar min-h-0 flex-1 overflow-y-auto">
          <div id="log-manager-table-wrap" phx-hook="LogDragSelect" class="contents">
            <table class="w-full text-[0.6875rem]">
              <thead>
                <tr style="color: var(--cns-text-2)" class="text-left uppercase">
                  <th class="w-6 py-1"></th>
                  <th class="py-1 pr-2">Log</th>
                  <th class="py-1 pr-2">Time</th>
                  <th class="py-1 pr-2">Harness / Model</th>
                  <th class="py-1 pr-2">Type</th>
                  <th class="py-1 pr-2">Visibility</th>
                </tr>
              </thead>
              <tbody>
                <tr :if={@rows == []}>
                  <td colspan="6" class="py-6 text-center" style="color: var(--cns-text-2)">
                    No log rows for this filter.
                  </td>
                </tr>
                <tr
                  :for={row <- @rows}
                  id={"log-mgr-row-#{row.id}"}
                  class={[
                    "log-mgr-row border-t",
                    MapSet.member?(@selected, row.id) && "log-mgr-row--selected"
                  ]}
                  style="border-color: var(--cns-border)"
                >
                  <td class="py-1">
                    <input
                      type="checkbox"
                      class="log-mgr-row__select"
                      data-row-id={row.id}
                      checked={MapSet.member?(@selected, row.id)}
                      phx-click="log_toggle_select"
                      phx-value-id={row.id}
                      aria-label={"Select log row #{row.id}"}
                    />
                  </td>
                  <td class="py-1 pr-2 font-semibold" style="color: var(--cns-cyan)">
                    {RepoBuilder.Logs.log_label(row.log_no)}
                  </td>
                  <td class="py-1 pr-2" style="color: var(--cns-text-2)">
                    {log_mgr_time(row.inserted_at, @timezone)}
                  </td>
                  <td class="py-1 pr-2">
                    {row.harness || "—"}<span :if={row.model} style="color: var(--cns-text-2)"> · {row.model}</span>
                  </td>
                  <td class="py-1 pr-2">{row.event_type}</td>
                  <td class="py-1 pr-2">
                    <span class={["cns-chip", row.hidden && "cns-chip--active cns-chip--hook"]}>
                      {if row.hidden, do: "Hidden", else: "Visible"}
                    </span>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <div class="mt-2 flex shrink-0 items-center justify-between text-[0.6875rem]">
          <span style="color: var(--cns-text-2)">
            rows {@range_lo}–{@range_hi} of {@total}
          </span>
          <div class="flex items-center gap-2">
            <button
              id="log-page-prev"
              type="button"
              phx-click="log_page_prev"
              disabled={@offset <= 0}
              class="cns-chip"
            >
              Prev
            </button>
            <button
              id="log-page-next"
              type="button"
              phx-click="log_page_next"
              disabled={@offset + @limit >= @total}
              class="cns-chip"
            >
              Next
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Timezone-aware row timestamp (mirrors the center view's formatting); nil-safe.
  @spec log_mgr_time(DateTime.t() | nil, String.t()) :: String.t()
  defp log_mgr_time(%DateTime{} = at, timezone),
    do: RepoBuilder.Timezones.format_datetime(at, timezone)

  defp log_mgr_time(_at, _timezone), do: ""

  attr :state, :map, required: true

  attr :caps, :list,
    required: true,
    doc: ~S(merged rows `%{cap, spent, ratio, state}` — DB caps overlaid with live spend)

  attr :form, :any, required: true
  attr :scope, :string, default: "global"
  attr :scope_targets, :map, default: %{}
  attr :editing?, :boolean, default: false

  @doc """
  Budget panel: a single spend-vs-cap list where every cap carries its own
  Edit / Reset / Delete controls, plus a create-or-edit form. The rows are the union of the
  durable DB caps (authoritative — the editable source of truth) and the live
  `Budget.Guard` snapshot (live spend/state), keyed by cap id, so every cap the operator
  can SEE is one they can act on — there are no DB-only or memory-only "ghost" rows the UI
  can't reach. Caps CRUD goes through the `RepoBuilder.Budget` context (the web layer never
  touches `Repo`).
  """
  @spec budget_panel(map()) :: Phoenix.LiveView.Rendered.t()
  def budget_panel(assigns) do
    ~H"""
    <div id="budget-panel" class="flex flex-col gap-2">
      <div class="flex items-center justify-between">
        <span class="text-[0.625rem] font-semibold uppercase" style="color: var(--cns-text-2)">
          Budget guardrails
        </span>
        <.kill_switch state={@state} />
      </div>

      <div :if={@caps == []} class="text-[0.625rem]" style="color: var(--cns-text-2)">
        No budget caps yet — spend is unbounded. Add a cap below.
      </div>

      <div :for={row <- @caps} id={"budget-cap-#{row.cap.id}"} class="flex flex-col gap-0.5">
        <div class="flex items-center justify-between gap-2 text-[0.6875rem]">
          <span class="truncate">
            {budget_scope_label(row.cap)} · {row.cap.period} · {budget_action_label(row.cap.action)}
          </span>
          <div class="flex shrink-0 items-center gap-2">
            <span data-budget-state={to_string(row.state)}>
              {budget_cost(row.spent)} / {budget_cost(row.cap.limit_usd)}
            </span>
            <button
              type="button"
              id={"budget-edit-#{row.cap.id}"}
              phx-click="edit_budget"
              phx-value-id={row.cap.id}
              class="cns-chip"
            >
              Edit
            </button>
            <button
              :if={row.state == :tripped}
              type="button"
              id={"budget-panel-reset-#{row.cap.id}"}
              phx-click="reset_budget"
              phx-value-id={row.cap.id}
              class="cns-chip"
            >
              Reset
            </button>
            <button
              type="button"
              id={"budget-delete-#{row.cap.id}"}
              phx-click="delete_budget"
              phx-value-id={row.cap.id}
              data-confirm="Delete this budget cap?"
              class="cns-chip"
            >
              Delete
            </button>
          </div>
        </div>
        <div class="h-1.5 w-full overflow-hidden rounded" style="background: var(--cns-border)">
          <div
            class="h-full"
            style={"width: #{budget_pct(row.ratio)}%; background: #{budget_bar_color(row.state)}"}
          />
        </div>
      </div>

      <.form
        :if={@form}
        id="budget-form"
        for={@form}
        phx-change="budget_form_change"
        phx-submit="save_budget"
        class="flex flex-wrap items-end gap-2"
      >
        <.input
          field={@form[:scope]}
          label="Scope"
          type="select"
          options={[
            {"Global", "global"},
            {"Project", "project"},
            {"Orchestrator", "orchestrator"},
            {"Workflow", "workflow"}
          ]}
          class="cns-input w-28"
        />
        <%= if @scope != "global" do %>
          <.input
            :if={Map.get(@scope_targets, @scope, []) != []}
            field={@form[:scope_id]}
            label="Target"
            type="select"
            options={Map.get(@scope_targets, @scope, [])}
            class="cns-input w-44"
          />
          <.input
            :if={Map.get(@scope_targets, @scope, []) == []}
            field={@form[:scope_id]}
            label={"#{String.capitalize(@scope)} id"}
            class="cns-input w-44"
          />
        <% end %>
        <.input
          field={@form[:period]}
          label="Period"
          type="select"
          options={[
            {"Total", "total"},
            {"Session", "session"},
            {"Daily", "daily"},
            {"Monthly", "monthly"}
          ]}
          class="cns-input w-24"
        />
        <.input
          field={@form[:limit_usd]}
          label="Limit $"
          type="number"
          step="any"
          class="cns-input w-24"
        />
        <.input
          field={@form[:action]}
          label="When exceeded"
          type="select"
          options={[{"Warn me", "alert"}, {"Pause runs", "pause"}, {"Hard stop", "hard_stop"}]}
          class="cns-input w-32"
        />
        <button id="budget-form-submit" type="submit" class="cns-chip">
          {if @editing?, do: "Save cap", else: "Add cap"}
        </button>
        <button
          :if={@editing?}
          type="button"
          id="budget-form-cancel"
          phx-click="cancel_edit_budget"
          class="cns-chip"
        >
          Cancel
        </button>
      </.form>
    </div>
    """
  end

  @spec budget_worst_state(map()) :: :ok | :warning | :tripped
  defp budget_worst_state(%{kill_switch?: true}), do: :tripped

  defp budget_worst_state(%{caps: caps}) do
    states = Enum.map(caps, & &1.state)

    cond do
      :tripped in states -> :tripped
      :warning in states -> :warning
      true -> :ok
    end
  end

  @spec budget_scope_label(RepoBuilder.Budget.Cap.t()) :: String.t()
  defp budget_scope_label(%{scope: :global}), do: "Global"
  defp budget_scope_label(%{scope: scope, scope_id: id}), do: "#{scope}:#{id}"

  # Inference-only spec — the concrete action atoms narrow below `atom()`.
  defp budget_action_label(:alert), do: "alert"
  defp budget_action_label(:pause), do: "pause"
  defp budget_action_label(:hard_stop), do: "hard-stop"

  @spec budget_cost(Decimal.t() | nil) :: String.t()
  defp budget_cost(%Decimal{} = cost), do: "$" <> Decimal.to_string(Decimal.round(cost, 2))
  defp budget_cost(_other), do: "—"

  @spec budget_pct(float()) :: integer()
  defp budget_pct(ratio) when is_float(ratio),
    do: ratio |> Kernel.*(100) |> min(100) |> max(0) |> round()

  defp budget_pct(_other), do: 0

  @spec budget_bar_color(atom()) :: String.t()
  defp budget_bar_color(:tripped), do: "#b91c1c"
  defp budget_bar_color(:warning), do: "#d97706"
  defp budget_bar_color(_ok), do: "#16a34a"

  # Stable DOM id for a rollup row (the dimension key; nil model/provider → "_").
  @spec cost_rollup_row_id(RepoBuilder.CostCenter.Rollup.t()) :: String.t()
  defp cost_rollup_row_id(rollup) do
    "cost-rollup-#{rollup.harness}-#{rollup.provider}-#{rollup.model || "_"}"
  end

  # A grouping dimension cell: blank provider/model → a muted "—".
  @spec cost_dim(String.t() | nil) :: String.t()
  defp cost_dim(value) when value in [nil, ""], do: "—"
  defp cost_dim(value) when is_binary(value), do: value

  @spec cost_str(Decimal.t() | nil) :: String.t()
  defp cost_str(%Decimal{} = cost), do: "$" <> Decimal.to_string(Decimal.round(cost, 2))
  defp cost_str(nil), do: "—"

  # Show the billed badge when there is a real billed amount, or when nothing was
  # estimated (so a genuine `$0.00` still renders). A purely-estimated bucket (zero billed
  # + an estimate present) hides the `$0.00` badge and shows only the `est.` chip — mirrors
  # the all-time rollup's actual-vs-estimate display.
  @spec spend_show_actual?(RepoBuilder.CostCenter.SpendRow.t()) :: boolean()
  defp spend_show_actual?(%{estimated_cost_usd: nil}), do: true

  defp spend_show_actual?(%{actual_cost_usd: %Decimal{} = actual}),
    do: Decimal.compare(actual, 0) == :gt

  @spec price_str(Decimal.t() | nil) :: String.t()
  defp price_str(%Decimal{} = price), do: Decimal.to_string(price)
  defp price_str(nil), do: "—"

  # Read a string-coerced field off the selected `Template` struct for a form value,
  # tolerating `nil` (the "+ New" blank-form state) and nil optional fields.
  @spec template_field(RepoBuilder.Orchestrator.Template.t() | nil, atom()) :: String.t()
  defp template_field(nil, _field), do: ""

  defp template_field(template, field) do
    case Map.get(template, field) do
      value when is_binary(value) -> value
      _other -> ""
    end
  end

  # The name of the selected template, or `nil` for the blank-form state.
  @spec template_name(RepoBuilder.Orchestrator.Template.t() | nil) :: String.t() | nil
  defp template_name(nil), do: nil
  defp template_name(template), do: template.name

  attr :rows, :list,
    default: [],
    doc: "per-category roster rows: %{category, harness, provider, model, *_options}"

  attr :saved, :boolean, default: false, doc: "transient 'Saved ✓' state"
  attr :configured_count, :integer, default: 0, doc: "count of categories with a non-blank model"
  attr :updated_at, :string, default: nil, doc: "ISO8601 UTC timestamp of last agent_models write"

  @doc """
  Modal to assign, per worker category (fast/main/heavy/leader), the
  harness/provider/model the orchestrator spawns into. Always rendered (shown/hidden
  client-side). A blank model = unassigned ⇒ the orchestrator can't spawn there.
  """
  @spec agent_models_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def agent_models_modal(assigns) do
    ~H"""
    <div
      id="agent-models-modal"
      class="cns-cmd-overlay"
      style="display:none"
      phx-window-keydown={hide_agent_models()}
      phx-key="Escape"
    >
      <div class="cns-cmd-panel" style="max-width: 56rem">
        <div class="mb-3 flex items-center justify-between">
          <span class="text-xs font-semibold" style="color: var(--cns-cyan)">
            AGENT MODELS — what the orchestrator spawns workers into
          </span>
          <div class="flex items-center gap-2">
            <span
              :if={@saved}
              class="cns-chip"
              style="color: var(--cns-green, #4ade80)"
            >
              Saved ✓
            </span>
            <span class="text-[0.625rem]" style="color: var(--cns-text-2)">
              {@configured_count}/4 configured
            </span>
            <button type="button" phx-click={hide_agent_models()} class="cns-chip">Done</button>
          </div>
        </div>

        <div class="flex flex-col gap-2">
          <form
            :for={row <- @rows}
            id={"agent-model-#{row.category}"}
            phx-change="set_agent_model"
            class="flex items-center gap-2"
          >
            <input type="hidden" name="category" value={row.category} />
            <span class="w-16 text-xs font-semibold uppercase" style="color: var(--cns-text-1)">
              {row.category}
            </span>

            <select name="harness" class="cns-chip" style="width: 8rem">
              <option value="" selected={row.harness in [nil, ""]}>harness…</option>
              <option :for={h <- row.harness_options} value={h} selected={row.harness == h}>
                {h}
              </option>
            </select>

            <select
              name="provider"
              class="cns-chip"
              style="width: 9rem"
              disabled={row.harness in [nil, ""]}
            >
              <option value="" selected={row.provider in [nil, ""]}>provider…</option>
              <option :for={p <- row.provider_options} value={p} selected={row.provider == p}>
                {p}
              </option>
            </select>

            <select
              name="model"
              class="cns-chip"
              style="width: 13rem"
              disabled={row.harness in [nil, ""]}
            >
              <option value="" selected={row.model in [nil, ""]}>no model (won't spawn)…</option>
              <option :for={m <- row.model_options} value={m} selected={row.model == m}>{m}</option>
            </select>

            <span
              :if={Map.get(row, :inherited?, false)}
              id={"agent-model-#{row.category}-inherited"}
              class="cns-chip text-[0.625rem]"
              style="color: var(--cns-text-2)"
              title="This tier inherits the global default (Settings → Default Models)"
            >
              inherited
            </span>

            <button
              :if={not Map.get(row, :inherited?, false) and row.model not in [nil, ""]}
              type="button"
              phx-click="clear_agent_model"
              phx-value-category={row.category}
              class="cns-chip text-[0.625rem]"
              title="Clear this project's override so the tier re-inherits the global default"
            >
              reset
            </button>
          </form>
        </div>

        <p class="mt-3 text-[0.625rem]" style="color: var(--cns-text-2)">
          This roster is per-project. A tier left blank inherits the global default
          (Settings → Default Models); "reset" clears a project override so it re-inherits.
        </p>
        <p :if={@updated_at} class="mt-1 text-[0.625rem]" style="color: var(--cns-text-2)">
          Last changed {format_relative_time(@updated_at)}
        </p>
      </div>
    </div>
    """
  end

  attr :status, :any,
    default: :idle,
    doc: ":idle | :running | {:ready, text} | {:error, msg}"

  attr :count, :integer, default: 0, doc: "number of selected rows being explained"

  @doc """
  Transient modal for the ephemeral "explain logs" result (issue-explain).

  Always mounted (shown/hidden client-side), `id=\"explain-modal\"`. Renders by
  `@status`: a spinner while running, the paragraph (with a Copy button) when ready,
  or an actionable error. Closing discards everything — nothing here is persisted.
  """
  @spec explain_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def explain_modal(assigns) do
    ~H"""
    <div
      id="explain-modal"
      class="cns-cmd-overlay"
      style="display:none"
      phx-window-keydown={JS.push("close_explain") |> hide_explain()}
      phx-key="Escape"
    >
      <div class="cns-cmd-panel" style="max-width: 48rem">
        <div class="mb-3 flex items-center justify-between">
          <span class="text-xs font-semibold" style="color: var(--cns-cyan)">
            EXPLAIN ✦ — Fast-agent log explanation
          </span>
          <button
            type="button"
            phx-click={JS.push("close_explain") |> hide_explain()}
            class="cns-chip"
          >
            Close
          </button>
        </div>

        <div :if={@status == :running} class="flex items-center gap-2 py-6">
          <span class="cns-spinner" aria-hidden="true">⟳</span>
          <span class="text-sm" style="color: var(--cns-text-2)">
            Explaining {@count} event(s)…
          </span>
        </div>

        <%= case @status do %>
          <% {:ready, text} -> %>
            <pre
              class="whitespace-pre-wrap break-words text-sm leading-relaxed"
              style="color: var(--cns-text-1)"
              phx-no-curly-interpolation
            ><%= text %></pre>
            <div class="mt-3 flex items-center gap-2">
              <button
                type="button"
                id="explain-copy"
                phx-hook="ClipboardCopy"
                data-copy={text}
                class="cns-chip cns-chip--active cns-chip--hook"
              >
                Copy
              </button>
              <button
                type="button"
                phx-click={JS.push("close_explain") |> hide_explain()}
                class="cns-chip"
              >
                Close
              </button>
            </div>
          <% {:error, msg} -> %>
            <p class="py-4 text-sm" style="color: var(--cns-red, #f87171)">{msg}</p>
            <button
              type="button"
              phx-click={JS.push("close_explain") |> hide_explain()}
              class="cns-chip"
            >
              Close
            </button>
          <% _ -> %>
        <% end %>
      </div>
    </div>
    """
  end

  @spec format_relative_time(String.t()) :: String.t()
  defp format_relative_time(iso8601) do
    case DateTime.from_iso8601(iso8601) do
      {:ok, dt, _offset} ->
        diff = DateTime.diff(DateTime.utc_now(), dt, :second)

        cond do
          diff < 60 -> "#{diff}s ago"
          diff < 3600 -> "#{div(diff, 60)}m ago"
          diff < 86_400 -> "#{div(diff, 3600)}h ago"
          true -> "#{div(diff, 86_400)}d ago"
        end

      _ ->
        "unknown"
    end
  end

  attr :slash_commands, :list, default: [], doc: "file-derived %Definitions.SlashCommand{} list"
  attr :agent_defs, :list, default: [], doc: "file-derived %Definitions.Agent{} list"
  attr :adws, :list, default: [], doc: "file-derived %Definitions.Adw{} list"
  attr :working_dir, :string, default: ""
  attr :uploads, :map, required: true
  attr :adw_builder?, :boolean, default: false
  attr :adw_steps, :list, default: []
  attr :adw_name, :string, default: ""
  attr :adw_local?, :boolean, default: false
  attr :agents, :list, default: [], doc: "live %Agent{} workers shown in the left rail"
  attr :statuses, :map, default: %{}, doc: "agent id => live runtime status"

  attr :palette_source_tab, :atom,
    default: :base,
    values: [:base, :project],
    doc:
      "active source tab for the file-derived palette: :base (platform repo) | :project (overlay)"

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
        <%!-- Header: title + mode toggle + close --%>
        <div class="mb-2 flex items-center justify-between">
          <div class="flex items-center gap-2">
            <span class="text-xs font-semibold" style="color: var(--cns-cyan)">
              {if @adw_builder?, do: "ADW BUILDER", else: "COMMAND (⌘K)"}
            </span>
            <button
              type="button"
              phx-click="toggle_adw_builder"
              class={["cns-chip", @adw_builder? && "cns-chip--active"]}
              title="Switch to ADW Builder mode"
            >
              ADW
            </button>
          </div>
          <div class="flex items-center gap-2">
            <label
              for={@uploads.attachments.ref}
              class="cns-chip cursor-pointer"
              title="Attach files"
            >
              📎 <.live_file_input upload={@uploads.attachments} form="command-form" class="sr-only" />
            </label>
            <button id="prompt-close" type="button" phx-click={hide_command()} class="cns-chip">
              Esc
            </button>
          </div>
        </div>

        <%!-- COMMAND MODE --%>
        <div :if={not @adw_builder?}>
          <div class="mb-2 flex items-center gap-2 text-[0.625rem]" style="color: var(--cns-text-2)">
            <span class="font-semibold">CWD</span>
            <button
              type="button"
              id="cmd-working-dir"
              phx-click="open_dir_picker"
              class="cns-cmd-chip min-w-0 max-w-full truncate font-mono"
              title="Choose the working directory the orchestrator and its workers run in"
            >
              📁 {if @working_dir in [nil, ""], do: "isolated workspace", else: @working_dir}
            </button>
            <button
              :if={@working_dir not in [nil, ""]}
              type="button"
              id="cmd-working-dir-clear"
              phx-click="clear_working_dir"
              class="cns-cmd-chip"
              title="Clear — each agent gets its own isolated scratch workspace"
            >
              ✕
            </button>
          </div>

          <form
            id="command-form"
            phx-change="validate_attachments"
            phx-submit={JS.push("run_command") |> hide_command()}
          >
            <div
              id="cmd-drop-zone"
              phx-drop-target={@uploads.attachments.ref}
              class="cns-cmd-drop-zone"
            >
              <textarea
                id="command-textarea"
                name="command"
                rows="3"
                placeholder="Type a command… (Enter ↵ send · Shift+Enter newline · drag & drop or paste images)"
                class="cns-cmd-textarea"
                phx-hook="CommandPaste"
              ></textarea>
            </div>

            <div :if={@uploads.attachments.entries != []} class="mt-2 flex flex-wrap gap-2">
              <div :for={entry <- @uploads.attachments.entries} class="cns-attachment-entry">
                <.live_img_preview
                  :if={String.starts_with?(entry.client_type, "image/")}
                  entry={entry}
                  class="cns-attachment-thumb"
                />
                <span
                  :if={not String.starts_with?(entry.client_type, "image/")}
                  class="cns-attachment-name"
                >
                  {entry.client_name}
                </span>
                <button
                  type="button"
                  phx-click="cancel_upload"
                  phx-value-ref={entry.ref}
                  class="cns-attachment-remove"
                  aria-label="Remove"
                >
                  ✕
                </button>
                <p
                  :for={err <- upload_errors(@uploads.attachments, entry)}
                  class="cns-attachment-error"
                >
                  {upload_error_to_string(err)}
                </p>
              </div>
            </div>
          </form>

          <%!-- Source-scoped palette (issue palette-source-tabs): vertical BASE / PROJECT tabs.
                BASE = artifacts from the platform repo's `.claude/` (source :app); PROJECT =
                artifacts from the active working dir's `.claude/` overlay (source :working_dir).
                Live workers are runtime state, not a repo artifact, so they stay below the tabs. --%>
          <div class="mt-3 text-[0.625rem]">
            <div class="flex gap-3">
              <div class="flex shrink-0 flex-col gap-1">
                <button
                  type="button"
                  id="palette-tab-base"
                  phx-click="set_palette_tab"
                  phx-value-tab="base"
                  class={[
                    "cns-cmd-chip w-full text-left",
                    @palette_source_tab == :base && "cns-chip--active"
                  ]}
                  title="Artifacts from the platform repo (.claude/, priv, adws)"
                >
                  base ({palette_source_count(@slash_commands, @agent_defs, @adws, :app)})
                </button>
                <button
                  type="button"
                  id="palette-tab-project"
                  phx-click="set_palette_tab"
                  phx-value-tab="project"
                  class={[
                    "cns-cmd-chip w-full text-left",
                    @palette_source_tab == :project && "cns-chip--active"
                  ]}
                  title="Artifacts from the active project's working directory (.claude/)"
                >
                  project ({palette_source_count(@slash_commands, @agent_defs, @adws, :working_dir)})
                </button>
              </div>

              <div class="flex min-w-0 flex-1 flex-col gap-2">
                <div :if={@palette_source_tab == :base} class="flex flex-col gap-2">
                  <.palette_row
                    id="slash-base"
                    label="SLASH"
                    chips={source_chips(:slash_command, @slash_commands, :app)}
                    empty_hint="none — add `.claude/commands/<name>.md` in the platform repo"
                  />
                  <.palette_row
                    id="agents-base"
                    label="AGENTS"
                    chips={source_chips(:agent, @agent_defs, :app)}
                    empty_hint="none — add `priv/orchestrator/agents/<name>/NNNN.md`"
                  />
                  <.palette_row
                    id="adws-base"
                    label="ADWS"
                    chips={source_chips(:adw, @adws, :app)}
                    empty_hint="none — add `adws/adw_*.py`"
                  />
                </div>

                <div :if={@palette_source_tab == :project} class="flex flex-col gap-2">
                  <.palette_row
                    id="slash-project"
                    label="SLASH"
                    chips={source_chips(:slash_command, @slash_commands, :working_dir)}
                    empty_hint="none — select a project, or add `.claude/commands/<name>.md` in its repo"
                  />
                  <.palette_row
                    id="agents-project"
                    label="AGENTS"
                    chips={source_chips(:agent, @agent_defs, :working_dir)}
                    empty_hint="none — add `.claude/agents/<name>.md` in the project repo"
                  />
                  <.palette_row
                    id="adws-project"
                    label="ADWS"
                    chips={source_chips(:adw, @adws, :working_dir)}
                    empty_hint="none — add `adws/adw_*.py` in the project repo"
                  />
                </div>
              </div>
            </div>

            <div class="mt-2">
              <.palette_row
                id="live"
                label="LIVE AGENTS"
                chips={live_agent_chips(@agents, @statuses)}
                empty_hint="no live agents — create one, then click to reference it"
              />
            </div>
          </div>
        </div>

        <%!-- ADW BUILDER MODE --%>
        <div :if={@adw_builder?} class="flex flex-col gap-3">
          <%!-- Workflow name + local toggle --%>
          <div class="flex items-center gap-2">
            <input
              type="text"
              placeholder="Workflow name (optional)"
              value={@adw_name}
              phx-change="adw_set_name"
              name="name"
              class="cns-cmd-textarea"
              style="padding: 0.25rem 0.5rem; height: auto"
            />
            <button
              type="button"
              phx-click="adw_toggle_local"
              class={["cns-chip", @adw_local? && "cns-chip--active"]}
              title="Local mode — no GitHub issue required"
            >
              local
            </button>
          </div>

          <%!-- Step palette --%>
          <div>
            <div class="mb-1 text-[0.625rem] font-semibold" style="color: var(--cns-text-2)">
              ADD STEP
            </div>
            <div class="flex flex-wrap gap-1">
              <button
                :for={step <- ~w(plan patch build test review document ship)}
                type="button"
                phx-click="adw_add_step"
                phx-value-step={step}
                class="cns-cmd-chip"
              >
                + {step}
              </button>
            </div>
          </div>

          <%!-- Step list --%>
          <div class="flex flex-col gap-1">
            <div
              :if={@adw_steps == []}
              class="text-[0.625rem]"
              style="color: var(--cns-text-3)"
            >
              No steps yet — click above to add steps in order.
            </div>

            <div :for={{step, idx} <- Enum.with_index(@adw_steps)} class="cns-adw-step-row">
              <div class="flex items-center gap-1">
                <span class="cns-adw-step-num">{idx + 1}</span>
                <span class="cns-adw-step-name">{step.name}</span>

                <button
                  type="button"
                  phx-click="adw_toggle_step"
                  phx-value-id={step.id}
                  class="cns-chip"
                  title="View default prompt"
                  style="font-size: 0.5rem; padding: 1px 4px"
                >
                  {if step.expanded, do: "▲", else: "▼"}
                </button>

                <div class="ml-auto flex items-center gap-1">
                  <button
                    type="button"
                    phx-click="adw_move_step"
                    phx-value-id={step.id}
                    phx-value-dir="up"
                    class="cns-chip"
                    style="font-size: 0.5rem; padding: 1px 4px"
                    disabled={idx == 0}
                  >
                    ↑
                  </button>
                  <button
                    type="button"
                    phx-click="adw_move_step"
                    phx-value-id={step.id}
                    phx-value-dir="down"
                    class="cns-chip"
                    style="font-size: 0.5rem; padding: 1px 4px"
                    disabled={idx == length(@adw_steps) - 1}
                  >
                    ↓
                  </button>
                  <button
                    type="button"
                    phx-click="adw_remove_step"
                    phx-value-id={step.id}
                    class="cns-chip"
                    style="font-size: 0.5rem; padding: 1px 4px; color: var(--cns-red, #f87171)"
                  >
                    ✕
                  </button>
                </div>
              </div>

              <div
                :if={step.expanded}
                class="mt-1 rounded p-2 text-[0.6rem]"
                style="background: var(--cns-surface-3); color: var(--cns-text-2)"
              >
                {adw_step_hint(step.name)}
              </div>
            </div>
          </div>

          <%!-- Launch button --%>
          <button
            type="button"
            phx-click="run_adw_builder"
            class="cns-chip"
            style="align-self: flex-end; color: var(--cns-cyan)"
            disabled={@adw_steps == []}
          >
            ▶ Launch ADW
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :chips, :list, required: true, doc: "normalized %{token,label,source,description} maps"
  attr :empty_hint, :string, required: true

  @doc """
  One collapsible row of the file-driven prompt palette. The toggle reveals a chip
  per definition; each chip dispatches `rb:insert-token` (handled client-side by the
  CommandPaste hook on the textarea) to append its token at the caret — no server
  round-trip. An empty category renders an actionable hint instead.
  """
  @spec palette_row(map()) :: Phoenix.LiveView.Rendered.t()
  def palette_row(assigns) do
    ~H"""
    <div>
      <button
        type="button"
        id={"palette-toggle-#{@id}"}
        phx-click={JS.toggle(to: "#palette-#{@id}")}
        class="cns-cmd-chip font-semibold"
        title={"Toggle #{@label} palette"}
      >
        {@label} ({length(@chips)})
      </button>
      <div id={"palette-#{@id}"} class="mt-1 flex flex-wrap gap-1" style="display:none">
        <button
          :for={chip <- @chips}
          type="button"
          class="cns-cmd-chip"
          phx-click={
            JS.dispatch("rb:insert-token", to: "#command-textarea", detail: %{token: chip.token})
          }
          title={chip.description || chip.token}
        >
          <span
            :if={chip[:status]}
            class={[
              "inline-block size-1.5 rounded-full align-middle",
              status_dot_class(chip[:status])
            ]}
            style="margin-right: 4px"
          />
          {chip.label}
          <span
            :if={chip.source == :working_dir}
            class="cns-chip"
            style="font-size: 0.5rem; padding: 0 3px; margin-left: 3px"
            title="from the selected working directory"
          >
            wd
          </span>
        </button>
        <span :if={@chips == []} style="color: var(--cns-text-3)">{@empty_hint}</span>
      </div>
    </div>
    """
  end

  # --- private helpers ------------------------------------------------------

  # Normalize a file-derived definition list into chip render maps. The token is the
  # exact text appended into the prompt: `/<name>` for slash commands, the bare name
  # for agents, and a valid `start_adw` invocation for ADWs.
  @spec palette_chips(:slash_command | :agent | :adw, [struct()]) :: [chip()]
  defp palette_chips(:slash_command, list) do
    Enum.map(list, fn cmd ->
      %{
        token: "/" <> cmd.name,
        label: "/" <> cmd.name,
        source: cmd.source,
        description: cmd.description
      }
    end)
  end

  defp palette_chips(:agent, list) do
    Enum.map(list, fn agent ->
      %{
        token: agent.name,
        label: agent.name,
        source: agent.source,
        description: agent.description
      }
    end)
  end

  defp palette_chips(:adw, list) do
    Enum.map(list, fn adw ->
      %{
        token: "start_adw workflow_type=" <> adw.name,
        label: adw.name,
        source: adw.source,
        description: adw.description
      }
    end)
  end

  # Chips for one category, filtered to a single provenance (`:app` for the BASE tab,
  # `:working_dir` for the PROJECT tab) so the two source tabs each render only their own
  # artifacts. Filtering BEFORE normalization keeps each entry's `source` authoritative.
  @spec source_chips(:slash_command | :agent | :adw, [struct()], :app | :working_dir) :: [chip()]
  defp source_chips(category, list, source) do
    list
    |> Enum.filter(&(&1.source == source))
    |> then(&palette_chips(category, &1))
  end

  # Total count of file-derived definitions (slash + agents + adws) carrying `source`, for the
  # `base (N)` / `project (N)` tab labels.
  @spec palette_source_count([struct()], [struct()], [struct()], :app | :working_dir) ::
          non_neg_integer()
  defp palette_source_count(slash, agents, adws, source) do
    Enum.reduce([slash, agents, adws], 0, fn list, acc ->
      acc + Enum.count(list, &(&1.source == source))
    end)
  end

  # Build chips for the live workers shown in the left rail. The token is the worker's
  # exact `name` — the string `Agents.get_by_name_for_orchestrator/2` (`Repo.get_by(name:)`)
  # matches — so a clicked chip lands a name the orchestrator resolves the first time.
  # Active workers (`:idle`/`:running`/`:holding`) are listed, idle-first then alphabetical,
  # and each chip carries its resolved status for the row's status dot. A `:holding` worker
  # (blocked pending external input) stays listed so it remains visible and resumable
  # (issue holding-status-for-blocked-agents).
  @spec live_agent_chips([Agent.t()], %{optional(Ecto.UUID.t()) => atom()}) :: [chip()]
  defp live_agent_chips(agents, statuses) do
    agents
    |> Enum.map(fn agent -> {agent, Map.get(statuses, agent.id, agent.status)} end)
    |> Enum.filter(fn {_agent, status} -> status in [:idle, :running, :holding] end)
    |> Enum.sort_by(fn {agent, status} -> {status != :idle, agent.name} end)
    |> Enum.map(fn {agent, status} ->
      %{
        token: agent.name,
        label: agent.name,
        source: :live,
        description: "#{status} · click to reference #{agent.name} in the prompt",
        status: status
      }
    end)
  end

  @spec adw_step_hint(String.t()) :: String.t()
  defp adw_step_hint("plan"),
    do: "/feature <spec-file> — AI reads the spec and writes a detailed implementation plan."

  defp adw_step_hint("patch"),
    do: "/feature <spec-file> — like plan but for a targeted patch/hotfix."

  defp adw_step_hint("build"),
    do: "/implement <plan-file> — reads the plan and implements all tasks; leaves code green."

  defp adw_step_hint("test"),
    do: "/test <spec-file> — writes and runs tests to cover the plan's acceptance criteria."

  defp adw_step_hint("review"),
    do: "/review <spec-file> — reviews the git diff against the spec; passes or raises issues."

  defp adw_step_hint("document"),
    do: "/docs — generates or updates documentation based on the implemented changes."

  defp adw_step_hint("ship"),
    do: "/ship — finalises the branch, opens a PR, and posts a summary comment."

  defp adw_step_hint(other), do: "/#{other} — custom step."

  @spec upload_error_to_string(atom()) :: String.t()
  defp upload_error_to_string(:too_large), do: "File too large (max 10 MB)"
  defp upload_error_to_string(:too_many_files), do: "Too many files (max 5)"
  defp upload_error_to_string(:not_accepted), do: "File type not accepted"
  defp upload_error_to_string(_), do: "Upload error"

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

  # Inference-only spec — fixed-length string returns supertype under :underspecs.
  defp category_label(:response), do: "RESPONSE"
  defp category_label(:tool), do: "TOOL"
  defp category_label(:thinking), do: "THINKING"
  defp category_label(:hook), do: "HOOK"
  defp category_label(:system), do: "SYS"

  @spec context_pct(non_neg_integer(), pos_integer()) :: non_neg_integer()
  defp context_pct(tokens, window), do: min(100, div(tokens * 100, max(window, 1)))

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
