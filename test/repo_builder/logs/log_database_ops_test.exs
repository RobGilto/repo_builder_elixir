defmodule RepoBuilder.Logs.LogDatabaseOpsTest do
  @moduledoc """
  Context unit tests for the Log Database operations (issue-log-db-manager): filter-aware
  pagination (`query_agent_logs/3`, `count_agent_logs/1`), per-row visibility
  (`hide_logs/1`, `unhide_logs/1`), and hard delete (`purge_logs/1`, `purge_all_logs/0`).

  All DB access stays behind the `RepoBuilder.Logs` context (BUILD_PROMPT.md §8); the
  tests read effects back through the context, never `Repo` directly.
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

  # Persist `n` text_delta rows for one agent and return their ids (insertion order).
  defp seed(agent_id, n) do
    for i <- 1..n do
      {:ok, log} =
        Logs.persist_event(
          %Event.TextDelta{harness: :fake, text: "row-#{i}", thinking?: false},
          %{agent_id: agent_id, session_id: "s"}
        )

      log.id
    end
  end

  describe "query_agent_logs/3 + count_agent_logs/1" do
    test "filters by visibility and counts per filter" do
      agent = agent_fixture()
      [id1, id2, _id3, _id4, _id5] = seed(agent.id, 5)

      # Hide two specific rows.
      assert Logs.hide_logs([id1, id2]) == 2

      assert Logs.count_agent_logs(:all) == 5
      assert Logs.count_agent_logs(:hidden) == 2
      assert Logs.count_agent_logs(:visible) == 3

      hidden = Logs.query_agent_logs(:hidden, 50, 0)
      assert length(hidden) == 2
      assert Enum.all?(hidden, & &1.hidden)

      visible = Logs.query_agent_logs(:visible, 50, 0)
      assert length(visible) == 3
      refute Enum.any?(visible, & &1.hidden)
    end

    test "is newest-first by log_no and respects offset/limit windowing" do
      agent = agent_fixture()
      seed(agent.id, 5)

      all = Logs.query_agent_logs(:all, 50, 0)
      nos = Enum.map(all, & &1.log_no)
      assert nos == Enum.sort(nos, :desc)

      page1 = Logs.query_agent_logs(:all, 2, 0)
      page2 = Logs.query_agent_logs(:all, 2, 2)
      assert length(page1) == 2
      assert length(page2) == 2
      assert Enum.map(page1, & &1.id) != Enum.map(page2, & &1.id)
      # The window is contiguous against the full newest-first ordering.
      assert Enum.map(page1 ++ page2, & &1.log_no) == Enum.take(nos, 4)
    end

    test "clamps a non-positive limit to the default and a huge limit to the max" do
      agent = agent_fixture()
      seed(agent.id, 3)

      assert length(Logs.query_agent_logs(:all, 0, 0)) == 3
      assert length(Logs.query_agent_logs(:all, -5, 0)) == 3
      # Over-large limit does not error and returns at most what exists.
      assert length(Logs.query_agent_logs(:all, 10_000, 0)) == 3
    end

    test "clamps a negative offset to 0" do
      agent = agent_fixture()
      seed(agent.id, 2)
      assert length(Logs.query_agent_logs(:all, 50, -10)) == 2
    end

    test "empty store returns [] and 0" do
      assert Logs.query_agent_logs(:all, 50, 0) == []
      assert Logs.count_agent_logs(:all) == 0
    end
  end

  describe "hide_logs/1 + unhide_logs/1" do
    test "flip only the targeted ids and return the right count" do
      agent = agent_fixture()
      [id1, id2, id3] = seed(agent.id, 3)

      assert Logs.hide_logs([id1, id2]) == 2
      assert Logs.count_agent_logs(:hidden) == 2

      hidden_ids = Logs.query_agent_logs(:hidden, 50, 0) |> Enum.map(& &1.id) |> Enum.sort()
      assert hidden_ids == Enum.sort([id1, id2])

      assert Logs.unhide_logs([id1]) == 1
      assert Logs.count_agent_logs(:hidden) == 1
      assert Logs.query_agent_logs(:hidden, 50, 0) |> Enum.map(& &1.id) == [id2]
      # id3 was never touched.
      assert id3 in (Logs.query_agent_logs(:visible, 50, 0) |> Enum.map(& &1.id))
    end

    test "are idempotent and treat an empty list as a no-op returning 0" do
      agent = agent_fixture()
      [id1] = seed(agent.id, 1)

      assert Logs.hide_logs([id1]) == 1
      assert Logs.hide_logs([id1]) == 1
      assert Logs.count_agent_logs(:hidden) == 1

      assert Logs.hide_logs([]) == 0
      assert Logs.unhide_logs([]) == 0
    end
  end

  describe "purge_logs/1 + purge_all_logs/0" do
    test "purge_logs deletes only the targeted ids" do
      agent = agent_fixture()
      [id1, id2, id3] = seed(agent.id, 3)

      assert Logs.purge_logs([id1, id2]) == 2
      assert Logs.count_agent_logs(:all) == 1
      assert Logs.query_agent_logs(:all, 50, 0) |> Enum.map(& &1.id) == [id3]
    end

    test "purge_logs treats an empty list as a no-op returning 0" do
      agent = agent_fixture()
      seed(agent.id, 2)
      assert Logs.purge_logs([]) == 0
      assert Logs.count_agent_logs(:all) == 2
    end

    test "purge_all_logs empties the table" do
      agent = agent_fixture()
      seed(agent.id, 4)
      assert Logs.purge_all_logs() == 4
      assert Logs.count_agent_logs(:all) == 0
      assert Logs.query_agent_logs(:all, 50, 0) == []
    end
  end
end
