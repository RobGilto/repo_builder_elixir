defmodule RepoBuilder.Console.Diff do
  @moduledoc """
  Pure, typed line-level LCS diff engine for the file-diff event cards
  (issue file-diff-event-cards).

  Splits old/new text on `"\\n"` and computes an ordered list of `:eq`/`:ins`/`:del`
  line operations using a Myers-style LCS dynamic-programming approach. Output is
  capped at `@max_lines` to bound DOM size for large writes. Pure, total, never raises.

  For inputs exceeding `@max_input_lines` per side the engine falls back to a simple
  all-del + all-ins representation (accurate counts, bounded allocation) instead of
  running an O(m·n) LCS on a multi-thousand-line file.
  """

  @enforce_keys [:lines, :added, :removed, :truncated?]
  defstruct [:lines, :added, :removed, :truncated?]

  @typedoc "A single diff line operation."
  @type line :: %{op: :eq | :ins | :del, text: String.t()}

  @typedoc "A computed line diff result."
  @type t :: %__MODULE__{
          lines: [line()],
          added: non_neg_integer(),
          removed: non_neg_integer(),
          truncated?: boolean()
        }

  # Maximum number of diff line ops emitted; longer diffs are capped + flagged.
  @max_lines 600

  # Maximum input lines per side before falling back to simple del+ins (avoids O(m·n) LCS).
  @max_input_lines 800

  @doc """
  Compute a line-level diff between `old_text` and `new_text`.

  Returns a `t()` with:
  - `lines` — ordered `:eq`/`:ins`/`:del` ops (at most `@max_lines`).
  - `added` / `removed` — total counts (computed before the output cap).
  - `truncated?` — `true` when the output cap was hit.

  Pure and total: both arguments must be binaries; any other input raises a function
  clause error (caller must guard). The result never raises internally.
  """
  @spec diff(String.t(), String.t()) :: t()
  def diff(old_text, new_text) when is_binary(old_text) and is_binary(new_text) do
    old_lines = split_lines(old_text)
    new_lines = split_lines(new_text)
    ops = compute_ops(old_lines, new_lines)

    added = Enum.count(ops, &(&1.op == :ins))
    removed = Enum.count(ops, &(&1.op == :del))

    {lines, truncated?} =
      if length(ops) > @max_lines do
        {Enum.take(ops, @max_lines), true}
      else
        {ops, false}
      end

    %__MODULE__{lines: lines, added: added, removed: removed, truncated?: truncated?}
  end

  # --- internal ---------------------------------------------------------------

  @spec split_lines(String.t()) :: [String.t()]
  defp split_lines(""), do: []
  defp split_lines(text), do: String.split(text, "\n")

  # Dispatch to the appropriate strategy based on input sizes.
  @spec compute_ops([String.t()], [String.t()]) :: [line()]
  defp compute_ops([], []), do: []
  defp compute_ops(old, []), do: Enum.map(old, &%{op: :del, text: &1})
  defp compute_ops([], new), do: Enum.map(new, &%{op: :ins, text: &1})

  defp compute_ops(old, new) do
    if length(old) > @max_input_lines or length(new) > @max_input_lines do
      # Large input fallback: all-del + all-ins (accurate counts, bounded allocation).
      Enum.map(old, &%{op: :del, text: &1}) ++ Enum.map(new, &%{op: :ins, text: &1})
    else
      common = lcs_sequence(old, new)
      emit_ops(old, new, common, []) |> Enum.reverse()
    end
  end

  # LCS via DP table (map-based: {i, j} → lcs_length).
  # Returns the common subsequence as a list of strings.
  @spec lcs_sequence([String.t()], [String.t()]) :: [String.t()]
  defp lcs_sequence(old, new) do
    m = length(old)
    n = length(new)
    oa = List.to_tuple(old)
    na = List.to_tuple(new)

    table =
      for i <- 1..m, j <- 1..n, reduce: %{} do
        acc ->
          val =
            if elem(oa, i - 1) == elem(na, j - 1) do
              Map.get(acc, {i - 1, j - 1}, 0) + 1
            else
              max(Map.get(acc, {i - 1, j}, 0), Map.get(acc, {i, j - 1}, 0))
            end

          Map.put(acc, {i, j}, val)
      end

    backtrack(table, oa, na, m, n, [])
  end

  # Reconstruct the LCS by backtracking through the DP table.
  @spec backtrack(map(), tuple(), tuple(), non_neg_integer(), non_neg_integer(), [String.t()]) ::
          [String.t()]
  defp backtrack(_table, _oa, _na, 0, _j, acc), do: acc
  defp backtrack(_table, _oa, _na, _i, 0, acc), do: acc

  defp backtrack(table, oa, na, i, j, acc) do
    if elem(oa, i - 1) == elem(na, j - 1) do
      backtrack(table, oa, na, i - 1, j - 1, [elem(oa, i - 1) | acc])
    else
      up = Map.get(table, {i - 1, j}, 0)
      left = Map.get(table, {i, j - 1}, 0)

      if up >= left do
        backtrack(table, oa, na, i - 1, j, acc)
      else
        backtrack(table, oa, na, i, j - 1, acc)
      end
    end
  end

  # Build ordered :eq/:del/:ins ops from old/new lines and their LCS.
  # `acc` is built in reverse; caller calls `Enum.reverse/1`.
  #
  # Strategy (del-before-ins for replaced blocks, matching standard git diff):
  #   - When both old and new heads match the LCS head → :eq, advance all three.
  #   - When old head differs from LCS head → :del, advance old only.
  #   - When old matches (or old is empty) but new doesn't → :ins, advance new only.
  #   - When LCS exhausted → drain remaining old as :del, new as :ins.
  @spec emit_ops([String.t()], [String.t()], [String.t()], [line()]) :: [line()]
  defp emit_ops([], [], _lcs, acc), do: acc

  # LCS exhausted with remaining old → drain as :del
  defp emit_ops([oh | ot], new, [], acc),
    do: emit_ops(ot, new, [], [%{op: :del, text: oh} | acc])

  # LCS exhausted with remaining new → drain as :ins
  defp emit_ops([], [nh | nt], _lcs, acc),
    do: emit_ops([], nt, [], [%{op: :ins, text: nh} | acc])

  # Both heads match the LCS head → :eq
  defp emit_ops([h | ot], [h | nt], [h | lt], acc),
    do: emit_ops(ot, nt, lt, [%{op: :eq, text: h} | acc])

  # Old head doesn't match LCS head → :del
  defp emit_ops([oh | ot], new, [lh | _] = lcs, acc) when oh != lh,
    do: emit_ops(ot, new, lcs, [%{op: :del, text: oh} | acc])

  # Old matches (or old empty), new doesn't match LCS head → :ins
  defp emit_ops(old, [nh | nt], lcs, acc),
    do: emit_ops(old, nt, lcs, [%{op: :ins, text: nh} | acc])
end
