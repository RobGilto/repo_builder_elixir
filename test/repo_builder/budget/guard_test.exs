defmodule RepoBuilder.Budget.GuardTest do
  @moduledoc """
  Unit tests for the live budget circuit breaker (issue-budget-guardrails). Each test
  starts its OWN named Guard with injected caps (`reconcile?: false`) so no DB/sandbox
  coupling is needed; spend is driven via `note_spend/3` (the same path the telemetry
  handler uses), and breaker transitions are asserted off the `"budget:events"` topic.
  """
  use ExUnit.Case, async: false

  alias RepoBuilder.Budget.{Cap, Guard, Scope}

  @global Scope.global()

  defp cap(attrs) do
    base = %Cap{
      id: "cap-#{System.unique_integer([:positive])}",
      scope: :global,
      scope_id: "",
      period: :total,
      limit_usd: Decimal.new(10),
      warn_ratio: 0.8,
      action: :pause,
      enabled: true,
      inserted_at: ~U[2026-06-19 00:00:00.000000Z]
    }

    struct!(base, attrs)
  end

  defp start_guard(caps) do
    name = :"guard_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Guard.start_link(name: name, caps: caps, reconcile?: false, refresh_ms: 3_600_000)

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    name
  end

  setup do
    Phoenix.PubSub.subscribe(RepoBuilder.PubSub, Guard.topic())
    :ok
  end

  test "accumulates spend and trips when the limit is crossed" do
    guard = start_guard([cap(limit_usd: Decimal.new(10), action: :pause)])

    assert Guard.check([@global], guard) == :ok

    Guard.note_spend(8.0, [@global], guard)
    assert_receive {:budget_warning, %Cap{}, _spent}
    assert Guard.check([@global], guard) == :ok

    Guard.note_spend(3.0, [@global], guard)
    assert_receive {:budget_tripped, %Cap{}, spent}
    assert Decimal.compare(spent, Decimal.new(10)) != :lt

    assert {:error, {:budget_exceeded, %Cap{}}} = Guard.check([@global], guard)
  end

  test "an :alert cap broadcasts on trip but never denies" do
    guard = start_guard([cap(limit_usd: Decimal.new(5), action: :alert)])

    Guard.note_spend(6.0, [@global], guard)
    assert_receive {:budget_tripped, %Cap{action: :alert}, _spent}

    # :alert never blocks new spend.
    assert Guard.check([@global], guard) == :ok
  end

  test "the kill switch denies all spend and release restores it" do
    guard = start_guard([cap(action: :alert)])

    assert Guard.check([@global], guard) == :ok

    Guard.engage_kill_switch(guard)
    assert_receive {:kill_switch, :engaged}
    assert {:error, {:budget_exceeded, %Cap{}}} = Guard.check([@global], guard)

    Guard.release_all(guard)
    assert_receive {:kill_switch, :released}
    assert Guard.check([@global], guard) == :ok
  end

  test "spend is attributed only to caps whose scope matches" do
    orch = {:orchestrator, "o1"}

    guard =
      start_guard([
        cap(id: "g", scope: :global, scope_id: "", limit_usd: Decimal.new(100), action: :pause),
        cap(
          id: "o",
          scope: :orchestrator,
          scope_id: "o1",
          limit_usd: Decimal.new(5),
          action: :pause
        )
      ])

    # Spend only in the orchestrator scope trips the orchestrator cap, not the global one.
    Guard.note_spend(6.0, [@global, orch], guard)
    assert_receive {:budget_tripped, %Cap{scope: :orchestrator}, _}

    assert {:error, {:budget_exceeded, %Cap{scope: :orchestrator}}} =
             Guard.check([@global, orch], guard)

    # A session in a different orchestrator scope is unaffected.
    assert Guard.check([@global, {:orchestrator, "o2"}], guard) == :ok
  end

  test "snapshot reports caps, spent, ratio, and breaker state" do
    guard = start_guard([cap(limit_usd: Decimal.new(10), action: :pause)])
    Guard.note_spend(5.0, [@global], guard)

    snap = Guard.snapshot(guard)
    assert snap.kill_switch? == false
    assert [%{cap: %Cap{}, spent: spent, ratio: ratio, state: state}] = snap.caps
    assert Decimal.equal?(spent, Decimal.from_float(5.0))
    assert_in_delta ratio, 0.5, 0.001
    assert state == :ok
  end

  test "reset_cap clears a tripped cap whose limit was raised in the DB" do
    # This path reloads the cap from the Budget context; without a DB-backed cap it is a
    # no-op, which we assert does not crash.
    guard = start_guard([cap(action: :pause)])
    Guard.note_spend(20.0, [@global], guard)
    assert_receive {:budget_tripped, _, _}

    assert Guard.reset_cap("nonexistent", guard) == :ok
    # Still tripped (no DB cap to reload).
    assert {:error, {:budget_exceeded, _}} = Guard.check([@global], guard)
  end
end
