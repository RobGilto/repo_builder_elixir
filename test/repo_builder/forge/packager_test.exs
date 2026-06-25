defmodule RepoBuilder.Forge.PackagerTest do
  @moduledoc """
  The Packager's wire boundary (forge-meta-artifact-generation, Phase 4): the synthesized
  `plugin.json` must round-trip through the strict `Manifest.parse/1`, and its checksum
  must match the install trust gate's digest.

  async: false — overrides the `:plugins` library dir so packages land in a tmp dir.
  """
  use ExUnit.Case, async: false

  alias RepoBuilder.Forge.{Generator, Packager}
  alias RepoBuilder.Plugins.{Manifest, Trust}

  setup do
    uniq = System.unique_integer([:positive])
    library = Path.join(System.tmp_dir!(), "rb_pack_#{uniq}")
    scratch = Path.join(System.tmp_dir!(), "rb_pack_scratch_#{uniq}")
    File.mkdir_p!(library)

    prev = Application.get_env(:repo_builder, :plugins)
    Application.put_env(:repo_builder, :plugins, Keyword.put(prev, :library_dir, library))

    on_exit(fn ->
      Application.put_env(:repo_builder, :plugins, prev)
      File.rm_rf(library)
      File.rm_rf(scratch)
    end)

    %{library: library, scratch: scratch}
  end

  defp artifact(kind), do: %RepoBuilder.Forge.Artifact{id: Ecto.UUID.generate(), kind: kind}

  test "packages a command into a manifest that round-trips and checksums correctly", %{
    scratch: scratch,
    library: library
  } do
    File.mkdir_p!(Path.join(scratch, "commands"))

    File.write!(Path.join([scratch, "commands", "smoke-test.md"]), """
    ---
    description: Runs the smoke test.
    ---

    # Smoke Test

    ## Purpose
    ## Workflow
    ## Report
    """)

    {:ok, def_t} = Generator.fetch(:command)
    assert {:ok, packaged} = Packager.package(artifact("command"), def_t, scratch)

    assert packaged.id == "smoke-test"
    assert packaged.dir == Path.join(library, "smoke-test")

    # The emitted manifest parses back through the strict boundary.
    assert {:ok, manifest} = Manifest.read(packaged.dir)
    assert manifest.id == "smoke-test"
    assert [%{kind: :command_pack, path: "commands"}] = manifest.contributions

    # The declared checksum matches the trust gate's digest over the package.
    assert manifest.checksum == Trust.checksum(packaged.dir)
  end

  test "packages a skill keyed by its bundle directory name", %{scratch: scratch} do
    bundle = Path.join([scratch, "skills", "processing-invoices"])
    File.mkdir_p!(bundle)

    File.write!(Path.join(bundle, "SKILL.md"), """
    ---
    name: processing-invoices
    description: Processes invoices.
    ---

    # Processing Invoices
    """)

    {:ok, def_t} = Generator.fetch(:skill)
    assert {:ok, packaged} = Packager.package(artifact("skill"), def_t, scratch)
    assert packaged.id == "processing-invoices"
    assert {:ok, manifest} = Manifest.read(packaged.dir)
    assert [%{kind: :skill, path: "skills"}] = manifest.contributions
  end

  test "an empty scratch asset dir is a clean error", %{scratch: scratch} do
    File.mkdir_p!(Path.join(scratch, "commands"))
    {:ok, def_t} = Generator.fetch(:command)
    assert {:error, :empty_asset} = Packager.package(artifact("command"), def_t, scratch)
  end
end
