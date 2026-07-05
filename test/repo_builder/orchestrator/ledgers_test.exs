defmodule RepoBuilder.Orchestrator.LedgersTest do
  @moduledoc """
  Self-healing Phase 3: the durable Task + Progress Ledger context — goal upsert, progress
  recording, the stall ladder, done/escalate transitions, current-ledger resolution, and the
  auto-record backstop.
  """
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.Orchestrator.Ledgers
  alias RepoBuilder.Orchestrator.TaskLedger
  alias RepoBuilder.Orchestrators

  defp orchestrator do
    {:ok, orch} =
      Orchestrators.create(%{name: "orch-#{System.unique_integer([:positive])}", harness: "fake"})

    orch
  end

  describe "upsert_goal/2 + current/1" do
    test "creates an active ledger and resolves it via current/1" do
      orch = orchestrator()
      assert Ledgers.current(orch.id) == nil

      {:ok, ledger} =
        Ledgers.upsert_goal(orch.id, %{
          goal: "ship the feature",
          definition_of_done: "tests green",
          plan: ["step one", "step two"]
        })

      assert ledger.status == :active
      assert ledger.goal == "ship the feature"

      assert ledger.plan == [
               %{"step" => "step one", "status" => "pending"},
               %{"step" => "step two", "status" => "pending"}
             ]

      assert %TaskLedger{id: id} = Ledgers.current(orch.id)
      assert id == ledger.id
    end

    test "refreshes the existing active ledger in place (no second active row)" do
      orch = orchestrator()
      {:ok, first} = Ledgers.upsert_goal(orch.id, %{goal: "v1", definition_of_done: "dod1"})
      {:ok, second} = Ledgers.upsert_goal(orch.id, %{goal: "v2", definition_of_done: "dod2"})

      assert first.id == second.id
      assert Ledgers.current(orch.id).goal == "v2"
    end
  end

  describe "record_progress/2" do
    test "appends an entry to the active ledger and surfaces it as latest" do
      orch = orchestrator()
      {:ok, _} = Ledgers.upsert_goal(orch.id, %{goal: "g", definition_of_done: "d"})

      {:ok, entry} =
        Ledgers.record_progress(orch.id, %{
          "made_progress" => true,
          "summary" => "did a thing",
          "next_agent" => "builder"
        })

      assert entry.made_progress == true
      latest = Ledgers.latest_progress(orch.id)
      assert latest.id == entry.id
      assert latest.summary == "did a thing"
      assert latest.next_agent == "builder"
    end

    test "errors when no goal is set" do
      orch = orchestrator()

      assert {:error, :no_active_ledger} =
               Ledgers.record_progress(orch.id, %{"made_progress" => true})
    end
  end

  describe "stall ladder" do
    test "bump_stall/1 increments and reset_stall/1 zeroes" do
      orch = orchestrator()
      {:ok, _} = Ledgers.upsert_goal(orch.id, %{goal: "g", definition_of_done: "d"})

      {:ok, l1} = Ledgers.bump_stall(orch.id)
      assert l1.stall_count == 1
      {:ok, l2} = Ledgers.bump_stall(orch.id)
      assert l2.stall_count == 2
      {:ok, l3} = Ledgers.reset_stall(orch.id)
      assert l3.stall_count == 0
    end

    test "bump_stall/1 errors with no active ledger" do
      orch = orchestrator()
      assert {:error, :no_active_ledger} = Ledgers.bump_stall(orch.id)
    end
  end

  describe "lifecycle transitions" do
    test "mark_done/2 ends the goal so current/1 returns nil" do
      orch = orchestrator()
      {:ok, _} = Ledgers.upsert_goal(orch.id, %{goal: "g", definition_of_done: "d"})

      {:ok, done} = Ledgers.mark_done(orch.id)
      assert done.status == :done
      assert Ledgers.current(orch.id) == nil
    end

    test "mark_escalated/2 ends the active goal" do
      orch = orchestrator()
      {:ok, _} = Ledgers.upsert_goal(orch.id, %{goal: "g", definition_of_done: "d"})

      {:ok, esc} = Ledgers.mark_escalated(orch.id, "blocked on creds")
      assert esc.status == :escalated
      assert Ledgers.current(orch.id) == nil
    end

    test "a new goal after done starts a fresh active ledger" do
      orch = orchestrator()
      {:ok, first} = Ledgers.upsert_goal(orch.id, %{goal: "g1", definition_of_done: "d1"})
      {:ok, _} = Ledgers.mark_done(orch.id)
      {:ok, second} = Ledgers.upsert_goal(orch.id, %{goal: "g2", definition_of_done: "d2"})

      refute second.id == first.id
      assert Ledgers.current(orch.id).goal == "g2"
    end
  end

  describe "auto_record_progress/4 backstop" do
    test "writes a minimal entry when the brain recorded none since the turn started" do
      orch = orchestrator()
      {:ok, _} = Ledgers.upsert_goal(orch.id, %{goal: "g", definition_of_done: "d"})
      since = DateTime.utc_now()

      :ok = Ledgers.auto_record_progress(orch.id, "orch-x-1", :ok, since)

      latest = Ledgers.latest_progress(orch.id)
      assert latest.turn_agent_id == "orch-x-1"
      assert latest.made_progress == false
    end

    test "is a no-op when the brain already recorded this turn" do
      orch = orchestrator()
      {:ok, _} = Ledgers.upsert_goal(orch.id, %{goal: "g", definition_of_done: "d"})
      since = DateTime.utc_now()

      {:ok, explicit} =
        Ledgers.record_progress(orch.id, %{"made_progress" => true, "summary" => "real"})

      :ok = Ledgers.auto_record_progress(orch.id, "orch-x-2", :ok, since)

      # No backstop row added — the latest is still the explicit one.
      assert Ledgers.latest_progress(orch.id).id == explicit.id
    end

    test "is a no-op when no goal is set" do
      orch = orchestrator()
      assert :ok = Ledgers.auto_record_progress(orch.id, "orch-x-3", :ok, DateTime.utc_now())
      assert Ledgers.latest_progress(orch.id) == nil
    end

    test ":transient outcome flags the entry transient with a distinct summary" do
      orch = orchestrator()
      {:ok, _} = Ledgers.upsert_goal(orch.id, %{goal: "g", definition_of_done: "d"})

      :ok = Ledgers.auto_record_progress(orch.id, "orch-t-1", :transient, DateTime.utc_now())

      latest = Ledgers.latest_progress(orch.id)
      assert latest.transient == true
      assert latest.made_progress == false
      assert latest.summary =~ "transient provider rate limit"
    end

    test ":error outcome leaves transient false (regression guard)" do
      orch = orchestrator()
      {:ok, _} = Ledgers.upsert_goal(orch.id, %{goal: "g", definition_of_done: "d"})

      :ok = Ledgers.auto_record_progress(orch.id, "orch-e-1", :error, DateTime.utc_now())

      latest = Ledgers.latest_progress(orch.id)
      assert latest.transient == false
      assert latest.summary =~ "no explicit progress report"
    end
  end

  describe "view/1" do
    test "returns a flat render-ready map of the ledger + latest progress" do
      orch = orchestrator()
      {:ok, _} = Ledgers.upsert_goal(orch.id, %{goal: "the goal", definition_of_done: "the dod"})
      {:ok, _} = Ledgers.record_progress(orch.id, %{"made_progress" => true, "summary" => "s"})

      view = Ledgers.view(orch.id)
      assert view.goal == "the goal"
      assert view.definition_of_done == "the dod"
      assert view.status == :active
      assert view.progress.summary == "s"
    end

    test "returns nil with no goal" do
      assert Ledgers.view(orchestrator().id) == nil
    end
  end
end
