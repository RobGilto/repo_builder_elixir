defmodule RepoBuilder.Session.ProjectSecretScrubE2ETest do
  @moduledoc """
  Value-based defense-in-depth across the live feed + persistence
  (issue-per-project-encrypted-secrets-vault): when a worker bound to a project echoes a
  project-secret VALUE in its output, the value is scrubbed BOTH on the live
  `"agent:<id>:events"` broadcast AND in the persisted `agent_logs` text.
  """
  use RepoBuilder.SessionCase, async: false

  import Mox

  alias RepoBuilder.{Agents, Logs, Projects, Secrets}
  alias RepoBuilder.Logs.Writer

  @mock RepoBuilder.Harness.Mock
  @secret "super-secret-value-9999"

  test "a worker echoing a project secret value is scrubbed live and at rest" do
    register_harness("mock", @mock)

    {:ok, project} =
      Projects.create_project(%{
        "name" => "scrub-#{System.unique_integer([:positive])}",
        "root_path" => "/tmp/scrub-#{System.unique_integer([:positive])}"
      })

    {:ok, _} = Secrets.put_secret(project.id, "MY_SECRET", @secret)

    {:ok, agent} =
      Agents.create_agent(%{
        name: "scrub-#{System.unique_integer([:positive])}",
        harness: "mock",
        provider: :anthropic,
        project_id: project.id
      })

    subscribe(agent.id)

    stub(@mock, :command, fn _opts ->
      frame = Jason.encode!(%{"k" => "text", "t" => "the secret is #{@secret} done"})
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
        project_id: project.id,
        prompt: "x"
      )

    ref = Process.monitor(pid)

    # The LIVE broadcast is value-scrubbed (the primary fix) — the feed never carries it.
    assert_receive {:harness_event, %Event.TextDelta{text: text}}, 2_000
    assert text =~ "[REDACTED]"
    refute text =~ @secret

    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000

    # Persistence is async (off the session hot path) — drain the writer before reading rows
    # so the assertion never races the in-flight insert.
    :ok = Writer.drain()

    # …and no persisted agent_logs payload contains the value either.
    logs = Logs.list_recent(agent.id)
    assert logs != []
    refute Enum.any?(logs, fn log -> String.contains?(inspect(log.payload), @secret) end)
  end
end
