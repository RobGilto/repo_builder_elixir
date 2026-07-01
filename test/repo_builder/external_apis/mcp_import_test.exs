defmodule RepoBuilder.ExternalApis.McpImportTest do
  @moduledoc """
  The pure deterministic MCP-config parser (issue-external-api-mcp-provisioning): maps the
  common config shapes onto the `ExternalApi.changeset/2` field set, stages embedded tokens
  for the vault, and asks a clarifying question when a required field is missing — without
  ever placing a literal token in `api_params`.
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.ExternalApis.{ExternalApi, ImportResult, McpImport}

  describe "parse/1 — recognized shapes" do
    test "Claude mcpServers single http server registers" do
      blob = ~s({"mcpServers":{"pixellab":{"url":"https://api.pixellab.ai/mcp","type":"http"}}})

      assert {:ok, %ImportResult{action: :register, source: :deterministic} = result} =
               McpImport.parse(blob)

      assert result.api_params["name"] == "pixellab"
      assert result.api_params["transport"] == "http"
      assert result.api_params["url"] == "https://api.pixellab.ai/mcp"
    end

    test "stdio server with command and args registers" do
      blob =
        ~s({"mcpServers":{"fs":{"command":"npx","args":["-y","@modelcontextprotocol/server-filesystem"]}}})

      assert {:ok, %ImportResult{action: :register} = result} = McpImport.parse(blob)
      assert result.api_params["transport"] == "stdio"
      assert result.api_params["command"] == "npx"
      assert result.api_params["args"] == ["-y", "@modelcontextprotocol/server-filesystem"]
    end

    test "sse transport inferred from a /sse url" do
      blob = ~s({"mcpServers":{"events":{"url":"https://example.com/sse"}}})

      assert {:ok, %ImportResult{action: :register} = result} = McpImport.parse(blob)
      assert result.api_params["transport"] == "sse"
    end

    test "explicit sse type wins over url inference" do
      blob = ~s({"mcpServers":{"events":{"url":"https://example.com/mcp","type":"sse"}}})

      assert {:ok, %ImportResult{} = result} = McpImport.parse(blob)
      assert result.api_params["transport"] == "sse"
    end

    test "a bare single-server object registers" do
      blob = ~s({"name":"pixellab","url":"https://api.pixellab.ai/mcp","type":"http"})

      assert {:ok, %ImportResult{action: :register} = result} = McpImport.parse(blob)
      assert result.api_params["name"] == "pixellab"
    end

    test "tolerates a ```json fenced blob" do
      blob = """
      ```json
      {"mcpServers":{"pixellab":{"url":"https://api.pixellab.ai/mcp","type":"http"}}}
      ```
      """

      assert {:ok, %ImportResult{action: :register}} = McpImport.parse(blob)
    end
  end

  describe "parse/1 — secret extraction (secret-safe)" do
    test "Authorization Bearer header → bearer scheme, derived secret name, staged value" do
      blob =
        ~s({"mcpServers":{"pixellab":{"url":"https://api.pixellab.ai/mcp","type":"http","headers":{"Authorization":"Bearer sk-live-123"}}}})

      assert {:ok, %ImportResult{} = result} = McpImport.parse(blob)
      assert result.api_params["auth_scheme"] == "bearer"
      assert result.secret_name == "PIXELLAB_API_KEY"
      assert result.api_params["secret_name"] == "PIXELLAB_API_KEY"
      assert result.secret_value == "sk-live-123"
      # The literal token must NEVER appear in the persisted params.
      refute Enum.any?(Map.values(result.api_params), &(&1 == "sk-live-123"))
      refute Map.has_key?(result.api_params, "headers")
    end

    test "custom auth header → header scheme with the header name" do
      blob =
        ~s({"mcpServers":{"svc":{"url":"https://svc.example/mcp","type":"http","headers":{"X-Api-Key":"tok-abc"}}}})

      assert {:ok, %ImportResult{} = result} = McpImport.parse(blob)
      assert result.api_params["auth_scheme"] == "header"
      assert result.api_params["auth_header"] == "X-Api-Key"
      assert result.secret_value == "tok-abc"
      refute Enum.any?(Map.values(result.api_params), &(&1 == "tok-abc"))
    end

    test "env credential → secret name from the env var, staged value" do
      blob =
        ~s({"mcpServers":{"fs":{"command":"npx","args":["x"],"env":{"PIXELLAB_API_KEY":"sk-env-9"}}}})

      assert {:ok, %ImportResult{} = result} = McpImport.parse(blob)
      assert result.secret_name == "PIXELLAB_API_KEY"
      assert result.secret_value == "sk-env-9"
      assert result.api_params["auth_scheme"] == "bearer"
      refute Enum.any?(Map.values(result.api_params), &(&1 == "sk-env-9"))
    end

    test "a ${PLACEHOLDER} header value is a reference, not a token — not staged" do
      blob =
        ~s({"mcpServers":{"pixellab":{"url":"https://api.pixellab.ai/mcp","type":"http","headers":{"Authorization":"Bearer ${PIXELLAB_API_KEY}"}}}})

      assert {:ok, %ImportResult{} = result} = McpImport.parse(blob)
      assert result.api_params["auth_scheme"] == "bearer"
      assert result.secret_value == nil
    end

    test "no credential → none scheme" do
      blob = ~s({"mcpServers":{"pub":{"url":"https://pub.example/mcp","type":"http"}}})

      assert {:ok, %ImportResult{} = result} = McpImport.parse(blob)
      assert result.api_params["auth_scheme"] == "none"
      assert result.secret_value == nil
    end
  end

  describe "parse/1 — questions" do
    test "multiple servers ask which to register and pre-draft the first" do
      blob =
        ~s({"mcpServers":{"a":{"url":"https://a.example/mcp","type":"http"},"b":{"command":"npx"}}})

      assert {:ok, %ImportResult{action: :question} = result} = McpImport.parse(blob)
      assert result.question =~ "2 servers"
      assert result.api_params["name"] == "a"
    end

    test "object with neither url nor command but a name asks the transport" do
      blob = ~s({"name":"mystery","type":"weird"})

      assert {:ok, %ImportResult{action: :question} = result} = McpImport.parse(blob)
      assert is_binary(result.question)
    end
  end

  describe "parse/1 — fall back / errors" do
    test "free-form prose falls back to the agent" do
      assert {:needs_agent, _hint} = McpImport.parse("register the pixellab MCP for me")
    end

    test "blank input is an error" do
      assert {:error, :empty} = McpImport.parse("   ")
    end
  end

  describe "contract round-trip" do
    test "register params produce a valid ExternalApi changeset" do
      blob =
        ~s({"mcpServers":{"pixellab":{"url":"https://api.pixellab.ai/mcp","type":"http","headers":{"Authorization":"Bearer sk-1"}}}})

      assert {:ok, %ImportResult{action: :register} = result} = McpImport.parse(blob)
      changeset = ExternalApi.changeset(%ExternalApi{}, result.api_params)
      assert changeset.valid?, "expected #{inspect(changeset.errors)} to be empty"
    end
  end
end
