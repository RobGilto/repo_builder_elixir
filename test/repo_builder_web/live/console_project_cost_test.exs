defmodule RepoBuilderWeb.ConsoleProjectCostTest do
  @moduledoc """
  LiveView tests for the per-project Cost panel (issue per-project-cost-tracking): the
  panel renders the active project's lifetime total + by-model rows, and the CLEAR /
  RESTORE controls soft-hide and reveal that project's cost rows.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Agents, Projects}
  alias RepoBuilder.Logs.{AgentLog, Usage}
  alias RepoBuilder.Repo

  defp uniq, do: System.unique_integer([:positive])

  defp project_fixture do
    {:ok, project} =
      Projects.create_project(%{"name" => "proj-#{uniq()}", "root_path" => "/tmp/p-#{uniq()}"})

    project
  end

  defp cost_row(project_id, cost) do
    {:ok, agent} =
      Agents.create_agent(%{name: "agent-#{uniq()}", harness: "claude", provider: :anthropic})

    Repo.insert!(%AgentLog{
      agent_id: agent.id,
      project_id: project_id,
      session_id: "s-#{uniq()}",
      event_type: :usage,
      harness: "claude",
      provider: "anthropic",
      model: "claude-sonnet-4-6",
      usage: %Usage{input_tokens: 100, output_tokens: 50, cost_usd: cost}
    })
  end

  defp open_project_cost_center(view, project_id) do
    render_hook(view, "select_project", %{"project_id" => project_id})
    view |> element(~s{button[phx-value-tab="cost_center"]}) |> render_click()
  end

  test "renders the active project's lifetime total and by-model rows", %{conn: conn} do
    project = project_fixture()
    cost_row(project.id, Decimal.new("2.50"))

    {:ok, view, _html} = live(conn, ~p"/")
    open_project_cost_center(view, project.id)

    assert has_element?(view, "#project-cost-panel")
    assert has_element?(view, "#project-cost-by-model")
    assert render(view) =~ "2.5"
  end

  test "CLEAR hides the project's cost rows and RESTORE brings them back", %{conn: conn} do
    project = project_fixture()
    cost_row(project.id, Decimal.new("4.00"))

    {:ok, view, _html} = live(conn, ~p"/")
    open_project_cost_center(view, project.id)

    # Clear: display total drops to zero, a restore control appears.
    view |> element("#project-cost-panel button", "Clear") |> render_click()
    assert has_element?(view, "#project-cost-panel button", "Restore")

    assert :sys.get_state(view.pid).socket.assigns.project_report.report.total_usd
           |> Decimal.equal?(0)

    # Restore: the spend reappears.
    view |> element("#project-cost-panel button", "Restore") |> render_click()

    assert :sys.get_state(view.pid).socket.assigns.project_report.report.total_usd
           |> Decimal.equal?(Decimal.new("4.00"))
  end
end
