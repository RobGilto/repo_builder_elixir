defmodule RepoBuilderWeb.TestOrchestratorEventsInScopedLogTest do
  @moduledoc """
  Regression for the project-scope filter false-negative
  (issue-am-adw-noticing-sdlc_planner-orchestrator-events-missing-from-middle-log):
  the console mounts scoped to the default project (`project_scoped?: true`), and the
  active project's bound orchestrator broadcasts events keyed `"orch-<id>-<int>"` (live)
  — a format that does NOT equal the bare orchestrator UUID in `project_agent_keys`. The
  exact-string membership test in `project_pass?/2` therefore dropped every orchestrator
  row from the middle event-stream. The fix matches orchestrator ownership by the
  `"orch-<orchestrator_id>"` prefix.

  This test drives the live event path directly via `record_event/4` (the message the
  global feed delivers) and asserts the orchestrator row reaches the `#event-stream`
  region — while a worker row still passes and an UNRELATED project's orchestrator row is
  still excluded (guarding against an over-broad / fail-open regression).

  `async: false` so the shared Ecto sandbox reaches the LiveView process.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Agents, Orchestrators, Projects}
  alias RepoBuilder.Harness.Event

  defp uniq, do: System.unique_integer([:positive])

  defp error_event(marker) do
    %Event.Error{harness: :claude, message: marker, reason: :no_model_selected}
  end

  test "the active project's orchestrator events stream to the middle log; worker scoping and cross-project exclusion preserved",
       %{conn: conn} do
    # The earliest project is the mount default (`Projects.default_project/0`).
    home = project_fixture()

    {:ok, worker} =
      Agents.create_agent(%{
        "name" => "worker-#{uniq()}",
        "harness" => "claude",
        "provider" => "anthropic",
        "project_id" => home.id
      })

    # A second project with its own bound orchestrator — its events must stay excluded.
    other = project_fixture()

    {:ok, view, _html} = live(conn, ~p"/")

    # The mounted (active) project is the default/home project; resolve its bound brain.
    assert home.id == Projects.default_project().id
    assert {:ok, orch} = Orchestrators.get_or_create_for_project(home.id)
    assert {:ok, other_orch} = Orchestrators.get_or_create_for_project(other.id)
    assert other_orch.id != orch.id

    # 1. Active orchestrator event in the LIVE key format `"orch-<id>-<int>"` — the case
    #    the bug dropped. Must now appear in the middle stream.
    orch_marker = "ORCHMARK-#{uniq()}"
    orch_key = "orch-#{orch.id}-#{uniq()}"
    send(view.pid, {:agent_event, orch_key, error_event(orch_marker), nil})

    # 2. A worker event for the active project must still pass (worker scoping intact).
    worker_marker = "WORKERMARK-#{uniq()}"
    send(view.pid, {:agent_event, worker.id, error_event(worker_marker), nil})

    # 3. The unrelated project's orchestrator event must stay excluded (no fail-open).
    other_marker = "OTHERMARK-#{uniq()}"
    other_key = "orch-#{other_orch.id}-#{uniq()}"
    send(view.pid, {:agent_event, other_key, error_event(other_marker), nil})

    _html = render(view)

    assert has_element?(view, "#event-stream", orch_marker)
    assert has_element?(view, "#event-stream", worker_marker)
    refute has_element?(view, "#event-stream", other_marker)
  end

  defp project_fixture do
    n = uniq()

    {:ok, project} =
      Projects.create_project(%{"name" => "scoped-#{n}", "root_path" => "/tmp/scoped-#{n}"})

    project
  end
end
