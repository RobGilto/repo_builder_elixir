defmodule RepoBuilder.Harness.OrchestratingTest do
  @moduledoc """
  The optional `Orchestrating` binding (issue-c): Claude writes a valid `.mcp.json`
  and emits `--mcp-config`/`--resume`; pi emits `-e`/session-resume args plus the
  tool-endpoint env; neither leaks the token into argv. Registry capability reads
  reflect config.
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.Harness.{Claude, Pi, Registry}
  alias RepoBuilder.Orchestrator.ToolCatalog

  defp ctx(overrides \\ %{}) do
    Map.merge(
      %{
        orchestrator_id: "11111111-1111-1111-1111-111111111111",
        mcp_base_url: "http://127.0.0.1:4000",
        token: "secret-token-xyz",
        resume_session_id: nil,
        system_prompt: "You are the orchestrator.",
        system_prompt_mode: :append,
        cwd: Path.join(System.tmp_dir!(), "orch-test-#{System.unique_integer([:positive])}")
      },
      overrides
    )
  end

  describe "Claude.orchestrator_spawn/2" do
    test "writes a valid .mcp.json (http + bearer header) and emits --mcp-config" do
      ctx = ctx()
      {args, env} = Claude.orchestrator_spawn(%{}, ctx)

      assert "--mcp-config" in args
      assert "--append-system-prompt" in args
      assert env == []

      path = Path.join(ctx.cwd, ".mcp.json")
      assert File.exists?(path)
      config = path |> File.read!() |> Jason.decode!()
      server = config["mcpServers"]["repo_builder"]
      assert server["type"] == "http"
      assert server["url"] =~ ctx.orchestrator_id
      assert server["headers"]["Authorization"] == "Bearer #{ctx.token}"

      File.rm_rf!(ctx.cwd)
    end

    test "adds --resume when resuming and keeps the token out of argv" do
      ctx = ctx(%{resume_session_id: "sess-abc"})
      {args, _env} = Claude.orchestrator_spawn(%{}, ctx)

      assert Enum.chunk_every(args, 2, 1) |> Enum.member?(["--resume", "sess-abc"])
      refute Enum.any?(args, &(&1 =~ ctx.token))
      File.rm_rf!(ctx.cwd)
    end
  end

  describe "Pi.orchestrator_spawn/2" do
    test "emits -e + endpoint env and never puts the token in argv" do
      ctx = ctx()
      {args, env} = Pi.orchestrator_spawn(%{}, ctx)

      assert "-e" in args
      assert {"PI_ORCH_TOKEN", "secret-token-xyz"} in env
      assert Enum.any?(env, fn {k, v} -> k == "PI_ORCH_BASE_URL" and v =~ ctx.orchestrator_id end)
      refute Enum.any?(args, &(&1 =~ ctx.token))
    end

    test "adds --session when resuming" do
      ctx = ctx(%{resume_session_id: "sess-pi"})
      {args, _env} = Pi.orchestrator_spawn(%{}, ctx)
      assert Enum.chunk_every(args, 2, 1) |> Enum.member?(["--session", "sess-pi"])
      File.rm_rf!(ctx.cwd)
    end

    test "writes the catalog-derived tool manifest and injects PI_ORCH_TOOLS_PATH (absolute)" do
      ctx = ctx()
      {_args, env} = Pi.orchestrator_spawn(%{}, ctx)

      path = Path.join(ctx.cwd, ".pi-orch-tools.json")
      assert {"PI_ORCH_TOOLS_PATH", ^path} = List.keyfind(env, "PI_ORCH_TOOLS_PATH", 0)
      assert Path.type(path) == :absolute
      assert File.exists?(path)

      manifest_names = path |> File.read!() |> Jason.decode!() |> Enum.map(& &1["name"])
      assert MapSet.new(manifest_names) == MapSet.new(ToolCatalog.names())

      File.rm_rf!(ctx.cwd)
    end
  end

  describe "Registry capability" do
    test "orchestrating?/1 reflects the config flag" do
      assert Registry.orchestrating?("claude")
      assert Registry.orchestrating?("pi")
      refute Registry.orchestrating?("cursor")
      refute Registry.orchestrating?("unknown")
    end

    test "orchestrating_harnesses/0 lists only capable harnesses" do
      harnesses = Registry.orchestrating_harnesses()
      assert "claude" in harnesses
      assert "pi" in harnesses
      refute "cursor" in harnesses
    end
  end
end
