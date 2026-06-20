defmodule RepoBuilder.Budget.GuardReloadTest do
  @moduledoc """
  Covers the DB-reload semantics of `Budget.Guard.refresh/1` (the fix for runtime cap CRUD
  not taking effect live). Uses a DB-backed Guard (no injected `caps:`) under the shared
  sandbox so the breaker process sees the test's inserts — hence `async: false`.
  """
  use RepoBuilder.DataCase, async: false

  alias RepoBuilder.Budget
  alias RepoBuilder.Budget.{Guard, Scope}

  defp start_db_guard do
    name = :"guard_reload_#{System.unique_integer([:positive])}"
    {:ok, pid} = Guard.start_link(name: name, reconcile?: false, refresh_ms: 3_600_000)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    name
  end

  defp cap_ids(guard), do: guard |> Guard.snapshot() |> Map.fetch!(:caps) |> Enum.map(& &1.cap.id)

  defp add_cap(attrs) do
    {:ok, cap} =
      Budget.upsert_cap(
        Map.merge(
          %{"scope" => "global", "scope_id" => "", "period" => "daily", "action" => "alert"},
          attrs
        )
      )

    cap
  end

  test "refresh reloads caps created at runtime and drops deleted ones" do
    guard = start_db_guard()
    cap = add_cap(%{"limit_usd" => "5.0"})

    # A cap inserted after boot is invisible to the live breaker until a refresh.
    refute cap.id in cap_ids(guard)

    :ok = Guard.refresh(guard)
    assert cap.id in cap_ids(guard)

    {:ok, _} = Budget.delete_cap(cap.id)
    :ok = Guard.refresh(guard)

    # The deleted cap no longer lingers as a stale in-memory "ghost".
    refute cap.id in cap_ids(guard)
  end

  test "reload preserves in-flight spend for caps that still exist" do
    guard = start_db_guard()
    cap = add_cap(%{"limit_usd" => "100.0"})

    :ok = Guard.refresh(guard)
    Guard.note_spend(7.0, [Scope.global()], guard)

    # The reload must not wipe the live accumulator for a surviving cap.
    :ok = Guard.refresh(guard)

    row =
      guard |> Guard.snapshot() |> Map.fetch!(:caps) |> Enum.find(&(&1.cap.id == cap.id))

    assert Decimal.equal?(row.spent, Decimal.new("7.0"))
  end
end
