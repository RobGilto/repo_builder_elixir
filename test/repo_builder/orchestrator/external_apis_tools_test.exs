defmodule RepoBuilder.Orchestrator.ExternalApisToolsTest do
  @moduledoc """
  Orchestrator delegation seam for the registered external API registry
  (issue-external-api-mcp-provisioning): `list_apis` returns in-scope rows without a
  token, `create_agent` validates/persists `config["apis"]` and prepends the API
  instructions to the worker charter, an unknown name errors, and the tool catalog
  advertises the `list_apis` tool plus the `apis` param on both meta-tools.
  """
  use RepoBuilder.SessionCase, async: false

  alias RepoBuilder.{Agents, ExternalApis, Orchestrators}
  alias RepoBuilder.Orchestrator.{ToolCatalog, Tools}

  defp uniq, do: System.unique_integer([:positive])

  defp orchestrator do
    {:ok, orch} = Orchestrators.create(%{name: "orch-#{uniq()}", harness: "fake"})
    orch
  end

  defp register_pixellab do
    {:ok, api} =
      ExternalApis.create(%{
        "name" => "pixellab",
        "transport" => "http",
        "url" => "https://api.pixellab.ai/mcp",
        "auth_scheme" => "bearer",
        "secret_name" => "PIXELLAB_API_KEY",
        "description" => "Image generation MCP",
        "instructions" => "Call mcp__pixellab__generate to render an image.",
        "doc_urls" => ["https://api.pixellab.ai/mcp/docs"]
      })

    api
  end

  describe "list_apis" do
    test "returns in-scope registrations without leaking a token" do
      orch = orchestrator()
      register_pixellab()

      assert {:ok, %{"apis" => apis, "count" => 1}} = Tools.call("list_apis", orch.id, %{})
      assert [entry] = apis
      assert entry["name"] == "pixellab"
      assert entry["scope"] == "platform"
      assert entry["transport"] == "http"
      assert entry["description"] == "Image generation MCP"
      assert entry["doc_urls"] == ["https://api.pixellab.ai/mcp/docs"]
      # Name-only exposure: the secret reference is surfaced, never a value/ciphertext.
      assert entry["secret_name"] == "PIXELLAB_API_KEY"
      refute Map.has_key?(entry, "token")
      refute Map.has_key?(entry, "secret_value")
    end
  end

  describe "create_agent with apis" do
    test "persists config[\"apis\"] and prepends the API instructions to the charter" do
      orch = orchestrator()
      register_pixellab()
      name = "imager-#{uniq()}"

      assert {:ok, %{"id" => id}} =
               Tools.call("create_agent", orch.id, %{
                 "name" => name,
                 "harness" => "fake",
                 "apis" => ["pixellab"]
               })

      worker = Agents.get_agent(id)
      assert worker.config["apis"] == ["pixellab"]
      assert worker.system_prompt =~ "pixellab"
      assert worker.system_prompt =~ "Call mcp__pixellab__generate"
    end

    test "an unknown api name is rejected up front" do
      orch = orchestrator()

      assert {:error, reason} =
               Tools.call("create_agent", orch.id, %{
                 "name" => "x-#{uniq()}",
                 "harness" => "fake",
                 "apis" => ["nope"]
               })

      assert reason =~ "nope"
    end

    test "no apis key ⇒ no apis in config" do
      orch = orchestrator()

      assert {:ok, %{"id" => id}} =
               Tools.call("create_agent", orch.id, %{
                 "name" => "plain-#{uniq()}",
                 "harness" => "fake"
               })

      refute Map.has_key?(Agents.get_agent(id).config, "apis")
    end
  end

  describe "tool catalog" do
    test "advertises list_apis and the apis param on create_agent/command_agent" do
      tools = ToolCatalog.tools()

      assert Enum.find(tools, &(&1.name == "list_apis"))

      for tool_name <- ["create_agent", "command_agent"] do
        tool = Enum.find(tools, &(&1.name == tool_name))
        prop = get_in(tool.input_schema, ["properties", "apis"])
        assert prop["type"] == "array"
        assert get_in(prop, ["items", "type"]) == "string"
      end
    end
  end
end
