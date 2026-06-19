defmodule RepoBuilder.PromptStandard.Checks do
  @moduledoc """
  Compiled regexes and small pure helpers shared by the validator (port of the Python
  module-level patterns in `prompt_builder/validator.py`). Keeping them here keeps the
  validator's check functions readable.
  """

  # Double-brace token pattern (Population B / Path-1 assembly).
  @double_brace ~r/\{\{[A-Z_]+\}\}/
  # Single-brace slot pattern (Population A / Path-2 / .format assembly).
  @single_brace ~r/\{[a-zA-Z_][a-zA-Z0-9_]*\}/
  # Markdown headings, levels 1–3, line-anchored.
  @heading ~r/^(\#{1,3} .+)$/m

  @doc "All `{{TOKEN}}` sentinels found in `content` (with braces), order-preserving."
  @spec find_tokens(String.t()) :: [String.t()]
  def find_tokens(content) when is_binary(content),
    do: @double_brace |> Regex.scan(content) |> Enum.map(&hd/1)

  @doc "All `{slot}` occurrences found in `content` (with braces), order-preserving."
  @spec find_slots(String.t()) :: [String.t()]
  def find_slots(content) when is_binary(content),
    do: @single_brace |> Regex.scan(content) |> Enum.map(&hd/1)

  @doc "All level 1–3 markdown headings in `content`."
  @spec headings(String.t()) :: [String.t()]
  def headings(content) when is_binary(content),
    do: @heading |> Regex.scan(content) |> Enum.map(&Enum.at(&1, 1))

  @doc "Whether the content starts with a UTF-8 BOM (matches Python `startswith(\"\\ufeff\")`)."
  @spec has_bom?(String.t()) :: boolean()
  def has_bom?(content) when is_binary(content), do: String.starts_with?(content, "﻿")

  @doc "Remove every `{{TOKEN}}` occurrence so single-brace detection ignores double braces."
  @spec strip_double_brace(String.t()) :: String.t()
  def strip_double_brace(content) when is_binary(content),
    do: Regex.replace(@double_brace, content, "")

  @doc "Whether `content` contains any `{{TOKEN}}` sentinel."
  @spec has_double_brace?(String.t()) :: boolean()
  def has_double_brace?(content) when is_binary(content), do: Regex.match?(@double_brace, content)

  @doc "Whether `content` contains any `{slot}` (single-brace) pattern."
  @spec has_single_brace?(String.t()) :: boolean()
  def has_single_brace?(content) when is_binary(content), do: Regex.match?(@single_brace, content)
end
