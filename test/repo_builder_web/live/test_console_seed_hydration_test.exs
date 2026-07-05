defmodule RepoBuilderWeb.ConsoleSeedHydrationTest do
  @moduledoc """
  Regression tests for the ConsoleLive mount-seed optimization
  (specs/console-mount-seed-optimization.html).

  Phase 2: the batched workflow lookup in `seed_workflow_progress` must produce
  the same titles/types the per-run `get_workflow/1` loop produced (parity), and
  the merged `seed_costs` must reconcile the header/orchestrator badges exactly
  as the two separate seeds did.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Workflows

  defp seed_workflow(name) do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: name,
        type: "plan_build",
        steps: [
          %{"name" => "plan", "harness" => "fake", "on_success" => "build"},
          %{"name" => "build", "harness" => "fake", "on_success" => "done"}
        ]
      })

    wf
  end

  defp seed_run(workflow) do
    {:ok, run} =
      Workflows.create_run(%{workflow_id: workflow.id, status: :running, current_step: "plan"})

    run
  end

  describe "seed_workflow_progress batched lookup parity" do
    test "titles and types match the per-run lookup for runs across shared workflows",
         %{conn: conn} do
      # Human-friendly names (no machine-looking kebab/digit shape) so the title
      # resolution deterministically picks the workflow NAME, not the humanized type.
      wf_a = seed_workflow("Alpha Pipeline")
      wf_b = seed_workflow("Beta Pipeline")

      run_a1 = seed_run(wf_a)
      run_a2 = seed_run(wf_a)
      run_b = seed_run(wf_b)

      {:ok, lv, _html} = live(conn, ~p"/")
      state = :sys.get_state(lv.pid)
      progress = state.socket.assigns.workflow_progress

      # Every seeded run is present with the title/type its OWN workflow row carries —
      # exactly what the per-run Repo.get produced before the batch.
      for {run, wf} <- [{run_a1, wf_a}, {run_a2, wf_a}, {run_b, wf_b}] do
        view = Map.fetch!(progress, run.id)
        assert view.workflow_id == wf.id
        assert view.title == wf.name
        assert view.type == wf.type
      end
    end
  end

  describe "deferred :seed_history hydration (Phase 3)" do
    test "persisted history hydrates the stream and swimlane right after mount", %{conn: conn} do
      wf = seed_workflow("Gamma Pipeline")
      run = seed_run(wf)

      {:ok, lv, _html} = live(conn, ~p"/")

      # live/2 returns after mount; the :seed_history message was queued during mount
      # and is processed before this render/1 call round-trips (mailbox ordering) —
      # the standard sync point, mirroring PlanningLive's deferred-load tests.
      render(lv)

      state = :sys.get_state(lv.pid)
      assert Map.has_key?(state.socket.assigns.workflow_progress, run.id)
    end

    test "a live event arriving before hydration survives the backfill reset once persisted",
         %{conn: conn} do
      # The backfill reset is authoritative: rows re-enter from the DB. A row that was
      # persisted before :seed_history processes must be present after hydration.
      alias RepoBuilder.{Agents, Logs}
      alias RepoBuilder.Harness.Event

      {:ok, agent} =
        Agents.create_agent(%{
          name: "hydra-#{System.unique_integer([:positive])}",
          harness: "fake",
          provider: :anthropic
        })

      marker = "HYDRATE-MARK-#{System.unique_integer([:positive])}"

      {:ok, _log} =
        Logs.persist_event(
          %Event.TextDelta{harness: :fake, text: marker, raw: %{"text" => marker}},
          %{agent_id: agent.id, session_id: "s-#{agent.id}"}
        )

      {:ok, lv, _html} = live(conn, ~p"/")
      html = render(lv)

      assert html =~ marker
    end
  end

  describe "merged seed_costs" do
    test "cost and orchestrator_cost assigns are both present after mount", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")
      state = :sys.get_state(lv.pid)

      # Empty test DB: both badges are unpriced (nil), never Decimal-0 — preserving
      # the nil-vs-zero display contract the two separate seeds guaranteed.
      assert state.socket.assigns.cost == nil
      assert state.socket.assigns.orchestrator_cost == nil
    end
  end
end
