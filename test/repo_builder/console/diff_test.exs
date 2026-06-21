defmodule RepoBuilder.Console.DiffTest do
  @moduledoc """
  Unit tests for the pure LCS line-diff engine (issue file-diff-event-cards).
  Covers pure creation, pure deletion, mixed changes, identical inputs, trailing-newline
  handling, and the truncation cap.
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.Console.Diff

  describe "diff/2 — pure creation (empty old)" do
    test "all lines are :ins, added = line count, removed = 0" do
      result = Diff.diff("", "line1\nline2\nline3")
      assert result.added == 3
      assert result.removed == 0
      assert Enum.all?(result.lines, &(&1.op == :ins))
      assert Enum.map(result.lines, & &1.text) == ["line1", "line2", "line3"]
    end

    test "single-line creation" do
      result = Diff.diff("", "hello")
      assert result.added == 1
      assert result.removed == 0
      assert [%{op: :ins, text: "hello"}] = result.lines
    end

    test "empty → empty produces an empty diff" do
      result = Diff.diff("", "")
      assert result.lines == []
      assert result.added == 0
      assert result.removed == 0
      refute result.truncated?
    end
  end

  describe "diff/2 — pure deletion (empty new)" do
    test "all lines are :del, removed = line count, added = 0" do
      result = Diff.diff("a\nb\nc", "")
      assert result.added == 0
      assert result.removed == 3
      assert Enum.all?(result.lines, &(&1.op == :del))
      assert Enum.map(result.lines, & &1.text) == ["a", "b", "c"]
    end
  end

  describe "diff/2 — identical inputs" do
    test "all lines are :eq, added = 0, removed = 0" do
      text = "foo\nbar\nbaz"
      result = Diff.diff(text, text)
      assert result.added == 0
      assert result.removed == 0
      assert Enum.all?(result.lines, &(&1.op == :eq))
      assert Enum.map(result.lines, & &1.text) == ["foo", "bar", "baz"]
    end

    test "single identical line" do
      result = Diff.diff("only", "only")
      assert result.lines == [%{op: :eq, text: "only"}]
      assert result.added == 0
      assert result.removed == 0
    end
  end

  describe "diff/2 — mixed changes (eq / ins / del interleaved)" do
    test "replaces middle line: context + del + ins + context" do
      old = "header\nold middle\nfooter"
      new = "header\nnew middle\nfooter"
      result = Diff.diff(old, new)

      ops = Enum.map(result.lines, & &1.op)
      texts = Enum.map(result.lines, & &1.text)

      assert result.added == 1
      assert result.removed == 1
      # header and footer are unchanged context
      assert :eq in ops
      assert :del in ops
      assert :ins in ops
      assert "header" in texts
      assert "footer" in texts
      assert "old middle" in texts
      assert "new middle" in texts
    end

    test "appends new lines: original lines are eq, new lines are ins" do
      old = "line1\nline2"
      new = "line1\nline2\nline3\nline4"
      result = Diff.diff(old, new)

      assert result.added == 2
      assert result.removed == 0
      eq_texts = result.lines |> Enum.filter(&(&1.op == :eq)) |> Enum.map(& &1.text)
      ins_texts = result.lines |> Enum.filter(&(&1.op == :ins)) |> Enum.map(& &1.text)
      assert eq_texts == ["line1", "line2"]
      assert ins_texts == ["line3", "line4"]
    end

    test "deletes first lines: deleted lines are :del, remaining are :eq" do
      old = "gone1\ngone2\nkept"
      new = "kept"
      result = Diff.diff(old, new)

      assert result.added == 0
      assert result.removed == 2
      assert [%{op: :del}, %{op: :del}, %{op: :eq, text: "kept"}] = result.lines
    end

    test "total replacement: all del then all ins" do
      old = "alpha\nbeta"
      new = "gamma\ndelta"
      result = Diff.diff(old, new)

      assert result.added == 2
      assert result.removed == 2
      del_ops = Enum.filter(result.lines, &(&1.op == :del))
      ins_ops = Enum.filter(result.lines, &(&1.op == :ins))
      assert length(del_ops) == 2
      assert length(ins_ops) == 2
    end
  end

  describe "diff/2 — trailing newline handling" do
    test "text ending with \\n produces a trailing empty-string line" do
      result = Diff.diff("", "a\nb\n")
      # "a\nb\n" splits into ["a", "b", ""]
      assert result.added == 3
      texts = Enum.map(result.lines, & &1.text)
      assert "a" in texts
      assert "b" in texts
      assert "" in texts
    end

    test "identical trailing-newline texts give all :eq" do
      result = Diff.diff("x\n", "x\n")
      assert result.removed == 0
      assert result.added == 0
      assert Enum.all?(result.lines, &(&1.op == :eq))
    end
  end

  describe "diff/2 — truncation cap" do
    test "truncated? is false for diffs within the cap" do
      # 3 lines → well under 600
      result = Diff.diff("a\nb\nc", "d\ne\nf")
      refute result.truncated?
    end

    test "truncated? is true when total ops exceed 600 lines" do
      # Force truncation: old has 400 unique lines, new has 400 unique lines ⇒ 800 ops
      old = Enum.map_join(1..400, "\n", &"old-#{&1}")
      new = Enum.map_join(1..400, "\n", &"new-#{&1}")
      result = Diff.diff(old, new)

      assert result.truncated?
      assert length(result.lines) == 600
    end

    test "added/removed counts are computed before the cap (full totals)" do
      # 400 pure insertions → added = 400, lines capped only at output
      old = ""
      new = Enum.map_join(1..400, "\n", &"line-#{&1}")
      result = Diff.diff(old, new)

      assert result.added == 400
      assert result.removed == 0
      # 400 lines ≤ 600 → not truncated
      refute result.truncated?
      assert length(result.lines) == 400
    end

    test "truncated diff has exactly 600 lines in its .lines list" do
      old = Enum.map_join(1..700, "\n", &"a-#{&1}")
      result = Diff.diff(old, "")

      assert result.truncated?
      assert length(result.lines) == 600
      # But the full removed count is still 700
      assert result.removed == 700
    end
  end

  describe "diff/2 — struct fields" do
    test "returns a %Diff{} with all required fields" do
      result = Diff.diff("x", "y")

      assert %Diff{lines: lines, added: added, removed: removed, truncated?: t} = result
      assert is_list(lines)
      assert is_integer(added) and added >= 0
      assert is_integer(removed) and removed >= 0
      assert is_boolean(t)
    end
  end
end
