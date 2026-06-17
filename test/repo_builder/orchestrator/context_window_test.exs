defmodule RepoBuilder.Orchestrator.ContextWindowTest do
  @moduledoc """
  Unit tests for the harness-blind context-window lookup: per-(harness,model)
  override, default fallback, unknown-model fallback, fraction math, the UNCLAMPED
  >1.0 case, and zero-tokens → 0.0 (no division by zero).
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.Orchestrator.ContextWindow

  describe "size/2" do
    test "a per-(harness,model) override wins" do
      assert ContextWindow.size("claude", "claude-sonnet-4-6") == 1_000_000
    end

    test "an unknown model falls back to the default" do
      assert ContextWindow.size("claude", "some-unconfigured-model") == 200_000
      assert ContextWindow.size("pi", nil) == 200_000
    end
  end

  describe "usage_fraction/3" do
    test "computes context_tokens / size" do
      # 100_000 / 200_000 (default) = 0.5
      assert ContextWindow.usage_fraction(100_000, "pi", "glm-4.6") == 0.5
    end

    test "uses the per-model window size for the fraction" do
      # 500_000 / 1_000_000 (sonnet override) = 0.5
      assert ContextWindow.usage_fraction(500_000, "claude", "claude-sonnet-4-6") == 0.5
    end

    test "is NOT clamped — over 100% is reported verbatim" do
      # 300_000 / 200_000 = 1.5 (the over-window signal must stay visible)
      assert ContextWindow.usage_fraction(300_000, "claude", "unknown") == 1.5
    end

    test "zero tokens yields 0.0 (no division-by-zero)" do
      assert ContextWindow.usage_fraction(0, "claude", "unknown") == 0.0
    end
  end
end
