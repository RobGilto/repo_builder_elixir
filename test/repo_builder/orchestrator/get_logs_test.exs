defmodule RepoBuilder.Orchestrator.GetLogsTest do
  @moduledoc """
  Unit tests for the harness-blind `get_logs` orchestrator tool (issue
  orchestrator-log-lookup-tools): resolve a `log-<n>` reference — single, inclusive
  range, or explicit array — back to its persisted `agent_logs` content.

  Reached via `Tools.call("get_logs", orch_id, args)`, exactly as the MCP/pi bindings
  do. Seeds rows through the `Logs` context (so the DB sequence stamps `log_no`) and
  asserts each input shape plus the bounds (`@max_log_lookup` cap), `missing`
  reporting, hidden include/exclude, owner labeling, text truncation, and the
  no-selector `{:error, _}` branch.
  """
  use RepoBuilder.SessionCase, async: false

  alias RepoBuilder.{Agents, Logs, Orchestrators}
  alias RepoBuilder.Harness.Event
  alias RepoBuilder.Orchestrator.Tools

  defp uniq, do: System.unique_integer([:positive])

  defp orchestrator do
    {:ok, orch} = Orchestrators.create(%{name: "orch-#{uniq()}", harness: "fake"})
    orch
  end

  defp worker(orch) do
    {:ok, agent} = Agents.create_worker(orch.id, %{"name" => "w-#{uniq()}", "harness" => "fake"})
    agent
  end

  # Persist `n` worker text_delta rows and return their stamped log_no's (ascending).
  defp seed_worker(agent_id, n, prefix \\ "row") do
    for i <- 1..n do
      {:ok, log} =
        Logs.persist_event(
          %Event.TextDelta{harness: :fake, text: "#{prefix}-#{i}", thinking?: false},
          %{agent_id: agent_id, session_id: "s"}
        )

      log.log_no
    end
  end

  describe "single selector" do
    test "resolves a \"log-<n>\" string and a bare integer to the same one row" do
      orch = orchestrator()
      agent = worker(orch)
      [n] = seed_worker(agent.id, 1)

      assert {:ok, by_string} = Tools.call("get_logs", orch.id, %{"log" => "log-#{n}"})
      assert {:ok, by_int} = Tools.call("get_logs", orch.id, %{"log" => n})

      assert [%{"log_no" => ^n, "log" => label}] = by_string["logs"]
      assert label == "log-#{n}"
      assert by_string["count"] == 1
      assert by_string["missing"] == []
      assert by_string["capped"] == false
      assert [%{"log_no" => ^n}] = by_int["logs"]
    end
  end

  describe "range selector" do
    test "returns the inclusive set ordered ascending (string and bare-int bounds)" do
      orch = orchestrator()
      agent = worker(orch)
      [n1, n2, n3] = seed_worker(agent.id, 3)

      assert {:ok, str} =
               Tools.call("get_logs", orch.id, %{"from" => "log-#{n1}", "to" => "log-#{n3}"})

      assert Enum.map(str["logs"], & &1["log_no"]) == [n1, n2, n3]

      assert {:ok, int} = Tools.call("get_logs", orch.id, %{"from" => n1, "to" => n3})
      assert Enum.map(int["logs"], & &1["log_no"]) == [n1, n2, n3]
    end

    test "an inverted range (from > to) yields no rows, not an error" do
      orch = orchestrator()
      agent = worker(orch)
      [n1, _n2, n3] = seed_worker(agent.id, 3)

      assert {:ok, result} = Tools.call("get_logs", orch.id, %{"from" => n3, "to" => n1})
      assert result["logs"] == []
      assert result["missing"] == []
    end
  end

  describe "array selector" do
    test "resolves a mixed array of \"log-<n>\" and bare ints, order normalized" do
      orch = orchestrator()
      agent = worker(orch)
      [n1, n2, n3] = seed_worker(agent.id, 3)

      assert {:ok, result} =
               Tools.call("get_logs", orch.id, %{"numbers" => [n3, "log-#{n1}", n2]})

      assert Enum.map(result["logs"], & &1["log_no"]) == [n1, n2, n3]
    end
  end

  describe "bounds" do
    test "a range wider than @max_log_lookup is capped and flagged" do
      orch = orchestrator()
      agent = worker(orch)
      [n1] = seed_worker(agent.id, 1)

      # 200-wide span → bounded to 100 numbers; only the one seeded row resolves.
      assert {:ok, result} = Tools.call("get_logs", orch.id, %{"from" => n1, "to" => n1 + 200})

      assert result["capped"] == true
      assert result["requested"] == 201
      assert length(result["logs"]) <= 100
      assert [%{"log_no" => ^n1}] = result["logs"]
    end
  end

  describe "missing" do
    test "a number with no row is reported under missing, not an error" do
      orch = orchestrator()
      agent = worker(orch)
      [n1] = seed_worker(agent.id, 1)
      absent = n1 + 50_000

      assert {:ok, result} = Tools.call("get_logs", orch.id, %{"numbers" => [n1, absent]})
      assert Enum.map(result["logs"], & &1["log_no"]) == [n1]
      assert result["missing"] == [absent]
    end
  end

  describe "hidden" do
    test "a hidden row is excluded by default and included with include_hidden" do
      orch = orchestrator()
      agent = worker(orch)
      [n1] = seed_worker(agent.id, 1)
      [id] = Logs.logs_by_numbers([n1]) |> Enum.map(& &1.id)
      assert Logs.hide_logs([id]) == 1

      assert {:ok, default} = Tools.call("get_logs", orch.id, %{"log" => n1})
      assert default["logs"] == []

      assert {:ok, shown} =
               Tools.call("get_logs", orch.id, %{"log" => n1, "include_hidden" => true})

      assert [%{"log_no" => ^n1}] = shown["logs"]
    end
  end

  describe "owner labeling" do
    test "a worker row reports worker:<id> and an orchestrator row reports orchestrator:<id>" do
      orch = orchestrator()
      agent = worker(orch)
      [wn] = seed_worker(agent.id, 1)

      {:ok, orch_log} =
        Logs.persist_orchestrator_event(
          %Event.TextDelta{harness: :fake, text: "orch turn", thinking?: false},
          %{orchestrator_id: orch.id, session_id: "o"}
        )

      assert {:ok, result} =
               Tools.call("get_logs", orch.id, %{"numbers" => [wn, orch_log.log_no]})

      owners = Map.new(result["logs"], &{&1["log_no"], &1["owner"]})
      assert owners[wn] == "worker:#{agent.id}"
      assert owners[orch_log.log_no] == "orchestrator:#{orch.id}"
    end
  end

  describe "text excerpt + usage" do
    test "long event text is truncated to the cap" do
      orch = orchestrator()
      agent = worker(orch)
      big = String.duplicate("x", 5_000)

      {:ok, log} =
        Logs.persist_event(
          %Event.TextDelta{harness: :fake, text: big, thinking?: false},
          %{agent_id: agent.id, session_id: "s"}
        )

      assert {:ok, result} = Tools.call("get_logs", orch.id, %{"log" => log.log_no})
      assert [%{"text" => text}] = result["logs"]
      assert String.length(text) < String.length(big)
      assert text =~ "truncated"
    end

    test "a usage row carries token/cost detail and a priced cost stringifies" do
      orch = orchestrator()
      agent = worker(orch)

      {:ok, log} =
        Logs.persist_event(
          %Event.Usage{
            harness: :fake,
            input_tokens: 100,
            output_tokens: 20,
            cost_usd: 0.5
          },
          %{agent_id: agent.id, session_id: "s"}
        )

      assert {:ok, result} = Tools.call("get_logs", orch.id, %{"log" => log.log_no})
      assert [%{"usage" => usage}] = result["logs"]
      assert usage["input_tokens"] == 100
      assert usage["output_tokens"] == 20
      assert usage["cost_usd"] == "0.5"
    end
  end

  describe "no selector" do
    test "an empty args map is an error, not a crash" do
      orch = orchestrator()
      assert {:error, reason} = Tools.call("get_logs", orch.id, %{})
      assert reason =~ "provide one of"
    end

    test "an all-unparseable numbers array resolves to an empty (non-error) result" do
      orch = orchestrator()
      assert {:ok, result} = Tools.call("get_logs", orch.id, %{"numbers" => ["foo", nil]})
      assert result["logs"] == []
      assert result["missing"] == []
    end
  end
end
