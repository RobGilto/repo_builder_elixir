defmodule RepoBuilder.Plugins.InstallerTest do
  # async: false — overrides the app-wide :plugins config (install dir) + the harness overlay.
  use RepoBuilder.DataCase, async: false

  alias RepoBuilder.Harness.Registry, as: HarnessRegistry
  alias RepoBuilder.Plugins
  alias RepoBuilder.Plugins.{HarnessOverlay, Installer}

  setup do
    tmp = Path.join(System.tmp_dir!(), "rb_install_#{System.unique_integer([:positive])}")
    previous = Application.get_env(:repo_builder, :plugins)

    Application.put_env(
      :repo_builder,
      :plugins,
      Keyword.merge(previous,
        install_dir: tmp,
        library_dir: Path.expand("plugin_library")
      )
    )

    on_exit(fn ->
      Application.put_env(:repo_builder, :plugins, previous)
      File.rm_rf(tmp)
      HarnessOverlay.delete("noop")
    end)

    %{install_dir: tmp}
  end

  defp set_trust(overrides) do
    config = Application.get_env(:repo_builder, :plugins)
    trust = Keyword.merge(Keyword.get(config, :trust, []), overrides)
    Application.put_env(:repo_builder, :plugins, Keyword.put(config, :trust, trust))
  end

  describe "install/uninstall from the local library" do
    test "installs a declarative plugin into agentic_plugins and records it", %{install_dir: dir} do
      assert {:ok, plugin} = Installer.install("library", "sample-commands")
      assert plugin.plugin_id == "sample-commands"
      assert plugin.version == "1.0.0"
      assert String.starts_with?(plugin.install_path, dir)
      assert File.regular?(Path.join(plugin.install_path, "plugin.json"))
      assert Plugins.installed?("sample-commands")
      # the stored manifest round-trips
      assert plugin.manifest["id"] == "sample-commands"
    end

    test "uninstall removes the dir and the record", %{install_dir: _dir} do
      {:ok, plugin} = Installer.install("library", "sample-commands")
      assert File.dir?(plugin.install_path)

      assert :ok = Installer.uninstall("sample-commands")
      refute File.dir?(plugin.install_path)
      refute Plugins.installed?("sample-commands")
    end

    test "an unknown source is a tagged error" do
      assert {:error, :unknown_source} = Installer.install("nope", "sample-commands")
    end
  end

  describe "trust gate" do
    test "refuses a code plugin when allow_code is false" do
      set_trust(allow_code: false)
      assert {:error, :code_not_allowed} = Installer.install("library", "noop-harness")
      refute Plugins.installed?("noop-harness")
    end

    test "enforces a required checksum" do
      set_trust(require_checksum: true)
      # the sample manifest declares no checksum → rejected
      assert {:error, :checksum_mismatch} = Installer.install("library", "sample-commands")
    end
  end

  describe "code-bearing plugin path (the §10 proof)" do
    test "installing a code plugin registers its harness via the overlay" do
      refute "noop" in HarnessRegistry.known()

      assert {:ok, _plugin} = Installer.install("library", "noop-harness")

      assert "noop" in HarnessRegistry.known()
      assert {:ok, RepoBuilder.SamplePlugins.NoopHarness.Adapter} = HarnessRegistry.fetch("noop")
      assert %{} = HarnessOverlay.all()["noop"]
    end
  end
end
