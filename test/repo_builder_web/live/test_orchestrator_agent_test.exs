defmodule RepoBuilderWeb.TestOrchestratorAgentTest do
  @moduledoc """
  LiveView integration for the orchestrator brain (issue-c): submitting a prompt
  with NO agent selected starts the default orchestrator (no "select an agent"
  flash), renders its reply as chat, and the worker it spawns appears in the rail
  roster — all over the keyless Fake harness, asserted via `console:events`.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Dashboard

  # Drain spawned orchestrator/worker sessions before the sandbox owner exits.
  setup do
    on_exit(&drain_sessions/0)
    :ok
  end

  test "a prompt with no agent selected runs the orchestrator and spawns a worker", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    :ok = Dashboard.subscribe_events()

    # The default orchestrator is created model-less (operator picks one); give it a
    # model so the turn clears the `:no_model_selected` gate.
    {:ok, orch} = RepoBuilder.Orchestrators.get_or_create_default()
    {:ok, _} = RepoBuilder.Orchestrators.set_model(orch.id, "fake-model")

    html = run_via_command(view, "build me a thing")

    # (a) The hard gate is gone — no "select an agent" flash.
    refute html =~ "Select an agent"

    # (d) The orchestrator's events and the spawned worker broadcast on console:events.
    assert_receive {:agent_event, agent_id, %RepoBuilder.Harness.Event.TextDelta{}, _seq_no},
                   5_000

    assert String.starts_with?(agent_id, "orch-")
    assert_receive {:agent_created, worker}, 5_000

    # (b) The orchestrator's reply renders as a chat bubble.
    assert wait_render(view, "spin up a worker")

    # (c) The spawned worker appears in the rail roster.
    assert wait_render(view, worker.name)
  end

  test "a single agent filter still uses the manual single-agent run (fallback intact)", %{
    conn: conn
  } do
    {:ok, agent} =
      RepoBuilder.Agents.create_agent(%{
        name: "manual-#{System.unique_integer([:positive])}",
        harness: "fake",
        provider: :anthropic
      })

    {:ok, view, _html} = live(conn, "/")
    # A lone active agent filter is the routing selection (id-based, mirrors a card click).
    render_click(view, "toggle_agent_filter", %{"id" => agent.id})

    html = run_via_command(view, "run directly")

    refute html =~ "Select an agent"
  end

  # The ⌘K command modal is always in the DOM (shown/hidden client-side); just
  # submit its form to drive the orchestrator.
  defp run_via_command(view, text) do
    view
    |> form("#command-form", command: text)
    |> render_submit()
  end

  defp drain_sessions(attempts \\ 150) do
    case DynamicSupervisor.count_children(RepoBuilder.SessionSupervisor) do
      %{active: 0} -> :ok
      _ when attempts > 0 -> Process.sleep(20) && drain_sessions(attempts - 1)
      _ -> :ok
    end
  end

  defp wait_render(view, substring, attempts \\ 150) do
    cond do
      render(view) =~ substring -> true
      attempts > 0 -> Process.sleep(20) && wait_render(view, substring, attempts - 1)
      true -> false
    end
  end
end
