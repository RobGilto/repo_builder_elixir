defmodule RepoBuilder.LogsRollupsTest do
  @moduledoc """
  Per-agent observability rollups (issue-per-agent token/context):

    * `context_tokens_by_agent/0` — the latest `usage` row's prompt occupancy
      (`input + cache_read + cache_creation`), cache tokens included.
    * `event_counts_by_agent/0` — per-agent counts mapped to the four card counters,
      mirroring the live `bump_counter` category derivation.
  """
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.Agents
  alias RepoBuilder.Harness.Event
  alias RepoBuilder.Logs

  defp agent_fixture do
    {:ok, agent} =
      Agents.create_agent(%{
        name: "w-#{System.unique_integer([:positive])}",
        harness: "fake",
        provider: "anthropic"
      })

    agent
  end

  defp persist(event, agent_id),
    do: {:ok, _} = Logs.persist_event(event, %{agent_id: agent_id, session_id: "s"})

  describe "context_size/1" do
    test "sums input + cache tokens, excludes output, nil-safe" do
      assert Logs.context_size(%RepoBuilder.Logs.Usage{
               input_tokens: 54,
               output_tokens: 1_646,
               cache_read: 160_059,
               cache_creation: 32_758
             }) == 192_871

      assert Logs.context_size(%RepoBuilder.Logs.Usage{input_tokens: 10}) == 10
      assert Logs.context_size(nil) == 0
    end
  end

  describe "context_tokens_by_agent/0" do
    test "returns the latest usage row's context size incl. cache, per agent" do
      agent = agent_fixture()

      persist(
        %Event.Usage{harness: :fake, input_tokens: 5, output_tokens: 1, cache_read: 100},
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

      assert Logs.context_tokens_by_agent()[agent.id] == 192_871
    end

    test "an agent with no usage rows is absent" do
      agent = agent_fixture()
      persist(%Event.TextDelta{harness: :fake, text: "x", thinking?: false}, agent.id)

      refute Map.has_key?(Logs.context_tokens_by_agent(), agent.id)
    end
  end

  describe "event_counts_by_agent/0" do
    test "maps event types to the four counter keys like the live path" do
      agent = agent_fixture()

      persist(%Event.TextDelta{harness: :fake, text: "a", thinking?: false}, agent.id)
      persist(%Event.TextDelta{harness: :fake, text: "b", thinking?: false}, agent.id)
      persist(%Event.TextDelta{harness: :fake, text: "t", thinking?: true}, agent.id)
      persist(%Event.ToolCall{harness: :fake, name: "read_file", input: %{}}, agent.id)
      persist(%Event.ToolResult{harness: :fake, content: "ok"}, agent.id)
      persist(%Event.Status{harness: :fake, kind: :retry, detail: %{}}, agent.id)
      # Non-counter rows must not contribute.
      persist(%Event.Usage{harness: :fake, input_tokens: 1, output_tokens: 1}, agent.id)

      assert Logs.event_counts_by_agent()[agent.id] == %{
               responses: 2,
               tools: 2,
               hooks: 1,
               thinking: 1
             }
    end

    test "an agent with no counted rows is absent" do
      agent = agent_fixture()
      persist(%Event.Usage{harness: :fake, input_tokens: 1, output_tokens: 1}, agent.id)

      refute Map.has_key?(Logs.event_counts_by_agent(), agent.id)
    end
  end
end
