defmodule RepoBuilder.CostCenter.Rollup do
  @moduledoc """
  One aggregated `(harness, provider, model)` cost row for the Cost Center rollup
  (issue-cost-center). Pure data — no `Repo` access; built by `CostCenter.rollup/1`
  from a grouped `agent_logs` query.

  `actual_cost_usd` sums only priced (`cost_usd IS NOT NULL`) rows. When that sum is
  zero/absent but the catalog has a price for the dimension, `estimated_cost_usd` holds
  the catalog-derived estimate and `estimated?` is `true`. With no catalog price the
  nil-vs-0 distinction is preserved: `estimated_cost_usd: nil`, `estimated?: false` —
  a billed cost is NEVER fabricated.
  """
  use TypedStruct

  typedstruct enforce: true do
    field :harness, String.t()
    field :provider, String.t()
    field :model, String.t() | nil
    field :actual_cost_usd, Decimal.t()
    field :estimated?, boolean()
    field :estimated_cost_usd, Decimal.t() | nil
    field :input_tokens, non_neg_integer()
    field :output_tokens, non_neg_integer()
    field :event_count, non_neg_integer()
    field :last_used_at, DateTime.t()
  end
end
