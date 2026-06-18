defmodule RepoBuilder.Session.BroadcastFeedTest do
  @moduledoc """
  The additive `:broadcast_feed?` gate on the session runtime (issue-explain).

  With `broadcast_feed?: false` and no `agent_db_id`/`orchestrator_db_id`, a run
  stays private: it broadcasts on its per-agent topic but NOT on the global console
  feed, and writes no `agent_logs` row. The default (unset) keeps the feed.
  """
  use RepoBuilder.SessionCase, async: false

  alias RepoBuilder.{Dashboard, Logs, Session}

  test "broadcast_feed?: false keeps the per-agent topic but suppresses the global feed" do
    agent_id = "ephemeral-#{System.unique_integer([:positive])}"
    :ok = subscribe(agent_id)
    :ok = Dashboard.subscribe_events()

    {:ok, _pid} =
      Session.Supervisor.start_session(
        agent_id: agent_id,
        harness: "fake",
        prompt: "hi",
        model: "fake-model-1",
        broadcast_feed?: false
      )

    # Per-agent topic still carries the run's events.
    assert_receive {:harness_event, %Event.Done{}}, 5_000

    # The global console feed received nothing for this agent.
    refute_received {:agent_event, ^agent_id, _event, _seq_no}

    # And nothing was persisted for it.
    refute Enum.any?(Logs.list_recent_global(500, true), fn log ->
             log.session_id == agent_id or
               (is_binary(log.session_id) and String.contains?(log.session_id, agent_id))
           end)
  end

  test "default (broadcast_feed? unset) still reaches the global feed" do
    agent_id = "feed-#{System.unique_integer([:positive])}"
    :ok = Dashboard.subscribe_events()

    {:ok, _pid} =
      Session.Supervisor.start_session(
        agent_id: agent_id,
        harness: "fake",
        prompt: "hi",
        model: "fake-model-1"
      )

    assert_receive {:agent_event, ^agent_id, _event, _seq_no}, 5_000
  end
end
