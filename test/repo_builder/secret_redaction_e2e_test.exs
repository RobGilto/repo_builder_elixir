defmodule RepoBuilder.SecretRedactionE2ETest do
  use RepoBuilder.SessionCase, async: false

  import Mox

  alias RepoBuilder.{Agents, Logs}

  @mock RepoBuilder.Harness.Mock
  @secret "sk-super-secret-key-1234567890"

  test "no secret reaches agent_logs/system_logs while the live event keeps full detail" do
    register_harness("mock", @mock)

    {:ok, agent} =
      Agents.create_agent(%{
        name: "redact-#{System.unique_integer([:positive])}",
        harness: "mock",
        provider: :anthropic
      })

    subscribe(agent.id)

    stub(@mock, :command, fn _ ->
      frame =
        Jason.encode!(%{
          "k" => "text",
          "t" => "hello",
          "authorization" => @secret,
          "nested" => %{"api_key" => @secret}
        })

      {"printf", ["%s\n", frame], [], %{harness: :mock}}
    end)

    stub(@mock, :normalize, fn
      %{"k" => "text", "t" => text} = raw, _ ->
        {:ok, [%Event.TextDelta{harness: :mock, text: text, raw: raw}]}

      _, _ ->
        :skip
    end)

    {:ok, pid} =
      Session.Supervisor.start_session(
        agent_id: agent.id,
        agent_db_id: agent.id,
        harness: "mock",
        prompt: "x"
      )

    ref = Process.monitor(pid)

    # The in-flight broadcast keeps the secret (live UI sees full detail).
    assert_receive {:harness_event, %Event.TextDelta{raw: raw}}, 2_000
    assert raw["authorization"] == @secret
    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000

    # No persisted agent_logs payload contains the secret anywhere.
    logs = Logs.list_recent(agent.id)
    assert logs != []
    refute Enum.any?(logs, fn log -> String.contains?(inspect(log.payload), @secret) end)

    # …and no system_logs contain it either.
    refute Enum.any?(Logs.list_system_logs(), fn log ->
             String.contains?(inspect(log), @secret)
           end)
  end
end
