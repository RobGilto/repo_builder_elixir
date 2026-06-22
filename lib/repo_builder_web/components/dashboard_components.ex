defmodule RepoBuilderWeb.DashboardComponents do
  @moduledoc """
  Typed function components for the observability dashboard (BUILD_PROMPT.md §9).
  `attr/3` + `slot/3` give compile-time validation; `values:` constrains the status
  enum.
  """
  use RepoBuilderWeb, :html

  @statuses [:queued, :running, :succeeded, :failed, :cancelled, :idle, :error]

  attr :kind, :string, required: true
  attr :body, :string, required: true
  attr :thinking?, :boolean, default: false

  @doc "One append-only log line; reasoning content is dimmed."
  @spec log_line(map()) :: Phoenix.LiveView.Rendered.t()
  def log_line(assigns) do
    ~H"""
    <div class={["flex gap-2 font-mono text-sm", @thinking? && "opacity-60 italic"]}>
      <span class="shrink-0 font-semibold text-base-content/70">{@kind}</span>
      <span class="break-all">{@body}</span>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :status, :atom, required: true, values: @statuses
  attr :kind, :atom, default: :agent, values: [:agent, :workflow]
  attr :harness, :string, default: nil

  @doc "A swimlane row that mutates running→done in place (stable dom_id by lane id)."
  @spec swimlane_row(map()) :: Phoenix.LiveView.Rendered.t()
  def swimlane_row(assigns) do
    ~H"""
    <div class="flex items-center justify-between rounded border border-base-300 px-3 py-2">
      <div class="flex items-center gap-2">
        <span class="badge badge-sm">{@kind}</span>
        <span class="font-medium">{@label}</span>
        <span :if={@harness} class="text-xs text-base-content/60">{@harness}</span>
      </div>
      <span class="flex items-center gap-1.5">
        <.adw_orb active?={@status == :running} />
        <span class={["badge", status_class(@status)]}>{@status}</span>
      </span>
    </div>
    """
  end

  @event_categories [:response, :tool, :thinking, :hook, :system]

  attr :id, :string, required: true

  attr :title, :string,
    required: true,
    doc: "human-friendly display name (ADW type or worker name)"

  attr :subtitle, :string,
    default: nil,
    doc: "the machine-ish worker name, shown under the title when the title is the ADW type"

  attr :status, :atom, required: true, values: @statuses
  attr :harness, :string, default: nil
  slot :inner_block, doc: "the per-stage lanes of event squares"

  @doc """
  A standalone agent card (manual / non-workflow agents): the same card chrome as
  `adw_card/1` (status-colored left border + header) holding per-stage lanes of event
  squares, so every block in the ADWS view shares one visual language.
  """
  @spec adw_agent_card(map()) :: Phoenix.LiveView.Rendered.t()
  def adw_agent_card(assigns) do
    ~H"""
    <div id={@id} class={["cns-card", "cns-card--#{@status}"]} data-run-status={@status}>
      <div class="flex items-start justify-between">
        <div class="flex flex-col gap-0.5">
          <span class="cns-card__key">AGENT</span>
          <span class="cns-card__title">{@title}</span>
          <span :if={@subtitle} class="text-[0.625rem]" style="color: var(--cns-text-2)">
            {@subtitle}
          </span>
          <span class="flex items-center gap-1.5">
            <.adw_orb active?={@status == :running} />
            <span class={["badge", status_class(@status)]}>{@status}</span>
            <span :if={@harness} class="text-[0.625rem]" style="color: var(--cns-text-2)">
              {@harness}
            </span>
          </span>
        </div>
      </div>
      <div class="mt-2 flex flex-wrap gap-3">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true, doc: "human-friendly display name (never a UUID)"
  attr :type, :string, default: nil, doc: "the workflow type slug (key line)"
  attr :status, :atom, required: true, values: @statuses
  attr :completed, :integer, required: true
  attr :total, :integer, required: true
  attr :cost, :any, default: nil
  attr :duration, :string, default: nil, doc: "elapsed/total display string"
  attr :current, :string, default: nil, doc: "the active step name (highlighted)"

  attr :steps, :list,
    required: true,
    doc: "per-step view maps (name/status/cost_usd) from Workflows.run_progress/1"

  attr :step_squares, :map,
    default: %{},
    doc: "map of step name → event rows whose squares render inside that step box"

  @doc """
  One ADW card: a status-colored left border, a header (`ADW: <type>` key + the
  human-friendly title + status/progress/cost + duration), then a wrapping set of
  per-step boxes (status-keyed, current step highlighted) each hosting that stage's
  event squares.
  """
  @spec adw_card(map()) :: Phoenix.LiveView.Rendered.t()
  def adw_card(assigns) do
    ~H"""
    <div id={@id} class={["cns-card", "cns-card--#{@status}"]} data-run-status={@status}>
      <div class="flex items-start justify-between">
        <div class="flex flex-col gap-0.5">
          <span class="cns-card__key">ADW: {@type || "workflow"}</span>
          <span class="cns-card__title">{@title}</span>
          <span class="flex items-center gap-1.5">
            <.adw_orb active?={@status == :running} />
            <span class={["badge", status_class(@status)]}>{@status}</span>
            <span class="text-[0.625rem]" style="color: var(--cns-text-2)">
              {@completed}/{@total}
            </span>
            <.cost_badge cost={@cost} />
          </span>
        </div>
        <span :if={@duration} class="cns-duration">{@duration}</span>
      </div>
      <div class="mt-2 flex flex-wrap gap-2">
        <.step_box
          :for={step <- @steps}
          id={"#{@id}-step-#{step.name}"}
          name={step.name}
          status={step.status}
          current?={step.name == @current}
        >
          <.event_square
            :for={row <- Map.get(@step_squares, step.name, [])}
            event_id={row.id}
            category={row.category}
            summary={"#{row.kind}: #{row.body}"}
          />
        </.step_box>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :status, :atom, required: true
  attr :current?, :boolean, default: false
  slot :inner_block, doc: "optional event squares for this stage"

  @doc """
  One ADW step box: tinted by status (`data-step-status`), highlighted when current; its
  body holds the stage's event squares when any are passed.
  """
  @spec step_box(map()) :: Phoenix.LiveView.Rendered.t()
  def step_box(assigns) do
    ~H"""
    <div
      id={@id}
      data-step-status={@status}
      title={"#{@name}: #{@status}"}
      class={["cns-step-box cns-stage-lane", @current? && "cns-step-box--current"]}
    >
      <span class="cns-step-box__name">{format_step_name(@name)}</span>
      <div :if={@inner_block != []} class="cns-stage-lane__squares">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :step, :string, required: true, doc: "raw step name; `_workflow` → `Workflow`"
  attr :status, :atom, default: nil, doc: "optional stage status for tinting/highlight"
  attr :current?, :boolean, default: false
  slot :inner_block, required: true, doc: "the stage's event squares"

  @doc """
  One stage lane: a labeled, status-tintable box (shares the `.cns-step-box` chrome) whose
  body is a wrapping grid of the stage's event squares. `"_workflow"` humanizes to
  `"Workflow"`, so non-ADW workers degrade to a single lane.
  """
  @spec stage_lane(map()) :: Phoenix.LiveView.Rendered.t()
  def stage_lane(assigns) do
    ~H"""
    <div
      id={@id}
      data-step-status={@status}
      class={["cns-step-box cns-stage-lane", @current? && "cns-step-box--current"]}
    >
      <span class="cns-step-box__name">{format_step_name(@step)}</span>
      <div class="cns-stage-lane__squares">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  # "plan" → "Plan", "plan_build" → "Plan Build", "_workflow" → "Workflow".
  @spec format_step_name(String.t()) :: String.t()
  defp format_step_name(name) do
    name
    |> String.split(~r/[-_\s]+/, trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  @doc "Icon glyph for a canonical event category (drives the event-square face)."
  @spec category_icon(atom()) :: String.t()
  def category_icon(:response), do: "💬"
  def category_icon(:tool), do: "🛠️"
  def category_icon(:thinking), do: "🧠"
  def category_icon(:hook), do: "🪝"
  def category_icon(:system), do: "⚙️"

  attr :category, :atom, required: true, values: @event_categories
  attr :summary, :string, required: true, doc: "hover-tooltip text"
  attr :event_id, :integer, required: true

  @doc "A colored event square with a category icon; hover tooltip + click opens the detail panel."
  @spec event_square(map()) :: Phoenix.LiveView.Rendered.t()
  def event_square(assigns) do
    assigns = assign(assigns, :icon, category_icon(assigns.category))

    ~H"""
    <button
      type="button"
      id={"square-#{@event_id}"}
      phx-click="open_event"
      phx-value-id={@event_id}
      title={@summary}
      class={["cns-square", "cns-square--#{@category}"]}
    >
      <span class="cns-square__icon">{@icon}</span>
    </button>
    """
  end

  attr :event, :map, default: nil, doc: "the selected event row (nil ⇒ hidden)"

  @doc "Right slide-out event detail panel: summary hero, type/category/step/time grid, pretty payload."
  @spec event_detail_panel(map()) :: Phoenix.LiveView.Rendered.t()
  def event_detail_panel(assigns) do
    ~H"""
    <div
      :if={@event}
      id="event-detail-panel"
      class="cns-detail flex w-80 shrink-0 flex-col gap-3 overflow-y-auto p-3"
    >
      <div class="flex items-center justify-between">
        <span class="text-xs font-semibold" style="color: var(--cns-cyan)">EVENT DETAIL</span>
        <button id="close-event" type="button" phx-click="close_event" class="cns-chip">×</button>
      </div>

      <div class="cns-bubble cns-bubble--orch text-sm">{@event.body}</div>

      <div class="grid grid-cols-2 gap-2 text-[0.6875rem]" style="color: var(--cns-text-1)">
        <div><span style="color: var(--cns-text-2)">type</span> {@event.kind}</div>
        <div><span style="color: var(--cns-text-2)">category</span> {@event.category}</div>
        <div>
          <span style="color: var(--cns-text-2)">step</span> {format_step_name(
            @event[:step] || "_workflow"
          )}
        </div>
        <div><span style="color: var(--cns-text-2)">agent</span> {@event.agent}</div>
        <div><span style="color: var(--cns-text-2)">time</span> {@event.time}</div>
        <div>
          <span style="color: var(--cns-text-2)">log</span> {RepoBuilder.Logs.log_label(
            @event[:log_no]
          )}
        </div>
      </div>

      <%= if fc = @event[:render][:file_change] do %>
        <div>
          <div class="mb-1 text-[0.625rem]" style="color: var(--cns-text-2)">FILE CHANGE</div>
          <RepoBuilderWeb.ConsoleComponents.file_change_card
            file_change={fc}
            expanded?={true}
            open_enabled?={true}
          />
        </div>
      <% end %>

      <div>
        <div class="mb-1 text-[0.625rem]" style="color: var(--cns-text-2)">PAYLOAD</div>
        <pre
          class="overflow-x-auto whitespace-pre-wrap break-all text-[0.625rem]"
          style="color: var(--cns-text-1)"
          phx-no-curly-interpolation
        ><%= @event.payload_json %></pre>
      </div>
    </div>
    """
  end

  attr :cost, :any, default: nil
  attr :estimated, :any, default: nil

  @doc """
  Cost badge — renders the authoritative billed amount when present (`$X.XX`),
  otherwise a token-derived live ESTIMATE marked with `~` (`~$X.XX`), otherwise
  `—` (unpriced / no signal yet). The estimate is superseded the instant an
  authoritative `cost` arrives.
  """
  @spec cost_badge(map()) :: Phoenix.LiveView.Rendered.t()
  def cost_badge(assigns) do
    ~H"""
    <span class="badge badge-outline" style="color: var(--cns-text-1)">
      <%= cond do %>
        <% @cost -> %>
          {"$" <> Decimal.to_string(Decimal.round(@cost, 2))}
        <% @estimated -> %>
          <span
            style="color: var(--cns-text-2)"
            title="Live estimate from tokens — billed amount pending"
          >
            {"~$" <> Decimal.to_string(Decimal.round(@estimated, 2))}
          </span>
        <% true -> %>
          —
      <% end %>
    </span>
    """
  end

  attr :active?, :boolean, default: false

  # Self-contained `:adw`-variant activity orb. Mirrors the canonical
  # `ConsoleComponents.activity_orb/1` markup (and shares its `cns-orb*` CSS), but is
  # inlined here to avoid a compile-time import cycle: `ConsoleComponents` already
  # imports `cost_badge/1` from this module, so importing back would deadlock.
  @spec adw_orb(map()) :: Phoenix.LiveView.Rendered.t()
  defp adw_orb(assigns) do
    ~H"""
    <span :if={@active?} data-orb data-active="true" class="cns-orb cns-orb--adw" title="running">
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

  @spec status_class(atom()) :: String.t()
  defp status_class(:running), do: "badge-info"
  defp status_class(:succeeded), do: "badge-success"
  defp status_class(:failed), do: "badge-error"
  defp status_class(:error), do: "badge-error"
  defp status_class(_status), do: "badge-ghost"
end
