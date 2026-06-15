defmodule RepoBuilder.HarnessFixtures do
  @moduledoc """
  Captured harness wire frames + chunk-splitter helpers for normalizer and
  runtime boundary tests (BUILD_PROMPT.md §13).
  """

  @fixtures_dir Path.join(__DIR__, "fixtures")

  @doc "Read a fixture file's raw contents."
  @spec read(String.t()) :: binary()
  def read(name), do: File.read!(Path.join(@fixtures_dir, name))

  @doc "Read a `.jsonl` fixture and return its non-empty lines (newline-stripped)."
  @spec lines(String.t()) :: [binary()]
  def lines(name) do
    name
    |> read()
    |> String.split("\n", trim: true)
  end

  @doc "Read a `.jsonl` fixture and decode each line into a raw map."
  @spec frames(String.t()) :: [map()]
  def frames(name) do
    name
    |> lines()
    |> Enum.map(&Jason.decode!/1)
  end

  @doc """
  Split a binary at an arbitrary BYTE offset into `{head, tail}` — used to simulate
  stdout chunks that split a multibyte UTF-8 character or JSON token across two
  messages. The offset is clamped to `[0, byte_size(bin)]`.
  """
  @spec chunk_at(binary(), non_neg_integer()) :: {binary(), binary()}
  def chunk_at(bin, offset) when is_binary(bin) do
    offset = offset |> max(0) |> min(byte_size(bin))
    <<head::binary-size(^offset), tail::binary>> = bin
    {head, tail}
  end
end
