defmodule RepoBuilder.CostCenter.ProjectReport do
  @moduledoc """
  A per-project lifetime cost report (issue per-project-cost-tracking). Pure data — built
  by `CostCenter.project_spend/2` by folding the project's `agent_logs` rollup up to a
  per-model breakdown.

  `total_usd` is the lifetime actual + estimated spend (the nil-vs-0 convention preserved
  via the underlying rollup — an unpriced harness contributes its estimate, never `$0`).
  `by_model` are `SpendRow`s keyed by model id (most-expensive first). `hidden?` flags that
  cleared (soft-hidden) rows exist for this project, so the UI can show a "N cleared
  (restorable)" marker; the report's totals respect the `:include_hidden?` option.
  """
  use TypedStruct

  alias RepoBuilder.CostCenter.SpendRow

  typedstruct enforce: true do
    field :project_id, Ecto.UUID.t()
    field :total_usd, Decimal.t()
    field :estimated?, boolean()
    field :by_model, [SpendRow.t()]
    field :event_count, non_neg_integer()
    field :first_used, DateTime.t() | nil
    field :last_used, DateTime.t() | nil
    field :hidden?, boolean()
  end
end
