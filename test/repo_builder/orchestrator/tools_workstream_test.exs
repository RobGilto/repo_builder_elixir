defmodule RepoBuilder.Orchestrator.ToolsWorkstreamTest do
  @moduledoc """
  Spec-driven phased orchestration (orchestration-adw-loop): the workstream tools round-trip
  through `Tools.call/3` (the single harness-blind entry point) — create_workstream /
  plan_phases / record_stage / list_workstreams / get_workstream / close_workstream — plus
  `ToolCatalog.names/0` advertising every new tool (binding parity for MCP + pi).
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

  defp create!(orch, title \\ "Build it") do
    {:ok, %{"workstream_id" => id}} =
      Tools.call("create_workstream", orch.id, %{
        "title" => title,
        "goal" => "deliver #{title}",
        "definition_of_done" => "gate green"
      })

    id
  end

  defp plan!(orch, id) do
    {:ok, _} =
      Tools.call("plan_phases", orch.id, %{
        "workstream" => id,
        "phases" => [
          %{"title" => "Phase one", "description" => "first"},
          %{"title" => "Phase two", "description" => "second"}
        ]
      })

    :ok
  end

  describe "ToolCatalog advertises the workstream tools" do
    test "names/0 includes every new tool (MCP + pi parity)" do
      names = ToolCatalog.names()

      for tool <-
            ~w(create_workstream plan_phases record_stage list_workstreams get_workstream close_workstream compact_self) do
        assert tool in names, "expected #{tool} advertised by ToolCatalog.names/0"
      end
    end

    test "every advertised tool has a description and input_schema" do
      for tool <- ToolCatalog.tools() do
        assert is_binary(tool.name) and tool.name != ""
        assert is_binary(tool.description) and tool.description != ""
        assert is_map(tool.input_schema)
      end
    end
  end

  describe "create_workstream / plan_phases / get_workstream" do
    test "creates, plans, and reads the full record", %{orch: orch} do
      id = create!(orch)

      assert {:ok, %{"phases" => 2}} =
               Tools.call("plan_phases", orch.id, %{
                 "workstream" => id,
                 "phases" => [%{"title" => "A"}, %{"title" => "B"}]
               })

      {:ok, record} = Tools.call("get_workstream", orch.id, %{"workstream" => id})
      assert record["status"] == "running"
      assert record["current_phase_position"] == 1
      assert length(record["phases"]) == 2
      assert is_binary(record["next_action"])
    end

    test "create_workstream requires title and goal", %{orch: orch} do
      assert {:error, _} = Tools.call("create_workstream", orch.id, %{"title" => "only title"})
    end

    test "plan_phases rejects an empty / malformed phases arg", %{orch: orch} do
      id = create!(orch)

      assert {:error, _} =
               Tools.call("plan_phases", orch.id, %{"workstream" => id, "phases" => []})

      assert {:error, _} =
               Tools.call("plan_phases", orch.id, %{"workstream" => id, "phases" => "nope"})
    end
  end

  describe "record_stage advances the machine" do
    test "spec passed advances current_stage and captures spec_path", %{orch: orch} do
      id = create!(orch)
      plan!(orch, id)

      {:ok, record} =
        Tools.call("record_stage", orch.id, %{
          "workstream" => id,
          "stage" => "spec",
          "outcome" => "passed",
          "artifact" => "specs/p1.md"
        })

      p1 = Enum.find(record["phases"], &(&1["position"] == 1))
      assert p1["current_stage"] == "implement"
      assert p1["spec_path"] == "specs/p1.md"
    end

    test "unknown workstream / invalid stage surface as tool errors", %{orch: orch} do
      assert {:error, _} =
               Tools.call("record_stage", orch.id, %{
                 "workstream" => Ecto.UUID.generate(),
                 "stage" => "spec",
                 "outcome" => "passed"
               })

      id = create!(orch)
      plan!(orch, id)

      assert {:error, _} =
               Tools.call("record_stage", orch.id, %{
                 "workstream" => id,
                 "stage" => "bogus",
                 "outcome" => "passed"
               })
    end
  end

  describe "list_workstreams / close_workstream" do
    test "lists the compact index then closes", %{orch: orch} do
      id = create!(orch, "Indexed")
      plan!(orch, id)

      {:ok, %{"workstreams" => [row], "count" => 1}} =
        Tools.call("list_workstreams", orch.id, %{})

      assert row["id"] == id
      assert row["phase"] == "1/2"
      assert is_binary(row["next_action"])

      assert {:ok, %{"status" => "done"}} =
               Tools.call("close_workstream", orch.id, %{"workstream" => id, "status" => "done"})
    end
  end

  describe "back-compat" do
    test "an orchestrator that never creates a workstream has an empty index", %{orch: orch} do
      assert {:ok, %{"workstreams" => [], "count" => 0}} =
               Tools.call("list_workstreams", orch.id, %{})
    end
  end
end
