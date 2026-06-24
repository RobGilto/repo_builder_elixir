defmodule RepoBuilderWeb.PluginsLiveTest do
  # async: false — install writes to the app-wide install dir.
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Plugins
  alias RepoBuilder.Plugins.HarnessOverlay

  setup do
    tmp = Path.join(System.tmp_dir!(), "rb_live_install_#{System.unique_integer([:positive])}")
    previous = Application.get_env(:repo_builder, :plugins)

    Application.put_env(
      :repo_builder,
      :plugins,
      Keyword.merge(previous, install_dir: tmp, library_dir: Path.expand("plugin_library"))
    )

    on_exit(fn ->
      Application.put_env(:repo_builder, :plugins, previous)
      File.rm_rf(tmp)
      HarnessOverlay.delete("noop")
    end)

    :ok
  end

  test "lists the store catalog and surfaces the code-plugin warning", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/plugins")

    assert has_element?(view, "#catalog-library-sample-commands")
    # the code-bearing sample is flagged
    assert render(view) =~ "code plugin — runs in-node"
  end

  test "install then activate then uninstall a declarative plugin", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/plugins")

    view
    |> element("#catalog-library-sample-commands button", "Install")
    |> render_click()

    assert has_element?(view, "#installed-sample-commands")
    assert Plugins.installed?("sample-commands")

    view
    |> element("#installed-sample-commands button", "Activate")
    |> render_click()

    assert Plugins.active?(nil, "sample-commands")
    assert has_element?(view, "#installed-sample-commands", "active")

    view
    |> element("#installed-sample-commands button", "Uninstall")
    |> render_click()

    refute Plugins.installed?("sample-commands")
  end
end
