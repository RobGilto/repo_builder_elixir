defmodule RepoBuilder.Orchestrator.WorkstreamsFocusTest do
  @moduledoc """
  Focus discipline (per-workstream level): `Workstreams.set_focus/3` / `clear_focus/2` and the
  `focus` + `focus_set_at` fields on the `index_row/1` INDEX and `record/1` RECORD views.
  """
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.Orchestrator.Workstreams
  alias RepoBuilder.Orchestrators

  defp orchestrator do
    {:ok, orch} =
      Orchestrators.create(%{name: "orch-#{System.unique_integer([:positive])}", harness: "fake"})

    orch
  end

  defp seed(orch, title \\ "Build feature") do
    {:ok, ws} =
      Workstreams.create_workstream(orch.id, %{
        title: title,
        goal: "deliver #{title}",
        definition_of_done: "gate green"
      })

    ws
  end

  defp index_for(orch, id) do
    Enum.find(Workstreams.list_workstreams(orch.id), &(&1.id == id))
  end

  describe "set_focus/3" do
    test "resolves by id, persists focus + focus_set_at, and surfaces on both views" do
      orch = orchestrator()
      ws = seed(orch)

      assert index_for(orch, ws.id).focus == nil

      {:ok, updated} = Workstreams.set_focus(orch.id, ws.id, "land phase 2 spec")

      assert updated.focus == "land phase 2 spec"
      assert %DateTime{} = updated.focus_set_at

      assert index_for(orch, ws.id).focus == "land phase 2 spec"

      {:ok, record} = Workstreams.get_workstream(orch.id, ws.id)
      assert record.focus == "land phase 2 spec"
      assert %DateTime{} = record.focus_set_at
    end

    test "resolves by title" do
      orch = orchestrator()
      _ws = seed(orch, "Payments")

      {:ok, updated} = Workstreams.set_focus(orch.id, "Payments", "refund flow")
      assert updated.focus == "refund flow"
    end

    test "overwrites the prior focus (single-focus-per-stream invariant)" do
      orch = orchestrator()
      ws = seed(orch)

      {:ok, _} = Workstreams.set_focus(orch.id, ws.id, "first")
      {:ok, second} = Workstreams.set_focus(orch.id, ws.id, "second")

      assert second.focus == "second"
    end

    test "{:error, :not_found} for an unknown ref" do
      orch = orchestrator()
      assert Workstreams.set_focus(orch.id, "nope", "x") == {:error, :not_found}
    end
  end

  describe "clear_focus/2" do
    test "nulls both fields" do
      orch = orchestrator()
      ws = seed(orch)
      {:ok, _} = Workstreams.set_focus(orch.id, ws.id, "something")

      {:ok, cleared} = Workstreams.clear_focus(orch.id, ws.id)

      assert cleared.focus == nil
      assert cleared.focus_set_at == nil
      assert index_for(orch, ws.id).focus == nil
    end

    test "{:error, :not_found} for an unknown ref" do
      orch = orchestrator()
      assert Workstreams.clear_focus(orch.id, "nope") == {:error, :not_found}
    end
  end
end
