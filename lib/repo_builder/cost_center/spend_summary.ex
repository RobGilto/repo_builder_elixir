defmodule RepoBuilder.CostCenter.SpendRow do
  @moduledoc """
  One aggregated spend row for a period breakdown (issue-cost-adw-periods). Pure data —
  built by `CostCenter.period_spend/1` by folding the windowed `agent_logs` rollup up to a
  single dimension (`harness` or `provider`).

  `key` is the dimension value (a harness name, or a provider — `""` for the "unknown"
  provider bucket of older, pre-snapshot rows). `actual_cost_usd` sums the billed
  (`cost_usd IS NOT NULL`) portion; `estimated_cost_usd` sums the catalog-derived estimate
  for any unpriced sub-rows the catalog can price (`nil` when none can be estimated). The
  nil-vs-0 convention from `Rollup` is preserved — a billed cost is never fabricated.
  """
  use TypedStruct

  typedstruct enforce: true do
    field :key, String.t()
    field :actual_cost_usd, Decimal.t()
    field :estimated?, boolean()
    field :estimated_cost_usd, Decimal.t() | nil
    field :input_tokens, non_neg_integer()
    field :output_tokens, non_neg_integer()
    field :event_count, non_neg_integer()
  end
end

defmodule RepoBuilder.CostCenter.SpendSummary do
  @moduledoc """
  Time-windowed spend summary (issue-cost-adw-periods): the operator's per-period,
  per-vendor accounting view. Pure data — built by `CostCenter.period_spend/1`.

  Three windows — **today**, **this week** (ISO-8601, Monday start), **this month** (since
  the 1st) — each resolved in the operator's display `timezone` and grouped two ways:
  `by_harness` and `by_provider`. Unlike `CostCenter.rollup/1`, this aggregation includes
  hidden/cleared rows: it is real money spent, not the current console buffer. Each period
  carries its resolved UTC `since` boundary (for display/tests).
  """
  use TypedStruct

  alias RepoBuilder.CostCenter.SpendRow

  @typedoc "One time window: its UTC start instant and the two dimension breakdowns."
  @type period :: %{
          since: DateTime.t(),
          by_harness: [SpendRow.t()],
          by_provider: [SpendRow.t()]
        }

  typedstruct enforce: true do
    field :timezone, String.t()
    field :today, period()
    field :week, period()
    field :month, period()
  end
end
