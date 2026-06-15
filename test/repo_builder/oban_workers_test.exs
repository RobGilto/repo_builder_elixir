defmodule RepoBuilder.ObanWorkersTest do
  use RepoBuilder.DataCase, async: false
  use Oban.Testing, repo: RepoBuilder.Repo

  alias RepoBuilder.{Webhooks, WorkflowEngine, Workflows}
  alias RepoBuilder.Workers.{CronTrigger, StepWorker, WorkflowResume}

  defp uniq, do: System.unique_integer([:positive])

  defp single_step_workflow(harness \\ "fake") do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "wf-#{uniq()}",
        steps: [
          %{
            "name" => "plan",
            "harness" => harness,
            "on_success" => "done",
            "on_failure" => "abort"
          }
        ]
      })

    wf
  end

  describe "StepWorker" do
    test "never-valid args return {:cancel, _} (no retry storm)" do
      assert {:cancel, :invalid_args} = perform_job(StepWorker, %{"bad" => "args"})

      assert {:cancel, :invalid_args} =
               perform_job(StepWorker, %{"workflow_run_id" => "not-a-uuid", "step_name" => "x"})
    end

    test "execute/2 on a finished run is an idempotent no-op" do
      wf = single_step_workflow()

      {:ok, run} =
        Workflows.create_run(%{workflow_id: wf.id, status: :succeeded, current_step: "plan"})

      assert :ok = StepWorker.execute(run.id, "plan")
    end

    test "enqueue/2 is deduped on {workflow_run_id, step_name}" do
      wf = single_step_workflow()

      {:ok, run} =
        Workflows.create_run(%{workflow_id: wf.id, status: :queued, current_step: "plan"})

      {:ok, _} = StepWorker.enqueue(run.id, "plan")
      {:ok, _} = StepWorker.enqueue(run.id, "plan")

      assert length(all_enqueued(worker: StepWorker)) == 1
    end

    test "a durable step executes via Oban and chains to completion" do
      wf = single_step_workflow("fake")

      {:ok, run} =
        Workflows.create_run(%{workflow_id: wf.id, status: :queued, current_step: "plan"})

      assert :ok = perform_job(StepWorker, %{"workflow_run_id" => run.id, "step_name" => "plan"})
      assert Workflows.get_run(run.id).status == :succeeded
    end
  end

  describe "WorkflowEngine.enqueue_workflow (durable trigger)" do
    test "creates the run and enqueues the first step" do
      wf = single_step_workflow()
      assert {:ok, run_id} = WorkflowEngine.enqueue_workflow(wf, %{"input" => "x"})

      assert Workflows.get_run(run_id).artifacts["input"] == "x"

      assert_enqueued(
        worker: StepWorker,
        args: %{"workflow_run_id" => run_id, "step_name" => "plan"}
      )
    end
  end

  describe "CronTrigger" do
    test "triggers a named workflow durably" do
      wf = single_step_workflow()
      assert :ok = CronTrigger.trigger(wf.name)
      assert_enqueued(worker: StepWorker, args: %{"step_name" => "plan"})
    end

    test "cancels on an unknown or missing workflow name" do
      assert {:cancel, :workflow_not_found} = CronTrigger.trigger("nope-#{uniq()}")
      assert {:cancel, :no_workflow_name} = CronTrigger.trigger(nil)
    end
  end

  describe "WorkflowResume (crash-resume reconciler)" do
    test "re-enqueues the current step for unfinished runs, idempotently" do
      wf = single_step_workflow()

      {:ok, running} =
        Workflows.create_run(%{workflow_id: wf.id, status: :running, current_step: "plan"})

      {:ok, _done} =
        Workflows.create_run(%{workflow_id: wf.id, status: :succeeded, current_step: "plan"})

      assert WorkflowResume.reconcile() == 1

      assert_enqueued(
        worker: StepWorker,
        args: %{"workflow_run_id" => running.id, "step_name" => "plan"}
      )

      # Running it again does not double-enqueue (unique dedup) — survives repeated cron fires.
      WorkflowResume.reconcile()
      assert length(all_enqueued(worker: StepWorker)) == 1
    end
  end

  describe "Webhooks (HMAC + timestamp replay protection)" do
    setup do
      wf = single_step_workflow()
      secret = Application.fetch_env!(:repo_builder, :webhooks)[:secret]
      %{workflow: wf, secret: secret}
    end

    defp signed(secret, payload, ts) do
      body = Jason.encode!(payload)
      {body, Webhooks.sign(secret, ts, body), ts}
    end

    test "a valid signed request durably triggers the workflow", %{workflow: wf, secret: secret} do
      ts = Integer.to_string(System.os_time(:second))
      {body, sig, ts} = signed(secret, %{"workflow_name" => wf.name, "inputs" => %{"x" => 1}}, ts)

      assert {:ok, run_id} = Webhooks.verify_and_trigger(body, sig, ts)
      assert_enqueued(worker: StepWorker, args: %{"workflow_run_id" => run_id})
    end

    test "a bad signature is rejected before any job is enqueued", %{workflow: wf} do
      ts = Integer.to_string(System.os_time(:second))
      body = Jason.encode!(%{"workflow_name" => wf.name})

      assert {:error, :bad_signature} = Webhooks.verify_and_trigger(body, "deadbeef", ts)
      assert all_enqueued(worker: StepWorker) == []
    end

    test "an expired (replayed) timestamp is rejected", %{workflow: wf, secret: secret} do
      old_ts = Integer.to_string(System.os_time(:second) - 10_000)
      {body, sig, old_ts} = signed(secret, %{"workflow_name" => wf.name}, old_ts)

      assert {:error, :expired} = Webhooks.verify_and_trigger(body, sig, old_ts)
      assert all_enqueued(worker: StepWorker) == []
    end

    test "an invalid JSON payload is rejected", %{secret: secret} do
      ts = Integer.to_string(System.os_time(:second))
      body = "not json {"
      sig = Webhooks.sign(secret, ts, body)

      assert {:error, :invalid_payload} = Webhooks.verify_and_trigger(body, sig, ts)
    end

    test "an unknown workflow name is rejected", %{secret: secret} do
      ts = Integer.to_string(System.os_time(:second))
      {body, sig, ts} = signed(secret, %{"workflow_name" => "missing-#{uniq()}"}, ts)

      assert {:error, :workflow_not_found} = Webhooks.verify_and_trigger(body, sig, ts)
    end
  end
end
