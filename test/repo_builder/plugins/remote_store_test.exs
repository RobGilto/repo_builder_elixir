defmodule RepoBuilder.Plugins.Source.RemoteStoreTest do
  # async: false — uses a process-scoped Req.Test stub.
  use ExUnit.Case, async: false

  alias RepoBuilder.Plugins.Manifest
  alias RepoBuilder.Plugins.Source.RemoteStore

  defp config, do: %{base_url: "http://store.test", req_options: [plug: {Req.Test, __MODULE__}]}

  defp build_tarball(id, version) do
    src = Path.join(System.tmp_dir!(), "rb_pkg_src_#{System.unique_integer([:positive])}")
    File.mkdir_p!(src)
    manifest = %{"id" => id, "name" => id, "version" => version, "contributions" => []}
    File.write!(Path.join(src, "plugin.json"), Jason.encode!(manifest))
    tar = Path.join(System.tmp_dir!(), "rb_pkg_#{System.unique_integer([:positive])}.tar.gz")

    :ok =
      :erl_tar.create(
        String.to_charlist(tar),
        [{~c"plugin.json", String.to_charlist(Path.join(src, "plugin.json"))}],
        [:compressed]
      )

    binary = File.read!(tar)
    File.rm_rf(src)
    File.rm(tar)
    binary
  end

  test "requires a base_url" do
    assert {:error, :no_base_url} = RemoteStore.list(%{})
  end

  test "lists and fetches a package over HTTP" do
    tarball = build_tarball("remote-x", "2.0.0")

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/index.json" ->
          Req.Test.json(conn, [%{"id" => "remote-x", "version" => "2.0.0", "name" => "Remote X"}])

        "/plugins/remote-x/2.0.0.tar.gz" ->
          Plug.Conn.send_resp(conn, 200, tarball)

        _other ->
          Plug.Conn.send_resp(conn, 404, "not found")
      end
    end)

    assert {:ok, [%{id: "remote-x", version: "2.0.0", name: "Remote X"}]} =
             RemoteStore.list(config())

    assert {:ok, %{manifest: %Manifest{id: "remote-x", version: "2.0.0"}, dir: dir}} =
             RemoteStore.fetch(config(), "remote-x", "2.0.0")

    assert File.regular?(Path.join(dir, "plugin.json"))
    File.rm_rf(dir)
  end
end
