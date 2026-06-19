defmodule RepoBuilder.Harness.PiWorkerMcpTest do
  @moduledoc """
  Adapter tests for the pi WORKER MCP binding (issue firecrawl-grant): a granted
  worker gets `--mcp-config <.pi-mcp.json>` WITHOUT `--no-extensions` (the auto-loaded
  adapter honors it); an ungated worker gets `--no-extensions` and no MCP file. The
  API key rides in env, never argv.
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.Harness.Pi

  defp tmp_cwd do
    dir = Path.join(System.tmp_dir!(), "rb_pi_mcp_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp base_opts(cwd, config) do
    %{prompt: "do research", model: nil, cwd: cwd, sink: self(), config: config}
  end

  describe "with firecrawl granted" do
    test "passes --mcp-config and writes the .pi-mcp.json, no -ne" do
      cwd = tmp_cwd()
      {"pi", args, _env, _ctx} = Pi.command(base_opts(cwd, %{"tools" => ["firecrawl"]}))

      assert "--mcp-config" in args
      refute "--no-extensions" in args

      path = Path.join(Path.expand(cwd), ".pi-mcp.json")
      assert path in args
      assert File.exists?(path)

      decoded = path |> File.read!() |> Jason.decode!()
      assert get_in(decoded, ["mcpServers", "firecrawl", "command"]) == "npx"
    end

    test "the API key never appears in argv" do
      cwd = tmp_cwd()
      {"pi", args, _env, _ctx} = Pi.command(base_opts(cwd, %{"tools" => ["firecrawl"]}))

      refute Enum.any?(args, &(&1 =~ "fc-"))
      refute Enum.any?(args, &(&1 == "FIRECRAWL_API_KEY"))
    end
  end

  describe "without a grant" do
    test "appends --no-extensions and writes no MCP file" do
      cwd = tmp_cwd()
      {"pi", args, _env, _ctx} = Pi.command(base_opts(cwd, %{}))

      assert "--no-extensions" in args
      refute "--mcp-config" in args
      refute File.exists?(Path.join(Path.expand(cwd), ".pi-mcp.json"))
    end

    test "an orchestrator config is inert (no -ne / --mcp-config here)" do
      cwd = tmp_cwd()
      {"pi", args, _env, _ctx} = Pi.command(base_opts(cwd, %{orchestrator: true}))

      refute "--no-extensions" in args
      refute "--mcp-config" in args
    end
  end
end
