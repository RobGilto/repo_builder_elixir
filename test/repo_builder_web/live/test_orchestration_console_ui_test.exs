defmodule RepoBuilderWeb.TestOrchestrationConsoleUiTest do
  @moduledoc """
  Integration test for the rebuilt orchestration console UI (BUILD_PROMPT.md §9):
  header pills, view + command toggles, the rich agent rail, category-chip + search
  filtering, canonical-event → event row / chat bubble / tool card / cost+counter
  updates, and the swimlane square → event-detail-panel flow.

  Events are pushed deterministically onto the global `console:events` feed via
  `Dashboard.broadcast_event/2`; PubSub delivery to the LiveView is ordered before
  the subsequent `render/1` call, so no `Process.sleep` is needed. `async: false`
  matches the existing console test (shared Ecto sandbox).
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Agents, Dashboard}
  alias RepoBuilder.Harness.Event

  defp uniq_name, do: "ui-agent-#{System.unique_integer([:positive])}"

  # Seed an agent the way the orchestrator will at runtime: persist it, then announce
  # it on the console's `agent_created` seam so the LiveView adds it to the rail live.
  defp create_agent(view, name) do
    {:ok, agent} = Agents.create_agent(%{name: name, harness: "fake", provider: "anthropic"})
    send(view.pid, {:agent_created, agent})
    _ = render(view)
    agent
  end

  test "renders the header with all status pills + view/prompt toggles", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    for id <- ~w(#console-header #stat-active #stat-running #stat-logs #stat-ws #stat-cost
                 #view-toggle #prompt-toggle) do
      assert has_element?(view, id)
    end
  end

  test "the view toggle switches the center column between logs and swimlanes", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    # Both containers stay mounted; the logs view is shown first.
    assert has_element?(view, "#event-stream")
    assert has_element?(view, "#swimlanes.hidden")

    view |> element("#view-toggle") |> render_click()

    assert has_element?(view, "#swimlanes:not(.hidden)")
  end

  test "the command-input modal is always rendered (hidden) and the prompt toggle shows it client-side",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    # The modal lives in the DOM at all times (shown/hidden client-side via JS),
    # starting hidden — this is what makes focus-on-open reliable.
    assert has_element?(view, ~s(#command-input[style*="display:none"]))
    assert has_element?(view, "#command-textarea")

    # The prompt toggle carries the client-side show command targeting the modal.
    assert view |> element("#prompt-toggle") |> render() =~ "command-input"
  end

  test "a created agent renders a rich card with a status badge + context bar", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    agent = create_agent(view, uniq_name())

    assert has_element?(view, "#agent-#{agent.id}")
    assert has_element?(view, "#agent-#{agent.id} .cns-cat")
    assert has_element?(view, "#agent-#{agent.id} .cns-ctx-bar")
  end

  test "a category chip toggles its active class", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    # All four chips start active (default = everything shown).
    assert has_element?(view, "#filter-tool.cns-chip--active")

    view |> element("#filter-tool") |> render_click()

    refute has_element?(view, "#filter-tool.cns-chip--active")
  end

  test "canonical events render rows, chat bubbles, and update the live pills", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    agent = create_agent(view, uniq_name())

    broadcast = fn event -> Dashboard.broadcast_event(agent.id, event) end

    broadcast.(%Event.TextDelta{harness: :fake, text: "hello response", thinking?: false})
    broadcast.(%Event.TextDelta{harness: :fake, text: "deep thoughts", thinking?: true})
    broadcast.(%Event.ToolCall{harness: :fake, name: "bash", input: %{"cmd" => "ls"}})

    broadcast.(%Event.Usage{
      harness: :fake,
      input_tokens: 100,
      output_tokens: 50,
      cost_usd: 0.01
    })

    broadcast.(%Event.Done{harness: :fake, ok: true, reason: :success})

    # Force the LiveView to drain its mailbox (FIFO: the 5 broadcasts are processed
    # before this render's $gen_call), then assert on the resulting DOM.
    _ = render(view)

    # Event rows: a RESPONSE-category and a TOOL-category badge.
    assert has_element?(view, ".cns-cat--response")
    assert has_element?(view, ".cns-cat--tool")

    # Chat bubbles: a thinking bubble + a tool-use card.
    assert has_element?(view, ".cns-bubble--thinking")
    assert has_element?(view, ".cns-bubble--tool")

    # Stat pills: 5 events counted on both Logs and WS Events.
    assert has_element?(view, "#stat-logs", "5")
    assert has_element?(view, "#stat-ws", "5")

    # Cost pill updated from the priced Usage event.
    assert has_element?(view, "#stat-cost", "0.01")
  end

  test "search filtering re-streams only matching event rows", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    agent = create_agent(view, uniq_name())

    Dashboard.broadcast_event(agent.id, %Event.TextDelta{
      harness: :fake,
      text: "keepme alpha",
      thinking?: false
    })

    Dashboard.broadcast_event(agent.id, %Event.TextDelta{
      harness: :fake,
      text: "dropme beta",
      thinking?: false
    })

    _ = render(view)
    assert has_element?(view, ".cns-event-row__body", "keepme alpha")
    assert has_element?(view, ".cns-event-row__body", "dropme beta")

    view |> form("#search-form", %{"q" => "keepme"}) |> render_change()

    assert has_element?(view, ".cns-event-row__body", "keepme alpha")
    refute has_element?(view, ".cns-event-row__body", "dropme beta")
  end

  test "an invalid regex search does not crash, falling back to substring", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    agent = create_agent(view, uniq_name())

    Dashboard.broadcast_event(agent.id, %Event.TextDelta{
      harness: :fake,
      text: "pattern target",
      thinking?: false
    })

    _ = render(view)

    view |> element("#regex-toggle") |> render_click()
    # "[" is an invalid regex → substring fallback, must not crash.
    html = view |> form("#search-form", %{"q" => "[target"}) |> render_change()

    assert is_binary(html)
    assert has_element?(view, "#event-stream")
  end

  test "in swimlanes view an event square opens the detail panel", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#view-toggle") |> render_click()

    Dashboard.broadcast_event("worker-xyz", %Event.ToolCall{
      harness: :fake,
      name: "grep",
      input: %{"q" => "needle"}
    })

    _ = render(view)
    assert has_element?(view, ".cns-square")
    refute has_element?(view, "#event-detail-panel")

    view |> element(".cns-square") |> render_click()

    assert has_element?(view, "#event-detail-panel")

    view |> element("#close-event") |> render_click()
    refute has_element?(view, "#event-detail-panel")
  end
end
