defmodule RepoBuilderWeb.Console.LogsComponents do
  @moduledoc """
  Log-stream panel components: the filter bar + chips, the event row (with the
  consumed-files and file-change cards), the selection action bar, the
  log-manager modal, and the explain-logs modal.

  Extracted verbatim from `RepoBuilderWeb.ConsoleComponents` (audit F3 task 3.2);
  that module remains the façade and delegates here.
  """
  use RepoBuilderWeb, :html

  import RepoBuilderWeb.Console.SharedComponents,
    only: [show_explain: 1, hide_explain: 1, hide_log_manager: 0]

  # Canonical-event categories the UI groups events under (the 4 chip categories
  # plus :system for non-chip lifecycle events, which always pass the filter).
  @categories [:response, :tool, :thinking, :hook, :system]

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

  # Inference-only spec — fixed-length string returns supertype under :underspecs.
  defp category_label(:response), do: "RESPONSE"
  defp category_label(:tool), do: "TOOL"
  defp category_label(:thinking), do: "THINKING"
  defp category_label(:hook), do: "HOOK"
  defp category_label(:system), do: "SYS"

  # Inference-only spec — the single 160 call-site literal supertypes under :underspecs.
  defp truncate(body, max) do
    if String.length(body) > max, do: String.slice(body, 0, max) <> "…", else: body
  end
end
