defmodule RepoBuilder.Harness.RedactValuesTest do
  @moduledoc """
  Value-based defense-in-depth scrubbing (issue-per-project-encrypted-secrets-vault):
  `Redact.scrub_values/2` replaces every exact occurrence of each secret value at any
  depth, walks event structs, and is an identity no-op on the empty value list.
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.Harness.{Event, Redact}

  test "replaces all occurrences at any depth in maps and lists" do
    term = %{
      "msg" => "the key is sk-secret-123 ok",
      "nested" => %{"again" => "sk-secret-123"},
      "list" => ["clean", "sk-secret-123 trailing"]
    }

    scrubbed = Redact.scrub_values(term, ["sk-secret-123"])

    assert scrubbed["msg"] == "the key is [REDACTED] ok"
    assert scrubbed["nested"]["again"] == "[REDACTED]"
    assert scrubbed["list"] == ["clean", "[REDACTED] trailing"]
  end

  test "walks an event struct's raw + text fields, preserving the struct type" do
    event = %Event.TextDelta{
      harness: :fake,
      text: "echoing sk-secret-123 to you",
      raw: %{"text" => "sk-secret-123", "ok" => 1}
    }

    scrubbed = Redact.scrub_values(event, ["sk-secret-123"])

    assert %Event.TextDelta{} = scrubbed
    assert scrubbed.text == "echoing [REDACTED] to you"
    assert scrubbed.raw["text"] == "[REDACTED]"
    assert scrubbed.raw["ok"] == 1
  end

  test "the empty value list is an exact identity (hot-path no-op)" do
    term = %{"a" => ["b", %{"c" => "d"}]}
    assert Redact.scrub_values(term, []) == term
  end

  test "blank and non-binary values are ignored" do
    assert Redact.scrub_values("keep me", ["", nil]) == "keep me"
  end

  test "scrubs multiple distinct values" do
    assert Redact.scrub_values("a=AAA b=BBB", ["AAA", "BBB"]) == "a=[REDACTED] b=[REDACTED]"
  end
end
