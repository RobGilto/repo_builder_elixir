defmodule RepoBuilder.Session.MissingApiSecretEventTest do
  @moduledoc """
  Integration test (issue-provisioned-api-secret-missing-silent): a worker `Session.Server`
  provisioned an external API whose vault secret was never deposited emits, at spawn, a
  non-terminal `%Event.Status{kind: :missing_secret}` naming the missing secret (broadcast on
  the per-agent topic AND persisted to `agent_logs`) — instead of silently spawning with an
  unresolvable `${SECRET}` placeholder. The converse holds: a worker whose secret IS deposited
  emits NO such event (happy-path byte-identity).
  """
  use RepoBuilder.SessionCase, async: false

  import Mox

  alias RepoBuilder.{Agents, ExternalApis, Logs, Projects, Secrets}
  alias RepoBuilder.Logs.Writer

  @mock RepoBuilder.Harness.Mock

  setup do
    register_harness("mock", @mock)

    {:ok, project} =
      Projects.create_project(%{
        "name" => "missingev-#{System.unique_integer([:positive])}",
        "root_path" => "/tmp/missingev-#{System.unique_integer([:positive])}"
      })

    {:ok, _} =
      ExternalApis.create(%{
        "name" => "pixellab",
        "transport" => "http",
        "url" => "https://api.pixellab.ai/mcp",
        "auth_scheme" => "bearer",
        "secret_name" => "PIXELLAB_API_KEY"
      })

    # A trivial child that emits one text frame then exits cleanly (terminal synthesized).
    stub(@mock, :command, fn _opts ->
      frame = Jason.encode!(%{"k" => "text", "t" => "hello"})
      {"printf", ["%s\n", frame], [], %{harness: :mock}}
    end)

    stub(@mock, :normalize, fn
      %{"k" => "text", "t" => text} = raw, _ ->
        {:ok, [%Event.TextDelta{harness: :mock, text: text, raw: raw}]}

      _, _ ->
        :skip
    end)

    %{project: project}
  end

  test "an undeposited provisioned secret emits a persisted :missing_secret Status at spawn", %{
    project: project
  } do
    {:ok, agent} =
      Agents.create_agent(%{
        name: "missingev-#{System.unique_integer([:positive])}",
        harness: "mock",
        provider: :anthropic,
        project_id: project.id
      })

    subscribe(agent.id)

    {:ok, pid} =
      Session.Supervisor.start_session(
        agent_id: agent.id,
        agent_db_id: agent.id,
        harness: "mock",
        project_id: project.id,
        config: %{"apis" => ["pixellab"]},
        prompt: "do the thing"
      )

    ref = Process.monitor(pid)

    assert_receive {:harness_event,
                    %Event.Status{
                      kind: :missing_secret,
                      detail: %{api: "pixellab", secret_name: "PIXELLAB_API_KEY"}
                    }},
                   2_000

    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000

    # …and the signal is persisted (operator-visible, queryable row).
    :ok = Writer.drain()
    logs = Logs.list_recent(agent.id)
    assert Enum.any?(logs, &(&1.event_type == :status))
  end

  test "a deposited provisioned secret emits NO :missing_secret event", %{project: project} do
    {:ok, _} = Secrets.put_secret(project.id, "PIXELLAB_API_KEY", "project_token")

    {:ok, agent} =
      Agents.create_agent(%{
        name: "deposited-#{System.unique_integer([:positive])}",
        harness: "mock",
        provider: :anthropic,
        project_id: project.id
      })

    subscribe(agent.id)

    {:ok, pid} =
      Session.Supervisor.start_session(
        agent_id: agent.id,
        agent_db_id: agent.id,
        harness: "mock",
        project_id: project.id,
        config: %{"apis" => ["pixellab"]},
        prompt: "do the thing"
      )

    ref = Process.monitor(pid)

    # The worker still runs and terminates cleanly…
    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000

    # …with no missing-secret signal anywhere in its broadcast feed.
    refute_received {:harness_event, %Event.Status{kind: :missing_secret}}
  end
end
