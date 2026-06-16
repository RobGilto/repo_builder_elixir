defmodule RepoBuilder.Harness.Pi.ModelsTest do
  @moduledoc """
  Parsing the columnar `pi --list-models` output into `%{provider => [model]}`
  (issue-d follow-up). The live shell-out is disabled in the test env; only the
  pure parser is exercised here.
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.Harness.Pi.Models

  @sample """
  provider    model                                               context  max-out  thinking  images
  anthropic   claude-3-5-haiku-latest                             200K     8.2K     no        yes
  anthropic   claude-sonnet-4-5                                   200K     64K      yes       yes
  minimax     MiniMax-M2.7                                        200K     8.2K     no        no
  minimax     MiniMax-M2.7-highspeed                              204.8K   131.1K   yes       no
  minimax     MiniMax-M3                                          1M       8.2K     yes       yes
  """

  test "parse/1 groups models by provider and skips the header" do
    parsed = Models.parse(@sample)

    assert parsed["minimax"] == ["MiniMax-M2.7", "MiniMax-M2.7-highspeed", "MiniMax-M3"]
    assert parsed["anthropic"] == ["claude-3-5-haiku-latest", "claude-sonnet-4-5"]
    refute Map.has_key?(parsed, "provider")
  end

  test "parse/1 tolerates blank lines and ragged whitespace" do
    parsed =
      Models.parse("provider model\n\nminimax   MiniMax-M3   1M\n   \nzai  glm-4.6  200K\n")

    assert parsed["minimax"] == ["MiniMax-M3"]
    assert parsed["zai"] == ["glm-4.6"]
  end

  test "list/1 is empty when discovery is disabled (test env)" do
    assert Models.list("minimax") == []
  end
end
