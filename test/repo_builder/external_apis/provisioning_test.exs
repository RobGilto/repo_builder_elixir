defmodule RepoBuilder.ExternalApis.ProvisioningTest do
  @moduledoc """
  Resolver coverage (issue-external-api-mcp-provisioning): the exact per-transport
  server-spec shapes (placeholder, never the literal token), default vs custom
  allowed_tools, secret_keys filtered by auth_scheme, instructions concatenation, the
  static+dynamic merge, and empty-input ⇒ empty fragments.
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.ExternalApis.{ExternalApi, Provisioning}
  alias RepoBuilder.Harness.McpTools

  defp http_bearer do
    %ExternalApi{
      name: "pixellab",
      transport: :http,
      url: "https://api.pixellab.ai/mcp",
      auth_scheme: :bearer,
      secret_name: "PIXELLAB_API_KEY",
      args: [],
      doc_urls: ["https://api.pixellab.ai/mcp/docs"],
      allowed_tools: [],
      description: "Image MCP",
      instructions: "Call mcp__pixellab__generate to render an image."
    }
  end

  defp stdio_none do
    %ExternalApi{
      name: "localtool",
      transport: :stdio,
      command: "npx",
      args: ["-y", "some-mcp"],
      auth_scheme: :none,
      secret_name: nil,
      doc_urls: [],
      allowed_tools: []
    }
  end

  describe "mcp_servers/1" do
    test "http+bearer carries the ${SECRET} placeholder, never the token" do
      assert %{"pixellab" => spec} = Provisioning.mcp_servers([http_bearer()])

      assert spec == %{
               "type" => "http",
               "url" => "https://api.pixellab.ai/mcp",
               "headers" => %{"Authorization" => "Bearer ${PIXELLAB_API_KEY}"}
             }
    end

    test "sse uses the sse type" do
      api = %{http_bearer() | transport: :sse}
      assert %{"pixellab" => %{"type" => "sse"}} = Provisioning.mcp_servers([api])
    end

    test "header auth uses a bare placeholder and honours a custom header" do
      api = %{http_bearer() | auth_scheme: :header, auth_header: "X-Api-Key"}
      assert %{"pixellab" => spec} = Provisioning.mcp_servers([api])
      assert spec["headers"] == %{"X-Api-Key" => "${PIXELLAB_API_KEY}"}
    end

    test "stdio carries command/args and no headers" do
      assert %{"localtool" => spec} = Provisioning.mcp_servers([stdio_none()])
      assert spec == %{"command" => "npx", "args" => ["-y", "some-mcp"], "env" => %{}}
    end

    test "auth_scheme none http has no headers key" do
      api = %{http_bearer() | auth_scheme: :none, secret_name: nil}
      assert %{"pixellab" => spec} = Provisioning.mcp_servers([api])
      refute Map.has_key?(spec, "headers")
    end

    test "empty input is an empty fragment" do
      assert Provisioning.mcp_servers([]) == %{}
    end
  end

  describe "allowed_tools/1" do
    test "defaults to the name wildcard" do
      assert Provisioning.allowed_tools([http_bearer()]) == ["mcp__pixellab__*"]
    end

    test "uses an explicit allowed_tools list when set" do
      api = %{http_bearer() | allowed_tools: ["mcp__pixellab__generate"]}
      assert Provisioning.allowed_tools([api]) == ["mcp__pixellab__generate"]
    end
  end

  describe "secret_keys/1" do
    test "includes auth'd rows and excludes none-auth rows" do
      assert Provisioning.secret_keys([http_bearer(), stdio_none()]) ==
               [{"pixellab", "PIXELLAB_API_KEY"}]
    end

    test "empty for a public API" do
      assert Provisioning.secret_keys([stdio_none()]) == []
    end
  end

  describe "instructions/1" do
    test "concatenates description, instructions, and doc URLs" do
      out = Provisioning.instructions([http_bearer()])
      assert out =~ "pixellab"
      assert out =~ "Image MCP"
      assert out =~ "Call mcp__pixellab__generate"
      assert out =~ "https://api.pixellab.ai/mcp/docs"
    end

    test "empty input is the empty string" do
      assert Provisioning.instructions([]) == ""
    end
  end

  describe "static + dynamic merge" do
    test "the dynamic servers merge alongside the static firecrawl fragment" do
      static = McpTools.mcp_servers(McpTools.enabled(["firecrawl"]))
      dynamic = Provisioning.mcp_servers([http_bearer()])
      merged = Map.merge(static, dynamic)

      assert Map.has_key?(merged, "firecrawl")
      assert Map.has_key?(merged, "pixellab")
    end
  end
end
