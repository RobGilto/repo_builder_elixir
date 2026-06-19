defmodule RepoBuilder.PromptStandard.CliTest do
  @moduledoc """
  Ports of the Python CLI tests (test_prompt_builder.py 21–23): `validate` exits 0 on a
  passing file / 1 on a failing file, and `lint` exits 0 on a clean directory. Exit codes
  are asserted via the pure `Cli.{validate,lint}/2` functions (no `System.halt` spawn);
  the real halt path is covered by the manual smoke in the spec's Validation Commands.
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.PromptStandard.Cli

  @good "# Agent\n\n## Core Operating Principle\n\nAlways delegate the work to agents.\n"
  @bad "# Broken Runtime Agent\n\n## Core Operating Principle\n\nUse {{BAD_TOKEN}} here.\n"

  setup do
    dir = Path.join(System.tmp_dir!(), "ps_cli_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  describe "validate" do
    test "a passing file exits 0 and prints Overall: PASS", %{dir: dir} do
      path = Path.join(dir, "good.md")
      File.write!(path, @good)

      assert {:ok, output, 0} = Cli.validate(path, nil)
      assert output =~ "Overall: PASS"
      assert output =~ "H10  SKIP"
    end

    test "a failing file exits 1 and prints Overall: FAIL", %{dir: dir} do
      path = Path.join(dir, "bad.md")
      File.write!(path, @bad)

      assert {:ok, output, 1} = Cli.validate(path, :b)
      assert output =~ "Overall: FAIL"
      assert output =~ "H4   FAIL"
    end

    test "a missing file is a usage error (exit 2)" do
      assert {:error, message} = Cli.validate("/nonexistent/nope.md", nil)
      assert message =~ "not a file"
    end
  end

  describe "lint" do
    test "a clean directory exits 0 with an all-pass summary", %{dir: dir} do
      File.write!(Path.join(dir, "a.md"), @good)
      File.write!(Path.join(dir, "b.md"), @good)

      assert {:ok, output, 0} = Cli.lint(dir, nil)
      assert output =~ "Summary: 2 files, 2 pass, 0 fail"
    end

    test "a directory with a failing file exits 1", %{dir: dir} do
      File.write!(Path.join(dir, "good.md"), @good)
      File.write!(Path.join(dir, "bad.md"), @bad)

      assert {:ok, output, 1} = Cli.lint(dir, nil)
      assert output =~ "Summary: 2 files, 1 pass, 1 fail"
    end

    test "an empty directory (no .md) is a usage error (exit 2)", %{dir: dir} do
      assert {:error, message} = Cli.lint(dir, nil)
      assert message =~ "no .md files"
    end

    test "a non-directory path is a usage error (exit 2)" do
      assert {:error, message} = Cli.lint("/nonexistent/dir", nil)
      assert message =~ "not a directory"
    end
  end
end
