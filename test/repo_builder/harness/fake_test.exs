defmodule RepoBuilder.Harness.FakeTest do
  use ExUnit.Case, async: true

  alias RepoBuilder.Harness.{Event, Fake}

  test "canned_events/0 emits the canonical sequence with harness: :fake" do
    events = Fake.canned_events()

    assert Enum.map(events, & &1.type) == [
             :session_started,
             :text_delta,
             :text_delta,
             :tool_call,
             :tool_result,
             :usage,
             :done
           ]

    assert Enum.all?(events, &(&1.harness == :fake))
  end

  test "canned_events/0 carries meaningful payloads" do
    events = Fake.canned_events()

    assert %Event.SessionStarted{session_id: "fake-session", model: "fake-model"} =
             Enum.at(events, 0)

    assert %Event.ToolCall{name: "bash", id: "call_1"} = Enum.at(events, 3)
    assert %Event.Usage{input_tokens: 10, output_tokens: 5, cost_usd: +0.0} = Enum.at(events, 5)
    assert %Event.Done{ok: true, reason: :success, final_text: "Hello world"} = Enum.at(events, 6)
  end

  test "command/1 returns a real argv that prints the canned frames as JSONL" do
    opts = %{prompt: "hi", model: nil, cwd: ".", sink: self()}
    assert {"printf", ["%s\n" | lines], [], %{harness: :fake}} = Fake.command(opts)
    assert Enum.all?(lines, &is_binary/1)
    assert {:ok, %{"type" => "session_started"}} = Jason.decode(hd(lines))
  end

  test "normalize/2 maps a fake frame and skips unknown frames" do
    assert {:ok, [%Event.TextDelta{text: "hi", harness: :fake}]} =
             Fake.normalize(%{"type" => "text_delta", "text" => "hi"}, %{harness: :fake})

    assert Fake.normalize(%{"type" => "nonsense"}, %{harness: :fake}) == :skip
  end
end
