defmodule RepoBuilderWeb.OrchestratorMCPControllerTest do
  @moduledoc """
  JSON-RPC contract + token-auth tests for the orchestrator MCP-over-HTTP surface
  (issue-c). Drives the endpoint with a real per-orchestrator token; verifies the
  `initialize` / `tools/list` / `tools/call` shapes, MCP error wrapping, and that a
  bad/missing token is rejected with `401` and never executes a tool.
  """
  use RepoBuilderWeb.ConnCase, async: false

  alias RepoBuilder.{Agents, Orchestrators}

  defp uniq, do: System.unique_integer([:positive])

  defp setup_orchestrator do
    {:ok, orch} = Orchestrators.create(%{name: "orch-#{uniq()}", harness: "fake"})
    {:ok, token} = Orchestrators.mint_token(orch.id)
    {orch, token}
  end

  defp post_rpc(conn, orchestrator_id, token, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> post("/orchestrator/#{orchestrator_id}/mcp", body)
  end

  describe "initialize" do
    test "returns protocol capabilities", %{conn: conn} do
      {orch, token} = setup_orchestrator()

      resp =
        conn
        |> post_rpc(orch.id, token, %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"})
        |> json_response(200)

      assert resp["id"] == 1
      assert resp["result"]["protocolVersion"]
      assert resp["result"]["capabilities"]["tools"]
    end
  end

  describe "tools/list" do
    test "returns the full catalog with camelCase inputSchema", %{conn: conn} do
      {orch, token} = setup_orchestrator()

      resp =
        conn
        |> post_rpc(orch.id, token, %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"})
        |> json_response(200)

      names = Enum.map(resp["result"]["tools"], & &1["name"])
      assert "create_agent" in names
      assert "command_agent" in names
      assert Enum.all?(resp["result"]["tools"], &Map.has_key?(&1, "inputSchema"))
    end
  end

  describe "tools/call" do
    test "create_agent creates a worker row and returns an ok content envelope", %{conn: conn} do
      {orch, token} = setup_orchestrator()
      name = "w-#{uniq()}"

      resp =
        conn
        |> post_rpc(orch.id, token, %{
          "jsonrpc" => "2.0",
          "id" => 3,
          "method" => "tools/call",
          "params" => %{
            "name" => "create_agent",
            "arguments" => %{"name" => name, "harness" => "fake"}
          }
        })
        |> json_response(200)

      assert resp["result"]["isError"] == false
      assert [%{"type" => "text", "text" => text}] = resp["result"]["content"]
      assert text =~ name
      assert {:ok, _worker} = Agents.get_by_name_for_orchestrator(orch.id, name)
    end

    test "a tool error is wrapped as isError: true, not a JSON-RPC error", %{conn: conn} do
      {orch, token} = setup_orchestrator()

      resp =
        conn
        |> post_rpc(orch.id, token, %{
          "jsonrpc" => "2.0",
          "id" => 4,
          "method" => "tools/call",
          "params" => %{
            "name" => "command_agent",
            "arguments" => %{"name" => "ghost", "prompt" => "x"}
          }
        })
        |> json_response(200)

      refute resp["error"]
      assert resp["result"]["isError"] == true
    end
  end

  describe "errors" do
    test "unknown method is a JSON-RPC error object, not a 500", %{conn: conn} do
      {orch, token} = setup_orchestrator()

      resp =
        conn
        |> post_rpc(orch.id, token, %{"jsonrpc" => "2.0", "id" => 5, "method" => "nope/nope"})
        |> json_response(200)

      assert resp["error"]["code"] == -32_601
    end

    test "missing token is 401 and executes no tool", %{conn: conn} do
      {orch, _token} = setup_orchestrator()

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/orchestrator/#{orch.id}/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 6,
          "method" => "tools/list"
        })

      assert json_response(conn, 401)["error"]["message"] == "unauthorized"
    end

    test "wrong token is 401", %{conn: conn} do
      {orch, _token} = setup_orchestrator()

      conn =
        post_rpc(conn, orch.id, "not-the-token", %{
          "jsonrpc" => "2.0",
          "id" => 7,
          "method" => "tools/list"
        })

      assert json_response(conn, 401)
    end
  end
end
