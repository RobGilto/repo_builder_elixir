defmodule RepoBuilder.LogsOrchestratorTest do
  @moduledoc """
  Orchestrator-scoped persistence (issue-d): canonical events round-trip to
  `agent_logs` under `orchestrator_id` (with `agent_id` NULL), appear in
  `list_recent_global/1`, roll into `orchestrator_cost_rollup!/1` (nil-vs-0.0
  preserved), and have secrets scrubbed from the persisted payload.
  """
  use RepoBuilder.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  alias RepoBuilder.Harness.Event
  alias RepoBuilder.Logs
  alias RepoBuilder.Logs.AgentLog
  alias RepoBuilder.Orchestrators
  alias RepoBuilder.Repo

  defp orchestrator_fixture do
    {:ok, orch} =
      Orchestrators.create(%{
        name: "orch-#{System.unique_integer([:positive])}",
        harness: "claude",
        provider: "anthropic"
      })

    orch
  end

  test "an orchestrator event round-trips to agent_logs under orchestrator_id (agent_id NULL)" do
    orch = orchestrator_fixture()

    event = %Event.TextDelta{
      harness: :claude,
      text: "hi",
      raw: %{"type" => "text_delta", "text" => "hi"}
    }

    assert {:ok, %AgentLog{} = log} =
             Logs.persist_orchestrator_event(event, %{orchestrator_id: orch.id, session_id: "s1"})

    assert log.orchestrator_id == orch.id
    assert log.agent_id == nil
    assert log.event_type == :text_delta
    assert log.harness == "claude"
    # TextDelta persists the canonical text (+ thinking flag), not the raw frame.
    assert log.payload == %{"text" => "hi", "thinking" => false}
  end

  test "the persisted payload is secret-redacted while the input event keeps full raw" do
    orch = orchestrator_fixture()

    raw = %{"type" => "system", "anthropic_api_key" => "sk-secret", "nested" => %{"token" => "t"}}
    event = %Event.SessionStarted{harness: :claude, session_id: "x", raw: raw}

    {:ok, log} =
      Logs.persist_orchestrator_event(event, %{orchestrator_id: orch.id, session_id: "s"})

    assert log.payload["anthropic_api_key"] == "[REDACTED]"
    assert log.payload["nested"]["token"] == "[REDACTED]"
    # The input event is untouched (the live broadcast keeps full raw).
    assert event.raw["anthropic_api_key"] == "sk-secret"
  end

  test "orchestrator rows appear in list_recent_global/1 interleaved with workers" do
    orch = orchestrator_fixture()
    event = %Event.TextDelta{harness: :claude, text: "yo", raw: %{"text" => "yo"}}

    {:ok, log} =
      Logs.persist_orchestrator_event(event, %{orchestrator_id: orch.id, session_id: "s"})

    ids = Logs.list_recent_global(200) |> Enum.map(& &1.id)
    assert log.id in ids
  end

  test "list_recent_global/2 returns rows ascending by (inserted_at, id)" do
    orch = orchestrator_fixture()

    # Insert in scrambled time order, then force distinct known instants.
    instants = [
      ~U[2026-06-18 03:00:00Z],
      ~U[2026-06-18 01:00:00Z],
      ~U[2026-06-18 02:00:00Z]
    ]

    for at <- instants do
      event = %Event.TextDelta{harness: :claude, text: "x", raw: %{"text" => "x"}}

      {:ok, log} =
        Logs.persist_orchestrator_event(event, %{orchestrator_id: orch.id, session_id: "s"})

      {1, _} =
        Repo.update_all(from(l in AgentLog, where: l.id == ^log.id), set: [inserted_at: at])
    end

    times = Logs.list_recent_global(200) |> Enum.map(& &1.inserted_at)
    assert times == Enum.sort(times, DateTime)
    # Oldest first (ascending): 01:00 precedes 02:00 precedes 03:00.
    assert Enum.take(times, 3) |> Enum.map(& &1.hour) == [1, 2, 3]
  end

  describe "orchestrator_cost_rollup!/1 (nil-vs-0.0 preserved)" do
    test "an unpriced turn stores NULL and contributes nothing to the rollup" do
      orch = orchestrator_fixture()

      unpriced = %Event.Usage{
        harness: :pi,
        input_tokens: 10,
        output_tokens: 5,
        cost_usd: nil,
        raw: %{}
      }

      {:ok, log} =
        Logs.persist_orchestrator_event(unpriced, %{orchestrator_id: orch.id, session_id: "s"})

      assert log.usage.cost_usd == nil
      assert Decimal.equal?(Logs.orchestrator_cost_rollup!(orch.id), Decimal.new(0))
    end

    test "priced turns sum; a priced-at-zero turn stores Decimal-0 (not NULL)" do
      orch = orchestrator_fixture()

      zero = %Event.Usage{
        harness: :claude,
        input_tokens: 1,
        output_tokens: 1,
        cost_usd: 0.0,
        raw: %{}
      }

      {:ok, zlog} =
        Logs.persist_orchestrator_event(zero, %{orchestrator_id: orch.id, session_id: "s"})

      assert %Decimal{} = zlog.usage.cost_usd
      assert Decimal.equal?(zlog.usage.cost_usd, Decimal.new(0))

      priced = %Event.Usage{
        harness: :claude,
        input_tokens: 1,
        output_tokens: 1,
        cost_usd: 1.25,
        raw: %{}
      }

      {:ok, _} =
        Logs.persist_orchestrator_event(priced, %{orchestrator_id: orch.id, session_id: "s"})

      assert Decimal.equal?(Logs.orchestrator_cost_rollup!(orch.id), Decimal.from_float(1.25))
    end
  end

  describe "durable log_no (log-<n>)" do
    test "persist_event/2 returns a log with a positive integer log_no" do
      {:ok, agent} =
        RepoBuilder.Agents.create_agent(%{
          name: "w-#{System.unique_integer([:positive])}",
          harness: "claude",
          provider: :local
        })

      event = %Event.TextDelta{
        harness: :claude,
        text: "hi",
        raw: %{"type" => "t", "text" => "hi"}
      }

      assert {:ok, %AgentLog{log_no: log_no}} =
               Logs.persist_event(event, %{agent_id: agent.id, session_id: "s"})

      assert is_integer(log_no) and log_no > 0
    end

    test "successive inserts produce strictly increasing log_no (monotonic / chronological)" do
      orch = orchestrator_fixture()
      event = %Event.TextDelta{harness: :claude, text: "x", raw: %{"type" => "t", "text" => "x"}}

      {:ok, a} =
        Logs.persist_orchestrator_event(event, %{orchestrator_id: orch.id, session_id: "s"})

      {:ok, b} =
        Logs.persist_orchestrator_event(event, %{orchestrator_id: orch.id, session_id: "s"})

      assert b.log_no > a.log_no
    end

    test "list_recent_global/2 rows each carry a non-nil log_no" do
      orch = orchestrator_fixture()
      event = %Event.TextDelta{harness: :claude, text: "x", raw: %{"type" => "t", "text" => "x"}}

      {:ok, _} =
        Logs.persist_orchestrator_event(event, %{orchestrator_id: orch.id, session_id: "s"})

      rows = Logs.list_recent_global(50)
      assert rows != []
      assert Enum.all?(rows, &is_integer(&1.log_no))
    end

    test "log_label/1 formats integers and degrades nil to —" do
      assert Logs.log_label(1) == "log-1"
      assert Logs.log_label(12) == "log-12"
      assert Logs.log_label(435_444_545) == "log-435444545"
      assert Logs.log_label(nil) == "—"
    end
  end
end
