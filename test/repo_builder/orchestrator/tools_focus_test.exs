defmodule RepoBuilder.Orchestrator.ToolsFocusTest do
  @moduledoc """
  Focus discipline through `Tools.call/3` (the harness-blind entry point): the `set_focus` /
  `clear_focus` handlers at both scopes, and the deterministic SCOPE-AWARE focus gate that
  refuses budget-spending worker tools when the targeted scope (a running workstream, or the
  active ledger for untagged work) has no focus.
  """
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.Orchestrator.ToolCatalog
  alias RepoBuilder.Orchestrator.Tools
  alias RepoBuilder.Orchestrators

  setup do
    {:ok, orch} =
      Orchestrators.create(%{name: "orch-#{System.unique_integer([:positive])}", harness: "fake"})

    %{orch: orch}
  end

  defp set_goal!(orch) do
    {:ok, _} =
      Tools.call("set_goal", orch.id, %{
        "goal" => "ship it",
        "definition_of_done" => "green"
      })

    :ok
  end

  defp create_ws!(orch, title \\ "Build it") do
    {:ok, %{"workstream_id" => id}} =
      Tools.call("create_workstream", orch.id, %{
        "title" => title,
        "goal" => "deliver #{title}",
        "definition_of_done" => "gate green"
      })

    id
  end

  # A `command_agent` call that is well-formed enough to reach dispatch (so the ONLY reason it
  # can return `:focus_required` is the gate, never a malformed-args error).
  defp command_args(extra \\ %{}) do
    Map.merge(%{"name" => "worker", "command" => "do the thing"}, extra)
  end

  describe "ToolCatalog advertises the focus tools" do
    test "names/0 includes set_focus and clear_focus (MCP + pi parity)" do
      names = ToolCatalog.names()
      assert "set_focus" in names
      assert "clear_focus" in names
    end
  end

  describe "set_focus / clear_focus handlers" do
    test "orchestrator scope: set_focus then get_ledger shows it; clear_focus removes it", %{
      orch: orch
    } do
      set_goal!(orch)

      assert {:ok, %{"status" => "focused", "scope" => "orchestrator", "focus" => "the gate"}} =
               Tools.call("set_focus", orch.id, %{"focus" => "the gate"})

      assert {:ok, ledger} = Tools.call("get_ledger", orch.id, %{})
      assert ledger["focus"] == "the gate"

      assert {:ok, %{"status" => "focus_cleared", "scope" => "orchestrator"}} =
               Tools.call("clear_focus", orch.id, %{})

      assert {:ok, ledger} = Tools.call("get_ledger", orch.id, %{})
      assert ledger["focus"] == nil
    end

    test "workstream scope: set_focus then get_workstream shows it; clear_focus removes it", %{
      orch: orch
    } do
      id = create_ws!(orch)

      assert {:ok, %{"status" => "focused", "scope" => "workstream", "focus" => "phase 2"}} =
               Tools.call("set_focus", orch.id, %{"workstream" => id, "focus" => "phase 2"})

      assert {:ok, record} = Tools.call("get_workstream", orch.id, %{"workstream" => id})
      assert record["focus"] == "phase 2"

      assert {:ok, %{"status" => "focus_cleared", "scope" => "workstream"}} =
               Tools.call("clear_focus", orch.id, %{"workstream" => id})

      assert {:ok, record} = Tools.call("get_workstream", orch.id, %{"workstream" => id})
      assert record["focus"] == nil
    end

    test "blank focus is rejected at the tool boundary", %{orch: orch} do
      set_goal!(orch)
      assert {:error, _} = Tools.call("set_focus", orch.id, %{"focus" => ""})
    end

    test "set_focus on an unknown workstream returns :not_found", %{orch: orch} do
      assert {:error, :not_found} =
               Tools.call("set_focus", orch.id, %{"workstream" => "nope", "focus" => "x"})
    end
  end

  describe "untagged focus gate" do
    test "active goal with no focus blocks command_agent with :focus_required", %{orch: orch} do
      set_goal!(orch)
      assert {:error, :focus_required} = Tools.call("command_agent", orch.id, command_args())
    end

    test "once the orchestrator is focused, command_agent is no longer gated", %{orch: orch} do
      set_goal!(orch)
      {:ok, _} = Tools.call("set_focus", orch.id, %{"focus" => "the gate"})

      # The call may still fail for unrelated reasons (no such worker), but NOT on the gate.
      assert Tools.call("command_agent", orch.id, command_args()) != {:error, :focus_required}
    end

    test "with no active goal, worker tools are never gated (back-compat)", %{orch: orch} do
      assert Tools.call("command_agent", orch.id, command_args()) != {:error, :focus_required}
    end
  end

  describe "workstream focus gate" do
    test "a running workstream with no focus blocks a command targeting it", %{orch: orch} do
      id = create_ws!(orch)

      assert {:error, :focus_required} =
               Tools.call("command_agent", orch.id, command_args(%{"workstream" => id}))
    end

    test "focusing the workstream unblocks it — independently of the orchestrator focus", %{
      orch: orch
    } do
      set_goal!(orch)
      id = create_ws!(orch)
      # Orchestrator itself is deliberately left UNFOCUSED.
      {:ok, _} = Tools.call("set_focus", orch.id, %{"workstream" => id, "focus" => "phase 2"})

      refute Tools.call("command_agent", orch.id, command_args(%{"workstream" => id})) ==
               {:error, :focus_required}
    end

    test "an orchestrator focus does NOT satisfy a workstream-scoped call", %{orch: orch} do
      set_goal!(orch)
      id = create_ws!(orch)
      {:ok, _} = Tools.call("set_focus", orch.id, %{"focus" => "untagged thing"})

      assert {:error, :focus_required} =
               Tools.call("command_agent", orch.id, command_args(%{"workstream" => id}))
    end
  end

  describe "what is NEVER gated" do
    test "plan_phases is not gated (it is the declaration step)", %{orch: orch} do
      id = create_ws!(orch)

      # No focus set; plan_phases must still proceed.
      assert {:ok, _} =
               Tools.call("plan_phases", orch.id, %{
                 "workstream" => id,
                 "phases" => [%{"title" => "P1", "description" => "first"}]
               })
    end

    test "read-only / ledger / workstream-read / focus tools are never gated", %{orch: orch} do
      set_goal!(orch)
      id = create_ws!(orch)

      for {tool, args} <- [
            {"get_ledger", %{}},
            {"list_agents", %{}},
            {"list_workstreams", %{}},
            {"get_workstream", %{"workstream" => id}},
            {"set_focus", %{"focus" => "x"}},
            {"clear_focus", %{}}
          ] do
        assert Tools.call(tool, orch.id, args) != {:error, :focus_required},
               "#{tool} must never be focus-gated"
      end
    end
  end

  describe "gate config toggle" do
    setup do
      prior = Application.get_env(:repo_builder, :orchestrator, [])
      Application.put_env(:repo_builder, :orchestrator, Keyword.put(prior, :focus_gate, false))
      on_exit(fn -> Application.put_env(:repo_builder, :orchestrator, prior) end)
      :ok
    end

    test "focus_gate: false never engages the gate", %{orch: orch} do
      set_goal!(orch)
      assert Tools.call("command_agent", orch.id, command_args()) != {:error, :focus_required}
    end
  end
end
