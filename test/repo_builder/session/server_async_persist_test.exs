defmodule RepoBuilder.Session.ServerAsyncPersistTest do
  @moduledoc """
  Persistence is off the dispatch hot path (issue hot-path-writes Part A): a slow
  `agent_logs` insert no longer head-of-line-blocks the per-agent event stream.

  We artificially slow every `agent_logs` INSERT for THIS session (via a scoped Ecto
  query telemetry handler) and assert the per-agent `"agent:<id>:events"` stream still
  delivers the terminal `Done` promptly — while the global `console:events` feed (which
  is emitted from the async writer AFTER the insert) is provably still pending at that
  moment, then lands later carrying the durable `log_no`.
  """
  use RepoBuilder.SessionCase, async: false

  alias RepoBuilder.{Agents, Dashboard, Session}

  defp uniq, do: System.unique_integer([:positive])

  # Slow only THIS session's agent_logs inserts so parallel work is unaffected.
  defp slow_agent_logs_inserts(session_id, ms) do
    handler_id = {__MODULE__, session_id}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:repo_builder, :repo, :query],
      fn _event, _measure, meta, _config ->
        query = meta[:query] || ""

        if is_binary(query) and String.contains?(query, "agent_logs") and
             String.starts_with?(query, "INSERT") and
             Enum.any?(meta[:params] || [], &(&1 == session_id)) do
          send(test_pid, :agent_logs_insert)
          Process.sleep(ms)
        end
      end,
      nil
    )

    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  test "the per-agent stream is not head-of-line-blocked by a slow insert" do
    {:ok, agent} =
      Agents.create_agent(%{name: "w-#{uniq()}", harness: "fake", provider: "anthropic"})

    agent_id = "feed-#{uniq()}"
    session_id = "sess-#{uniq()}"

    :ok = slow_agent_logs_inserts(session_id, 150)
    :ok = subscribe(agent_id)
    :ok = Dashboard.subscribe_events()

    {:ok, _pid} =
      Session.Supervisor.start_session(
        agent_id: agent_id,
        agent_db_id: agent.id,
        session_id: session_id,
        harness: "fake",
        prompt: "hi",
        model: "fake-model-1"
      )

    # The per-agent topic delivers the terminal Done quickly — it is broadcast
    # synchronously in dispatch, never waiting on the (now async, slowed) insert.
    assert_receive {:harness_event, %Event.Done{}}, 2_000

    # At this instant the global feed's Done is provably still pending: it is emitted
    # by the writer only AFTER the slowed insert chain. This is the head-of-line
    # decoupling — the per-agent stream led the persistence-gated feed.
    refute_received {:agent_event, ^agent_id, %Event.Done{}, _log_no}

    # Once the insert completes, the global feed lands carrying the durable log_no.
    assert_receive {:agent_event, ^agent_id, %Event.Done{}, log_no}, 5_000
    assert is_integer(log_no) and log_no > 0
  end
end
