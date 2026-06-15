defmodule RepoBuilder.Harness.EventTest do
  use ExUnit.Case, async: true

  alias RepoBuilder.Harness.Event

  describe "variant defaults" do
    test "each variant carries its fixed :type discriminator" do
      assert %Event.SessionStarted{harness: :fake, session_id: "s"}.type == :session_started
      assert %Event.TextDelta{harness: :fake, text: "t"}.type == :text_delta
      assert %Event.ToolCall{harness: :fake, name: "n"}.type == :tool_call
      assert %Event.ToolResult{harness: :fake, content: nil}.type == :tool_result
      assert %Event.Usage{harness: :fake, input_tokens: 0, output_tokens: 0}.type == :usage
      assert %Event.Status{harness: :fake, kind: :retry}.type == :status
      assert %Event.Done{harness: :fake, ok: true, reason: :success}.type == :done
      assert %Event.Error{harness: :fake, message: "boom"}.type == :error
    end

    test "raw defaults to an empty map; thinking? defaults to false; error reason defaults to :unknown" do
      assert %Event.TextDelta{harness: :fake, text: "t"}.raw == %{}
      assert %Event.TextDelta{harness: :fake, text: "t"}.thinking? == false
      assert %Event.Error{harness: :fake, message: "m"}.reason == :unknown
      assert %Event.Error{harness: :fake, message: "m"}.retryable == false
    end
  end

  describe "@enforce_keys" do
    test "raises when a required field is missing" do
      assert_raise ArgumentError, fn -> struct!(Event.SessionStarted, harness: :claude) end
      assert_raise ArgumentError, fn -> struct!(Event.TextDelta, harness: :claude) end

      assert_raise ArgumentError, fn ->
        struct!(Event.Usage, harness: :claude, input_tokens: 1)
      end

      assert_raise ArgumentError, fn -> struct!(Event.Done, harness: :claude, ok: true) end
      assert_raise ArgumentError, fn -> struct!(Event.Error, harness: :claude) end
    end

    test "optional fields are not enforced" do
      e = struct!(Event.SessionStarted, harness: :claude, session_id: "s")
      assert e.model == nil
      assert e.tools == nil
    end
  end

  describe "open harness identity (§3 rule 5 / §10)" do
    test "an unregistered harness atom is representable with no core edit" do
      assert %Event.TextDelta{harness: :cursor, text: "x"}.harness == :cursor

      assert %Event.Done{harness: :some_future_harness, ok: true, reason: :clean_exit}.harness ==
               :some_future_harness
    end
  end
end
