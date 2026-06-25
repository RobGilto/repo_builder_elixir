defmodule RepoBuilder.Agents.HoldingTest do
  @moduledoc """
  Unit tests for the pure holding-protocol helpers (issue
  holding-status-for-blocked-agents): the `:holding <reason>` signal parser, the
  conservative phrase heuristic (positive on documented blocked-on-external phrases,
  NEGATIVE on normal completions so it never mis-flags a success), and the combined
  classifier (signal beats heuristic). No DB / no harness — pure functions.
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.Agents.Holding

  describe "parse_signal/1" do
    test "matches a well-formed token, taking the rest of the line as the reason" do
      assert Holding.parse_signal(":holding browser login required") ==
               {:ok, "browser login required"}
    end

    test "finds the token at the end of a multi-line message" do
      msg = "I can't proceed until someone logs in.\n\n:holding browser login required"
      assert Holding.parse_signal(msg) == {:ok, "browser login required"}
    end

    test "takes the LAST occurrence (a worker may quote the contract earlier)" do
      msg = """
      The contract says to end with `:holding <short reason>`.
      Here is mine:
      :holding waiting for the operator to authenticate
      """

      assert Holding.parse_signal(msg) == {:ok, "waiting for the operator to authenticate"}
    end

    test "strips a trailing period" do
      assert Holding.parse_signal("done for now :holding credential needed.") ==
               {:ok, "credential needed"}
    end

    test "strips trailing backticks" do
      assert Holding.parse_signal("see `:holding manual step required`") ==
               {:ok, "manual step required"}
    end

    test "returns :none for prose without the token" do
      assert Holding.parse_signal("I finished the analysis and reported back.") == :none
    end

    test "returns :none for an empty reason" do
      assert Holding.parse_signal(":holding   ") == :none
    end

    test "returns :none for nil" do
      assert Holding.parse_signal(nil) == :none
    end
  end

  describe "detect/1" do
    for phrase <- [
          "waiting for you to log in",
          "log in to the browser",
          "requires a browser login",
          "please sign in",
          "authenticate in the browser",
          "manual login required"
        ] do
      test "positive on the documented phrase #{inspect(phrase)} (case-insensitive)" do
        phrase = unquote(phrase)
        text = "The tool is blocked. #{String.upcase(phrase)} before I can continue."
        assert Holding.detect(text) == {:ok, phrase}
      end
    end

    test "negative on a normal successful completion (no false positive)" do
      assert Holding.detect("Done. All tests pass.") == :none
    end

    test "negative on an ordinary in-progress report" do
      assert Holding.detect("Still working on the refactor; about halfway through.") == :none
    end

    test "returns :none for nil" do
      assert Holding.detect(nil) == :none
    end
  end

  describe "classify/1" do
    test "the explicit signal beats the heuristic" do
      # Both a phrase AND a signal are present; the signal's reason wins.
      text = "This requires a browser login.\n:holding operator must authenticate"
      assert Holding.classify(text) == {:ok, "operator must authenticate"}
    end

    test "falls back to the heuristic when no signal is present" do
      assert Holding.classify("The page says: please sign in to continue.") ==
               {:ok, "please sign in"}
    end

    test "returns :none when neither a signal nor a phrase is present" do
      assert Holding.classify("Finished and summarized the results.") == :none
    end

    test "returns :none for nil" do
      assert Holding.classify(nil) == :none
    end
  end

  describe "protocol_clause/0 and holding_resume_prompt/2" do
    test "protocol_clause teaches the :holding signal and the HOLDING (not retired) outcome" do
      clause = Holding.protocol_clause()
      assert clause =~ ":holding <short reason>"
      assert clause =~ "HOLDING"
      assert clause =~ "do NOT report success"
    end

    test "holding_resume_prompt names the worker + reason and says blocked, not done" do
      prompt = Holding.holding_resume_prompt("scraper", "browser login required")
      assert prompt =~ "scraper"
      assert prompt =~ "browser login required"
      assert prompt =~ "HOLDING"
      assert prompt =~ "command_agent"
      assert prompt =~ "NOT been deleted"
    end
  end
end
