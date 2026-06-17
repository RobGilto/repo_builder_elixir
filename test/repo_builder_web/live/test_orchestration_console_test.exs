defmodule RepoBuilderWeb.TestOrchestrationConsoleTest do
  @moduledoc """
  Integration test for the multi-layered orchestration console
  (BUILD_PROMPT.md §9): mount → create agent → select → run a `fake` session via
  the ⌘K command modal → assert streamed canonical events + stat updates → toggle
  view → route a prompt to the orchestrator.

  `async: false` so the shared Ecto sandbox reaches the spawned `Session.Server`
  and workflow `Runner`. The `fake` harness is resolved through the registry seam
  (§13) — it is already registered in `config/test.exs`, no per-test override
  needed.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Agents, Dashboard}
  alias RepoBuilder.Harness.Event

  defp uniq_name, do: "console-agent-#{System.unique_integer([:positive])}"

  # Seed an agent the way the orchestrator will at runtime: persist it, then announce
  # it on the console's `agent_created` seam so the LiveView adds it to the rail live.
  defp create_agent(view, name) do
    {:ok, agent} = Agents.create_agent(%{name: name, harness: "fake", provider: "anthropic"})
    send(view.pid, {:agent_created, agent})
    _ = render(view)
    agent
  end

  # The ⌘K command modal is the sole prompt input. Open it, then submit `text`
  # (routes to the orchestrator, or the selected agent if one is selected).
  # The command modal is always in the DOM (shown/hidden client-side), so we just
  # submit its form. Submitting routes to the orchestrator (or the selected agent).
  defp run_via_command(view, text) do
    view
    |> form("#command-form", command: text)
    |> render_submit()
  end

  test "mounts and renders the header, agent rail, and event stream regions", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ ~s(id="console-header")
    assert html =~ ~s(id="agent-rail")
    assert html =~ ~s(id="event-stream")
  end

  test "an agent_created broadcast adds a selectable rail item", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    name = uniq_name()
    agent = create_agent(view, name)

    assert agent
    assert has_element?(view, "#agent-#{agent.id}")
    assert render(view) =~ name
  end

  test "selecting an agent and running streams the canonical fake sequence + updates pills", %{
    conn: conn
  } do
    # Observe the global feed deterministically (no Process.sleep).
    :ok = Dashboard.subscribe_events()

    {:ok, view, _html} = live(conn, ~p"/")
    agent = create_agent(view, uniq_name())

    view |> element("#agent-#{agent.id}") |> render_click()

    run_via_command(view, "ship it")

    assert_receive {:agent_event, _id, %Event.SessionStarted{}}, 2_000
    assert_receive {:agent_event, _id, %Event.Done{ok: true}}, 2_000

    # The test process can observe the broadcasts a beat before the LiveView process
    # has handled them; wait until all 7 canned events are reflected (stat-logs pill)
    # before asserting the rendered stream — avoids racing the view's mailbox.
    assert wait_until(fn -> has_element?(view, "#stat-logs", "7") end)
    html = render(view)

    # The fake sequence: session_started → text_delta* → tool_call → tool_result → usage → done.
    assert html =~ "Hello"
    assert html =~ "world"
    assert html =~ "bash"
    assert html =~ "done"

    # Stat pills updated live: 7 canned events, 1 active agent.
    assert has_element?(view, "#stat-logs", "7")
    assert has_element?(view, "#stat-active", "1")
  end

  test "Done flips the agent's swimlane to succeeded in ADWS view", %{conn: conn} do
    :ok = Dashboard.subscribe_events()
    :ok = Dashboard.subscribe()

    {:ok, view, _html} = live(conn, ~p"/")
    agent = create_agent(view, uniq_name())

    view |> element("#agent-#{agent.id}") |> render_click()

    run_via_command(view, "ship it")

    assert_receive {:agent_event, _id, %Event.Done{ok: true}}, 2_000
    # The session also broadcasts a lane transition; wait for the terminal one so the
    # view has processed it before we render (no Process.sleep).
    assert_receive {:lane, %{id: "agent:" <> _, status: :succeeded}}, 2_000

    # Toggle to swimlanes; the agent lane (stable dom_id) shows the terminal status.
    view |> element("#view-toggle") |> render_click()
    html = render(view)

    assert html =~ ~s(id="swimlanes")
    assert html =~ "lane-agent:#{agent.id}"
    # The terminal lane broadcast may reach the LiveView process just after the test
    # process; poll the render so we observe the processed `succeeded` transition
    # rather than racing it.
    assert wait_render(view, "succeeded")
  end

  defp wait_render(view, substring, attempts \\ 100) do
    cond do
      render(view) =~ substring -> true
      attempts > 0 -> Process.sleep(20) && wait_render(view, substring, attempts - 1)
      true -> false
    end
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> true
      attempts > 0 -> Process.sleep(20) && wait_until(fun, attempts - 1)
      true -> false
    end
  end

  test "the LOGS/ADWS toggle switches the center column", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")

    # Both stream containers stay mounted (so stream rows are never dropped); the
    # toggle flips which one is visible, reflected by the toggle button's label.
    assert html =~ ~s(id="event-stream")
    assert html =~ ~s(id="swimlanes")
    assert has_element?(view, "#view-toggle", "LOGS")

    view |> element("#view-toggle") |> render_click()

    assert has_element?(view, "#view-toggle", "ADWS")
  end

  test "a prompt with no agent selected routes to the orchestrator (no select-an-agent gate)", %{
    conn: conn
  } do
    # issue-c: the human is no longer the orchestrator. A prompt with no agent
    # selected starts the default orchestrator brain instead of flashing an error.
    # (ADW launches now happen via the orchestrator's start_adw tool, not a form.)
    {:ok, view, _html} = live(conn, ~p"/")

    html = run_via_command(view, "hi")

    refute html =~ "Select an agent before running"
    # The prompt is echoed into the chat as the operator's message.
    assert html =~ "YOU"
  end
end
