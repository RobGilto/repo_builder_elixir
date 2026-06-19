defmodule RepoBuilder.Budget.EnforcementSeamsTest do
  @moduledoc """
  The budget breaker is consulted at the spend-origination seams (issue-budget-guardrails).
  These tests drive the in-memory global kill switch (no DB cap needed) and assert each
  seam degrades gracefully:

    * `Session.Supervisor.start_session/1` refuses with `{:error, {:budget_exceeded, cap}}`.
    * `Orchestrator.Tools` `command_agent` returns a typed `budget_exceeded` tool result
      (an `{:ok, map}`, so the orchestrator agent sees it) and starts no worker session.

  `async: false` — the global `Budget.Guard` kill switch is shared process state; it is
  always released in `on_exit/1`.
  """
  use RepoBuilder.SessionCase, async: false

  alias RepoBuilder.{Agents, Budget, Orchestrators, Session}
  alias RepoBuilder.Orchestrator.Tools

  setup do
    on_exit(fn -> Budget.Guard.release_all() end)
    :ok
  end

  defp uniq, do: System.unique_integer([:positive])

  test "the session supervisor refuses a start while the global breaker is tripped" do
    Budget.Guard.engage_kill_switch()

    assert {:error, {:budget_exceeded, _cap}} =
             Session.Supervisor.start_session(
               agent_id: "a-#{uniq()}",
               harness: "fake",
               prompt: "x"
             )
  end

  test "command_agent returns a budget_exceeded tool result and starts no session" do
    {:ok, orch} = Orchestrators.create(%{name: "orch-#{uniq()}", harness: "fake"})
    name = "w-#{uniq()}"

    {:ok, _} =
      Tools.call("create_agent", orch.id, %{
        "name" => name,
        "harness" => "fake",
        "model" => "fake-model"
      })

    Budget.Guard.engage_kill_switch()

    assert {:ok, %{"status" => "budget_exceeded"} = result} =
             Tools.call("command_agent", orch.id, %{"name" => name, "prompt" => "do work"})

    assert result["message"] =~ "budget exceeded"

    # No worker session was started.
    {:ok, worker} = Agents.get_by_name_for_orchestrator(orch.id, name)
    assert Session.Supervisor.whereis(worker.id) == nil
  end
end
