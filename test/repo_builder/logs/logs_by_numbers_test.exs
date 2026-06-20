defmodule RepoBuilder.Logs.LogsByNumbersTest do
  @moduledoc """
  Context unit tests for `RepoBuilder.Logs.logs_by_numbers/2` (issue
  orchestrator-log-lookup-tools) — the bounded `log_no` reader that resolves a
  `log-<n>` reference back to its `agent_logs` row.

  All DB access stays behind the `RepoBuilder.Logs` context (BUILD_PROMPT.md §8); the
  tests seed through `persist_event/2` (so the DB sequence stamps `log_no`) and read
  effects back through the context, never `Repo` directly.
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

  # Persist `n` text_delta rows for one agent and return their stamped log_no's
  # (insertion order, ascending).
  defp seed(agent_id, n) do
    for i <- 1..n do
      {:ok, log} =
        Logs.persist_event(
          %Event.TextDelta{harness: :fake, text: "row-#{i}", thinking?: false},
          %{agent_id: agent_id, session_id: "s"}
        )

      log.log_no
    end
  end

  describe "logs_by_numbers/2" do
    test "returns exactly the requested rows ordered ascending by log_no" do
      agent = agent_fixture()
      [n1, n2, n3, n4, n5] = seed(agent.id, 5)

      # Request a non-contiguous, out-of-order subset.
      rows = Logs.logs_by_numbers([n4, n1, n3])

      assert Enum.map(rows, & &1.log_no) == [n1, n3, n4]
      refute n2 in Enum.map(rows, & &1.log_no)
      refute n5 in Enum.map(rows, & &1.log_no)
    end

    test "ignores numbers with no row" do
      agent = agent_fixture()
      [n1, n2] = seed(agent.id, 2)
      absent = n2 + 100_000

      rows = Logs.logs_by_numbers([n1, absent])
      assert Enum.map(rows, & &1.log_no) == [n1]
    end

    test "excludes hidden rows by default and includes them with include_hidden?: true" do
      agent = agent_fixture()
      [n1, n2, n3] = seed(agent.id, 3)

      # Hide the middle row by its id.
      [hide_id] =
        Logs.logs_by_numbers([n2]) |> Enum.map(& &1.id)

      assert Logs.hide_logs([hide_id]) == 1

      visible = Logs.logs_by_numbers([n1, n2, n3])
      assert Enum.map(visible, & &1.log_no) == [n1, n3]

      all = Logs.logs_by_numbers([n1, n2, n3], include_hidden?: true)
      assert Enum.map(all, & &1.log_no) == [n1, n2, n3]
    end

    test "returns [] for an empty list without querying" do
      assert Logs.logs_by_numbers([]) == []
      assert Logs.logs_by_numbers([], include_hidden?: true) == []
    end
  end
end
