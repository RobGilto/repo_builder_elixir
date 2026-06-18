defmodule RepoBuilder.Harness.OrchestratorToolRestrictionTest do
  @moduledoc """
  The orchestrator is a delegation-only meta-agent: it must call ONLY its bound
  meta-tools, never the harness's native file/shell tools (otherwise a drifting model
  writes files itself instead of dispatching to a worker). These tests pin the structural
  guardrail: `orchestrator_spawn/2` restricts the native toolset for BOTH harnesses, while
  the WORKER path (plain `command/1`, no orchestrator binding) keeps the full toolset.
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.Harness.{Claude, Pi}

  defp ctx(overrides \\ %{}) do
    Map.merge(
      %{
        orchestrator_id: "11111111-1111-1111-1111-111111111111",
        mcp_base_url: "http://127.0.0.1:4000",
        token: "secret-token-xyz",
        resume_session_id: nil,
        system_prompt: "You are the orchestrator.",
        system_prompt_mode: :append,
        cwd: Path.join(System.tmp_dir!(), "orch-restrict-#{System.unique_integer([:positive])}")
      },
      overrides
    )
  end

  describe "Claude orchestrator is denied native file/shell tools" do
    test "orchestrator_spawn/2 emits --disallowedTools covering Write/Edit/Bash" do
      ctx = ctx()
      {args, _env} = Claude.orchestrator_spawn(%{}, ctx)

      assert "--disallowedTools" in args
      # The dangerous "do the work itself" tools must be denied.
      for tool <- ~w(Write Edit MultiEdit NotebookEdit Bash) do
        assert tool in args, "expected #{tool} to be disallowed for the orchestrator"
      end

      # The MCP binding is still present (delegation tools survive).
      assert "--mcp-config" in args

      File.rm_rf!(ctx.cwd)
    end

    test "the WORKER path (command/1) keeps native tools — no --disallowedTools" do
      {"claude", args, _env, _ctx} = Claude.command(%{prompt: "edit the file"})

      refute "--disallowedTools" in args
      refute "Write" in args
      refute "Bash" in args
    end
  end

  describe "pi orchestrator is denied built-in tools" do
    test "orchestrator_spawn/2 emits --no-builtin-tools and keeps the -e extension" do
      ctx = ctx()
      {args, _env} = Pi.orchestrator_spawn(%{}, ctx)

      assert "--no-builtin-tools" in args
      # The orchestrator extension (its delegation tools) is still loaded.
      assert Enum.chunk_every(args, 2, 1) |> Enum.any?(&match?(["-e", _], &1))

      File.rm_rf!(ctx.cwd)
    end

    test "the WORKER path (command/1) keeps built-in tools — no --no-builtin-tools" do
      {"pi", args, _env, _ctx} = Pi.command(%{prompt: "edit the file"})

      refute "--no-builtin-tools" in args
    end
  end
end
