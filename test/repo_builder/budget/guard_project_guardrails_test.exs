defmodule RepoBuilder.Budget.GuardProjectGuardrailsTest do
  @moduledoc """
  Per-project / session / daily budget guardrails (issue per-project-cost-tracking). Each
  test starts its own named Guard with injected caps (`reconcile?: false`) and drives spend
  via `note_spend/3` (the telemetry path), asserting warn → pause → hard-stop off the
  `"budget:events"` topic.
  """
  use ExUnit.Case, async: false

  alias RepoBuilder.Budget.{Cap, Guard}

  defp cap(attrs) do
    base = %Cap{
      id: "cap-#{System.unique_integer([:positive])}",
      scope: :project,
      scope_id: "p1",
      period: :total,
      limit_usd: Decimal.new(10),
      warn_ratio: 0.8,
      action: :pause,
      enabled: true,
      inserted_at: ~U[2026-06-26 00:00:00.000000Z]
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

  test "a project cap warns then trips, and only its own project's spend counts" do
    p1 = {:project, "p1"}
    p2 = {:project, "p2"}
    guard = start_guard([cap(scope_id: "p1", limit_usd: Decimal.new(10), action: :pause)])

    # Spend on a different project never touches p1's cap.
    Guard.note_spend(50.0, [p2], guard)
    assert Guard.check([p1], guard) == :ok

    Guard.note_spend(8.0, [p1], guard)
    assert_receive {:budget_warning, %Cap{scope: :project, scope_id: "p1"}, _spent}

    Guard.note_spend(3.0, [p1], guard)
    assert_receive {:budget_tripped, %Cap{scope: :project, scope_id: "p1"}, _spent}
    assert {:error, {:budget_exceeded, %Cap{}}} = Guard.check([p1], guard)
  end

  test "a :hard_stop project cap denies new spend once tripped" do
    p1 = {:project, "p1"}
    guard = start_guard([cap(limit_usd: Decimal.new(5), action: :hard_stop)])

    Guard.note_spend(6.0, [p1], guard)
    assert_receive {:budget_tripped, %Cap{action: :hard_stop}, _spent}
    assert {:error, {:budget_exceeded, %Cap{}}} = Guard.check([p1], guard)
  end

  test "a session-period project cap accumulates and trips like any window" do
    p1 = {:project, "p1"}
    guard = start_guard([cap(period: :session, limit_usd: Decimal.new(4), action: :pause)])

    Guard.note_spend(5.0, [p1], guard)
    assert_receive {:budget_tripped, %Cap{period: :session}, _spent}
    assert {:error, {:budget_exceeded, %Cap{}}} = Guard.check([p1], guard)
  end
end
