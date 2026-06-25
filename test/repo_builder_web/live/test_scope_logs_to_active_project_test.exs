defmodule RepoBuilderWeb.TestScopeLogsToActiveProjectTest do
  @moduledoc """
  Integration test for scoping the log/event stream to the active project (see
  specs/issue-selecting-adw-a-sdlc_planner-scope-logs-to-active-project.md).

  Selecting a project re-scopes `#event-stream` to that project's bound orchestrator
  plus its worker agents (`agent.project_id` matches): events from other projects'
  agents disappear from the stream view (but stay in the buffer). A single
  `PROJECT ONLY` chip toggles back to the full unscoped feed, re-revealing the
  buffered rows with no reload.

  `async: false` so the shared Ecto sandbox reaches the LiveView process.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Agents, Orchestrators, Projects}
  alias RepoBuilder.Harness.Event

  defp uniq, do: System.unique_integer([:positive])

  defp project_fixture do
    n = uniq()

    {:ok, project} =
      Projects.create_project(%{"name" => "scope-#{n}", "root_path" => "/tmp/scope-#{n}"})

    project
  end

  # A worker bound to a project: the `project_id` binding the owned-key set relies on.
  defp worker_fixture(project_id) do
    {:ok, agent} =
      Agents.create_agent(%{
        name: "scope-worker-#{uniq()}",
        harness: "fake",
        provider: "anthropic",
        project_id: project_id
      })

    agent
  end

  # Feed the LiveView a finalized (non-partial) reasoning event keyed by an id, exactly
  # as the runtime does. It lands in the center stream under THINKING, keyed by that id,
  # so the owned-key predicate can match it. `log_no` is the durable persisted number.
  defp seed_row(view, id, text) do
    send(
      view.pid,
      {:agent_event, id, %Event.TextDelta{harness: :fake, text: text, thinking?: true}, nil}
    )

    _ = render(view)
    :ok
  end

  test "selecting a project scopes the stream to its orchestrator + workers; PROJECT ONLY toggles the full feed",
       %{conn: conn} do
    project_a = project_fixture()
    project_b = project_fixture()

    # Project A's bound orchestrator (its "brain"), plus a worker under each project.
    {:ok, orch_a} = Orchestrators.get_or_create_for_project(project_a.id)
    worker_a = worker_fixture(project_a.id)
    worker_b = worker_fixture(project_b.id)

    {:ok, view, _html} = live(conn, ~p"/")

    # Switch to project A: re-binds the orchestrator, re-scopes the roster, and applies
    # the project scope to the stream.
    render_change(view, "select_project", %{"project_id" => project_a.id})

    # Seed one row from each source: A's orchestrator, A's worker, and B's worker.
    seed_row(view, orch_a.id, "orch-a-row")
    seed_row(view, worker_a.id, "worker-a-row")
    seed_row(view, worker_b.id, "worker-b-row")

    # Scoped (default on): only project A's orchestrator + worker render; B's worker is
    # filtered out of the view (still buffered).
    assert has_element?(view, "#event-stream", "orch-a-row")
    assert has_element?(view, "#event-stream", "worker-a-row")
    refute has_element?(view, "#event-stream", "worker-b-row")

    # The PROJECT ONLY chip is present (a project is active) and active-styled.
    assert has_element?(view, "#project-scope.cns-chip--active")

    # Toggle scope off: the unscoped feed returns, re-revealing B's worker row with no
    # reload (it was never dropped from the buffer).
    view |> element("#project-scope") |> render_click()

    assert has_element?(view, "#event-stream", "orch-a-row")
    assert has_element?(view, "#event-stream", "worker-a-row")
    assert has_element?(view, "#event-stream", "worker-b-row")
    refute has_element?(view, "#project-scope.cns-chip--active")
  end
end
