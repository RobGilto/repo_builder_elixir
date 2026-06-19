defmodule RepoBuilder.Orchestrator.EstimatedCostTest do
  @moduledoc """
  Proves the orchestrator surfaces a live token-derived `estimated_cost_usd` (REPLACE-latest,
  display-only) while the authoritative `total_cost_usd` stays untouched until the terminal
  `Done`. The estimate is strictly separate from — and never accumulated into — the billed total.
  """
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.Orchestrators

  defp uniq, do: System.unique_integer([:positive])

  defp orchestrator do
    {:ok, orch} = Orchestrators.create(%{name: "orch-#{uniq()}", harness: "fake"})
    orch
  end

  test "a usage estimate sets estimated_cost_usd while total_cost_usd stays 0" do
    orch = orchestrator()
    assert Decimal.equal?(orch.total_cost_usd, 0)
    assert is_nil(orch.estimated_cost_usd)

    {:ok, _} = Orchestrators.add_usage(orch.id, 1000, 500)
    {:ok, updated} = Orchestrators.set_estimated_cost(orch.id, 0.04)

    assert Decimal.equal?(updated.estimated_cost_usd, Decimal.from_float(0.04))
    assert Decimal.equal?(updated.total_cost_usd, 0), "estimate must NOT touch the billed total"
  end

  test "set_estimated_cost is REPLACE-latest, not additive" do
    orch = orchestrator()

    {:ok, _} = Orchestrators.set_estimated_cost(orch.id, 0.02)
    {:ok, updated} = Orchestrators.set_estimated_cost(orch.id, 0.05)

    assert Decimal.equal?(updated.estimated_cost_usd, Decimal.from_float(0.05))
  end

  test "a nil estimate is a no-op (prior estimate preserved)" do
    orch = orchestrator()
    {:ok, _} = Orchestrators.set_estimated_cost(orch.id, 0.03)
    {:ok, updated} = Orchestrators.set_estimated_cost(orch.id, nil)

    assert Decimal.equal?(updated.estimated_cost_usd, Decimal.from_float(0.03))
  end

  test "the terminal authoritative cost lands on total_cost_usd independently of the estimate" do
    orch = orchestrator()
    {:ok, _} = Orchestrators.set_estimated_cost(orch.id, 0.04)
    {:ok, settled} = Orchestrators.add_cost(orch.id, 0.42)

    assert Decimal.equal?(settled.total_cost_usd, Decimal.from_float(0.42))
    # The estimate is untouched by the authoritative cost write (display supersedes it in the UI).
    assert Decimal.equal?(settled.estimated_cost_usd, Decimal.from_float(0.04))
  end
end
