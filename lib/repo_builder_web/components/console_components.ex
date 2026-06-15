defmodule RepoBuilderWeb.ConsoleComponents do
  @moduledoc """
  Typed function components for the multi-layered orchestration console
  (BUILD_PROMPT.md §9). Mirrors the reference Vue console's pieces — the header
  stat bar, the left agent rail item, a center event row, and the right command
  panel scaffold — as `attr/3`-validated, harness-blind components.

  Every public component carries an `@spec component(map()) ::
  Phoenix.LiveView.Rendered.t()`; the status enums are constrained via `values:`.
  """
  use RepoBuilderWeb, :html

  import RepoBuilderWeb.DashboardComponents, only: [cost_badge: 1]

  # Lifecycle statuses an agent rail item may display. Superset of the closed
  # `Agent.status` enum because the live `statuses` map also tracks terminal
  # outcomes (succeeded/failed) derived from canonical Done/Error events (§4.1).
  @statuses [:idle, :running, :succeeded, :failed, :error, :cancelled, :queued]

  attr :connected?, :boolean, default: false
  attr :agent_count, :integer, default: 0
  attr :running_count, :integer, default: 0
  attr :log_count, :integer, default: 0
  attr :cost, :any, default: nil
  attr :view_mode, :atom, default: :logs, values: [:logs, :adws]
  attr :prompt_open?, :boolean, default: false

  @doc """
  Full-bleed header: a live connection dot, the Active/Running/Logs/Cost stat
  pills, the LOGS/ADWS view-mode toggle, and the Prompt toggle.
  """
  @spec header_bar(map()) :: Phoenix.LiveView.Rendered.t()
  def header_bar(assigns) do
    ~H"""
    <header
      id="console-header"
      class="flex items-center justify-between gap-4 border-b border-base-300 bg-base-200 px-4 py-2"
    >
      <div class="flex items-center gap-3">
        <span class="flex items-center gap-2 font-semibold">
          <span
            id="connection-dot"
            class={["inline-block size-2.5 rounded-full", conn_dot_class(@connected?)]}
            title={if @connected?, do: "connected", else: "connecting"}
          /> Orchestration Console
        </span>
      </div>

      <div class="flex items-center gap-2">
        <.stat_pill id="stat-active" label="Active" value={@agent_count} />
        <.stat_pill id="stat-running" label="Running" value={@running_count} />
        <.stat_pill id="stat-logs" label="Logs" value={@log_count} />
        <span id="stat-cost" class="flex items-center gap-1 text-xs">
          <span class="text-base-content/60">Cost</span>
          <.cost_badge cost={@cost} />
        </span>
      </div>

      <div class="flex items-center gap-2">
        <button
          id="view-toggle"
          type="button"
          phx-click="toggle_view"
          class="btn btn-sm btn-outline"
        >
          {if @view_mode == :logs, do: "LOGS", else: "ADWS"}
        </button>
        <button
          id="prompt-toggle"
          type="button"
          phx-click="toggle_prompt"
          class={["btn btn-sm", (@prompt_open? && "btn-primary") || "btn-ghost"]}
        >
          Prompt
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
    <span id={@id} class="flex items-center gap-1 text-xs">
      <span class="text-base-content/60">{@label}</span>
      <span class="badge badge-sm badge-neutral font-mono">{@value}</span>
    </span>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :status, :atom, required: true, values: @statuses
  attr :harness, :string, default: nil
  attr :model, :string, default: nil
  attr :cost, :any, default: nil, doc: "per-agent cost Decimal (nil = unpriced)"
  attr :selected?, :boolean, default: false

  @doc """
  One left-rail agent entry: a selectable area (status dot + name + harness +
  model badge + status badge + per-agent cost) plus discrete Edit and Archive
  controls. The row container is a `div` with sibling interactive elements — the
  selectable area and the Edit/Archive buttons are NOT nested (valid HTML).
  """
  @spec agent_rail_item(map()) :: Phoenix.LiveView.Rendered.t()
  def agent_rail_item(assigns) do
    ~H"""
    <div
      id={"agent-row-#{@id}"}
      class={[
        "flex items-center gap-1 rounded px-1 text-sm transition-colors",
        (@selected? && "bg-primary/15 ring-1 ring-primary/40") || "hover:bg-base-200"
      ]}
    >
      <button
        id={"agent-#{@id}"}
        type="button"
        phx-click="select_agent"
        phx-value-id={@id}
        class="flex min-w-0 flex-1 flex-col gap-0.5 rounded px-1 py-1.5 text-left"
      >
        <span class="flex items-center gap-2">
          <span class={["inline-block size-2.5 shrink-0 rounded-full", status_class(@status)]} />
          <span class="min-w-0 flex-1 truncate font-medium">{@name}</span>
          <span :if={@harness} class="badge badge-ghost badge-sm">{@harness}</span>
        </span>
        <span class="flex items-center gap-1 pl-4.5 text-xs">
          <span class={["badge badge-xs", status_badge_class(@status)]}>{@status}</span>
          <span :if={@model} class="badge badge-xs badge-outline">{@model}</span>
          <.cost_badge cost={@cost} />
        </span>
      </button>
      <div class="flex shrink-0 items-center">
        <button
          type="button"
          phx-click="edit_agent"
          phx-value-id={@id}
          class="btn btn-ghost btn-xs"
          title="Edit agent"
        >
          Edit
        </button>
        <button
          type="button"
          phx-click="archive_agent"
          phx-value-id={@id}
          data-confirm="Archive this agent?"
          class="btn btn-ghost btn-xs"
          title="Archive agent"
        >
          Archive
        </button>
      </div>
    </div>
    """
  end

  attr :agent, :string, required: true
  attr :kind, :string, required: true
  attr :body, :string, required: true
  attr :thinking?, :boolean, default: false

  @doc "One center event-stream row: agent label + kind chip + body; dimmed when thinking."
  @spec event_row(map()) :: Phoenix.LiveView.Rendered.t()
  def event_row(assigns) do
    ~H"""
    <div class={["flex items-start gap-2 font-mono text-sm", @thinking? && "italic opacity-60"]}>
      <span class="shrink-0 text-base-content/50">{@agent}</span>
      <span class="badge badge-sm badge-outline shrink-0">{@kind}</span>
      <span class="break-all">{@body}</span>
    </div>
    """
  end

  attr :form, :any, required: true, doc: "the launch form (to_form/2)"
  attr :adw_form, :any, required: true, doc: "the ADW launcher form (to_form/2)"
  attr :harness_options, :list, required: true
  attr :selected_agent, :string, default: nil

  @doc "Right command/launch panel: the prompt composer (Run), Interrupt, and Launch ADW."
  @spec command_panel(map()) :: Phoenix.LiveView.Rendered.t()
  def command_panel(assigns) do
    ~H"""
    <div id="command-panel" class="flex h-full flex-col gap-4">
      <div class="text-xs text-base-content/60">
        Target: <span class="font-mono">{@selected_agent || "— select an agent —"}</span>
      </div>

      <.form
        for={@form}
        id="launch-form"
        phx-submit="run"
        phx-change="validate_launch"
        class="space-y-2"
      >
        <.input
          field={@form[:prompt]}
          type="textarea"
          label="Prompt"
          rows="5"
          placeholder="Describe the task…"
        />
        <.input field={@form[:harness]} type="select" label="Harness" options={@harness_options} />
        <.input field={@form[:model]} type="text" label="Model (optional)" />
        <div class="flex gap-2">
          <button id="run-button" type="submit" class="btn btn-primary btn-sm flex-1">Run</button>
          <button
            id="interrupt-button"
            type="button"
            phx-click="interrupt"
            class="btn btn-ghost btn-sm"
          >
            Interrupt
          </button>
        </div>
      </.form>

      <div class="divider my-0 text-xs">ADW</div>

      <.form for={@adw_form} id="launch-adw-form" phx-submit="launch_adw" class="space-y-2">
        <.input
          field={@adw_form[:harness]}
          type="select"
          label="ADW harness"
          options={@harness_options}
        />
        <button id="launch-adw" type="submit" class="btn btn-outline btn-sm w-full">Launch ADW</button>
      </.form>
    </div>
    """
  end

  @spec conn_dot_class(boolean()) :: String.t()
  defp conn_dot_class(true), do: "bg-success"
  defp conn_dot_class(false), do: "bg-warning animate-pulse"

  @spec status_class(atom()) :: String.t()
  defp status_class(:running), do: "bg-info"
  defp status_class(:succeeded), do: "bg-success"
  defp status_class(:failed), do: "bg-error"
  defp status_class(:error), do: "bg-error"
  defp status_class(:queued), do: "bg-warning"
  defp status_class(_status), do: "bg-base-content/40"

  @spec status_badge_class(atom()) :: String.t()
  defp status_badge_class(:running), do: "badge-info"
  defp status_badge_class(:succeeded), do: "badge-success"
  defp status_badge_class(:failed), do: "badge-error"
  defp status_badge_class(:error), do: "badge-error"
  defp status_badge_class(:queued), do: "badge-warning"
  defp status_badge_class(_status), do: "badge-ghost"
end
