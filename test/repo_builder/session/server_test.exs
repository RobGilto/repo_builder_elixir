defmodule RepoBuilder.Session.ServerTest do
  use RepoBuilder.SessionCase, async: false

  import Mox

  alias RepoBuilder.{Agents, HarnessFixtures, Logs, OsPidLedger}
  alias RepoBuilder.Session.{Admission, Supervisor}

  @mock RepoBuilder.Harness.Mock

  defp unique_agent, do: "agent-" <> Integer.to_string(System.unique_integer([:positive]))

  describe "end-to-end via the Fake harness" do
    test "streams the full canonical sequence and cleans up on exit" do
      agent = unique_agent()
      subscribe(agent)
      before = Admission.count().used

      {:ok, pid} = Supervisor.start_session(agent_id: agent, harness: "fake", prompt: "hi")
      ref = Process.monitor(pid)

      assert_receive {:harness_event, %Event.SessionStarted{harness: :fake}}, 2_000
      assert_receive {:harness_event, %Event.TextDelta{text: "Hello"}}, 2_000
      assert_receive {:harness_event, %Event.ToolCall{name: "bash"}}, 2_000
      assert_receive {:harness_event, %Event.Usage{input_tokens: 10}}, 2_000
      assert_receive {:harness_event, %Event.Done{ok: true}}, 2_000
      assert_receive {:DOWN, ^ref, :process, _, _}, 2_000

      # terminate/2: ledger row deleted, admission slot released.
      assert OsPidLedger.list_for_node(to_string(node())) == []
      assert Admission.count().used == before
    end
  end

  describe "terminal-state synthesis & framing (Mock adapter)" do
    setup do
      register_harness("mock", @mock)
      :ok
    end

    test "synthesizes Done{:clean_exit} on a clean exit with output and no terminal event" do
      agent = unique_agent()
      subscribe(agent)

      stub(@mock, :command, fn _ ->
        {"printf", ["%s\n", ~s({"k":"text","t":"only text"})], [], %{harness: :mock}}
      end)

      stub(@mock, :normalize, fn
        %{"k" => "text", "t" => text}, _ -> {:ok, [%Event.TextDelta{harness: :mock, text: text}]}
        _, _ -> :skip
      end)

      {:ok, pid} = Supervisor.start_session(agent_id: agent, harness: "mock", prompt: "x")
      ref = Process.monitor(pid)

      assert_receive {:harness_event, %Event.TextDelta{text: "only text"}}, 2_000
      assert_receive {:harness_event, %Event.Done{reason: :clean_exit, ok: true}}, 2_000
      assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
    end

    test "a hung child fires the idle timeout and emits Error{:idle_timeout}" do
      agent = unique_agent()
      subscribe(agent)

      stub(@mock, :command, fn _ -> {"sleep", ["10"], [], %{harness: :mock}} end)
      stub(@mock, :normalize, fn _, _ -> :skip end)

      {:ok, pid} =
        Supervisor.start_session(agent_id: agent, harness: "mock", prompt: "x", idle_ms: 100)

      ref = Process.monitor(pid)

      assert_receive {:harness_event, %Event.Error{reason: :idle_timeout, retryable: true}}, 2_000
      assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
    end

    test "an un-newline-terminated stream past the byte cap emits Error stdout overflow" do
      agent = unique_agent()
      subscribe(agent)

      stub(@mock, :command, fn _ ->
        {"head", ["-c", "50000", "/dev/zero"], [], %{harness: :mock}}
      end)

      stub(@mock, :normalize, fn _, _ -> :skip end)

      {:ok, pid} =
        Supervisor.start_session(
          agent_id: agent,
          harness: "mock",
          prompt: "x",
          max_line_bytes: 1_000
        )

      ref = Process.monitor(pid)

      assert_receive {:harness_event,
                      %Event.Error{message: "stdout overflow", reason: :provider_error}},
                     2_000

      assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
    end

    test "a malformed JSON line is skipped, not fatal" do
      agent = unique_agent()
      subscribe(agent)

      stub(@mock, :command, fn _ ->
        {"printf", ["%s\n", "this is not json {", ~s({"k":"text","t":"ok"})], [],
         %{harness: :mock}}
      end)

      stub(@mock, :normalize, fn
        %{"k" => "text", "t" => text}, _ -> {:ok, [%Event.TextDelta{harness: :mock, text: text}]}
        _, _ -> :skip
      end)

      {:ok, pid} = Supervisor.start_session(agent_id: agent, harness: "mock", prompt: "x")
      ref = Process.monitor(pid)

      assert_receive {:harness_event, %Event.TextDelta{text: "ok"}}, 2_000
      assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
    end

    test "provisions a per-session workspace and removes it on terminate" do
      agent = unique_agent()
      stub(@mock, :command, fn _ -> {"sleep", ["10"], [], %{harness: :mock}} end)
      stub(@mock, :normalize, fn _, _ -> :skip end)

      {:ok, pid} = Supervisor.start_session(agent_id: agent, harness: "mock", prompt: "x")
      ref = Process.monitor(pid)
      cwd = :sys.get_state(pid).cwd
      assert File.dir?(cwd)

      :ok = Supervisor.stop_session(agent)
      assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
      refute File.dir?(cwd)
    end

    test "a multibyte char split across two stdout chunks reassembles into one event" do
      agent = unique_agent()
      subscribe(agent)

      # Long-running child so the server stays alive while we inject crafted stdout.
      stub(@mock, :command, fn _ -> {"sleep", ["10"], [], %{harness: :mock}} end)

      stub(@mock, :normalize, fn
        %{"k" => "text", "t" => text}, _ -> {:ok, [%Event.TextDelta{harness: :mock, text: text}]}
        _, _ -> :skip
      end)

      {:ok, pid} = Supervisor.start_session(agent_id: agent, harness: "mock", prompt: "x")
      os_pid = :sys.get_state(pid).os_pid
      assert is_integer(os_pid)

      line = ~s({"k":"text","t":"café"}) <> "\n"
      # Split inside the é (bytes C3 A9): head ends with C3, tail begins with A9.
      {head, tail} = HarnessFixtures.chunk_at(line, byte_size(line) - 4)

      send(pid, {:stdout, os_pid, head})
      send(pid, {:stdout, os_pid, tail})

      assert_receive {:harness_event, %Event.TextDelta{text: "café"}}, 2_000

      :ok = Supervisor.stop_session(agent)
    end
  end

  describe "persistence when tied to a durable agent (M3)" do
    test "persists REDACTED events to agent_logs while broadcasting the FULL raw" do
      register_harness("mock", @mock)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "persist-#{System.unique_integer([:positive])}",
          harness: "mock",
          provider: :anthropic
        })

      subscribe(agent.id)

      stub(@mock, :command, fn _ ->
        {"printf", ["%s\n", ~s({"k":"text","t":"hi","api_key":"sk-secret"})], [],
         %{harness: :mock}}
      end)

      stub(@mock, :normalize, fn
        %{"k" => "text", "t" => text} = raw, _ ->
          {:ok, [%Event.TextDelta{harness: :mock, text: text, raw: raw}]}

        _, _ ->
          :skip
      end)

      {:ok, pid} =
        Supervisor.start_session(
          agent_id: agent.id,
          agent_db_id: agent.id,
          harness: "mock",
          prompt: "x"
        )

      ref = Process.monitor(pid)

      assert_receive {:harness_event, %Event.TextDelta{text: "hi", raw: raw}}, 2_000
      assert raw["api_key"] == "sk-secret", "the in-flight broadcast keeps full raw"
      assert_receive {:DOWN, ^ref, :process, _, _}, 2_000

      logs = Logs.list_recent(agent.id)
      text_log = Enum.find(logs, &(&1.event_type == :text_delta))
      assert text_log.payload["t"] == "hi"
      assert text_log.payload["api_key"] == "[REDACTED]", "persisted payload is scrubbed"

      # A clean exit with output and no terminal event synthesizes a persisted Done.
      assert Enum.any?(logs, &(&1.event_type == :done))
      # Agent status reflects the terminal Done(ok: true).
      assert Agents.get_agent(agent.id).status == :idle
    end
  end
end
