defmodule RepoBuilder.Forge.GeneratorTest do
  @moduledoc "The closed generator-registry seam (forge-meta-artifact-generation, Phase 2)."
  use ExUnit.Case, async: true

  alias RepoBuilder.Forge.Generator
  alias RepoBuilder.Plugins.Contribution

  test "fetch/1 returns a definition for each closed kind" do
    for kind <- Generator.kinds() do
      assert {:ok, def_t} = Generator.fetch(kind)
      assert def_t.kind == kind
      assert is_binary(def_t.template)
      assert def_t.contribution_kind in Contribution.kinds()
    end
  end

  test "fetch/1 accepts wire strings and rejects unknown generators" do
    assert {:ok, def_t} = Generator.fetch("command")
    assert def_t.kind == :command
    assert {:error, :unknown_generator} = Generator.fetch("nonsense")
    assert {:error, :unknown_generator} = Generator.fetch(:nope)
  end

  test "cast_kind/1 never calls to_atom on untrusted input" do
    assert {:ok, :skill} = Generator.cast_kind("skill")
    assert {:error, :unknown_generator} = Generator.cast_kind("definitely-not-a-real-atom-xyz")
    assert {:error, :unknown_generator} = Generator.cast_kind(123)
  end

  test "every template resolves to a file that exists on disk" do
    for kind <- Generator.kinds() do
      {:ok, def_t} = Generator.fetch(kind)
      assert File.exists?(Generator.template_path(def_t))
    end
  end
end
