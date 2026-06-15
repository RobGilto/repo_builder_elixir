defmodule RepoBuilderWeb.TestAgentCrudTest do
  @moduledoc """
  Integration test for full agent CRUD via the orchestration console
  (BUILD_PROMPT.md §9): create (with model/system_prompt) → edit → archive,
  asserting the rail updates live, that a run against an archived agent is
  blocked, and that the Cost pill is human-formatted (3 dp).

  `async: false` so the shared Ecto sandbox reaches the spawned `Session.Server`
  for the `fake` run that exercises the cost pill.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Agents, Dashboard}
  alias RepoBuilder.Harness.Event

  defp uniq_name, do: "crud-agent-#{System.unique_integer([:positive])}"

  defp create_agent(view, params) do
    view |> element("#show-new-agent") |> render_click()

    view
    |> form("#new-agent-form", agent: params)
    |> render_submit()

    Enum.find(Agents.list_agents(), &(&1.name == params.name))
  end

  test "create persists model/system_prompt and the rail shows the model badge", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    name = uniq_name()

    agent =
      create_agent(view, %{
        name: name,
        harness: "fake",
        provider: "anthropic",
        model: "claude-opus-4-8",
        system_prompt: "Be terse."
      })

    assert agent
    assert agent.model == "claude-opus-4-8"
    assert agent.system_prompt == "Be terse."

    html = render(view)
    assert html =~ name
    assert html =~ "claude-opus-4-8"
  end

  test "edit updates the agent name + model and the rail reflects it live", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    agent = create_agent(view, %{name: uniq_name(), harness: "fake", provider: "anthropic"})

    view |> element("#agent-row-#{agent.id} button", "Edit") |> render_click()

    new_name = uniq_name()

    view
    |> form("#edit-agent-form",
      agent: %{name: new_name, harness: "fake", provider: "anthropic", model: "gpt-5"}
    )
    |> render_submit()

    updated = Agents.get_agent(agent.id)
    assert updated.name == new_name
    assert updated.model == "gpt-5"

    html = render(view)
    assert html =~ new_name
    assert html =~ "gpt-5"
  end

  test "archive removes the rail item and excludes it from the default list", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    agent = create_agent(view, %{name: uniq_name(), harness: "fake", provider: "anthropic"})

    assert has_element?(view, "#agent-#{agent.id}")

    view |> element("#agent-row-#{agent.id} button", "Archive") |> render_click()

    refute has_element?(view, "#agent-#{agent.id}")
    refute Enum.any?(Agents.list_agents(), &(&1.id == agent.id))
    assert Enum.any?(Agents.list_agents(include_archived: true), &(&1.id == agent.id))
  end

  test "running against an archived agent flashes an error and starts no session", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    agent = create_agent(view, %{name: uniq_name(), harness: "fake", provider: "anthropic"})

    # Select it in the UI, then archive it out from under the launch target.
    view |> element("#agent-#{agent.id}") |> render_click()
    {:ok, archived} = Agents.archive_agent(Agents.get_agent(agent.id))
    assert archived.archived

    html =
      view
      |> form("#launch-form", launch: %{prompt: "go", harness: "fake", model: ""})
      |> render_submit()

    assert html =~ "no longer available"
  end

  test "the Cost pill renders a 3-dp dollar value after a fake run, and — when unpriced", %{
    conn: conn
  } do
    :ok = Dashboard.subscribe_events()

    {:ok, view, _html} = live(conn, ~p"/")

    # Unpriced before any run.
    assert render(view) =~ "—"

    agent = create_agent(view, %{name: uniq_name(), harness: "fake", provider: "anthropic"})
    view |> element("#agent-#{agent.id}") |> render_click()

    view
    |> form("#launch-form", launch: %{prompt: "ship it", harness: "fake", model: ""})
    |> render_submit()

    assert_receive {:agent_event, _id, %Event.Done{ok: true}}, 2_000

    html = render(view)
    # A human-formatted price: "$" followed by digits with exactly 3 decimal places,
    # NOT a raw 18-digit Decimal.
    assert html =~ ~r/\$\d+\.\d{3}\b/
    refute html =~ ~r/\$\d+\.\d{6,}/
  end
end
