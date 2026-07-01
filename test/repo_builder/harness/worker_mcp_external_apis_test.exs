defmodule RepoBuilder.Harness.WorkerMcpExternalApisTest do
  @moduledoc """
  Adapter coverage for the dynamic external-API provision merge
  (issue-external-api-mcp-provisioning): a worker whose `config["apis"]` names a
  registered http+bearer API is spawned with that server in its `.mcp.json` (Claude) /
  `.pi-mcp.json` (pi), carrying the `${SECRET}` placeholder (never the token) and the
  default allow-list pattern (Claude). The static firecrawl grant still merges alongside.

  `async: false` — exercises the shared Ecto sandbox via the ExternalApis context.
  """
  use RepoBuilder.DataCase, async: false

  alias RepoBuilder.ExternalApis
  alias RepoBuilder.Harness.{Claude, Pi}

  defp tmp_cwd do
    dir = Path.join(System.tmp_dir!(), "rb_api_mcp_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp register_pixellab do
    {:ok, _} =
      ExternalApis.create(%{
        "name" => "pixellab",
        "transport" => "http",
        "url" => "https://api.pixellab.ai/mcp",
        "auth_scheme" => "bearer",
        "secret_name" => "PIXELLAB_API_KEY"
      })

    :ok
  end

  defp opts(cwd, config) do
    %{prompt: "render", model: nil, cwd: cwd, sink: self(), config: config, project_id: nil}
  end

  describe "Claude" do
    test "merges the registered API server + allow-list and uses the placeholder" do
      register_pixellab()
      cwd = tmp_cwd()

      {"claude", args, _env, _ctx} =
        Claude.command(opts(cwd, %{"apis" => ["pixellab"], "tools" => ["firecrawl"]}))

      assert "--mcp-config" in args
      assert "mcp__pixellab__*" in args
      assert "mcp__firecrawl__*" in args

      body = File.read!(Path.join(Path.expand(cwd), ".mcp.json"))
      decoded = Jason.decode!(body)

      assert get_in(decoded, ["mcpServers", "pixellab", "type"]) == "http"
      assert get_in(decoded, ["mcpServers", "pixellab", "url"]) == "https://api.pixellab.ai/mcp"

      assert get_in(decoded, ["mcpServers", "pixellab", "headers", "Authorization"]) ==
               "Bearer ${PIXELLAB_API_KEY}"

      # Static firecrawl still present (merge, not replace).
      assert get_in(decoded, ["mcpServers", "firecrawl", "command"]) == "npx"
    end

    test "a plain worker (no tools, no apis) writes no .mcp.json" do
      cwd = tmp_cwd()
      {"claude", args, _env, _ctx} = Claude.command(opts(cwd, %{}))
      refute "--mcp-config" in args
      refute File.exists?(Path.join(Path.expand(cwd), ".mcp.json"))
    end
  end

  describe "pi" do
    test "merges the registered API server into .pi-mcp.json" do
      register_pixellab()
      cwd = tmp_cwd()

      {"pi", args, _env, _ctx} = Pi.command(opts(cwd, %{"apis" => ["pixellab"]}))

      assert "--mcp-config" in args
      refute "--no-extensions" in args

      body = File.read!(Path.join(Path.expand(cwd), ".pi-mcp.json"))
      decoded = Jason.decode!(body)
      assert get_in(decoded, ["mcpServers", "pixellab", "type"]) == "http"
      assert body =~ "${PIXELLAB_API_KEY}"
    end

    test "a plain worker still gets --no-extensions" do
      cwd = tmp_cwd()
      {"pi", args, _env, _ctx} = Pi.command(opts(cwd, %{}))
      assert "--no-extensions" in args
    end
  end
end
