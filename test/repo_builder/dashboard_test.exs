defmodule RepoBuilder.DashboardTest do
  use ExUnit.Case, async: true

  alias RepoBuilder.Dashboard
  alias RepoBuilder.Harness.Event

  describe "global console event feed (console:events)" do
    test "broadcast_event/2 delivers {:agent_event, id, %Event{}} to a subscriber" do
      :ok = Dashboard.subscribe_events()

      event = %Event.TextDelta{harness: :fake, text: "hello-console"}
      :ok = Dashboard.broadcast_event("agent-123", event)

      assert_receive {:agent_event, "agent-123", %Event.TextDelta{text: "hello-console"}, _log_no}
    end

    test "the lanes topic and the events topic are independent" do
      :ok = Dashboard.subscribe_events()

      # A lane broadcast must NOT arrive on the events feed.
      :ok =
        Dashboard.broadcast_lane(%{
          id: "agent:x",
          kind: :agent,
          label: "x",
          status: :running,
          harness: "fake"
        })

      refute_receive {:agent_event, _id, _event, _log_no}, 100
    end
  end
end
