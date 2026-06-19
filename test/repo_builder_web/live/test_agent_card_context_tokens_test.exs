defmodule RepoBuilderWeb.AgentCardContextTokensTest do
  @moduledoc """
  Regression test for the agent-card context-window bar + counters (issue-per-agent
  token/context): the CONTEXT WINDOW number/bar must reflect the latest persisted
  `usage` row's *prompt* occupancy — `input + cache_read + cache_creation` — and the
  per-category counters must be seeded from persisted logs on mount/reconnect, not
  only from live events. `cache_read` dominates a resumed Claude prompt, so counting
  only `input+output` left the bar effectively dead.

  `async: false` so the shared Ecto sandbox reaches the connected LiveView process.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Agents, Logs}
  alias RepoBuilder.Harness.Event

  defp persist(event, agent_id),
    do: {:ok, _} = Logs.persist_event(event, %{agent_id: agent_id, session_id: "s"})

  test "card shows context kTok/bar incl. cache tokens and non-zero counters from backfill",
       %{conn: conn} do
    {:ok, agent} =
      Agents.create_agent(%{
        name: "w-#{System.unique_integer([:positive])}",
        harness: "fake",
        provider: "anthropic"
      })

    # Latest usage row: input 54 + cache_read 160_059 + cache_creation 32_758 = 192_871
    # (output 1_646 is excluded — it is the reply, not prompt occupancy). ~96% of 200k.
    persist(
      %Event.Usage{
        harness: :fake,
        input_tokens: 10,
        output_tokens: 5,
        cache_read: 100,
        cache_creation: 0
      },
      agent.id
    )

    persist(
      %Event.Usage{
        harness: :fake,
        input_tokens: 54,
        output_tokens: 1_646,
        cache_read: 160_059,
        cache_creation: 32_758
      },
      agent.id
    )

    # Counter-feeding rows: 2 responses, 1 thinking, tool_call + tool_result (2 tools),
    # 1 status (hook).
    persist(%Event.TextDelta{harness: :fake, text: "a", thinking?: false}, agent.id)
    persist(%Event.TextDelta{harness: :fake, text: "b", thinking?: false}, agent.id)
    persist(%Event.TextDelta{harness: :fake, text: "t", thinking?: true}, agent.id)
    persist(%Event.ToolCall{harness: :fake, name: "read_file", input: %{}}, agent.id)
    persist(%Event.ToolResult{harness: :fake, content: "ok"}, agent.id)
    persist(%Event.Status{harness: :fake, kind: :retry, detail: %{}}, agent.id)

    {:ok, view, _html} = live(conn, ~p"/")

    card = element(view, "#agent-#{agent.id}") |> render()

    # 192_871 tokens → 192k / 200k, bar ~96%.
    assert card =~ "192k / 200k"
    assert card =~ "width: 96%"

    # Counters seeded from persisted logs.
    assert card =~ "💬 2"
    assert card =~ "🛠️ 2"
    assert card =~ "🪝 1"
    assert card =~ "🧠 1"
  end
end
