defmodule RepoBuilderWeb.TestCostCenterSpendTest do
  @moduledoc """
  Integration test for the period-spend summary on the Cost Center tab
  (issue-cost-adw-periods): seeds priced logs across harnesses/providers — including a
  hidden/cleared row — opens Settings → Cost Center, and asserts the period sections render
  the per-harness and per-provider totals AND that the hidden row IS counted in period
  spend while the visibility-filtered all-time rollup still excludes it.

  `async: false` so the shared Ecto sandbox reaches the LiveView process.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Agents
  alias RepoBuilder.Logs.{AgentLog, Usage}
  alias RepoBuilder.Repo

  defp uniq, do: System.unique_integer([:positive])

  defp agent_fixture do
    {:ok, agent} =
      Agents.create_agent(%{name: "agent-#{uniq()}", harness: "claude", provider: :anthropic})

    agent
  end

  defp log_fixture(agent, opts) do
    now = DateTime.utc_now()

    Repo.insert!(%AgentLog{
      agent_id: agent.id,
      session_id: "s-#{uniq()}",
      event_type: :usage,
      harness: Keyword.fetch!(opts, :harness),
      provider: opts[:provider],
      model: opts[:model],
      hidden: Keyword.get(opts, :hidden, false),
      usage: %Usage{
        input_tokens: opts[:input] || 0,
        output_tokens: opts[:output] || 0,
        cost_usd: opts[:cost]
      },
      inserted_at: now,
      updated_at: now
    })
  end

  test "renders period breakdowns and counts hidden logs in spend", %{conn: conn} do
    agent = agent_fixture()

    # Visible claude/anthropic spend.
    log_fixture(agent,
      harness: "claude",
      provider: "anthropic",
      model: "claude-opus-4-8",
      cost: Decimal.new("1.50")
    )

    # Hidden/cleared zai spend — must still count toward period spend.
    log_fixture(agent,
      harness: "pi",
      provider: "zai",
      model: "glm-4.6",
      cost: Decimal.new("3.25"),
      hidden: true
    )

    {:ok, view, _html} = live(conn, "/")
    html = render_click(view, "select_settings_tab", %{"tab" => "cost_center"})

    # The three period sections render with both dimension breakdowns.
    assert has_element?(view, "#spend-today")
    assert has_element?(view, "#spend-week")
    assert has_element?(view, "#spend-month")
    assert has_element?(view, "#spend-today-harness")
    assert has_element?(view, "#spend-today-provider")

    # Hidden zai spend IS reflected in the accounting view (today's by-provider table).
    assert html =~ "zai"
    assert html =~ "$3.25"
    assert html =~ "anthropic"
    assert html =~ "$1.50"

    # The hidden zai row is NOT in the visibility-filtered all-time rollup table.
    refute has_element?(view, "#cost-rollup-table", "glm-4.6")
    assert has_element?(view, "#cost-rollup-table", "claude-opus-4-8")
  end
end
