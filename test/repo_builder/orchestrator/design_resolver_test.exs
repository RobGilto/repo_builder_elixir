defmodule RepoBuilder.Orchestrator.DesignResolverTest do
  @moduledoc """
  Precedence + {surface, framework} selection + the TUI language fallback for the
  design-system resolver (design-system-plugins). Pure (in-memory `Project` structs
  against the shipped `priv/design_systems/` builtins), so async. The plugin-wins layer
  is covered end-to-end in the plugin-distribution suite (Phase 5).
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.Orchestrator.DesignResolver
  alias RepoBuilder.Projects.Project

  defp project(stack) do
    %Project{
      id: nil,
      name: "p",
      root_path: nil,
      stack: stack,
      capabilities: %{},
      command_pack: "auto",
      command_pack_version: "latest",
      isolation_mode: :direct,
      status: :active
    }
  end

  describe "builtin {surface, framework} selection" do
    test "web/phoenix resolves the web-phoenix builtin" do
      p = project(%{"language" => "elixir", "surface" => "web", "framework" => "phoenix"})
      assert {:ok, resolved} = DesignResolver.resolve(p)
      assert resolved.source == :builtin
      assert resolved.name == "web-phoenix"
      assert resolved.descriptor.surface == :web
      assert resolved.descriptor.framework == "phoenix"
    end

    test "web/react resolves the web-react builtin" do
      p = project(%{"language" => "node", "surface" => "web", "framework" => "react"})
      assert {:ok, %{name: "web-react", source: :builtin}} = DesignResolver.resolve(p)
    end

    test "tui/bubbletea resolves the tui-bubbletea builtin with its paradigm" do
      p = project(%{"language" => "go", "surface" => "tui", "framework" => "bubbletea"})
      assert {:ok, resolved} = DesignResolver.resolve(p)
      assert resolved.name == "tui-bubbletea"
      assert resolved.descriptor.paradigm == :mvu
    end
  end

  describe "TUI language fallback (§1 router)" do
    test "a tui surface with no framework match falls to the language default" do
      # Go/TUI, framework unknown → tui-bubbletea via @tui_defaults, source :tui_default.
      p = project(%{"language" => "go", "surface" => "tui", "framework" => "none"})
      assert {:ok, resolved} = DesignResolver.resolve(p)
      assert resolved.source == :tui_default
      assert resolved.name == "tui-bubbletea"
    end

    test "elixir/tui with no framework falls to ratatouille" do
      p = project(%{"language" => "elixir", "surface" => "tui", "framework" => "none"})
      assert {:ok, %{name: "tui-ratatouille", source: :tui_default}} = DesignResolver.resolve(p)
    end

    test "rust/tui with no framework falls to ratatui" do
      p = project(%{"language" => "rust", "surface" => "tui", "framework" => "none"})
      assert {:ok, %{name: "tui-ratatui", source: :tui_default}} = DesignResolver.resolve(p)
    end
  end

  describe "generic fallback" do
    test "an unknown surface/framework falls to generic" do
      p = project(%{"language" => "unknown", "surface" => "none", "framework" => "none"})
      assert {:ok, resolved} = DesignResolver.resolve(p)
      assert resolved.source == :generic
      assert resolved.name == "generic"
      assert resolved.descriptor.surface == :any
    end

    test "a web surface with an unmatched framework falls to generic (not a tui default)" do
      p = project(%{"language" => "node", "surface" => "web", "framework" => "svelte"})
      assert {:ok, %{name: "generic", source: :generic}} = DesignResolver.resolve(p)
    end

    test "a nil stack resolves generic without raising" do
      p = project(nil)
      assert {:ok, %{name: "generic"}} = DesignResolver.resolve(p)
    end
  end
end
