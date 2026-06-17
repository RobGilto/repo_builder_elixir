defmodule RepoBuilder.Orchestrator.TemplatesTest do
  @moduledoc """
  Context + versioning tests for `RepoBuilder.Orchestrator.Templates`. Hermetic: each
  test points `agents_dir` at a fresh tmp root (restored on exit) so the real
  ~/.repo_builder/agents and the shipped built-ins' writable history are never touched.

  `async: false` — the suite mutates the shared `:repo_builder, :orchestrator` app env.
  """
  use ExUnit.Case, async: false

  alias RepoBuilder.Orchestrator.Templates

  setup do
    original = Application.get_env(:repo_builder, :orchestrator)
    tmp = Path.join(System.tmp_dir!(), "rb_templates_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    Application.put_env(
      :repo_builder,
      :orchestrator,
      Keyword.put(original, :agents_dir, tmp)
    )

    on_exit(fn ->
      Application.put_env(:repo_builder, :orchestrator, original)
      File.rm_rf(tmp)
    end)

    {:ok, tmp: tmp}
  end

  defp valid(overrides \\ %{}) do
    Map.merge(
      %{"name" => "test-writer", "description" => "Writes tests.", "body" => "Be terse."},
      overrides
    )
  end

  describe "save/1" do
    test "creates version 1, then bumps to version 2" do
      assert {:ok, v1} = Templates.save(valid())
      assert v1.version == 1
      assert v1.author == :operator

      assert {:ok, v2} = Templates.save(valid(%{"body" => "Be very terse."}))
      assert v2.version == 2

      assert {:ok, current} = Templates.fetch("test-writer")
      assert current.version == 2
      assert current.body == "Be very terse."
    end

    test "records the orchestrator author when given" do
      assert {:ok, t} = Templates.save(valid(%{"author" => :orchestrator}))
      assert t.author == :orchestrator
    end

    test "rejects an invalid payload" do
      assert {:error, _reason} = Templates.save(%{"name" => "Bad Name", "description" => "d"})
    end

    test "two saves off the same starting version both persist as distinct files", %{tmp: tmp} do
      assert {:ok, a} = Templates.save(valid())
      assert {:ok, b} = Templates.save(valid(%{"body" => "second"}))

      assert a.version == 1
      assert b.version == 2
      assert File.exists?(Path.join([tmp, "test-writer", "0001.md"]))
      assert File.exists?(Path.join([tmp, "test-writer", "0002.md"]))
    end
  end

  describe "versions/1 and restore/2" do
    test "lists versions newest-first and restores non-destructively" do
      {:ok, _} = Templates.save(valid(%{"body" => "one"}))
      {:ok, _} = Templates.save(valid(%{"body" => "two"}))

      versions = Templates.versions("test-writer")
      assert Enum.map(versions, & &1.version) == [2, 1]

      assert {:ok, v3} = Templates.restore("test-writer", 1)
      assert v3.version == 3
      assert v3.body == "one"

      # History is preserved (1, 2, 3 all present), restore is non-destructive.
      assert Enum.map(Templates.versions("test-writer"), & &1.version) == [3, 2, 1]
    end

    test "restore of a non-existent version is not_found" do
      {:ok, _} = Templates.save(valid())
      assert {:error, :not_found} = Templates.restore("test-writer", 99)
    end
  end

  describe "fetch/1" do
    test "unknown template is not_found" do
      assert {:error, :not_found} = Templates.fetch("ghost")
    end
  end

  describe "built-in templates" do
    test "the shipped code-scout is listed and not deletable" do
      names = Enum.map(Templates.list(), & &1.name)
      assert "code-scout" in names

      assert {:ok, scout} = Templates.fetch("code-scout")
      assert scout.version == 1
      assert scout.body =~ "Code Scout"

      assert {:error, :builtin} = Templates.delete("code-scout")
    end

    test "editing a built-in writes 0002.md to the writable root (cross-root numbering)", %{
      tmp: tmp
    } do
      assert {:ok, edited} =
               Templates.save(%{
                 "name" => "code-scout",
                 "description" => "Tweaked scout.",
                 "body" => "Scout, but terser."
               })

      assert edited.version == 2
      assert File.exists?(Path.join([tmp, "code-scout", "0002.md"]))

      assert {:ok, current} = Templates.fetch("code-scout")
      assert current.version == 2
      assert current.body == "Scout, but terser."
    end
  end

  describe "delete/1" do
    test "removes a writable template" do
      {:ok, _} = Templates.save(valid())
      assert :ok = Templates.delete("test-writer")
      assert {:error, :not_found} = Templates.fetch("test-writer")
    end

    test "unknown name is not_found" do
      assert {:error, :not_found} = Templates.delete("ghost")
    end
  end
end
