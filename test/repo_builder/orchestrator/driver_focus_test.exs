defmodule RepoBuilder.Orchestrator.DriverFocusTest do
  @moduledoc """
  Focus discipline in the autonomous drive loop: an active-goal orchestrator with NO focus is
  driven with a focus-first nudge turn (declare your focus before spending budget); once a focus
  is set, the normal drive prompt surfaces it. Deterministic `Driver.tick/0` (`drive_on_boot:
  false`, `drive_interval_ms: :infinity`), mirroring `driver_test.exs`.
  """
  use RepoBuilder.DataCase, async: false

  alias RepoBuilder.Orchestrator.{Driver, Ledgers, Queue}
  alias RepoBuilder.Orchestrators

  setup do
    :ok = Driver.reset()
    :ok
  end

  defp create_orch do
    {:ok, orch} =
      Orchestrators.create(%{
        name: "orch-#{System.unique_integer([:positive])}",
        harness: "fake",
        model: "fake-model"
      })

    orch
  end

  # A Queue whose starter records the prompt it was asked to drive (into `sink`), then dies so
  # the Queue advances.
  defp queue_capturing(orch_id, sink) do
    starter = fn oid, prompt ->
      Agent.update(sink, &[prompt | &1])
      {:ok, spawn(fn -> :ok end), "orch-#{oid}-#{System.unique_integer([:positive])}"}
    end

    start_supervised!({Queue, orchestrator_id: orch_id, starter: starter}, id: {:queue, orch_id})
  end

  defp tick(queue) do
    _ = Driver.tick()
    _ = :sys.get_state(queue)
    :ok
  end

  defp last_prompt(sink), do: sink |> Agent.get(& &1) |> List.first()

  test "an active goal with no focus is driven with a focus-first nudge" do
    orch = create_orch()
    {:ok, _} = Ledgers.upsert_goal(orch.id, %{goal: "ship it", definition_of_done: "green"})
    sink = start_supervised!({Agent, fn -> [] end}, id: :sink)
    queue = queue_capturing(orch.id, sink)

    tick(queue)

    prompt = last_prompt(sink)
    assert prompt =~ "FOCUS FIRST"
    assert prompt =~ "set_focus"
  end

  test "once a focus is set, the drive prompt surfaces it (not the nudge)" do
    orch = create_orch()
    {:ok, _} = Ledgers.upsert_goal(orch.id, %{goal: "ship it", definition_of_done: "green"})
    {:ok, _} = Ledgers.set_focus(orch.id, "land the focus gate")
    sink = start_supervised!({Agent, fn -> [] end}, id: :sink)
    queue = queue_capturing(orch.id, sink)

    tick(queue)

    prompt = last_prompt(sink)
    refute prompt =~ "FOCUS FIRST"
    assert prompt =~ "AUTONOMOUS DRIVE"
    assert prompt =~ "land the focus gate"
  end
end
