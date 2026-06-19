defmodule RepoBuilder.Orchestrator.ClearContextTest do
  @moduledoc """
  Unit tests for the `clear_context` orchestrator tool (issue clear-context). It
  reaps any live worker session, NULLS the worker's resumable `session_id` so the
  next `command_agent` mints a fresh harness session, marks the worker `:idle`, and
  broadcasts an agent-updated event. Workers run on the keyless Fake harness.
  """
  use RepoBuilder.SessionCase, async: false

  alias RepoBuilder.{Agents, Dashboard, Orchestrators, Session}
  alias RepoBuilder.Orchestrator.{ToolCatalog, Tools}

  defp uniq, do: System.unique_integer([:positive])

  # Drain spawned worker sessions before the sandbox owner exits (mirrors tools_test).
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

  defp orchestrator do
    {:ok, orch} = Orchestrators.create(%{name: "orch-#{uniq()}", harness: "fake"})
    orch
  end

  defp worker(orch) do
    name = "worker-#{uniq()}"

    {:ok, _} =
      Tools.call("create_agent", orch.id, %{
        "name" => name,
        "harness" => "fake",
        "model" => "fake-model"
      })

    {:ok, w} = Agents.get_by_name_for_orchestrator(orch.id, name)
    {name, w}
  end

  describe "clear_context" do
    test "nulls the worker's session and marks it idle (Case A)" do
      orch = orchestrator()
      {name, w} = worker(orch)

      {:ok, _} = Agents.set_session(w.id, "worker-existing-session")
      {:ok, _} = Agents.set_status(w.id, :running)

      assert {:ok, %{"status" => "cleared", "name" => ^name}} =
               Tools.call("clear_context", orch.id, %{"name" => name})

      reloaded = Agents.get_agent(w.id)
      assert reloaded.session_id == nil
      assert reloaded.status == :idle
    end

    test "broadcasts an agent-updated event reflecting the idle reset" do
      :ok = Dashboard.subscribe_events()
      orch = orchestrator()
      {name, _w} = worker(orch)

      assert {:ok, _} = Tools.call("clear_context", orch.id, %{"name" => name})
      assert_receive {:agent_updated, %{name: ^name, status: :idle}}
    end

    test "the next dispatch mints a fresh, different session id (Case B)" do
      orch = orchestrator()
      {name, w} = worker(orch)

      {:ok, _} = Agents.set_session(w.id, "worker-old-session")
      assert {:ok, _} = Tools.call("clear_context", orch.id, %{"name" => name})
      assert Agents.get_agent(w.id).session_id == nil

      assert {:ok, %{"status" => "dispatched"}} =
               Tools.call("command_agent", orch.id, %{"name" => name, "prompt" => "do work"})

      new_session = Agents.get_agent(w.id).session_id
      assert is_binary(new_session)
      assert new_session != "worker-old-session"
    end

    test "reaps a live worker session (Case D)" do
      orch = orchestrator()
      {name, w} = worker(orch)

      assert {:ok, _} =
               Tools.call("command_agent", orch.id, %{"name" => name, "prompt" => "long task"})

      # The session may finish fast on the Fake harness; only assert reaping when live.
      if Session.Supervisor.whereis(w.id) do
        assert {:ok, _} = Tools.call("clear_context", orch.id, %{"name" => name})
        assert Session.Supervisor.whereis(w.id) == nil
      else
        assert {:ok, _} = Tools.call("clear_context", orch.id, %{"name" => name})
      end
    end

    test "an unknown worker returns {:error, :not_found} (Case C)" do
      orch = orchestrator()
      assert {:error, :not_found} = Tools.call("clear_context", orch.id, %{"name" => "ghost"})
    end

    test "a worker owned by another orchestrator is not found (no cross-tenant clear)" do
      orch_a = orchestrator()
      orch_b = orchestrator()
      {name, _w} = worker(orch_a)

      assert {:error, :not_found} = Tools.call("clear_context", orch_b.id, %{"name" => name})
    end

    test "a never-dispatched worker (nil session) still clears cleanly" do
      orch = orchestrator()
      {name, w} = worker(orch)
      assert Agents.get_agent(w.id).session_id == nil

      assert {:ok, %{"status" => "cleared"}} =
               Tools.call("clear_context", orch.id, %{"name" => name})
    end

    test "missing name is an error" do
      orch = orchestrator()
      assert {:error, _reason} = Tools.call("clear_context", orch.id, %{})
    end
  end

  describe "tool catalog" do
    test "advertises clear_context with a required name input" do
      tool = Enum.find(ToolCatalog.tools(), &(&1.name == "clear_context"))

      assert tool
      assert tool.input_schema["required"] == ["name"]
      assert get_in(tool.input_schema, ["properties", "name", "type"]) == "string"
    end
  end
end
