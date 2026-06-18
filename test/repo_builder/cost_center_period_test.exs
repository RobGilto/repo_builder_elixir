defmodule RepoBuilder.CostCenterPeriodTest do
  @moduledoc """
  Unit tests for `CostCenter.period_spend/1` (issue-cost-adw-periods): tz-aware window
  boundaries, hidden/cleared rows INCLUDED (the defining difference from `rollup/1`),
  grouping by harness vs provider, nil-vs-0/estimated handling, and empty periods.

  A fixed `:now` and an explicit `:timezone` make the windows deterministic.
  """
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.{Agents, CostCenter}
  alias RepoBuilder.CostCenter.{SpendRow, SpendSummary}
  alias RepoBuilder.Logs.{AgentLog, Usage}
  alias RepoBuilder.Repo

  defp uniq, do: System.unique_integer([:positive])

  defp agent_fixture do
    {:ok, agent} =
      Agents.create_agent(%{name: "agent-#{uniq()}", harness: "claude", provider: :anthropic})

    agent
  end

  defp log_fixture(agent, opts) do
    # The inserted_at column is :utc_datetime_usec — promote second-precision literals.
    at = %{Keyword.fetch!(opts, :at) | microsecond: {0, 6}}

    usage =
      case Keyword.get(opts, :cost, :none) do
        :none ->
          %Usage{input_tokens: opts[:input] || 0, output_tokens: opts[:output] || 0}

        cost ->
          %Usage{
            input_tokens: opts[:input] || 0,
            output_tokens: opts[:output] || 0,
            cost_usd: cost
          }
      end

    Repo.insert!(%AgentLog{
      agent_id: agent.id,
      session_id: "s-#{uniq()}",
      event_type: :usage,
      harness: Keyword.fetch!(opts, :harness),
      provider: opts[:provider],
      model: opts[:model],
      hidden: Keyword.get(opts, :hidden, false),
      usage: usage,
      inserted_at: at,
      updated_at: at
    })
  end

  defp find(rows, key), do: Enum.find(rows, &(&1.key == key))

  describe "period_spend/1 windows" do
    test "buckets rows into today/week/month by inserted_at, in UTC" do
      agent = agent_fixture()
      # Reference: Thursday 2026-06-18 12:00 UTC.
      now = ~U[2026-06-18 12:00:00Z]

      # Today (after local midnight 2026-06-18 00:00 UTC).
      log_fixture(agent,
        harness: "claude",
        provider: "anthropic",
        at: ~U[2026-06-18 09:00:00Z],
        cost: Decimal.new("1.00")
      )

      # Earlier this week but not today (Monday 2026-06-15).
      log_fixture(agent,
        harness: "claude",
        provider: "anthropic",
        at: ~U[2026-06-15 09:00:00Z],
        cost: Decimal.new("2.00")
      )

      # Earlier this month but not this week (2026-06-03).
      log_fixture(agent,
        harness: "claude",
        provider: "anthropic",
        at: ~U[2026-06-03 09:00:00Z],
        cost: Decimal.new("4.00")
      )

      # Last month — outside all windows.
      log_fixture(agent,
        harness: "claude",
        provider: "anthropic",
        at: ~U[2026-05-20 09:00:00Z],
        cost: Decimal.new("8.00")
      )

      summary = CostCenter.period_spend(timezone: "UTC", now: now)
      assert %SpendSummary{} = summary

      assert Decimal.equal?(
               find(summary.today.by_harness, "claude").actual_cost_usd,
               Decimal.new("1.00")
             )

      assert Decimal.equal?(
               find(summary.week.by_harness, "claude").actual_cost_usd,
               Decimal.new("3.00")
             )

      assert Decimal.equal?(
               find(summary.month.by_harness, "claude").actual_cost_usd,
               Decimal.new("7.00")
             )
    end

    test "resolves day boundary in the operator's timezone, not UTC" do
      agent = agent_fixture()
      # 2026-06-18 02:00 UTC is still 2026-06-17 in America/New_York (UTC-4 in June).
      now = ~U[2026-06-18 12:00:00Z]

      log_fixture(agent,
        harness: "claude",
        provider: "anthropic",
        at: ~U[2026-06-18 02:00:00Z],
        cost: Decimal.new("5.00")
      )

      # In UTC the row is "today".
      utc = CostCenter.period_spend(timezone: "UTC", now: now)
      assert find(utc.today.by_harness, "claude")

      # In New York the same instant is yesterday → not in "today", but still in the week.
      ny = CostCenter.period_spend(timezone: "America/New_York", now: now)
      assert utc.today.since != ny.today.since
      assert find(ny.today.by_harness, "claude") == nil

      assert Decimal.equal?(
               find(ny.week.by_harness, "claude").actual_cost_usd,
               Decimal.new("5.00")
             )
    end

    test "week starts Monday and month starts on the 1st" do
      now = ~U[2026-06-18 12:00:00Z]
      summary = CostCenter.period_spend(timezone: "UTC", now: now)

      assert summary.today.since == ~U[2026-06-18 00:00:00Z]
      assert summary.week.since == ~U[2026-06-15 00:00:00Z]
      assert summary.month.since == ~U[2026-06-01 00:00:00Z]
    end
  end

  describe "period_spend/1 hidden rows" do
    test "INCLUDES hidden/cleared rows (the defining difference from rollup/1)" do
      agent = agent_fixture()
      now = ~U[2026-06-18 12:00:00Z]

      log_fixture(agent,
        harness: "claude",
        provider: "anthropic",
        at: ~U[2026-06-18 09:00:00Z],
        cost: Decimal.new("1.00")
      )

      log_fixture(agent,
        harness: "claude",
        provider: "anthropic",
        at: ~U[2026-06-18 10:00:00Z],
        cost: Decimal.new("3.00"),
        hidden: true
      )

      summary = CostCenter.period_spend(timezone: "UTC", now: now)
      # Both rows counted regardless of visibility.
      assert Decimal.equal?(
               find(summary.today.by_harness, "claude").actual_cost_usd,
               Decimal.new("4.00")
             )

      # Contrast: the all-time rollup excludes the hidden row by default.
      [rollup] = CostCenter.rollup()
      assert Decimal.equal?(rollup.actual_cost_usd, Decimal.new("1.00"))
    end
  end

  describe "period_spend/1 grouping" do
    test "groups by harness and by provider independently" do
      agent = agent_fixture()
      now = ~U[2026-06-18 12:00:00Z]

      log_fixture(agent,
        harness: "claude",
        provider: "anthropic",
        at: ~U[2026-06-18 09:00:00Z],
        cost: Decimal.new("1.00")
      )

      log_fixture(agent,
        harness: "pi",
        provider: "zai",
        model: "glm-4.6",
        at: ~U[2026-06-18 09:30:00Z],
        cost: Decimal.new("2.00")
      )

      log_fixture(agent,
        harness: "pi",
        provider: "minimax",
        model: "m1",
        at: ~U[2026-06-18 10:00:00Z],
        cost: Decimal.new("4.00")
      )

      summary = CostCenter.period_spend(timezone: "UTC", now: now)

      # By harness: pi aggregates both providers.
      assert Decimal.equal?(
               find(summary.today.by_harness, "claude").actual_cost_usd,
               Decimal.new("1.00")
             )

      assert Decimal.equal?(
               find(summary.today.by_harness, "pi").actual_cost_usd,
               Decimal.new("6.00")
             )

      # By provider: each vendor is its own line.
      assert Decimal.equal?(
               find(summary.today.by_provider, "anthropic").actual_cost_usd,
               Decimal.new("1.00")
             )

      assert Decimal.equal?(
               find(summary.today.by_provider, "zai").actual_cost_usd,
               Decimal.new("2.00")
             )

      assert Decimal.equal?(
               find(summary.today.by_provider, "minimax").actual_cost_usd,
               Decimal.new("4.00")
             )
    end

    test ~s|buckets a nil/empty provider as the "unknown" ("") key, not dropped| do
      agent = agent_fixture()
      now = ~U[2026-06-18 12:00:00Z]

      log_fixture(agent,
        harness: "claude",
        provider: nil,
        at: ~U[2026-06-18 09:00:00Z],
        cost: Decimal.new("1.00")
      )

      summary = CostCenter.period_spend(timezone: "UTC", now: now)
      row = find(summary.today.by_provider, "")
      assert %SpendRow{} = row
      assert Decimal.equal?(row.actual_cost_usd, Decimal.new("1.00"))
    end
  end

  describe "period_spend/1 estimated vs actual" do
    test "derives an estimate for an unpriced row the catalog can price, preserving nil-vs-0" do
      {:ok, _} =
        CostCenter.upsert_price(%{
          harness: "pi",
          provider: "zai",
          model: "glm-4.6",
          output_price_per_mtok: "2.0"
        })

      agent = agent_fixture()
      now = ~U[2026-06-18 12:00:00Z]

      # Unpriced (cost: nil) but catalog-priced → estimate.
      log_fixture(agent,
        harness: "pi",
        provider: "zai",
        model: "glm-4.6",
        input: 500_000,
        output: 500_000,
        at: ~U[2026-06-18 09:00:00Z],
        cost: nil
      )

      summary = CostCenter.period_spend(timezone: "UTC", now: now)
      row = find(summary.today.by_harness, "pi")
      assert row.estimated?
      assert %Decimal{} = row.estimated_cost_usd
      assert Decimal.equal?(row.actual_cost_usd, Decimal.new(0))
    end

    test "no catalog price → no fabricated cost (estimated_cost_usd nil)" do
      agent = agent_fixture()
      now = ~U[2026-06-18 12:00:00Z]

      log_fixture(agent,
        harness: "pi",
        provider: "mystery",
        model: "x",
        input: 100,
        output: 100,
        at: ~U[2026-06-18 09:00:00Z],
        cost: nil
      )

      summary = CostCenter.period_spend(timezone: "UTC", now: now)
      row = find(summary.today.by_harness, "pi")
      refute row.estimated?
      assert row.estimated_cost_usd == nil
      assert Decimal.equal?(row.actual_cost_usd, Decimal.new(0))
    end
  end

  describe "period_spend/1 empty" do
    test "no logs → empty breakdowns, not a crash" do
      summary = CostCenter.period_spend(timezone: "UTC", now: ~U[2026-06-18 12:00:00Z])
      assert summary.today.by_harness == []
      assert summary.today.by_provider == []
      assert summary.week.by_harness == []
      assert summary.month.by_provider == []
    end

    test "defaults the timezone when none is given" do
      summary = CostCenter.period_spend(now: ~U[2026-06-18 12:00:00Z])
      assert summary.timezone == RepoBuilder.Timezones.default()
    end
  end
end
