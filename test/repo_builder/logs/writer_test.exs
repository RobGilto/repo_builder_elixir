defmodule RepoBuilder.Logs.WriterTest do
  @moduledoc """
  The async persistence writer (issue hot-path-writes Part A): `Logs.Writer.record/1`
  is a fire-and-forget cast that persists off the caller's hot path, broadcasts the
  durable `log_no` on the global feed on success, degrades to a `nil` `log_no` on a
  persist failure (never crashing), and keeps per-row FIFO ordering.
  """
  use RepoBuilder.DataCase, async: false

  alias RepoBuilder.{Agents, Dashboard}
  alias RepoBuilder.Harness.Event
  alias RepoBuilder.Logs.Writer

  defp uniq, do: System.unique_integer([:positive])

  defp agent_fixture do
    {:ok, agent} =
      Agents.create_agent(%{name: "w-#{uniq()}", harness: "fake", provider: "anthropic"})

    agent
  end

  defp record(opts) do
    Writer.record(%Writer.Record{
      event: Keyword.get(opts, :event, %Event.Done{harness: :fake, ok: true, reason: :success}),
      agent_id: Keyword.fetch!(opts, :agent_id),
      broadcast_feed?: Keyword.get(opts, :broadcast_feed?, true),
      persist: Keyword.get(opts, :persist)
    })
  end

  setup do
    :ok = Dashboard.subscribe_events()
    :ok
  end

  test "a successful persist broadcasts the durable log_no on the global feed" do
    agent = agent_fixture()
    feed_id = "feed-#{uniq()}"

    :ok = record(agent_id: feed_id, persist: {:agent, %{agent_id: agent.id, session_id: "s1"}})

    assert_receive {:agent_event, ^feed_id, %Event.Done{}, log_no}, 2_000
    assert is_integer(log_no) and log_no > 0
  end

  test "events for one row persist FIFO with strictly increasing log_no" do
    agent = agent_fixture()
    feed_id = "feed-#{uniq()}"
    ctx = {:agent, %{agent_id: agent.id, session_id: "s1"}}

    for _ <- 1..3, do: :ok = record(agent_id: feed_id, persist: ctx)

    assert_receive {:agent_event, ^feed_id, %Event.Done{}, a}, 2_000
    assert_receive {:agent_event, ^feed_id, %Event.Done{}, b}, 2_000
    assert_receive {:agent_event, ^feed_id, %Event.Done{}, c}, 2_000
    assert is_integer(a) and b > a and c > b
  end

  test "a persist failure degrades to a nil log_no without crashing the writer" do
    feed_id = "feed-#{uniq()}"
    # A random, non-existent agent FK → {:error, changeset} → nil log_no.
    bad = {:agent, %{agent_id: Ecto.UUID.generate(), session_id: "s1"}}

    :ok = record(agent_id: feed_id, persist: bad)
    assert_receive {:agent_event, ^feed_id, %Event.Done{}, log_no}, 2_000
    assert is_nil(log_no)

    # The writer is still alive and serving — a subsequent record still flows.
    feed_id2 = "feed-#{uniq()}"
    :ok = record(agent_id: feed_id2, persist: nil)
    assert_receive {:agent_event, ^feed_id2, %Event.Done{}, nil}, 2_000
  end

  test "broadcast_feed?: false suppresses the global feed broadcast" do
    feed_id = "feed-#{uniq()}"
    :ok = record(agent_id: feed_id, broadcast_feed?: false, persist: nil)
    refute_receive {:agent_event, ^feed_id, _event, _log_no}, 300
  end
end
