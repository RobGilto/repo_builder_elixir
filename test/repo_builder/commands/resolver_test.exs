defmodule RepoBuilder.Commands.ResolverTest do
  @moduledoc """
  Precedence, version resolution, capability-token fill, and provenance for the
  stack-aware command resolver. Uses the shipped `priv/command_packs` packs plus a
  tmp repo-local override. Pure (in-memory `Project` structs), so async.
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.Commands.Resolver
  alias RepoBuilder.Projects.Capabilities
  alias RepoBuilder.Projects.Project

  defp project(attrs) do
    base = %Project{
      id: Ecto.UUID.generate(),
      name: "p",
      root_path: nil,
      stack: %{"language" => "unknown"},
      capabilities: %{},
      command_pack: "auto",
      command_pack_version: "latest",
      isolation_mode: :direct,
      status: :active
    }

    struct(base, attrs)
  end

  defp caps(language) do
    %{"language" => language} |> Capabilities.detect() |> Capabilities.to_map()
  end

  defp repo_with_command(name, body) do
    root = Path.join(System.tmp_dir!(), "rb_resolver_#{System.unique_integer([:positive])}")
    path = Path.join([root, ".claude", "commands", name <> ".md"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "---\ndescription: local\n---\n\n#{body}")
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  test "repo-local wins over every pack and is returned verbatim (no token fill)" do
    root = repo_with_command("build", "LOCAL BUILD {{TEST_COMMAND}}")

    proj =
      project(%{root_path: root, stack: %{"language" => "elixir"}, capabilities: caps("elixir")})

    assert {:ok, resolved} = Resolver.resolve(proj, "build")
    assert resolved.layer == :repo_local
    assert resolved.body == "LOCAL BUILD {{TEST_COMMAND}}"
    assert resolved.provenance =~ "repo-local"
  end

  test "auto + detected stack resolves the stack pack when it overrides the command" do
    proj = project(%{stack: %{"language" => "elixir"}, capabilities: caps("elixir")})

    assert {:ok, resolved} = Resolver.resolve(proj, "build")
    assert resolved.layer == :stack_pack
    assert resolved.pack == "elixir"
    assert resolved.version == "1.0.0"
    assert resolved.body =~ "mix compile --warnings-as-errors"
  end

  test "falls through to the generic base when the stack pack lacks the command" do
    # The node pack ships only `test`; `build` falls to generic with tokens filled.
    proj = project(%{stack: %{"language" => "node"}, capabilities: caps("node")})

    assert {:ok, resolved} = Resolver.resolve(proj, "build")
    assert resolved.layer == :generic
    assert resolved.pack == "generic"
    assert resolved.body =~ "npm test"
    assert resolved.body =~ "npm run build"
    refute resolved.body =~ "{{"
  end

  test "a pinned pack/version beats the stack pack" do
    # Stack is node, but the project pins the elixir pack — pinned wins for `build`.
    proj =
      project(%{
        stack: %{"language" => "node"},
        capabilities: caps("node"),
        command_pack: "elixir",
        command_pack_version: "1.0.0"
      })

    assert {:ok, resolved} = Resolver.resolve(proj, "build")
    assert resolved.layer == :pinned_pack
    assert resolved.pack == "elixir"
    assert resolved.body =~ "mix compile"
  end

  test "capability tokens fill from the project's capability map" do
    proj = project(%{stack: %{"language" => "unknown"}, capabilities: caps("node")})

    assert {:ok, resolved} = Resolver.resolve(proj, "plan")
    assert resolved.layer == :generic
    assert resolved.body =~ "npm test"
    refute resolved.body =~ "{{TEST_COMMAND}}"
  end

  test "an unknown command is {:error, :not_found}" do
    proj = project(%{stack: %{"language" => "elixir"}, capabilities: caps("elixir")})
    assert Resolver.resolve(proj, "frobnicate") == {:error, :not_found}
  end

  test "resolve_all dedups by name with higher-precedence layers winning" do
    proj = project(%{stack: %{"language" => "elixir"}, capabilities: caps("elixir")})
    all = Resolver.resolve_all(proj)
    names = Enum.map(all, & &1.name)

    assert "plan" in names
    assert "build" in names
    assert names == Enum.uniq(names)
    build = Enum.find(all, &(&1.name == "build"))
    assert build.layer == :stack_pack
  end
end
