defmodule RepoBuilder.LogsOrchestratorErrorTest do
  @moduledoc """
  Regression guard (issue-fix-pi-orchestrator-extension-load): a runtime-SYNTHESIZED
  `Event.Error` carries no `raw` wire frame, so the old `payload: scrubbed.raw`
  persisted an empty `%{}` and the diagnostic was silently dropped. Both
  `persist_event/2` and `persist_orchestrator_event/2` must instead persist the
  error's own `message`/`reason`/`retryable` into `payload`.
  """
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.{Agents, Logs, Orchestrators}
  alias RepoBuilder.Harness.Event
  alias RepoBuilder.Logs.AgentLog

  defp agent_fixture do
    {:ok, agent} =
      Agents.create_agent(%{
        name: "agent-#{System.unique_integer([:positive])}",
        harness: "pi",
        provider: :local
      })

    agent
  end

  defp orchestrator_fixture do
    {:ok, orch} =
      Orchestrators.create(%{
        name: "orch-#{System.unique_integer([:positive])}",
        harness: "pi",
        provider: "zai"
      })

    orch
  end

  defp synthesized_error do
    # `raw` defaults to %{} for a synthesized error — exactly the empty-raw case.
    %Event.Error{
      harness: :pi,
      message: "provider exited: {:exit_status, 256}\nstderr: pi is not defined",
      reason: :provider_error,
      retryable: false
    }
  end

  test "persist_orchestrator_event/2 persists error diagnostics into payload (not empty)" do
    orch = orchestrator_fixture()

    assert {:ok, %AgentLog{} = log} =
             Logs.persist_orchestrator_event(synthesized_error(), %{
               orchestrator_id: orch.id,
               session_id: "s1"
             })

    assert log.event_type == :error
    assert log.harness == "pi"
    assert log.orchestrator_id == orch.id
    assert log.agent_id == nil
    assert log.payload["message"] =~ "provider exited"
    assert log.payload["message"] =~ "pi is not defined"
    assert log.payload["reason"] == "provider_error"
    assert log.payload["retryable"] == false
  end

  test "persist_event/2 persists error diagnostics into payload (not empty)" do
    agent = agent_fixture()

    assert {:ok, %AgentLog{} = log} =
             Logs.persist_event(synthesized_error(), %{agent_id: agent.id, session_id: "s1"})

    assert log.event_type == :error
    assert log.harness == "pi"
    assert log.agent_id == agent.id
    assert log.payload["message"] =~ "pi is not defined"
    assert log.payload["reason"] == "provider_error"
    assert log.payload["retryable"] == false
  end
end
