defmodule RepoBuilder.Harness.ClaudeNormalizeTest do
  use ExUnit.Case, async: true

  alias RepoBuilder.Harness.{Claude, Event}
  alias RepoBuilder.HarnessFixtures

  @ctx %{harness: :claude}

  setup do
    %{frames: HarnessFixtures.frames("claude_stream.jsonl")}
  end

  test "command/1 builds the streaming-json argv with all three delta flags and secrets in env" do
    opts = %{
      prompt: "do it",
      model: "claude-sonnet-4-6",
      cwd: ".",
      sink: self(),
      secrets: %{"ANTHROPIC_API_KEY" => "sk-x"}
    }

    {exe, args, env, ctx} = Claude.command(opts)

    assert exe == "claude"
    assert "--output-format" in args and "stream-json" in args
    assert "--verbose" in args
    assert "--include-partial-messages" in args
    assert "--model" in args and "claude-sonnet-4-6" in args
    refute "sk-x" in args, "secrets must never appear in argv (visible in ps)"
    assert {"ANTHROPIC_API_KEY", "sk-x"} in env
    assert ctx == @ctx
  end

  test "system init -> SessionStarted", %{frames: frames} do
    assert {:ok,
            [
              %Event.SessionStarted{
                harness: :claude,
                session_id: "sess_abc123",
                model: "claude-sonnet-4-6",
                tools: ["Bash", "Read"]
              }
            ]} =
             Claude.normalize(Enum.at(frames, 0), @ctx)
  end

  test "stream_event nested delta -> partial TextDelta", %{frames: frames} do
    assert {:ok, [%Event.TextDelta{text: "Hel", thinking?: false}]} =
             Claude.normalize(Enum.at(frames, 1), @ctx)
  end

  test "assistant text block -> TextDelta + per-message Usage", %{frames: frames} do
    assert {:ok,
            [
              %Event.TextDelta{text: "Hello, world", thinking?: false},
              %Event.Usage{input_tokens: 12, output_tokens: 3}
            ]} =
             Claude.normalize(Enum.at(frames, 2), @ctx)
  end

  test "assistant thinking block -> thinking TextDelta", %{frames: frames} do
    assert {:ok, [%Event.TextDelta{text: "Let me think about this.", thinking?: true}]} =
             Claude.normalize(Enum.at(frames, 3), @ctx)
  end

  test "assistant tool_use block -> ToolCall", %{frames: frames} do
    assert {:ok, [%Event.ToolCall{id: "toolu_1", name: "Bash", input: %{"command" => "ls"}}]} =
             Claude.normalize(Enum.at(frames, 4), @ctx)
  end

  test "user tool_result block -> ToolResult", %{frames: frames} do
    assert {:ok, [%Event.ToolResult{id: "toolu_1", is_error: false, content: "file.txt"}]} =
             Claude.normalize(Enum.at(frames, 5), @ctx)
  end

  test "system api_retry -> Status(:retry)", %{frames: frames} do
    assert {:ok, [%Event.Status{kind: :retry, attempt: 1}]} =
             Claude.normalize(Enum.at(frames, 6), @ctx)
  end

  test "multibyte payload survives normalization", %{frames: frames} do
    assert {:ok, [%Event.TextDelta{text: text}]} = Claude.normalize(Enum.at(frames, 7), @ctx)
    assert String.contains?(text, "こんにちは")
    assert String.contains?(text, "🌍")
  end

  test "result success -> [Usage, Done] with cost and ok=true", %{frames: frames} do
    assert {:ok,
            [
              %Event.Usage{
                input_tokens: 120,
                output_tokens: 45,
                cache_read: 10,
                cost_usd: 0.0123
              },
              done
            ]} =
             Claude.normalize(Enum.at(frames, 8), @ctx)

    assert %Event.Done{
             ok: true,
             reason: :success,
             cost_usd: 0.0123,
             final_text: "All done",
             duration_ms: 3400,
             num_turns: 2
           } = done
  end

  test "is_error on a success subtype overrides Done.ok" do
    raw = %{
      "type" => "result",
      "subtype" => "success",
      "is_error" => true,
      "result" => "partial",
      "usage" => %{}
    }

    assert {:ok, [%Event.Done{ok: false, reason: :success}]} = Claude.normalize(raw, @ctx)
  end

  test "result error subtype -> Error(:provider_error)" do
    raw = %{
      "type" => "result",
      "subtype" => "error_max_turns",
      "errors" => ["hit max turns"],
      "api_error_status" => 500
    }

    assert {:ok, [%Event.Error{reason: :provider_error, message: "hit max turns", status: 500}]} =
             Claude.normalize(raw, @ctx)
  end
end
