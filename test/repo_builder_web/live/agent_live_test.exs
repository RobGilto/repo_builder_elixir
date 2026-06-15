defmodule RepoBuilderWeb.AgentLiveTest do
  # async: false so the shared Ecto sandbox reaches the spawned Session.Server.
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Agents, Logs}
  alias RepoBuilder.Harness.Event

  @topic_prefix "agent:"

  defp broadcast(agent_id, event) do
    Phoenix.PubSub.broadcast(
      RepoBuilder.PubSub,
      @topic_prefix <> agent_id <> ":events",
      {:harness_event, event}
    )
  end

  test "mounts and renders the controls", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/agents/demo")
    assert html =~ "Agent"
    assert html =~ "demo"
    assert html =~ "Start"
    assert html =~ "Interrupt"
  end

  test "renders a stream entry for every broadcast canonical variant", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/agents/render-test")

    broadcast("render-test", %Event.SessionStarted{harness: :fake, session_id: "sess-xyz"})
    broadcast("render-test", %Event.TextDelta{harness: :fake, text: "hello-text"})

    broadcast("render-test", %Event.TextDelta{
      harness: :fake,
      text: "deep-reasoning",
      thinking?: true
    })

    broadcast("render-test", %Event.ToolCall{harness: :fake, name: "bash-tool", input: %{}})
    broadcast("render-test", %Event.ToolResult{harness: :fake, content: "tool-output"})
    broadcast("render-test", %Event.Usage{harness: :fake, input_tokens: 7, output_tokens: 3})
    broadcast("render-test", %Event.Status{harness: :fake, kind: :rate_limit})
    broadcast("render-test", %Event.Done{harness: :fake, ok: true, reason: :success})

    html = render(view)
    assert html =~ "sess-xyz"
    assert html =~ "hello-text"
    assert html =~ "deep-reasoning"
    assert html =~ "bash-tool"
    assert html =~ "tool-output"
    assert html =~ "in=7 out=3"
    assert html =~ "rate_limit"
    assert html =~ "done"
  end

  test "an Error event flips the status to failed", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/agents/err-test")
    broadcast("err-test", %Event.Error{harness: :fake, message: "boom", reason: :provider_error})
    assert render(view) =~ "failed"
  end

  test "the Start control invokes the supervisor (a real session starts and streams)", %{
    conn: conn
  } do
    # Subscribe the test process too, so we can deterministically observe that the
    # control actually started a live session (a real Fake session via the runtime).
    Phoenix.PubSub.subscribe(RepoBuilder.PubSub, "agent:start-test:events")
    {:ok, view, _html} = live(conn, ~p"/agents/start-test")

    render_click(view, "start")

    assert_receive {:harness_event, %Event.SessionStarted{}}, 2_000
    assert_receive {:harness_event, %Event.Done{}}, 2_000
  end

  test "the Interrupt control is a no-op when no session is live", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/agents/int-test")
    assert render_click(view, "interrupt")
  end

  test "a connected mount seeds the stream from persisted history (reconnect backfill)", %{
    conn: conn
  } do
    {:ok, agent} =
      Agents.create_agent(%{
        name: "live-#{System.unique_integer([:positive])}",
        harness: "fake",
        provider: :anthropic
      })

    {:ok, _} =
      Logs.persist_event(
        %Event.TextDelta{
          harness: :fake,
          text: "historic-line",
          raw: %{"type" => "text_delta", "text" => "historic-line"}
        },
        %{agent_id: agent.id, session_id: "s"}
      )

    {:ok, _view, html} = live(conn, ~p"/agents/#{agent.id}")
    assert html =~ "historic-line"
  end
end
