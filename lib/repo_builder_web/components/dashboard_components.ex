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

  attr :cost, :any, default: nil

  @doc "Cost badge — distinguishes unpriced (nil → “—”) from a priced amount."
  @spec cost_badge(map()) :: Phoenix.LiveView.Rendered.t()
  def cost_badge(assigns) do
    ~H"""
    <span class="badge badge-outline">{format_cost(@cost)}</span>
    """
  end

  @doc """
  Human-format a cost `Decimal` to 3 decimal places (e.g. `$0.873`). A priced
  zero renders `$0.000`; an unpriced (`nil`) cost renders `—` (never `$0`).
  """
  @spec format_cost(Decimal.t() | nil) :: String.t()
  def format_cost(nil), do: "—"
  def format_cost(%Decimal{} = cost), do: "$" <> Decimal.to_string(Decimal.round(cost, 3))

  @spec status_class(atom()) :: String.t()
  defp status_class(:running), do: "badge-info"
  defp status_class(:succeeded), do: "badge-success"
  defp status_class(:failed), do: "badge-error"
  defp status_class(:error), do: "badge-error"
  defp status_class(_status), do: "badge-ghost"
end
