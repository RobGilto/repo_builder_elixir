defmodule RepoBuilder.CostCenterProjectSpendTest do
  @moduledoc """
  Per-project cost attribution + reporting + clear/restore (issue per-project-cost-tracking):
  `scope_spend(:project, ...)`, `project_spend/2`, `project_period_spend/2`, and the
  per-project hide/release accounting in `Logs`.
  """
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.{Agents, CostCenter, Logs, Projects}
  alias RepoBuilder.Logs.{AgentLog, Usage}
  alias RepoBuilder.Repo

  defp uniq, do: System.unique_integer([:positive])

  defp project_fixture do
    {:ok, project} =
      Projects.create_project(%{"name" => "proj-#{uniq()}", "root_path" => "/tmp/p-#{uniq()}"})

    project
  end

  defp agent_id do
    {:ok, agent} =
      Agents.create_agent(%{name: "agent-#{uniq()}", harness: "claude", provider: :anthropic})

    agent.id
  end

  defp cost_row(opts) do
    at = Keyword.get(opts, :at, DateTime.utc_now())

    Repo.insert!(%AgentLog{
      agent_id: agent_id(),
      project_id: Keyword.get(opts, :project_id),
      session_id: "s-#{uniq()}",
      event_type: :usage,
      harness: Keyword.get(opts, :harness, "claude"),
      provider: Keyword.get(opts, :provider, "anthropic"),
      model: Keyword.get(opts, :model, "claude-sonnet-4-6"),
      hidden: Keyword.get(opts, :hidden, false),
      usage: %Usage{
        input_tokens: opts[:input] || 100,
        output_tokens: opts[:output] || 50,
        cost_usd: Keyword.fetch!(opts, :cost)
      },
      inserted_at: at,
      updated_at: at
    })
  end

  describe "scope_spend(:project, ...)" do
    test "isolates one project's spend from another's and excludes unscoped rows" do
      a = project_fixture()
      b = project_fixture()

      cost_row(project_id: a.id, cost: Decimal.new("1.50"))
      cost_row(project_id: a.id, cost: Decimal.new("2.50"))
      cost_row(project_id: b.id, cost: Decimal.new("9.00"))
      # Unscoped (NULL) row — counts globally, never for a project.
      cost_row(project_id: nil, cost: Decimal.new("99.00"))

      assert Decimal.equal?(CostCenter.scope_spend(:project, a.id, nil), Decimal.new("4.00"))
      assert Decimal.equal?(CostCenter.scope_spend(:project, b.id, nil), Decimal.new("9.00"))
    end
  end

  describe "project_spend/2" do
    test "returns lifetime total, by-model rows, and event count for the project" do
      a = project_fixture()
      cost_row(project_id: a.id, cost: Decimal.new("1.00"), model: "claude-sonnet-4-6")
      cost_row(project_id: a.id, cost: Decimal.new("3.00"), model: "claude-opus-4-8")
      cost_row(project_id: a.id, cost: Decimal.new("1.00"), model: "claude-sonnet-4-6")

      report = CostCenter.project_spend(a.id)

      assert Decimal.equal?(report.total_usd, Decimal.new("5.00"))
      assert report.event_count == 3
      assert length(report.by_model) == 2
    end

    test "an empty project reports a zero total and no rows" do
      report = CostCenter.project_spend(project_fixture().id)
      assert Decimal.equal?(report.total_usd, Decimal.new(0))
      assert report.by_model == []
      assert report.event_count == 0
    end
  end

  describe "clear / restore per project" do
    test "hide excludes rows from the display total; restore brings them back" do
      a = project_fixture()
      b = project_fixture()
      cost_row(project_id: a.id, cost: Decimal.new("4.00"))
      cost_row(project_id: b.id, cost: Decimal.new("7.00"))

      assert Logs.hide_logs_for_project(a.id) == 1

      # Display total (hidden excluded) drops to zero; true-money (include_hidden) is intact.
      assert Decimal.equal?(CostCenter.project_spend(a.id).total_usd, Decimal.new(0))

      assert Decimal.equal?(
               CostCenter.project_spend(a.id, include_hidden?: true).total_usd,
               Decimal.new("4.00")
             )

      # Project B is untouched by A's clear.
      assert Decimal.equal?(CostCenter.project_spend(b.id).total_usd, Decimal.new("7.00"))

      assert Logs.release_hidden_logs_for_project(a.id) == 1
      assert Decimal.equal?(CostCenter.project_spend(a.id).total_usd, Decimal.new("4.00"))
    end
  end
end
