defmodule RepoBuilder.Harness.OrchestratorAutonomyTest do
  @moduledoc """
  Hermetic argv/env assertions for the programmatic-permission behaviour (issue-d),
  driven purely off `command/1`/`orchestrator_spawn/2` — NO real CLI.

  The asymmetry is the whole point: Claude needs `--dangerously-skip-permissions`
  (+ `--strict-mcp-config` for the orchestrator MCP binding) so an unattended turn
  never deadlocks on a permission prompt; pi has NO such flag by design — its
  autonomy is `--approve` plus `PI_SKIP_VERSION_CHECK=1` hygiene env.
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.Harness.{Claude, Pi}

  defp base_opts(extra) do
    Map.merge(%{prompt: "do it", model: nil, cwd: ".", sink: self(), secrets: %{}}, extra)
  end

  describe "Claude command/1 programmatic permission skip" do
    test "an autonomous (orchestrator) session appends --dangerously-skip-permissions" do
      {_exe, args, _env, _ctx} = Claude.command(base_opts(%{config: %{orchestrator: true}}))
      assert "--dangerously-skip-permissions" in args
    end

    test "an explicit autonomous config flag also triggers the skip" do
      {_exe, args, _env, _ctx} = Claude.command(base_opts(%{config: %{autonomous: true}}))
      assert "--dangerously-skip-permissions" in args
    end

    test "a plain worker (no autonomy flag) gets NO skip flag (safety)" do
      {_exe, args, _env, _ctx} = Claude.command(base_opts(%{config: %{}}))
      refute "--dangerously-skip-permissions" in args

      {_exe, args2, _env, _ctx} = Claude.command(base_opts(%{}))
      refute "--dangerously-skip-permissions" in args2
    end

    test "the opus alias passes through verbatim as --model opus" do
      {_exe, args, _env, _ctx} =
        Claude.command(base_opts(%{model: "opus", config: %{orchestrator: true}}))

      assert "--model" in args and "opus" in args
    end
  end

  describe "Claude orchestrator_spawn/2 strict MCP binding" do
    test "appends --strict-mcp-config + --mcp-config <path>, writes .mcp.json, token in headers only" do
      cwd = Path.join(System.tmp_dir!(), "orch-#{System.unique_integer([:positive])}")

      ctx = %{
        orchestrator_id: Ecto.UUID.generate(),
        mcp_base_url: "http://127.0.0.1:4000",
        token: "super-secret-token",
        resume_session_id: nil,
        system_prompt: "be the orchestrator",
        cwd: cwd
      }

      {args, env} = Claude.orchestrator_spawn(base_opts(%{config: %{orchestrator: true}}), ctx)

      assert "--strict-mcp-config" in args
      assert "--mcp-config" in args
      mcp_path = Path.join(cwd, ".mcp.json")
      assert mcp_path in args
      assert File.exists?(mcp_path)

      # The bearer token lives in the .mcp.json headers, NEVER in argv (ps-visible).
      refute "super-secret-token" in args
      assert env == []
      assert File.read!(mcp_path) =~ "super-secret-token"
    after
      File.rm_rf(Path.join(System.tmp_dir!(), "orch"))
    end
  end

  describe "pi command/1 provider + approve + hygiene env" do
    test "provider + autonomous ⇒ --provider <name>, --approve, PI_SKIP_VERSION_CHECK, NO skip flag" do
      {exe, args, env, _ctx} =
        Pi.command(base_opts(%{provider: "openai", config: %{orchestrator: true}}))

      assert exe == "pi"
      assert "--provider" in args and "openai" in args
      assert "--approve" in args
      assert {"PI_SKIP_VERSION_CHECK", "1"} in env
      # pi has no permission-skip flag by design — asserting its absence matters.
      refute "--dangerously-skip-permissions" in args
    end

    test "no provider ⇒ no --provider arg (never an empty --provider \"\")" do
      {_exe, args, _env, _ctx} = Pi.command(base_opts(%{config: %{orchestrator: true}}))
      refute "--provider" in args
      refute "" in args
    end

    test "an arbitrary open provider (groq) threads through to --provider groq" do
      {_exe, args, _env, _ctx} = Pi.command(base_opts(%{provider: "groq"}))
      assert "--provider" in args and "groq" in args
    end

    test "a non-autonomous pi worker gets no --approve" do
      {_exe, args, _env, _ctx} = Pi.command(base_opts(%{provider: "openai", config: %{}}))
      refute "--approve" in args
    end
  end
end
