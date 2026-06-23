defmodule RepoBuilder.Agents.HandoverTest do
  @moduledoc """
  Unit tests for the pure handover helpers (issue graceful-agent-handover): signal
  parsing across edge cases, threshold/occupancy math, and prompt construction.
  No DB / no harness — these are pure functions.
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.Agents.Handover

  describe "parse_signal/1" do
    test "matches a well-formed token" do
      assert Handover.parse_signal(":handover ai_docs/x-handover.md") ==
               {:ok, "ai_docs/x-handover.md"}
    end

    test "finds the token at the end of a multi-line message" do
      msg = "All done. Wrote the doc.\n\n:handover ai_docs/port-handover.md"
      assert Handover.parse_signal(msg) == {:ok, "ai_docs/port-handover.md"}
    end

    test "ignores prose without the token" do
      assert Handover.parse_signal("I finished the analysis and reported back.") == :none
    end

    test "strips a trailing period" do
      assert Handover.parse_signal("done :handover ai_docs/x-handover.md.") ==
               {:ok, "ai_docs/x-handover.md"}
    end

    test "strips trailing backticks" do
      assert Handover.parse_signal("see `:handover ai_docs/x-handover.md`") ==
               {:ok, "ai_docs/x-handover.md"}
    end

    test "takes the LAST occurrence (worker may quote the contract earlier)" do
      msg = """
      The contract says to end with `:handover ai_docs/example.md`.
      Here is mine:
      :handover ai_docs/real-handover.md
      """

      assert Handover.parse_signal(msg) == {:ok, "ai_docs/real-handover.md"}
    end

    test "nil and empty are :none" do
      assert Handover.parse_signal(nil) == :none
      assert Handover.parse_signal("") == :none
    end

    test "a bare token with no path is :none" do
      assert Handover.parse_signal("winding down :handover") == :none
    end
  end

  describe "threshold/0 and over_threshold?/1" do
    test "reads the configured threshold" do
      assert Handover.threshold() == 0.8
    end

    test "is inclusive at exactly the threshold" do
      assert Handover.over_threshold?(0.8)
      assert Handover.over_threshold?(0.95)
      refute Handover.over_threshold?(0.79)
      refute Handover.over_threshold?(0.0)
    end
  end

  describe "occupancy/3" do
    test "agrees with ContextWindow for a known model (Opus 4.8 = 1M window)" do
      # 850k / 1M = 0.85 → over; 700k / 1M = 0.7 → under.
      assert Handover.occupancy("claude", "claude-opus-4-8", 850_000) == 0.85
      assert Handover.over_threshold?(Handover.occupancy("claude", "claude-opus-4-8", 850_000))
      refute Handover.over_threshold?(Handover.occupancy("claude", "claude-opus-4-8", 700_000))
    end

    test "unknown model falls back to the default window (no spurious wind-down at low counts)" do
      # default 200k → 1000 tokens is ~0.5%, never over threshold.
      refute Handover.over_threshold?(Handover.occupancy("claude", "made-up-model", 1_000))
    end

    test "nil harness yields 0.0 (window unknown)" do
      assert Handover.occupancy(nil, nil, 999_999) == 0.0
    end
  end

  describe "prompt builders" do
    test "wind_down_prompt includes the original ask when given and names the contract" do
      prompt = Handover.wind_down_prompt("Port the session runtime to Elixir")
      assert prompt =~ "[WIND DOWN — CONTEXT LIMIT]"
      assert prompt =~ "Port the session runtime to Elixir"
      assert prompt =~ ":handover <relative-path-to-doc>"
      assert prompt =~ "ai_docs/"
    end

    test "wind_down_prompt omits the receipt cleanly when nil/blank" do
      prompt = Handover.wind_down_prompt(nil)
      assert prompt =~ "[WIND DOWN — CONTEXT LIMIT]"
      refute prompt =~ "original ask you were dispatched with"

      assert Handover.wind_down_prompt("   ") |> String.contains?("original ask you were") ==
               false
    end

    test "retired_resume_prompt names the worker as retired and links the doc" do
      prompt = Handover.retired_resume_prompt("scout", "ai_docs/scout-handover.md")
      assert prompt =~ "scout"
      assert prompt =~ "RETIRED"
      assert prompt =~ "ai_docs/scout-handover.md"
      assert prompt =~ "FRESH worker"
    end

    test "forced_retire_resume_prompt notes the missing doc" do
      prompt = Handover.forced_retire_resume_prompt("scout")
      assert prompt =~ "scout"
      assert prompt =~ "RETIRED"
      assert prompt =~ "WITHOUT writing a handover document"
    end

    test "protocol_clause teaches the layout and the contract" do
      clause = Handover.protocol_clause()
      assert clause =~ "[WIND DOWN — CONTEXT LIMIT]"
      assert clause =~ "ai_docs/<descriptive-name>-handover.md"
      assert clause =~ ":handover <relative-path>"
      assert clause =~ "## Achieved"
      assert clause =~ "## Remaining"
    end
  end
end
