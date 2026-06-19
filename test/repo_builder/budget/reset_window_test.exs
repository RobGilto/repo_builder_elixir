defmodule RepoBuilder.Budget.ResetWindowTest do
  @moduledoc """
  Covers the operator "Reset" action on a tripped cap (issue-budget-guardrails, option 2):
  `Budget.reset_cap_window/1` stamps `reset_at = now` and the live `Budget.Guard` then
  counts spend only from that moment — so a tripped cap actually clears instead of
  immediately re-tripping against the same accumulated spend.

  `async: false` so the Guard process started here shares the test's Ecto sandbox.
  """
  use RepoBuilder.DataCase, async: false

  alias RepoBuilder.Budget
  alias RepoBuilder.Budget.{Cap, Guard, Scope}
  alias RepoBuilder.Logs.{AgentLog, Usage}

  @global Scope.global()

  defp uniq, do: System.unique_integer([:positive])

  defp cap_fixture do
    {:ok, %Cap{} = cap} =
      Budget.upsert_cap(%{
        "scope" => "global",
        "scope_id" => "",
        "period" => "total",
        "limit_usd" => "5.0",
        "action" => "pause"
      })

    cap
  end

  # A priced log dated in the past, so it lands inside the all-time window but OUTSIDE a
  # window restarted at "now".
  defp past_spend(cost) do
    at = DateTime.add(DateTime.utc_now(), -3600, :second)

    Repo.insert!(%AgentLog{
      session_id: "s-#{uniq()}",
      event_type: :usage,
      harness: "claude",
      provider: "anthropic",
      usage: %Usage{input_tokens: 0, output_tokens: 0, cost_usd: cost},
      inserted_at: at,
      updated_at: at
    })
  end

  defp start_guard(cap) do
    name = :"guard_#{uniq()}"

    {:ok, pid} =
      Guard.start_link(name: name, caps: [cap], reconcile?: true, refresh_ms: 3_600_000)

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    name
  end

  describe "Budget.reset_cap_window/1" do
    test "stamps reset_at = now and returns the reloaded cap" do
      cap = cap_fixture()
      assert is_nil(cap.reset_at)

      assert %Cap{reset_at: %DateTime{} = reset_at} = Budget.reset_cap_window(cap.id)
      assert DateTime.diff(DateTime.utc_now(), reset_at, :second) <= 5

      # Persisted, not just in-memory.
      assert %Cap{reset_at: ^reset_at} = Budget.get_cap(cap.id)
    end

    test "returns nil for an unknown cap" do
      assert Budget.reset_cap_window(Ecto.UUID.generate()) == nil
    end
  end

  test "resetting a tripped cap clears it by counting spend only from the reset" do
    cap = cap_fixture()
    # $10 spent in the past trips the $5 cap on boot reconcile.
    past_spend(Decimal.new("10.0"))

    guard = start_guard(cap)

    assert {:error, {:budget_exceeded, %Cap{}}} = Guard.check([@global], guard)

    # Reset restarts the window at "now" — the past $10 falls outside it, so the breaker
    # recomputes to :ok instead of re-tripping against the same spend.
    assert Guard.reset_cap(cap.id, guard) == :ok
    assert Guard.check([@global], guard) == :ok

    snap = Guard.snapshot(guard)
    assert Enum.any?(snap.caps, fn c -> c.cap.id == cap.id and c.state == :ok end)
  end
end
