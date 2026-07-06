defmodule RepoBuilder.Plugins.DesignSystemTest do
  @moduledoc """
  WIRE → DOMAIN validation for the design-system descriptor (design-system-plugins):
  malformed/partial/unknown-surface JSON never raises and returns `:error`; valid web and
  TUI descriptors parse to the typed struct; every builtin (web + TUI) loads.
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.Plugins.DesignSystem

  @web ~s({"surface":"web","stack":"elixir","framework":"phoenix","components":[{"name":"input","tag":"<.input>","package":"core_components"}],"rules":["use core_components"]})
  @tui ~s({"surface":"tui","stack":"go","framework":"bubbletea","paradigm":"mvu","components":[{"name":"list","package":"bubbles/list"}]})

  describe "parse/1" do
    test "normalizes a valid web descriptor into the typed struct" do
      assert {:ok, %DesignSystem{surface: :web, stack: "elixir", framework: "phoenix"} = ds} =
               DesignSystem.parse(@web)

      assert ds.paradigm == :none

      assert [%DesignSystem.Component{name: "input", tag: "<.input>", package: "core_components"}] =
               ds.components

      assert ds.rules == ["use core_components"]
    end

    test "normalizes a valid TUI descriptor and its paradigm" do
      assert {:ok, %DesignSystem{surface: :tui, framework: "bubbletea", paradigm: :mvu} = ds} =
               DesignSystem.parse(@tui)

      assert [%DesignSystem.Component{name: "list", package: "bubbles/list", tag: nil}] =
               ds.components
    end

    test "defaults paradigm to :none and collections to empty" do
      json = ~s({"surface":"any","stack":"generic","framework":"generic"})
      assert {:ok, ds} = DesignSystem.parse(json)
      assert ds.paradigm == :none
      assert ds.tokens == %{}
      assert ds.components == []
      assert ds.rules == []
      assert ds.references == []
    end

    test "rejects malformed JSON without raising" do
      assert {:error, :invalid_json} = DesignSystem.parse("{not json")
    end

    test "rejects missing required fields" do
      assert {:error, :missing_required_fields} =
               DesignSystem.parse(~s({"surface":"web","stack":"x"}))

      assert {:error, :missing_required_fields} = DesignSystem.parse(~s({"framework":"phoenix"}))
    end

    test "rejects an unknown surface" do
      json = ~s({"surface":"holographic","stack":"x","framework":"y"})
      assert {:error, :unknown_surface} = DesignSystem.parse(json)
    end

    test "rejects an unknown paradigm" do
      json = ~s({"surface":"tui","stack":"x","framework":"y","paradigm":"quantum"})
      assert {:error, :unknown_paradigm} = DesignSystem.parse(json)
    end

    test "rejects a component missing a name" do
      json = ~s({"surface":"web","stack":"x","framework":"y","components":[{"tag":"<.x>"}]})
      assert {:error, :invalid_component} = DesignSystem.parse(json)
    end

    test "rejects a non-list components" do
      json = ~s({"surface":"web","stack":"x","framework":"y","components":"nope"})
      assert {:error, :invalid_components} = DesignSystem.parse(json)
    end
  end

  describe "from_wire/1" do
    test "rejects a non-map / non-string-keyed value without raising" do
      assert {:error, :invalid_descriptor} = DesignSystem.from_wire("nope")
      assert {:error, :invalid_descriptor} = DesignSystem.from_wire(%{1 => 2})
    end
  end

  describe "builtin descriptors" do
    test "every shipped builtin (web + TUI) loads and parses" do
      dir = Application.app_dir(:repo_builder, "priv/design_systems")
      paths = Path.wildcard(Path.join(dir, "*.json"))

      assert length(paths) >= 8, "expected the web + TUI builtins to be present"

      for path <- paths do
        assert {:ok, %DesignSystem{}} = DesignSystem.read(path),
               "builtin design system #{Path.basename(path)} failed to load"
      end
    end
  end
end
