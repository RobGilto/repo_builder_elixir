defmodule RepoBuilder.Orchestrator.WorkstreamsTest do
  @moduledoc """
  Spec-driven phased orchestration (orchestration-adw-loop): the durable Workstream context —
  create + plan_phases, the per-phase spec→implement→test→review state machine (with the
  review→fix→review branch and `:blocked`), next-phase promotion, multi-workstream isolation,
  and the rehydration INDEX (`list_workstreams/1`) + RECORD (`get_workstream/2`) shapes.
  """
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.Orchestrator.Workstream
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

  defp two_phases(orch, ws) do
    {:ok, ws} =
      Workstreams.plan_phases(orch.id, ws.id, [
        %{title: "Phase one", description: "first", definition_of_done: "one done"},
        %{title: "Phase two", description: "second", definition_of_done: "two done"}
      ])

    ws
  end

  # Drive the current phase spec→implement→test→review with all-passed stages.
  defp pass_phase(orch, ref) do
    for stage <- [:spec, :implement, :test, :review] do
      artifact = if stage == :spec, do: "specs/phase.md", else: nil

      {:ok, _} =
        Workstreams.record_stage(orch.id, ref, %{
          stage: stage,
          outcome: :passed,
          artifact: artifact
        })
    end
  end

  describe "create_workstream/2" do
    test "creates a running workstream with no phases" do
      orch = orchestrator()

      {:ok, ws} =
        Workstreams.create_workstream(orch.id, %{title: "T", goal: "G", definition_of_done: "D"})

      assert ws.status == :running
      assert ws.current_phase_position == 0
      assert {:ok, %{phases: []}} = Workstreams.get_workstream(orch.id, ws.id)
    end

    test "requires title and goal" do
      orch = orchestrator()
      assert {:error, %Ecto.Changeset{}} = Workstreams.create_workstream(orch.id, %{title: "T"})
    end
  end

  describe "plan_phases/3" do
    test "inserts ordered phases; phase 1 running at spec; current_phase_position set" do
      orch = orchestrator()
      ws = orch |> seed() |> then(&two_phases(orch, &1))

      assert ws.current_phase_position == 1
      [p1, p2] = ws.phases
      assert {p1.position, p1.status, p1.current_stage} == {1, :running, :spec}
      assert {p2.position, p2.status, p2.current_stage} == {2, :pending, :spec}
    end

    test "resolves a workstream by title as well as id" do
      orch = orchestrator()
      _ws = seed(orch, "By Title")

      assert {:ok, %Workstream{}} =
               Workstreams.plan_phases(orch.id, "By Title", [%{title: "P", description: "d"}])
    end

    test "unknown ref → :not_found; empty phases → :no_phases" do
      orch = orchestrator()
      ws = seed(orch)

      assert {:error, :not_found} =
               Workstreams.plan_phases(orch.id, Ecto.UUID.generate(), [%{title: "P"}])

      assert {:error, :no_phases} = Workstreams.plan_phases(orch.id, ws.id, [])
    end
  end

  describe "record_stage/3 — full traversal + promotion" do
    test "spec→implement→test→review advances current_stage and captures spec_path" do
      orch = orchestrator()
      ws = orch |> seed() |> then(&two_phases(orch, &1))

      {:ok, _} =
        Workstreams.record_stage(orch.id, ws.id, %{
          stage: :spec,
          outcome: :passed,
          artifact: "specs/p1.md"
        })

      {:ok, rec} = Workstreams.get_workstream(orch.id, ws.id)
      p1 = Enum.find(rec.phases, &(&1.position == 1))
      assert p1.current_stage == :implement
      assert p1.spec_path == "specs/p1.md"

      {:ok, _} = Workstreams.record_stage(orch.id, ws.id, %{stage: :implement, outcome: :passed})
      {:ok, _} = Workstreams.record_stage(orch.id, ws.id, %{stage: :test, outcome: :passed})
      {:ok, rec} = Workstreams.get_workstream(orch.id, ws.id)
      assert Enum.find(rec.phases, &(&1.position == 1)).current_stage == :review
    end

    test "passed review marks phase done and promotes the next pending phase" do
      orch = orchestrator()
      ws = orch |> seed() |> then(&two_phases(orch, &1))

      pass_phase(orch, ws.id)
      {:ok, rec} = Workstreams.get_workstream(orch.id, ws.id)

      assert rec.current_phase_position == 2
      assert Enum.find(rec.phases, &(&1.position == 1)).status == :done
      p2 = Enum.find(rec.phases, &(&1.position == 2))
      assert {p2.status, p2.current_stage} == {:running, :spec}
    end

    test "completing the last phase leaves no current phase; next_action says all complete" do
      orch = orchestrator()

      {:ok, ws} =
        Workstreams.create_workstream(orch.id, %{
          title: "Solo",
          goal: "g",
          definition_of_done: "d"
        })

      {:ok, _} = Workstreams.plan_phases(orch.id, ws.id, [%{title: "Only"}])

      pass_phase(orch, ws.id)
      {:ok, rec} = Workstreams.get_workstream(orch.id, ws.id)
      assert rec.next_action =~ "all phases complete"
      refute ws.id in Enum.map(Workstreams.ready_workstreams(orch.id), & &1.id)
    end
  end

  describe "record_stage/3 — review→fix→review and blocked" do
    test "failed review keeps current_stage review; passing after fix completes the phase" do
      orch = orchestrator()
      ws = orch |> seed() |> then(&two_phases(orch, &1))

      {:ok, _} =
        Workstreams.record_stage(orch.id, ws.id, %{
          stage: :spec,
          outcome: :passed,
          artifact: "s.md"
        })

      {:ok, _} = Workstreams.record_stage(orch.id, ws.id, %{stage: :implement, outcome: :passed})
      {:ok, _} = Workstreams.record_stage(orch.id, ws.id, %{stage: :test, outcome: :passed})
      {:ok, _} = Workstreams.record_stage(orch.id, ws.id, %{stage: :review, outcome: :failed})

      {:ok, rec} = Workstreams.get_workstream(orch.id, ws.id)
      p1 = Enum.find(rec.phases, &(&1.position == 1))
      assert p1.current_stage == :review
      assert p1.status == :running
      assert rec.next_action =~ "fix"

      {:ok, _} = Workstreams.record_stage(orch.id, ws.id, %{stage: :review, outcome: :passed})
      {:ok, rec} = Workstreams.get_workstream(orch.id, ws.id)
      assert Enum.find(rec.phases, &(&1.position == 1)).status == :done
    end

    test "blocked outcome blocks the phase and the workstream" do
      orch = orchestrator()
      ws = orch |> seed() |> then(&two_phases(orch, &1))

      {:ok, _} =
        Workstreams.record_stage(orch.id, ws.id, %{stage: :spec, outcome: :blocked, note: "stuck"})

      {:ok, rec} = Workstreams.get_workstream(orch.id, ws.id)

      assert rec.status == :blocked
      assert Enum.find(rec.phases, &(&1.position == 1)).status == :blocked
      assert Workstreams.ready_workstreams(orch.id) == []
    end

    test "repeated failures bump stall_count and eventually block (no infinite loop)" do
      orch = orchestrator()
      ws = orch |> seed() |> then(&two_phases(orch, &1))

      for _ <- 1..3 do
        {:ok, _} = Workstreams.record_stage(orch.id, ws.id, %{stage: :spec, outcome: :failed})
      end

      {:ok, rec} = Workstreams.get_workstream(orch.id, ws.id)
      assert rec.status == :blocked
      assert rec.stall_count >= 3
    end

    test "unknown stage/outcome → typed errors; unknown ref → :not_found" do
      orch = orchestrator()
      ws = orch |> seed() |> then(&two_phases(orch, &1))

      assert {:error, :invalid_stage} =
               Workstreams.record_stage(orch.id, ws.id, %{stage: "nope", outcome: :passed})

      assert {:error, :invalid_outcome} =
               Workstreams.record_stage(orch.id, ws.id, %{stage: :spec, outcome: "nope"})

      assert {:error, :not_found} =
               Workstreams.record_stage(orch.id, Ecto.UUID.generate(), %{
                 stage: :spec,
                 outcome: :passed
               })
    end

    test "record_stage with no planned phases → :no_current_phase" do
      orch = orchestrator()
      ws = seed(orch)

      assert {:error, :no_current_phase} =
               Workstreams.record_stage(orch.id, ws.id, %{stage: :spec, outcome: :passed})
    end
  end

  describe "multi-workstream isolation" do
    test "two workstreams advance independently and both list/ready" do
      orch = orchestrator()
      a = orch |> seed("Stream A") |> then(&two_phases(orch, &1))
      b = orch |> seed("Stream B") |> then(&two_phases(orch, &1))

      {:ok, _} =
        Workstreams.record_stage(orch.id, a.id, %{
          stage: :spec,
          outcome: :passed,
          artifact: "a.md"
        })

      {:ok, ra} = Workstreams.get_workstream(orch.id, a.id)
      {:ok, rb} = Workstreams.get_workstream(orch.id, b.id)
      assert Enum.find(ra.phases, &(&1.position == 1)).current_stage == :implement
      assert Enum.find(rb.phases, &(&1.position == 1)).current_stage == :spec

      ids = Enum.map(Workstreams.list_workstreams(orch.id), & &1.id)
      assert a.id in ids and b.id in ids
      assert length(Workstreams.ready_workstreams(orch.id)) == 2
    end

    test "workstreams are scoped to their orchestrator" do
      a = orchestrator()
      b = orchestrator()
      ws = seed(a, "Only A")
      assert {:error, :not_found} = Workstreams.get_workstream(b.id, ws.id)
      assert Workstreams.list_workstreams(b.id) == []
    end
  end

  describe "rehydration record shapes" do
    test "list_workstreams/1 index row carries id/title/status/phase/current_stage/next_action/stall_count" do
      orch = orchestrator()
      ws = orch |> seed("Indexed") |> then(&two_phases(orch, &1))

      [row] = Workstreams.list_workstreams(orch.id)
      assert row.id == ws.id
      assert row.title == "Indexed"
      assert row.status == :running
      assert row.phase == "1/2"
      assert row.current_stage == :spec
      assert is_binary(row.next_action)
      assert row.stall_count == 0
    end

    test "get_workstream/2 record carries goal/DoD, per-phase spec_path, completed/remaining, next_action" do
      orch = orchestrator()
      ws = orch |> seed("Recorded") |> then(&two_phases(orch, &1))

      {:ok, _} =
        Workstreams.record_stage(orch.id, ws.id, %{
          stage: :spec,
          outcome: :passed,
          artifact: "specs/x.md"
        })

      {:ok, rec} = Workstreams.get_workstream(orch.id, ws.id)
      assert rec.goal == "deliver Recorded"
      assert rec.definition_of_done == "gate green"
      assert is_binary(rec.next_action)

      p1 = Enum.find(rec.phases, &(&1.position == 1))
      assert p1.spec_path == "specs/x.md"
      assert "spec" in p1.completed
      assert "implement" in p1.remaining
    end
  end

  describe "close_workstream/3" do
    test "closes done/abandoned; rejects invalid status" do
      orch = orchestrator()
      ws = seed(orch)

      assert {:ok, %Workstream{status: :done}} =
               Workstreams.close_workstream(orch.id, ws.id, :done)

      ws2 = seed(orch, "Two")

      assert {:ok, %Workstream{status: :abandoned}} =
               Workstreams.close_workstream(orch.id, ws2.id, "abandoned")

      assert {:error, :invalid_status} = Workstreams.close_workstream(orch.id, ws2.id, :running)
    end
  end
end
