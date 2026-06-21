defmodule RepoBuilder.Session.ServerTest do
  use RepoBuilder.SessionCase, async: false

  import Mox

  alias RepoBuilder.{Agents, HarnessFixtures, Logs, OsPidLedger}
  alias RepoBuilder.Logs.Writer
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

      assert_receive {:harness_event, %Event.Error{message: message, reason: :provider_error}},
                     2_000

      assert String.starts_with?(message, "stdout overflow")
      assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
    end

    test "a large but newline-terminated frame above the old 1 MiB default is not treated as overflow" do
      agent = unique_agent()
      subscribe(agent)

      # Long-running child so the server stays alive while we inject crafted stdout.
      stub(@mock, :command, fn _ -> {"sleep", ["10"], [], %{harness: :mock}} end)

      stub(@mock, :normalize, fn
        %{"k" => "text", "t" => text}, _ -> {:ok, [%Event.TextDelta{harness: :mock, text: text}]}
        _, _ -> :skip
      end)

      {:ok, pid} =
        Supervisor.start_session(
          agent_id: agent,
          harness: "mock",
          prompt: "x",
          max_line_bytes: 2_000_000
        )

      os_pid = :sys.get_state(pid).os_pid
      assert is_integer(os_pid)

      # A single valid, newline-terminated frame ~1.5 MiB — comfortably above the old 1 MiB
      # default but under the generous cap: must normalize, NOT be killed as overflow.
      padding = String.duplicate("x", 1_500_000)
      line = ~s({"k":"text","t":"#{padding}"}) <> "\n"
      assert byte_size(line) > 1_048_576

      send(pid, {:stdout, os_pid, line})

      assert_receive {:harness_event, %Event.TextDelta{text: ^padding}}, 2_000
      refute_receive {:harness_event, %Event.Error{reason: :provider_error}}, 200

      :ok = Supervisor.stop_session(agent)
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

      # Persistence is now async (issue hot-path-writes Part A) — wait for this agent's
      # writer partition to drain before asserting on the persisted rows / status.
      :ok = Writer.sync(agent.id)

      logs = Logs.list_recent(agent.id)
      text_log = Enum.find(logs, &(&1.event_type == :text_delta))
      # TextDelta persists the canonical text (+ thinking flag), not the raw frame, so
      # the secret-bearing raw never reaches the payload at all.
      assert text_log.payload["text"] == "hi"
      refute Map.has_key?(text_log.payload, "api_key"), "raw secrets never persisted"

      # A clean exit with output and no terminal event synthesizes a persisted Done.
      assert Enum.any?(logs, &(&1.event_type == :done))
      # Agent status reflects the terminal Done(ok: true).
      assert Agents.get_agent(agent.id).status == :idle
    end

    test "broadcasts partial text deltas live but does NOT persist them (lean agent_logs)" do
      register_harness("mock", @mock)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "gate-#{System.unique_integer([:positive])}",
          harness: "mock",
          provider: :anthropic
        })

      subscribe(agent.id)

      # Two partial token deltas followed by one finalized block.
      stub(@mock, :command, fn _ ->
        {"printf",
         [
           "%s\n",
           ~s({"k":"partial","t":"Hel"}\n{"k":"partial","t":"lo"}\n{"k":"final","t":"Hello"})
         ], [], %{harness: :mock}}
      end)

      stub(@mock, :normalize, fn
        %{"k" => "partial", "t" => text} = raw, _ ->
          {:ok, [%Event.TextDelta{harness: :mock, text: text, partial?: true, raw: raw}]}

        %{"k" => "final", "t" => text} = raw, _ ->
          {:ok, [%Event.TextDelta{harness: :mock, text: text, partial?: false, raw: raw}]}

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

      # All three deltas (2 partial + 1 finalized) are broadcast to the live UI.
      assert_receive {:harness_event, %Event.TextDelta{text: "Hel", partial?: true}}, 2_000
      assert_receive {:harness_event, %Event.TextDelta{text: "lo", partial?: true}}, 2_000
      assert_receive {:harness_event, %Event.TextDelta{text: "Hello", partial?: false}}, 2_000
      assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
      :ok = Writer.sync(agent.id)

      # Only the finalized text delta is persisted — partials write no rows.
      text_logs =
        agent.id |> Logs.list_recent() |> Enum.filter(&(&1.event_type == :text_delta))

      assert [%{payload: %{"text" => "Hello"}}] = text_logs
    end
  end

  describe "operator working directory (cwd opt)" do
    test "runs in the given cwd and NEVER deletes it on exit" do
      agent = unique_agent()
      subscribe(agent)

      # An operator-provided working dir holding a sentinel file (the "project").
      cwd =
        Path.join(
          System.tmp_dir!(),
          "rb-wd-" <> Integer.to_string(System.unique_integer([:positive]))
        )

      File.mkdir_p!(cwd)
      sentinel = Path.join(cwd, "KEEP_ME")
      File.write!(sentinel, "project file")

      {:ok, pid} =
        Supervisor.start_session(agent_id: agent, harness: "fake", prompt: "hi", cwd: cwd)

      ref = Process.monitor(pid)
      assert_receive {:harness_event, %Event.Done{ok: true}}, 2_000
      assert_receive {:DOWN, ^ref, :process, _, _}, 2_000

      # The operator's directory and its contents survive session teardown.
      assert File.dir?(cwd)
      assert File.read!(sentinel) == "project file"

      File.rm_rf!(cwd)
    end
  end

  describe "SIGTERM handling (issue-adw-sigterm)" do
    alias RepoBuilder.Session.Server

    test "blocking_command_detected?/1 detects phx.server in stderr" do
      assert Server.blocking_command_detected?("Running Phoenix with mix phx.server\n")
      assert Server.blocking_command_detected?("some output\nmix phx.server started\nmore")
      refute Server.blocking_command_detected?("mix test passed")
      refute Server.blocking_command_detected?("")
    end

    test "sigterm?/1 detects SIGTERM exit status" do
      # Exit status 143 (SIGTERM) is encoded as 36608 by erlexec (143 * 256)
      assert Server.sigterm?({:exit_status, 36608})
      refute Server.sigterm?({:exit_status, 0})
      refute Server.sigterm?({:exit_status, 256})
      refute Server.sigterm?(:normal)
    end

    test "clean_exit?/2 with blocking_command? true treats SIGTERM as clean" do
      base_state = %Server.State{
        agent_id: "test",
        session_id: "s1",
        harness: :mock,
        adapter: RepoBuilder.Harness.Mock,
        prompt: "",
        cwd: "/tmp",
        marker: "m1",
        idle_ms: 1000,
        max_line_bytes: 1_000_000
      }

      state_blocking = %{base_state | blocking_command?: true}
      state_normal = %{base_state | blocking_command?: false}

      # Exit 0 is always clean
      assert Server.clean_exit?({:exit_status, 0}, state_blocking)
      assert Server.clean_exit?({:exit_status, 0}, state_normal)
      assert Server.clean_exit?(:normal, state_blocking)
      assert Server.clean_exit?(:normal, state_normal)

      # SIGTERM (143 → 36608) is clean ONLY when blocking_command? is true
      assert Server.clean_exit?({:exit_status, 36608}, state_blocking)
      refute Server.clean_exit?({:exit_status, 36608}, state_normal)

      # Other non-zero exits are NOT clean regardless of blocking_command?
      refute Server.clean_exit?({:exit_status, 256}, state_blocking)
      refute Server.clean_exit?({:exit_status, 256}, state_normal)
    end

    test "idle timeout with blocking_command? false emits Error immediately" do
      register_harness("mock", @mock)
      agent = unique_agent()
      subscribe(agent)

      stub(@mock, :command, fn _ -> {"sleep", ["100"], [], %{harness: :mock}} end)
      stub(@mock, :normalize, fn _, _ -> :skip end)

      {:ok, pid} =
        Supervisor.start_session(agent_id: agent, harness: "mock", prompt: "x", idle_ms: 100)

      ref = Process.monitor(pid)

      # No blocking pattern → idle timeout emits Error{:idle_timeout}
      assert_receive {:harness_event, %Event.Error{reason: :idle_timeout, retryable: true}},
                     2_000

      assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
    end

    test "stderr with blocking pattern sets blocking_command? flag" do
      register_harness("mock", @mock)
      agent = unique_agent()

      stub(@mock, :command, fn _ ->
        # Command that writes to stderr then blocks, so we can inspect state
        {"sh", ["-c", "echo 'Running Phoenix with mix phx.server' >&2; sleep 10"], [],
         %{harness: :mock}}
      end)

      stub(@mock, :normalize, fn _, _ -> :skip end)

      {:ok, pid} = Supervisor.start_session(agent_id: agent, harness: "mock", prompt: "x")

      # Let stderr propagate
      Process.sleep(100)

      # Check the internal state has the flag set
      state = :sys.get_state(pid)
      assert state.blocking_command? == true

      :ok = Supervisor.stop_session(agent)
    end
  end
end
