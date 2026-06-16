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
      <span class={["badge", status_class(@status)]}>{@status}</span>
    </div>
    """
  end

  @event_categories [:response, :tool, :thinking, :hook, :system]

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :status, :atom, required: true, values: @statuses
  attr :kind, :atom, default: :agent, values: [:agent, :workflow]
  attr :harness, :string, default: nil
  attr :duration, :string, default: nil
  slot :inner_block, doc: "the step columns of event squares"

  @doc "One ADW swimlane: key/label + status badge (+ duration), holding step columns of event squares."
  @spec swimlane(map()) :: Phoenix.LiveView.Rendered.t()
  def swimlane(assigns) do
    ~H"""
    <div id={@id} class="cns-panel rounded p-2">
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-2">
          <span class="cns-cat cns-cat--system">{@kind}</span>
          <span class="text-sm font-semibold" style="color: var(--cns-text-0)">{@label}</span>
          <span :if={@harness} class="text-[0.625rem]" style="color: var(--cns-text-2)">{@harness}</span>
          <span :if={@duration} class="text-[0.625rem]" style="color: var(--cns-text-2)">{@duration}</span>
        </div>
        <span class={["badge", status_class(@status)]}>{@status}</span>
      </div>
      <div class="mt-2 flex gap-3 overflow-x-auto pb-1">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr :category, :atom, required: true, values: @event_categories
  attr :summary, :string, required: true, doc: "hover-tooltip text"
  attr :event_id, :integer, required: true

  @doc "A 12px colored event square (by canonical category); hover tooltip + click opens the detail panel."
  @spec event_square(map()) :: Phoenix.LiveView.Rendered.t()
  def event_square(assigns) do
    ~H"""
    <button
      type="button"
      id={"square-#{@event_id}"}
      phx-click="open_event"
      phx-value-id={@event_id}
      title={@summary}
      class={["cns-square", "cns-square--#{@category}"]}
    />
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
        <div><span style="color: var(--cns-text-2)">agent</span> {@event.agent}</div>
        <div><span style="color: var(--cns-text-2)">time</span> {@event.time}</div>
      </div>

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

  @doc "Cost badge — distinguishes unpriced (nil → “—”) from a priced amount."
  @spec cost_badge(map()) :: Phoenix.LiveView.Rendered.t()
  def cost_badge(assigns) do
    ~H"""
    <span class="badge badge-outline">
      {if @cost, do: "$" <> Decimal.to_string(@cost), else: "—"}
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
