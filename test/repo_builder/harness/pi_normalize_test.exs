defmodule RepoBuilder.Harness.PiNormalizeTest do
  use ExUnit.Case, async: true

  alias RepoBuilder.Harness.{Event, Pi}
  alias RepoBuilder.HarnessFixtures

  @ctx %{harness: :pi}

  setup do
    %{frames: HarnessFixtures.frames("pi_stream.jsonl")}
  end

  test "cache tokens contribute to the derived cost when a price table is supplied" do
    ctx = %{harness: :pi, model: "glm-4.6", price_table: %{"glm-4.6" => 6.0}}

    base = %{"type" => "turn_end", "message" => %{"usage" => %{"input" => 10, "output" => 5}}}

    cached =
      put_in(base["message"]["usage"]["cache_read"], 1_000_000)

    assert {:ok, [%Event.Usage{cost_usd: base_cost}]} = Pi.normalize(base, ctx)
    assert {:ok, [%Event.Usage{cost_usd: cached_cost}]} = Pi.normalize(cached, ctx)
    assert cached_cost > base_cost

    # Unpriced still yields nil even with cache tokens present.
    assert {:ok, [%Event.Usage{cost_usd: nil}]} =
             Pi.normalize(cached, %{harness: :pi, model: "x", price_table: %{}})
  end

  test "command/1 builds the --mode json argv" do
    {exe, args, _env, ctx} = Pi.command(%{prompt: "go", model: nil, cwd: ".", sink: self()})
    assert exe == "pi"
    assert "--mode" in args and "json" in args
    assert ctx.harness == :pi
  end

  test "session (first line) -> SessionStarted", %{frames: frames} do
    assert {:ok, [%Event.SessionStarted{harness: :pi, session_id: "pi_sess_1"}]} =
             Pi.normalize(Enum.at(frames, 0), @ctx)
  end

  test "lifecycle-noise frames -> :skip", %{frames: frames} do
    assert Pi.normalize(Enum.at(frames, 1), @ctx) == :skip
    assert Pi.normalize(Enum.at(frames, 2), @ctx) == :skip
    assert Pi.normalize(Enum.at(frames, 3), @ctx) == :skip
  end

  test "message_update discriminates text_delta vs thinking_delta (both partial)", %{
    frames: frames
  } do
    assert {:ok, [%Event.TextDelta{text: "Hi ", thinking?: false, partial?: true}]} =
             Pi.normalize(Enum.at(frames, 4), @ctx)

    assert {:ok, [%Event.TextDelta{text: "pondering", thinking?: true, partial?: true}]} =
             Pi.normalize(Enum.at(frames, 5), @ctx)
  end

  test "tool execution (camelCase fields) -> ToolCall / ToolResult", %{frames: frames} do
    assert {:ok, [%Event.ToolCall{id: "tc_1", name: "bash", input: %{"cmd" => "echo hi"}}]} =
             Pi.normalize(Enum.at(frames, 6), @ctx)

    assert {:ok, [%Event.ToolResult{id: "tc_1", is_error: false, content: "hi"}]} =
             Pi.normalize(Enum.at(frames, 7), @ctx)
  end

  test "message_end with text + Anthropic-shaped usage -> [TextDelta, Usage]", %{frames: frames} do
    assert {:ok,
            [
              %Event.TextDelta{thinking?: false, partial?: false, text: text},
              %Event.Usage{input_tokens: 100, output_tokens: 50, cost_usd: nil}
            ]} =
             Pi.normalize(Enum.at(frames, 8), @ctx)

    assert String.contains?(text, "世界")
  end

  test "message_end for a `toolResult` message is NOT harvested as assistant text" do
    # pi-agent-core emits message_start/message_end for the `toolResult` message it
    # feeds back to the model. Its content is the tool's output as `type:"text"`
    # blocks — this MUST NOT leak into the orchestrator's TEXT channel (chat); the
    # canonical result already comes from the `tool_execution_end` clause.
    tool_result_echo = %{
      "type" => "message_end",
      "message" => %{
        "role" => "toolResult",
        "toolCallId" => "call_18cde5414901425d94fc3183",
        "toolName" => "configure_tier",
        "isError" => false,
        "content" => [
          %{
            "type" => "text",
            "text" =>
              ~s({"category":"fast","harness":"claude","model":"claude-haiku-4-5","status":"configured"})
          }
        ]
      }
    }

    assert Pi.normalize(tool_result_echo, @ctx) == :skip
  end

  test "message_end for an `assistant` message still yields the genuine prose TextDelta" do
    assistant_prose = %{
      "type" => "message_end",
      "message" => %{
        "role" => "assistant",
        "content" => [%{"type" => "text", "text" => "Configured the fast tier."}]
      }
    }

    assert {:ok,
            [
              %Event.TextDelta{
                thinking?: false,
                partial?: false,
                text: "Configured the fast tier."
              }
            ]} =
             Pi.normalize(assistant_prose, @ctx)
  end

  test "turn_end with OpenAI-shaped usage -> Usage", %{frames: frames} do
    assert {:ok, [%Event.Usage{input_tokens: 100, output_tokens: 50}]} =
             Pi.normalize(Enum.at(frames, 9), @ctx)
  end

  test "agent_end with pi-native usage -> [Usage, Done(:agent_end)]", %{frames: frames} do
    assert {:ok,
            [
              %Event.Usage{input_tokens: 120, output_tokens: 60, cache_read: 5},
              %Event.Done{ok: true, reason: :agent_end}
            ]} =
             Pi.normalize(Enum.at(frames, 10), @ctx)
  end

  describe "provider-polymorphic usage (all three shapes)" do
    test "Anthropic-shaped" do
      raw = %{
        "type" => "turn_end",
        "message" => %{"usage" => %{"input_tokens" => 7, "output_tokens" => 9}}
      }

      assert {:ok, [%Event.Usage{input_tokens: 7, output_tokens: 9}]} = Pi.normalize(raw, @ctx)
    end

    test "OpenAI-shaped" do
      raw = %{
        "type" => "turn_end",
        "message" => %{"usage" => %{"prompt_tokens" => 11, "completion_tokens" => 13}}
      }

      assert {:ok, [%Event.Usage{input_tokens: 11, output_tokens: 13}]} = Pi.normalize(raw, @ctx)
    end

    test "pi-native (zai/GLM) bare input/output + cache" do
      raw = %{
        "type" => "turn_end",
        "message" => %{"usage" => %{"input" => 17, "output" => 19, "cacheRead" => 3}}
      }

      assert {:ok, [%Event.Usage{input_tokens: 17, output_tokens: 19, cache_read: 3}]} =
               Pi.normalize(raw, @ctx)
    end
  end

  test "auto_retry_end success:false -> Error(:auto_retry_exhausted)" do
    raw = %{
      "type" => "auto_retry_end",
      "success" => false,
      "finalError" => "model overloaded",
      "retryable" => true
    }

    assert {:ok,
            [
              %Event.Error{
                reason: :auto_retry_exhausted,
                message: "model overloaded",
                retryable: true
              }
            ]} = Pi.normalize(raw, @ctx)
  end

  test "pi cost is never defaulted to 0.0 — unpriced stays nil", %{frames: frames} do
    {:ok, events} = Pi.normalize(Enum.at(frames, 8), @ctx)
    usage = Enum.find(events, &match?(%Event.Usage{}, &1))
    assert usage.cost_usd == nil
  end

  test "zai/GLM stream: partial delta is partial?, message_end finalized is not" do
    zai = HarnessFixtures.frames("pi_zai_stream.jsonl")

    assert {:ok, [%Event.TextDelta{text: "GLM output", partial?: true}]} =
             Pi.normalize(Enum.at(zai, 1), @ctx)

    assert {:ok, [%Event.TextDelta{text: "GLM final", partial?: false} | _usage]} =
             Pi.normalize(Enum.at(zai, 2), @ctx)
  end
end
