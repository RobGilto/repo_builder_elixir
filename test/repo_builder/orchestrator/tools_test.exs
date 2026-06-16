defmodule RepoBuilder.Orchestrator.ToolsTest do
  @moduledoc """
  Unit tests for the harness-blind orchestrator tool logic (issue-c). Workers run
  on the keyless Fake harness; the Repo is the test sandbox. Covers each tool's
  happy path plus its `{:error, reason}` branches (unknown agent, duplicate name,
  unknown harness, unknown tool).
  """
  use RepoBuilder.SessionCase, async: false

  alias RepoBuilder.{Agents, Orchestrators, Workflows}
  alias RepoBuilder.Orchestrator.Tools

  defp uniq, do: System.unique_integer([:positive])

  # Drain spawned worker/workflow sessions before the sandbox owner exits so they
  # don't crash on a torn-down connection or leak events into a later test.
  setup do
    on_exit(&drain_sessions/0)
    :ok
  end

  defp drain_sessions(attempts \\ 200) do
    case DynamicSupervisor.count_children(RepoBuilder.SessionSupervisor) do
      %{active: 0} -> :ok
      _ when attempts > 0 -> Process.sleep(20) && drain_sessions(attempts - 1)
      _ -> :ok
    end
  end

  defp orchestrator(harness \\ "fake") do
    {:ok, orch} = Orchestrators.create(%{name: "orch-#{uniq()}", harness: harness})
    orch
  end

  describe "create_agent" do
    test "creates a worker scoped to the orchestrator and broadcasts agent_created" do
      :ok = RepoBuilder.Dashboard.subscribe_events()
      orch = orchestrator()
      name = "worker-#{uniq()}"

      assert {:ok, result} =
               Tools.call("create_agent", orch.id, %{"name" => name, "harness" => "fake"})

      assert result["name"] == name
      assert result["harness"] == "fake"
      assert {:ok, worker} = Agents.get_by_name_for_orchestrator(orch.id, name)
      assert worker.orchestrator_id == orch.id
      assert_receive {:agent_created, %{name: ^name}}
    end

    test "defaults the harness from the orchestrator when omitted" do
      orch = orchestrator("fake")
      name = "worker-#{uniq()}"

      assert {:ok, %{"harness" => "fake"}} =
               Tools.call("create_agent", orch.id, %{"name" => name})
    end

    test "missing name is an error" do
      orch = orchestrator()
      assert {:error, _reason} = Tools.call("create_agent", orch.id, %{"harness" => "fake"})
    end

    test "category resolves the worker's harness/provider/model from the roster" do
      orch = orchestrator("fake")

      {:ok, _} =
        Orchestrators.set_agent_model(orch.id, "heavy", %{
          "harness" => "fake",
          "provider" => "minimax",
          "model" => "MiniMax-M3"
        })

      name = "heavy-#{uniq()}"

      assert {:ok, result} =
               Tools.call("create_agent", orch.id, %{"name" => name, "category" => "heavy"})

      assert result["model"] == "MiniMax-M3"
      assert result["provider"] == "minimax"

      assert {:ok, worker} = Agents.get_by_name_for_orchestrator(orch.id, name)
      assert worker.model == "MiniMax-M3"
      # The open provider rides in config (the enum column can't hold it).
      assert worker.config["provider"] == "minimax"
    end

    test "a category with no assigned model is rejected" do
      orch = orchestrator("fake")

      {:ok, _} =
        Orchestrators.set_agent_model(orch.id, "fast", %{"harness" => "fake", "model" => ""})

      assert {:error, reason} =
               Tools.call("create_agent", orch.id, %{
                 "name" => "x-#{uniq()}",
                 "category" => "fast"
               })

      assert reason =~ "no model selected for category fast"
    end

    test "duplicate name within one orchestrator is rejected" do
      orch = orchestrator()
      name = "dup-#{uniq()}"

      assert {:ok, _} =
               Tools.call("create_agent", orch.id, %{"name" => name, "harness" => "fake"})

      assert {:error, _reason} =
               Tools.call("create_agent", orch.id, %{"name" => name, "harness" => "fake"})
    end

    test "the same name under a DIFFERENT orchestrator is allowed" do
      name = "shared-#{uniq()}"
      a = orchestrator()
      b = orchestrator()
      assert {:ok, _} = Tools.call("create_agent", a.id, %{"name" => name, "harness" => "fake"})
      assert {:ok, _} = Tools.call("create_agent", b.id, %{"name" => name, "harness" => "fake"})
    end

    test "unknown harness is rejected (harness openness preserved via registry)" do
      orch = orchestrator()

      assert {:error, _reason} =
               Tools.call("create_agent", orch.id, %{"name" => "x-#{uniq()}", "harness" => "nope"})
    end
  end

  describe "list_agents" do
    test "lists only this orchestrator's workers" do
      a = orchestrator()
      b = orchestrator()

      {:ok, _} =
        Tools.call("create_agent", a.id, %{"name" => "a1-#{uniq()}", "harness" => "fake"})

      {:ok, _} =
        Tools.call("create_agent", b.id, %{"name" => "b1-#{uniq()}", "harness" => "fake"})

      assert {:ok, %{"agents" => [_], "count" => 1}} = Tools.call("list_agents", a.id, %{})
    end
  end

  describe "command_agent" do
    test "dispatches to a known worker and persists its resume session id" do
      orch = orchestrator()
      name = "cmd-#{uniq()}"

      {:ok, _} =
        Tools.call("create_agent", orch.id, %{
          "name" => name,
          "harness" => "fake",
          "model" => "fake-model-1"
        })

      assert {:ok, %{"status" => "dispatched", "name" => ^name}} =
               Tools.call("command_agent", orch.id, %{"name" => name, "prompt" => "do it"})

      assert {:ok, worker} = Agents.get_by_name_for_orchestrator(orch.id, name)
      assert is_binary(worker.session_id)
    end

    test "unknown worker is {:error, :not_found}" do
      orch = orchestrator()

      assert {:error, :not_found} =
               Tools.call("command_agent", orch.id, %{"name" => "ghost", "prompt" => "x"})
    end

    test "missing prompt is an error" do
      orch = orchestrator()
      name = "cmd2-#{uniq()}"
      {:ok, _} = Tools.call("create_agent", orch.id, %{"name" => name, "harness" => "fake"})
      assert {:error, _reason} = Tools.call("command_agent", orch.id, %{"name" => name})
    end
  end

  describe "check_agent_status" do
    test "returns status, cost, and a recent-event tail" do
      orch = orchestrator()
      name = "stat-#{uniq()}"
      {:ok, _} = Tools.call("create_agent", orch.id, %{"name" => name, "harness" => "fake"})

      assert {:ok, result} = Tools.call("check_agent_status", orch.id, %{"name" => name})
      assert result["name"] == name
      assert is_binary(result["cost_usd"])
      assert is_list(result["recent_events"])
    end

    test "unknown worker is {:error, :not_found}" do
      orch = orchestrator()

      assert {:error, :not_found} =
               Tools.call("check_agent_status", orch.id, %{"name" => "ghost"})
    end
  end

  describe "interrupt_agent" do
    test "unknown worker is {:error, :not_found}" do
      orch = orchestrator()
      assert {:error, :not_found} = Tools.call("interrupt_agent", orch.id, %{"name" => "ghost"})
    end

    test "interrupts a known worker" do
      orch = orchestrator()
      name = "int-#{uniq()}"
      {:ok, _} = Tools.call("create_agent", orch.id, %{"name" => name, "harness" => "fake"})

      assert {:ok, %{"status" => "interrupted"}} =
               Tools.call("interrupt_agent", orch.id, %{"name" => name})
    end
  end

  describe "start_adw" do
    test "launches the seeded workflow and returns a run id" do
      orch = orchestrator()

      assert {:ok, %{"run_id" => run_id}} =
               Tools.call("start_adw", orch.id, %{"input" => "ship it", "harness" => "fake"})

      assert is_binary(run_id)
      # Let the spawned runner reach a terminal state before the sandbox owner exits,
      # so its step sessions don't crash on a torn-down connection.
      assert_run_terminal(run_id)
    end
  end

  defp assert_run_terminal(run_id, attempts \\ 80) do
    case Workflows.get_run(run_id) do
      %{status: status} when status in [:succeeded, :failed, :aborted] ->
        :ok

      _ when attempts > 0 ->
        Process.sleep(25)
        assert_run_terminal(run_id, attempts - 1)

      _ ->
        flunk("workflow #{run_id} did not reach a terminal state")
    end
  end

  describe "dispatch" do
    test "unknown tool is {:error, :unknown_tool}" do
      orch = orchestrator()
      assert {:error, :unknown_tool} = Tools.call("nope", orch.id, %{})
    end
  end
end
