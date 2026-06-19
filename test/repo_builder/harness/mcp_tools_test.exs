defmodule RepoBuilder.Harness.McpToolsTest do
  @moduledoc """
  Unit tests for the harness-agnostic worker MCP tool catalog (issue firecrawl-grant):
  parsing the config `"tools"` list, the stdio server fragment (with the
  `${FIRECRAWL_API_KEY}` placeholder, never a literal key), the Claude allow patterns,
  and the secret-key pairs.
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.Harness.McpTools

  test "known/0 lists firecrawl" do
    assert McpTools.known() == ["firecrawl"]
  end

  describe "enabled/1" do
    test "parses known names and drops unknowns" do
      assert McpTools.enabled(["firecrawl", "bogus"]) == [:firecrawl]
    end

    test "dedupes" do
      assert McpTools.enabled(["firecrawl", "firecrawl"]) == [:firecrawl]
    end

    test "nil / non-list is empty" do
      assert McpTools.enabled(nil) == []
      assert McpTools.enabled("firecrawl") == []
    end
  end

  describe "mcp_servers/1" do
    test "declares the firecrawl stdio server with a placeholder, not a literal key" do
      servers = McpTools.mcp_servers([:firecrawl])

      assert %{"firecrawl" => spec} = servers
      assert spec["command"] == "npx"
      assert spec["args"] == ["-y", "firecrawl-mcp"]
      assert spec["env"]["FIRECRAWL_API_KEY"] == "${FIRECRAWL_API_KEY}"

      # No real key leaks into the fragment.
      refute Jason.encode!(servers) =~ "fc-"
    end

    test "empty list is an empty map" do
      assert McpTools.mcp_servers([]) == %{}
    end
  end

  test "allowed_tools/1 yields one wildcard per server" do
    assert McpTools.allowed_tools([:firecrawl]) == ["mcp__firecrawl__*"]
    assert McpTools.allowed_tools([]) == []
  end

  test "secret_keys/1 maps each tool to its env var" do
    assert McpTools.secret_keys([:firecrawl]) == [{"firecrawl", "FIRECRAWL_API_KEY"}]
    assert McpTools.secret_keys([]) == []
  end
end
