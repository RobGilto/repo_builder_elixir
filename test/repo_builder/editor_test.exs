defmodule RepoBuilder.EditorTest do
  @moduledoc """
  Unit tests for the `RepoBuilder.Editor` context (issue file-diff-event-cards).
  Covers path validation, the disabled flag, missing files, and the success path
  against a stub command. The editor is configured to `enabled: false` in test.exs,
  so each test that needs the enabled path sets it temporarily via `Application.put_env`.
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.Editor

  # Restore the original editor config after tests that mutate it.
  setup do
    original = Application.get_env(:repo_builder, :editor, [])
    on_exit(fn -> Application.put_env(:repo_builder, :editor, original) end)
    :ok
  end

  describe "open/1 — when disabled" do
    test "returns {:error, :disabled} when enabled: false" do
      Application.put_env(:repo_builder, :editor, enabled: false, command: ["true"])
      assert Editor.open("/tmp/anything.ex") == {:error, :disabled}
    end

    test "defaults to disabled when no config is set" do
      Application.delete_env(:repo_builder, :editor)
      assert Editor.open("/tmp/anything.ex") == {:error, :disabled}
    end
  end

  describe "open/1 — path validation (enabled)" do
    setup do
      Application.put_env(:repo_builder, :editor, enabled: true, command: ["true"])
      :ok
    end

    test "returns {:error, :invalid_path} for a non-binary argument" do
      assert Editor.open(42) == {:error, :invalid_path}
      assert Editor.open(:atom) == {:error, :invalid_path}
      assert Editor.open(nil) == {:error, :invalid_path}
    end

    test "returns {:error, :invalid_path} for a relative path" do
      assert Editor.open("relative/path.ex") == {:error, :invalid_path}
      assert Editor.open("file.ex") == {:error, :invalid_path}
    end

    test "returns {:error, :not_found} for an absolute path that doesn't exist" do
      assert Editor.open("/this/path/does/not/exist/file.ex") == {:error, :not_found}
    end

    test "returns {:error, :not_found} for an absolute path that is a directory" do
      # /tmp is an absolute path but is a directory, not a regular file
      assert Editor.open("/tmp") == {:error, :not_found}
    end
  end

  describe "open/1 — success path" do
    setup do
      # Use system `true` as a no-op stub editor command (exits 0, no output).
      Application.put_env(:repo_builder, :editor, enabled: true, command: ["true"])
      :ok
    end

    test "returns {:ok, path} for an absolute path to an existing regular file" do
      # Write a tmp file so we can open it.
      tmp_path =
        Path.join(System.tmp_dir!(), "editor_test_#{System.unique_integer([:positive])}.ex")

      File.write!(tmp_path, "defmodule Tmp, do: :ok")
      on_exit(fn -> File.rm(tmp_path) end)

      assert Editor.open(tmp_path) == {:ok, tmp_path}
    end
  end

  describe "open/1 — editor exit codes" do
    setup do
      # Use `false` (exits 1) to simulate a non-zero exit.
      Application.put_env(:repo_builder, :editor, enabled: true, command: ["false"])
      :ok
    end

    test "returns {:error, {:exit, code}} when editor exits non-zero" do
      tmp_path =
        Path.join(System.tmp_dir!(), "editor_fail_#{System.unique_integer([:positive])}.ex")

      File.write!(tmp_path, "content")
      on_exit(fn -> File.rm(tmp_path) end)

      assert {:error, {:exit, code}} = Editor.open(tmp_path)
      assert is_integer(code) and code != 0
    end
  end
end
