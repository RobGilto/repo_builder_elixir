defmodule RepoBuilder.ClearPersistenceTest do
  @moduledoc """
  Unit tests for the soft-hide persistence behind the console CLEAR actions: clearing
  the log view (`Logs.hide_all_logs/0`) and clearing finished workflows
  (`Workflows.hide_finished_runs/0`) mark rows hidden (NOT deleted) so the cleared
  state survives a reconnect, while the backfill reads exclude hidden rows by default
  and include them when the "show hidden" troubleshooting flag is set.
  """
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.{Agents, Logs, Workflows}
  alias RepoBuilder.Harness.Event

  defp uniq, do: System.unique_integer([:positive])

  defp agent_fixture do
    {:ok, agent} =
      Agents.create_agent(%{name: "agent-#{uniq()}", harness: "claude", provider: :anthropic})

    agent
  end

  defp log_for(agent_id) do
    {:ok, log} =
      Logs.persist_event(%Event.TextDelta{harness: :claude, text: "hello"}, %{
        agent_id: agent_id,
        session_id: "s-#{uniq()}"
      })

    log
  end

  describe "Logs.hide_all_logs/0 + list_recent_global/2 hidden filter" do
    test "hides all current logs; default backfill excludes them, show-hidden includes them" do
      agent = agent_fixture()
      log = log_for(agent.id)

      assert log.id in Enum.map(Logs.list_recent_global(500), & &1.id)

      assert Logs.hide_all_logs() == 1

      # Default backfill no longer sees it...
      refute log.id in Enum.map(Logs.list_recent_global(500), & &1.id)
      # ...but it is NOT deleted — the troubleshooting flag reveals it.
      assert log.id in Enum.map(Logs.list_recent_global(500, true), & &1.id)
    end

    test "a log inserted AFTER a clear is visible again (only the cleared ones stay hidden)" do
      agent = agent_fixture()
      _old = log_for(agent.id)
      assert Logs.hide_all_logs() == 1

      fresh = log_for(agent.id)
      assert fresh.id in Enum.map(Logs.list_recent_global(500), & &1.id)
    end
  end

  describe "Logs.release_hidden_logs/0 (durable reveal — inverse of hide_all_logs/0)" do
    test "un-hides every cleared log so the DEFAULT read sees it again (no flag held)" do
      agent = agent_fixture()
      log = log_for(agent.id)
      assert Logs.hide_all_logs() == 1
      refute log.id in Enum.map(Logs.list_recent_global(500), & &1.id)

      assert Logs.release_hidden_logs() == 1
      # Visible in the DEFAULT read — not just under the troubleshooting flag.
      assert log.id in Enum.map(Logs.list_recent_global(500), & &1.id)
    end

    test "is idempotent — a second release with nothing hidden returns 0" do
      agent = agent_fixture()
      _log = log_for(agent.id)
      assert Logs.hide_all_logs() == 1
      assert Logs.release_hidden_logs() == 1
      assert Logs.release_hidden_logs() == 0
    end
  end

  describe "Workflows.hide_finished_runs/0 + list_recent_runs/2 hidden filter" do
    test "hides finished runs, keeps running/queued, excludes hidden by default" do
      {:ok, wf} = Workflows.create_workflow(%{name: "wf-#{uniq()}", steps: []})
      {:ok, running} = Workflows.create_run(%{workflow_id: wf.id, status: :running})
      {:ok, succeeded} = Workflows.create_run(%{workflow_id: wf.id, status: :succeeded})
      {:ok, failed} = Workflows.create_run(%{workflow_id: wf.id, status: :failed})

      assert Workflows.hide_finished_runs() == 2

      visible = Workflows.list_recent_runs(50) |> Enum.map(& &1.id)
      assert running.id in visible
      refute succeeded.id in visible
      refute failed.id in visible

      # Not deleted — the troubleshooting flag reveals the finished runs again.
      all = Workflows.list_recent_runs(50, true) |> Enum.map(& &1.id)
      assert succeeded.id in all
      assert failed.id in all
    end
  end

  describe "Workflows.release_hidden_runs/0 (durable reveal — inverse of hide_finished_runs/0)" do
    test "un-hides cleared finished runs so the DEFAULT read sees them; running/queued untouched" do
      {:ok, wf} = Workflows.create_workflow(%{name: "wf-#{uniq()}", steps: []})
      {:ok, running} = Workflows.create_run(%{workflow_id: wf.id, status: :running})
      {:ok, succeeded} = Workflows.create_run(%{workflow_id: wf.id, status: :succeeded})

      assert Workflows.hide_finished_runs() == 1
      refute succeeded.id in (Workflows.list_recent_runs(50) |> Enum.map(& &1.id))

      assert Workflows.release_hidden_runs() == 1
      visible = Workflows.list_recent_runs(50) |> Enum.map(& &1.id)
      assert succeeded.id in visible
      assert running.id in visible
    end

    test "is idempotent — a second release with nothing hidden returns 0" do
      {:ok, wf} = Workflows.create_workflow(%{name: "wf-#{uniq()}", steps: []})
      {:ok, _succeeded} = Workflows.create_run(%{workflow_id: wf.id, status: :succeeded})
      assert Workflows.hide_finished_runs() == 1
      assert Workflows.release_hidden_runs() == 1
      assert Workflows.release_hidden_runs() == 0
    end
  end
end
