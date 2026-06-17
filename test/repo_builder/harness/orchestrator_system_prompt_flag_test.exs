defmodule RepoBuilder.Harness.OrchestratorSystemPromptFlagTest do
  @moduledoc """
  Asserts the Claude and pi `orchestrator_spawn/2` adapters select the correct CLI
  prompt flag from `ctx.system_prompt_mode`: `--append-system-prompt` for `:append`
  and `--system-prompt` for `:replace` (both confirmed for both harnesses). The
  unused flag must never appear, and the chosen flag must be immediately followed by
  the prompt text. Existing args (Claude's `--mcp-config`/`--strict-mcp-config`,
  pi's `-e <ext>`) are preserved.
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.Harness.{Claude, Pi}

  # Build a tool_ctx for `mode`, writing into a unique tmp cwd so Claude's `.mcp.json`
  # side effect has a real directory.
  defp ctx(mode) do
    cwd = Path.join(System.tmp_dir!(), "orch-prompt-#{System.unique_integer([:positive])}")

    %{
      orchestrator_id: Ecto.UUID.generate(),
      mcp_base_url: "http://127.0.0.1:4000",
      token: "tok-secret",
      resume_session_id: nil,
      system_prompt: "CUSTOM",
      system_prompt_mode: mode,
      cwd: cwd
    }
  end

  # The index of `flag` in `args` such that the next element is the prompt text.
  defp flag_followed_by?(args, flag, value) do
    case Enum.find_index(args, &(&1 == flag)) do
      nil -> false
      i -> Enum.at(args, i + 1) == value
    end
  end

  describe "Claude.orchestrator_spawn/2" do
    test "append mode emits --append-system-prompt CUSTOM (no --system-prompt)" do
      {args, _env} = Claude.orchestrator_spawn(%{}, ctx(:append))

      assert flag_followed_by?(args, "--append-system-prompt", "CUSTOM")
      refute "--system-prompt" in args
      # Existing MCP args preserved.
      assert "--mcp-config" in args
      assert "--strict-mcp-config" in args
    end

    test "replace mode emits --system-prompt CUSTOM (no --append-system-prompt)" do
      {args, _env} = Claude.orchestrator_spawn(%{}, ctx(:replace))

      assert flag_followed_by?(args, "--system-prompt", "CUSTOM")
      refute "--append-system-prompt" in args
    end
  end

  describe "Pi.orchestrator_spawn/2" do
    test "append mode emits --append-system-prompt CUSTOM (no --system-prompt)" do
      {args, env} = Pi.orchestrator_spawn(%{}, ctx(:append))

      assert flag_followed_by?(args, "--append-system-prompt", "CUSTOM")
      refute "--system-prompt" in args
      assert "-e" in args
      # Token goes in env, never argv.
      assert {"PI_ORCH_TOKEN", "tok-secret"} in env
      refute "tok-secret" in args
    end

    test "replace mode emits --system-prompt CUSTOM (no --append-system-prompt)" do
      {args, _env} = Pi.orchestrator_spawn(%{}, ctx(:replace))

      assert flag_followed_by?(args, "--system-prompt", "CUSTOM")
      refute "--append-system-prompt" in args
    end
  end
end
