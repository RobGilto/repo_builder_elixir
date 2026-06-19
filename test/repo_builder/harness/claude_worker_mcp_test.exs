defmodule RepoBuilder.Harness.ClaudeWorkerMcpTest do
  @moduledoc """
  Adapter tests for the Claude WORKER MCP binding (issue firecrawl-grant): a worker
  whose config grants `firecrawl` is spawned with a `.mcp.json` + `--mcp-config`/
  `--strict-mcp-config`/`--allowedTools mcp__firecrawl__*`; the literal key never
  touches argv or the file (only the `${FIRECRAWL_API_KEY}` placeholder). A worker
  with no grant gets none of that.
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.Harness.Claude

  defp tmp_cwd do
    dir = Path.join(System.tmp_dir!(), "rb_claude_mcp_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp base_opts(cwd, config) do
    %{prompt: "do research", model: nil, cwd: cwd, sink: self(), config: config}
  end

  describe "with firecrawl granted" do
    test "writes a .mcp.json and appends the MCP flags" do
      cwd = tmp_cwd()
      {"claude", args, _env, _ctx} = Claude.command(base_opts(cwd, %{"tools" => ["firecrawl"]}))

      assert "--mcp-config" in args
      assert "--strict-mcp-config" in args
      assert "--allowedTools" in args
      assert "mcp__firecrawl__*" in args

      path = Path.join(Path.expand(cwd), ".mcp.json")
      assert File.exists?(path)

      body = File.read!(path)
      decoded = Jason.decode!(body)
      assert get_in(decoded, ["mcpServers", "firecrawl", "command"]) == "npx"
      assert get_in(decoded, ["mcpServers", "firecrawl", "args"]) == ["-y", "firecrawl-mcp"]

      # The placeholder is present; no literal key value is written.
      assert body =~ "${FIRECRAWL_API_KEY}"
      refute body =~ "fc-"
    end

    test "the API key never appears in argv" do
      cwd = tmp_cwd()
      {"claude", args, _env, _ctx} = Claude.command(base_opts(cwd, %{"tools" => ["firecrawl"]}))

      refute Enum.any?(args, &(&1 =~ "FIRECRAWL_API_KEY" and &1 != "--mcp-config"))
      # The mcp-config arg is the path, not the key; assert no arg holds a fc- value.
      refute Enum.any?(args, &(&1 =~ "fc-"))
    end
  end

  describe "without a grant" do
    test "writes no .mcp.json and adds no MCP args" do
      cwd = tmp_cwd()
      {"claude", args, _env, _ctx} = Claude.command(base_opts(cwd, %{}))

      refute "--mcp-config" in args
      refute "--strict-mcp-config" in args
      refute "--allowedTools" in args
      refute File.exists?(Path.join(Path.expand(cwd), ".mcp.json"))
    end

    test "an orchestrator config is inert (no worker MCP binding here)" do
      cwd = tmp_cwd()
      {"claude", args, _env, _ctx} = Claude.command(base_opts(cwd, %{orchestrator: true}))

      refute "--mcp-config" in args
      refute File.exists?(Path.join(Path.expand(cwd), ".mcp.json"))
    end
  end
end
