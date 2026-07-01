defmodule RepoBuilder.Orchestrator.LedgersFocusTest do
  @moduledoc """
  Focus discipline (orchestrator level): the `Ledgers.set_focus/2` / `clear_focus/1` context
  functions and the `focus` + `focus_set_at` fields on the flat `view/1`.
  """
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.Orchestrator.Ledgers
  alias RepoBuilder.Orchestrators

  defp orchestrator do
    {:ok, orch} =
      Orchestrators.create(%{name: "orch-#{System.unique_integer([:positive])}", harness: "fake"})

    orch
  end

  defp with_goal(orch) do
    {:ok, _} = Ledgers.upsert_goal(orch.id, %{goal: "ship it", definition_of_done: "green"})
    orch
  end

  describe "set_focus/2 + view/1" do
    test "persists focus + focus_set_at and surfaces them on the view" do
      orch = orchestrator() |> with_goal()

      assert Ledgers.view(orch.id).focus == nil
      assert Ledgers.view(orch.id).focus_set_at == nil

      {:ok, ledger} = Ledgers.set_focus(orch.id, "wire the focus gate")

      assert ledger.focus == "wire the focus gate"
      assert %DateTime{} = ledger.focus_set_at

      view = Ledgers.view(orch.id)
      assert view.focus == "wire the focus gate"
      assert %DateTime{} = view.focus_set_at
    end

    test "overwrites the prior focus and refreshes focus_set_at (single-focus invariant)" do
      orch = orchestrator() |> with_goal()

      {:ok, first} = Ledgers.set_focus(orch.id, "first thing")
      {:ok, second} = Ledgers.set_focus(orch.id, "second thing")

      assert second.focus == "second thing"
      assert DateTime.compare(second.focus_set_at, first.focus_set_at) in [:gt, :eq]
    end
  end

  describe "clear_focus/1" do
    test "nulls both focus and focus_set_at" do
      orch = orchestrator() |> with_goal()
      {:ok, _} = Ledgers.set_focus(orch.id, "some focus")

      {:ok, cleared} = Ledgers.clear_focus(orch.id)

      assert cleared.focus == nil
      assert cleared.focus_set_at == nil
      assert Ledgers.view(orch.id).focus == nil
    end
  end

  describe "no active ledger" do
    test "set_focus/2 and clear_focus/1 return {:error, :no_active_ledger}" do
      orch = orchestrator()

      assert Ledgers.set_focus(orch.id, "x") == {:error, :no_active_ledger}
      assert Ledgers.clear_focus(orch.id) == {:error, :no_active_ledger}
    end
  end
end
