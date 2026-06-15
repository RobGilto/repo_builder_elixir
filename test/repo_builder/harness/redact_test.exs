defmodule RepoBuilder.Harness.RedactTest do
  use ExUnit.Case, async: true

  alias RepoBuilder.Harness.{Event, Redact}

  test "masks credential keys at arbitrary nesting in maps AND lists (string keys)" do
    raw = %{
      "ANTHROPIC_API_KEY" => "sk-ant-secret",
      "nested" => %{"authorization" => "Bearer abc", "ok" => 1},
      "messages" => [
        %{"api_key" => "sk-leak", "text" => "hello"},
        %{"token" => "tok_123", "role" => "user"}
      ]
    }

    scrubbed = Redact.scrub(%Event.TextDelta{harness: :claude, text: "t", raw: raw}).raw

    assert scrubbed["ANTHROPIC_API_KEY"] == "[REDACTED]"
    assert scrubbed["nested"]["authorization"] == "[REDACTED]"
    assert scrubbed["nested"]["ok"] == 1
    assert Enum.at(scrubbed["messages"], 0)["api_key"] == "[REDACTED]"
    assert Enum.at(scrubbed["messages"], 0)["text"] == "hello"
    assert Enum.at(scrubbed["messages"], 1)["token"] == "[REDACTED]"
    assert Enum.at(scrubbed["messages"], 1)["role"] == "user"
  end

  test "is case-insensitive on key names" do
    raw = %{"Api_Key" => "x", "AUTHORIZATION" => "y", "Secret" => "z"}
    scrubbed = Redact.scrub(%Event.TextDelta{harness: :pi, text: "t", raw: raw}).raw

    assert scrubbed == %{
             "Api_Key" => "[REDACTED]",
             "AUTHORIZATION" => "[REDACTED]",
             "Secret" => "[REDACTED]"
           }
  end

  test "truncates oversized blobs" do
    big = String.duplicate("a", 20_000)
    scrubbed = Redact.scrub(%Event.TextDelta{harness: :pi, text: "t", raw: %{"blob" => big}}).raw
    assert String.length(scrubbed["blob"]) < 20_000
    assert String.ends_with?(scrubbed["blob"], "...[truncated]")
  end

  test "preserves non-secret data and event shape" do
    event = %Event.ToolCall{
      harness: :claude,
      name: "Bash",
      input: %{"command" => "ls"},
      raw: %{"keep" => true}
    }

    scrubbed = Redact.scrub(event)
    assert %Event.ToolCall{} = scrubbed
    assert scrubbed.name == "Bash"
    assert scrubbed.raw == %{"keep" => true}
  end

  test "is total over arbitrary terms and never raises" do
    assert Redact.scrub_term(nil) == nil
    assert Redact.scrub_term({:a, :tuple}) == {:a, :tuple}
    assert Redact.scrub_term(42) == 42

    assert Redact.scrub_term([%{"token" => "x"}, "plain", 3]) == [
             %{"token" => "[REDACTED]"},
             "plain",
             3
           ]

    # atom-keyed secret also masked
    assert Redact.scrub_term(%{api_key: "leak", ok: 1}) == %{api_key: "[REDACTED]", ok: 1}
  end
end
