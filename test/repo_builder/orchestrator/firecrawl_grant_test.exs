defmodule RepoBuilder.Orchestrator.FirecrawlGrantTest do
  @moduledoc """
  Tests the orchestrator-granted firecrawl capability (issue firecrawl-grant):
  `create_agent`/`update_agent` persist/replace `config["tools"]` while preserving
  other config keys, an all-unknown grant is rejected, and the tool catalog advertises
  the `tools` param on both meta-tools.
  """
  use RepoBuilder.SessionCase, async: false

  alias RepoBuilder.{Agents, Orchestrators}
  alias RepoBuilder.Orchestrator.{ToolCatalog, Tools}

  defp uniq, do: System.unique_integer([:positive])

  defp orchestrator do
    {:ok, orch} = Orchestrators.create(%{name: "orch-#{uniq()}", harness: "fake"})
    orch
  end

  describe "create_agent with tools" do
    test "persists config[\"tools\"] and preserves the provider" do
      orch = orchestrator()
      name = "researcher-#{uniq()}"

      assert {:ok, %{"id" => id}} =
               Tools.call("create_agent", orch.id, %{
                 "name" => name,
                 "harness" => "pi",
                 "provider" => "openai",
                 "tools" => ["firecrawl"]
               })

      worker = Agents.get_agent(id)
      assert worker.config["tools"] == ["firecrawl"]
      assert worker.config["provider"] == "openai"
    end

    test "drops unknown tool names but keeps the known ones" do
      orch = orchestrator()
      name = "researcher-#{uniq()}"

      assert {:ok, %{"id" => id}} =
               Tools.call("create_agent", orch.id, %{
                 "name" => name,
                 "harness" => "fake",
                 "tools" => ["firecrawl", "bogus"]
               })

      assert Agents.get_agent(id).config["tools"] == ["firecrawl"]
    end

    test "an all-unknown grant is rejected with the known set" do
      orch = orchestrator()

      assert {:error, reason} =
               Tools.call("create_agent", orch.id, %{
                 "name" => "x-#{uniq()}",
                 "harness" => "fake",
                 "tools" => ["bogus"]
               })

      assert reason =~ "firecrawl"
    end

    test "no tools key ⇒ no tools in config" do
      orch = orchestrator()
      name = "plain-#{uniq()}"

      assert {:ok, %{"id" => id}} =
               Tools.call("create_agent", orch.id, %{"name" => name, "harness" => "fake"})

      refute Map.has_key?(Agents.get_agent(id).config, "tools")
    end
  end

  describe "update_agent tools" do
    setup do
      orch = orchestrator()
      name = "researcher-#{uniq()}"

      {:ok, %{"id" => id}} =
        Tools.call("create_agent", orch.id, %{
          "name" => name,
          "harness" => "pi",
          "provider" => "openai"
        })

      %{orch: orch, name: name, id: id}
    end

    test "adds the grant, preserving provider", %{orch: orch, name: name, id: id} do
      assert {:ok, _} =
               Tools.call("update_agent", orch.id, %{"name" => name, "tools" => ["firecrawl"]})

      worker = Agents.get_agent(id)
      assert worker.config["tools"] == ["firecrawl"]
      assert worker.config["provider"] == "openai"
    end

    test "an empty array revokes the grant", %{orch: orch, name: name, id: id} do
      {:ok, _} = Tools.call("update_agent", orch.id, %{"name" => name, "tools" => ["firecrawl"]})
      assert Agents.get_agent(id).config["tools"] == ["firecrawl"]

      assert {:ok, _} = Tools.call("update_agent", orch.id, %{"name" => name, "tools" => []})
      assert Agents.get_agent(id).config["tools"] == []
    end
  end

  describe "tool catalog" do
    test "create_agent and update_agent advertise the tools array param" do
      tools = ToolCatalog.tools()

      for tool_name <- ["create_agent", "update_agent"] do
        tool = Enum.find(tools, &(&1.name == tool_name))
        prop = get_in(tool.input_schema, ["properties", "tools"])
        assert prop["type"] == "array"
        assert get_in(prop, ["items", "enum"]) == ["firecrawl"]
      end
    end
  end
end
