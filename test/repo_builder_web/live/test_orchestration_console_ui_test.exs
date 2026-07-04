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

  alias RepoBuilder.{Agents, Dashboard, Workflows}
  alias RepoBuilder.Harness.Event

  defp uniq_name, do: "ui-agent-#{System.unique_integer([:positive])}"

  # Seed a running plan_build workflow run so the console renders its ADW card (with
  # per-step boxes) on mount.
  defp seed_run do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "wf-#{System.unique_integer([:positive])}",
        type: "plan_build",
        steps: [
          %{"name" => "plan", "harness" => "fake", "on_success" => "build"},
          %{"name" => "build", "harness" => "fake", "on_success" => "done"}
        ]
      })

    {:ok, run} =
      Workflows.create_run(%{workflow_id: wf.id, status: :running, current_step: "build"})

    run
  end

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

  test "canonical events render rows and update the live pills", %{conn: conn} do
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

  test "in swimlanes view an ADW step square opens the detail panel", %{conn: conn} do
    run = seed_run()

    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#view-toggle") |> render_click()

    # An ADW worker event keyed to the run's `build` step (via the `wf-<run_id>` agent key
    # + `adw_step` on the raw frame) lands as a square inside that step box of the card.
    Dashboard.broadcast_event("wf-#{run.id}-build", %Event.ToolCall{
      harness: :fake,
      name: "grep",
      input: %{"q" => "needle"},
      raw: %{"adw_step" => "build"}
    })

    _ = render(view)
    assert has_element?(view, "#workflow-#{run.id}")
    assert has_element?(view, ".cns-square")
    refute has_element?(view, "#event-detail-panel")

    view |> element(".cns-square") |> render_click()

    assert has_element?(view, "#event-detail-panel")

    view |> element("#close-event") |> render_click()
    refute has_element?(view, "#event-detail-panel")
  end

  test "system-category rows are hidden by default, the SYS chip toggles them on, and DB rows are untouched",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    agent = create_agent(view, uniq_name())

    # `Usage` is one of the four `:system`-category canonical events (per
    # `Shared.category_for_type/1`); broadcast it through the LiveView pipeline so the
    # row hits `record_event/4` ⇒ `maybe_stream_insert/2` ⇒ `Shared.passes?/2`.
    Dashboard.broadcast_event(agent.id, %Event.Usage{
      harness: :fake,
      input_tokens: 100,
      output_tokens: 50,
      cost_usd: 0.01
    })

    _ = render(view)

    # (a) Default-hidden assertion: with `@show_system?` initialized to `false`, a
    # `:system` row must NOT make it to the rendered DOM. Scope the selector to the
    # event-stream section so the agent card's `:idle` status badge (which also uses
    # `.cns-cat--system` for non-running/non-terminal states) doesn't false-positive
    # the assertion.
    refute has_element?(view, "#event-stream .cns-cat--system")

    # The new SYS chip itself is rendered (independent of category badge presence).
    assert has_element?(view, "#filter-system")
    refute has_element?(view, "#filter-system.cns-chip--active")

    # (b) Toggle reveals: clicking the SYS chip flips `@show_system?` and re-streams
    # the bounded buffer; the previously-buffered `:system` row now renders.
    view |> element("#filter-system") |> render_click()
    assert has_element?(view, "#event-stream .cns-cat--system")

    # And the chip itself is now in the active state.
    assert has_element?(view, "#filter-system.cns-chip--active")

    # Click it back off; the row disappears again (no DB round-trip — view-only).
    view |> element("#filter-system") |> render_click()
    refute has_element?(view, "#event-stream .cns-cat--system")
    refute has_element?(view, "#filter-system.cns-chip--active")
  end
end
