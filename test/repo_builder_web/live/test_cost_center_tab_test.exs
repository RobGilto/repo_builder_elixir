defmodule RepoBuilderWeb.TestCostCenterTabTest do
  @moduledoc """
  Integration test for the Cost Center settings tab (issue-cost-center). Opens the
  settings modal, switches to the Cost Center tab via the existing
  `select_settings_tab` mechanism, and asserts the rollup table + editable price catalog
  render — including the `est.` marker on an unpriced-but-catalog-priced dimension — then
  drives a price upsert and a delete and asserts the catalog reflects each change.

  `async: false` so the shared Ecto sandbox reaches the LiveView process.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Agents, CostCenter}
  alias RepoBuilder.Logs.{AgentLog, Usage}
  alias RepoBuilder.Repo

  defp uniq, do: System.unique_integer([:positive])

  defp agent_fixture do
    {:ok, agent} =
      Agents.create_agent(%{name: "agent-#{uniq()}", harness: "claude", provider: :anthropic})

    agent
  end

  defp log_fixture(agent, opts) do
    Repo.insert!(%AgentLog{
      agent_id: agent.id,
      session_id: "s-#{uniq()}",
      event_type: :usage,
      harness: Keyword.fetch!(opts, :harness),
      provider: opts[:provider],
      model: opts[:model],
      usage: %Usage{
        input_tokens: opts[:input] || 0,
        output_tokens: opts[:output] || 0,
        cost_usd: opts[:cost]
      },
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    })
  end

  defp open_cost_center(view) do
    render_click(view, "select_settings_tab", %{"tab" => "cost_center"})
  end

  test "renders the rollup + catalog, and upserts/deletes a price", %{conn: conn} do
    {:ok, _} =
      CostCenter.upsert_price(%{
        harness: "pi",
        provider: "zai",
        model: "glm-4.6",
        output_price_per_mtok: "2.0"
      })

    agent = agent_fixture()

    log_fixture(agent,
      harness: "claude",
      provider: "anthropic",
      model: "claude-opus-4-8",
      input: 1000,
      output: 500,
      cost: Decimal.new("0.25")
    )

    # Unpriced row whose catalog entry yields an estimate (the `est.` marker).
    log_fixture(agent,
      harness: "pi",
      provider: "zai",
      model: "glm-4.6",
      input: 500_000,
      output: 500_000,
      cost: nil
    )

    {:ok, view, _html} = live(conn, "/")

    html = open_cost_center(view)

    assert has_element?(view, "#cost-rollup-table")
    assert html =~ "claude-opus-4-8"
    assert html =~ "glm-4.6"
    # The estimate marker on the unpriced pi row.
    assert html =~ "est."

    assert has_element?(view, "#price-catalog-table")
    assert has_element?(view, "#price-form")

    # Upsert a brand-new catalog price and assert the row appears.
    view
    |> form("#price-form", %{
      "model_price" => %{
        "harness" => "pi",
        "provider" => "openai",
        "model" => "gpt-5",
        "input_price_per_mtok" => "1.25",
        "output_price_per_mtok" => "10.0"
      }
    })
    |> render_submit()

    assert has_element?(view, "#price-catalog-table", "gpt-5")
    saved = CostCenter.get_price("pi", "openai", "gpt-5")
    assert saved.source == :manual

    # Delete it and assert removal.
    render_click(view, "delete_price", %{"id" => saved.id})
    refute has_element?(view, "#price-row-#{saved.id}")
    assert CostCenter.get_price("pi", "openai", "gpt-5") == nil
  end
end
