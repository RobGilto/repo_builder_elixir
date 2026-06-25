defmodule RepoBuilder.Session.HoldingClassificationTest do
  @moduledoc """
  Session-runtime classification of a HOLDING terminal (issue
  holding-status-for-blocked-agents): a WORKER session whose terminal `%Event.Done{ok:
  true}` final text carries a holding signal is rewritten to `reason:
  :held_pending_input`, which must (a) broadcast a `:holding` swimlane lane (not
  `:succeeded`), (b) emit a `{:worker_terminal, info}` with `holding?: true`, and (c)
  reconcile the worker's persisted status to `:holding` (not `:idle`). An ordinary
  successful Done is unaffected (regression).

  Drives the Mock adapter to emit one terminal Done, mirroring the §6 runtime. `async:
  false` (shared sandbox + global Mox), per SessionCase.
  """
  use RepoBuilder.SessionCase, async: false

  import Mox

  alias RepoBuilder.{Agents, Dashboard, Orchestrators}
  alias RepoBuilder.Logs.Writer
  alias RepoBuilder.Session.Supervisor

  @mock RepoBuilder.Harness.Mock

  # Emit exactly one terminal Done frame whose final text the adapter carries through.
  defp stub_done(final_text) do
    stub(@mock, :command, fn _ ->
      {"printf", ["%s\n", ~s({"k":"done"})], [], %{harness: :mock}}
    end)

    stub(@mock, :normalize, fn
      %{"k" => "done"}, _ ->
        {:ok, [%Event.Done{harness: :mock, ok: true, reason: :success, final_text: final_text}]}

      _, _ ->
        :skip
    end)
  end

  defp create_worker(orchestrator_id) do
    {:ok, worker} =
      Agents.create_worker(orchestrator_id, %{
        "name" => "w-#{System.unique_integer([:positive])}",
        "harness" => "mock",
        "provider" => "anthropic",
        "model" => "mock-model",
        "session_id" => "sess-#{System.unique_integer([:positive])}"
      })

    worker
  end

  setup do
    register_harness("mock", @mock)
    {:ok, orch} = Orchestrators.get_or_create_default()
    :ok = Dashboard.subscribe()
    :ok = Dashboard.subscribe_orchestrator_workers(orch.id)
    %{orch: orch}
  end

  test "a worker Done whose final text holds → :holding lane, worker_terminal, :holding status",
       %{orch: orch} do
    worker = create_worker(orch.id)
    subscribe(worker.id)
    stub_done("I can't continue.\n:holding browser login required")

    {:ok, pid} =
      Supervisor.start_session(
        agent_id: worker.id,
        agent_db_id: worker.id,
        harness: "mock",
        prompt: "x"
      )

    ref = Process.monitor(pid)

    # The terminal event flowing on the per-agent topic is the rewritten holding Done.
    assert_receive {:harness_event, %Event.Done{reason: :held_pending_input, ok: true}}, 2_000

    # (a) the swimlane lane is :holding, NOT :succeeded.
    assert_receive {:lane, %{kind: :agent, status: :holding}}, 2_000

    # (b) the worker-terminal broadcast carries holding?: true + the reason.
    assert_receive {:worker_terminal,
                    %{holding?: true, holding_reason: "browser login required", ok?: true}},
                   2_000

    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000

    # (c) the persisted status reconciles to :holding (not :idle).
    :ok = Writer.sync(worker.id)
    assert Agents.get_agent(worker.id).status == :holding
  end

  test "an ordinary successful worker Done still yields :succeeded lane + :idle status", %{
    orch: orch
  } do
    worker = create_worker(orch.id)
    subscribe(worker.id)
    stub_done("All done. Summary: implemented the feature and tests pass.")

    {:ok, pid} =
      Supervisor.start_session(
        agent_id: worker.id,
        agent_db_id: worker.id,
        harness: "mock",
        prompt: "x"
      )

    ref = Process.monitor(pid)

    assert_receive {:harness_event, %Event.Done{reason: :success, ok: true}}, 2_000
    assert_receive {:lane, %{kind: :agent, status: :succeeded}}, 2_000
    assert_receive {:worker_terminal, %{holding?: false, ok?: true}}, 2_000
    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000

    :ok = Writer.sync(worker.id)
    assert Agents.get_agent(worker.id).status == :idle
  end
end
