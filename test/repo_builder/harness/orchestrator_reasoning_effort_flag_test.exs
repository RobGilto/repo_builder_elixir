defmodule RepoBuilder.Harness.OrchestratorReasoningEffortFlagTest do
  @moduledoc """
  Hermetic argv assertions that the Claude and pi `command/1` adapters map the
  harness-blind `reasoning_effort` to the correct native flag — Claude `--effort`,
  pi `--thinking` — with the right per-harness level word (`:max` ⇒ Claude `max`,
  pi `xhigh`), and that `:default` emits NO effort/thinking flag (zero regression).

  Driven purely off `command/1` — NO real CLI.
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.Harness.{Claude, Pi}

  defp base_opts(extra) do
    Map.merge(%{prompt: "do it", model: nil, cwd: ".", sink: self(), secrets: %{}}, extra)
  end

  # True when `flag` appears in `args` immediately followed by `value`.
  defp adjacent?(args, flag, value) do
    case Enum.find_index(args, &(&1 == flag)) do
      nil -> false
      i -> Enum.at(args, i + 1) == value
    end
  end

  defp claude_args(effort) do
    {"claude", args, _env, _ctx} = Claude.command(base_opts(%{reasoning_effort: effort}))
    args
  end

  defp pi_args(effort) do
    {"pi", args, _env, _ctx} = Pi.command(base_opts(%{reasoning_effort: effort}))
    args
  end

  describe "Claude.command/1 --effort mapping" do
    test ":high ⇒ --effort high (adjacent), base argv preserved" do
      args = claude_args(:high)
      assert adjacent?(args, "--effort", "high")
      assert "-p" in args and "--output-format" in args
    end

    test ":max ⇒ --effort max" do
      assert adjacent?(claude_args(:max), "--effort", "max")
    end

    test ":off ⇒ NO --effort (Claude has no off; model default)" do
      refute "--effort" in claude_args(:off)
    end

    test ":default ⇒ NO --effort flag (zero regression)" do
      refute "--effort" in claude_args(:default)
    end

    test "absent reasoning_effort ⇒ NO --effort flag (worker sessions)" do
      {"claude", args, _env, _ctx} = Claude.command(base_opts(%{}))
      refute "--effort" in args
    end
  end

  describe "Pi.command/1 --thinking mapping" do
    test ":high ⇒ --thinking high (adjacent), base argv preserved" do
      args = pi_args(:high)
      assert adjacent?(args, "--thinking", "high")
      assert "--mode" in args and "json" in args
    end

    test ":max ⇒ --thinking xhigh (pi's top level)" do
      assert adjacent?(pi_args(:max), "--thinking", "xhigh")
    end

    test ":off ⇒ --thinking off" do
      assert adjacent?(pi_args(:off), "--thinking", "off")
    end

    test ":default ⇒ NO --thinking flag (zero regression)" do
      refute "--thinking" in pi_args(:default)
    end

    test "absent reasoning_effort ⇒ NO --thinking flag (worker sessions)" do
      {"pi", args, _env, _ctx} = Pi.command(base_opts(%{}))
      refute "--thinking" in args
    end
  end
end
