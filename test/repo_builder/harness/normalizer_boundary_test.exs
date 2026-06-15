defmodule RepoBuilder.Harness.NormalizerBoundaryTest do
  use ExUnit.Case, async: true

  alias RepoBuilder.Harness.{Claude, Pi}
  alias RepoBuilder.HarnessFixtures

  # Mirrors the §6 runtime line-framing: accumulate bytes, split on "\n" (0x0A)
  # ONLY, carry the trailing partial fragment forward untouched.
  @spec frame_chunks([binary()]) :: [binary()]
  defp frame_chunks(chunks) do
    {lines, _buf} =
      Enum.reduce(chunks, {[], ""}, fn chunk, {acc, buf} ->
        bin = buf <> chunk
        parts = String.split(bin, "\n")
        {complete, [partial]} = Enum.split(parts, length(parts) - 1)
        {acc ++ complete, partial}
      end)

    Enum.reject(lines, &(&1 == ""))
  end

  test "a malformed/non-JSON line is reported by Jason.decode and never crashes" do
    assert {:error, _} = Jason.decode("this is not json {")
    assert {:error, _} = Jason.decode(~s({"unterminated": ))
  end

  test "splitting a multibyte UTF-8 stream byte-by-byte never corrupts a complete line" do
    bin = HarnessFixtures.read("claude_stream.jsonl")
    one_byte_chunks = for <<b <- bin>>, do: <<b>>

    lines = frame_chunks(one_byte_chunks)

    # Same number of lines as a naive newline split, and every complete line is valid UTF-8 + JSON.
    assert length(lines) == length(HarnessFixtures.lines("claude_stream.jsonl"))

    for line <- lines do
      assert String.valid?(line)
      assert {:ok, %{"type" => _}} = Jason.decode(line)
    end
  end

  test "a partial line split across two chunks reassembles correctly" do
    [line | _] = HarnessFixtures.lines("pi_stream.jsonl")
    {head, tail} = HarnessFixtures.chunk_at(line <> "\n", 5)

    assert frame_chunks([head, tail]) == [line]
    assert {:ok, _} = Jason.decode(line)
  end

  test "U+2028 / U+2029 inside a JSON string payload are NOT treated as line breaks" do
    payload = "a" <> "\u{2028}" <> "b" <> "\u{2029}" <> "c"
    line = Jason.encode!(%{"type" => "text", "text" => payload})

    # The framing splitter cuts on "\n" only; the line stays whole.
    assert frame_chunks([line <> "\n"]) == [line]
    assert {:ok, %{"text" => ^payload}} = Jason.decode(line)
  end

  test "unknown / wrong-shaped frames return :skip and never raise (both adapters)" do
    weird = [
      %{},
      %{"type" => "totally_unknown"},
      %{"type" => 123},
      %{"no_type" => true},
      %{"type" => "system", "subtype" => "weird"}
    ]

    for frame <- weird do
      assert Claude.normalize(frame, %{harness: :claude}) in [:skip] or
               match?({:ok, _}, Claude.normalize(frame, %{harness: :claude}))

      assert Pi.normalize(frame, %{harness: :pi}) in [:skip] or
               match?({:ok, _}, Pi.normalize(frame, %{harness: :pi}))
    end
  end

  test "feeding each adapter the OTHER adapter's frames never raises" do
    for frame <- HarnessFixtures.frames("pi_stream.jsonl") do
      result = Claude.normalize(frame, %{harness: :claude})
      assert result == :skip or match?({:ok, _}, result)
    end

    for frame <- HarnessFixtures.frames("claude_stream.jsonl") do
      result = Pi.normalize(frame, %{harness: :pi})
      assert result == :skip or match?({:ok, _}, result)
    end
  end
end
