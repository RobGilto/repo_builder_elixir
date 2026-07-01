defmodule RepoBuilder.Orchestrator.SurfaceDetectorTest do
  @moduledoc """
  Front-end surface detection (orchestrator-iterative-ui-ux-polish-phase, Phase 2): tiny fake
  repo trees classify to web / desktop / tui / none, including the multi-surface case. Pure
  filesystem, no network.
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.Orchestrator.SurfaceDetector

  defp tmp_repo(files) do
    root = Path.join(System.tmp_dir!(), "rb_surface_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    Enum.each(files, fn {rel, contents} ->
      path = Path.join(root, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)
    end)

    root
  end

  describe "detect/1" do
    test "classifies a web app (package.json bundler)" do
      root = tmp_repo(%{"package.json" => ~s({"devDependencies": {"vite": "^5.0.0"}})})
      assert {:ok, [:web]} = SurfaceDetector.detect(root)
    end

    test "classifies a web app by an assets/ dir alone (no manifest marker)" do
      root = tmp_repo(%{"assets/app.js" => "console.log(1)"})
      assert {:ok, [:web]} = SurfaceDetector.detect(root)
    end

    test "classifies a Phoenix LiveView app (heex template + phoenix dep)" do
      root =
        tmp_repo(%{
          "mix.exs" => ~s(defp deps, do: [{:phoenix_live_view, "~> 1.0"}]),
          "lib/app_web/live/home.html.heex" => "<div>hi</div>"
        })

      assert {:ok, [:web]} = SurfaceDetector.detect(root)
    end

    test "classifies a desktop app (electron dep)" do
      root = tmp_repo(%{"package.json" => ~s({"dependencies": {"electron": "^30.0.0"}})})
      assert {:ok, [:desktop]} = SurfaceDetector.detect(root)
    end

    test "classifies a desktop app (Tauri project marker)" do
      root = tmp_repo(%{"src-tauri/tauri.conf.json" => "{}"})
      assert {:ok, [:desktop]} = SurfaceDetector.detect(root)
    end

    test "classifies a TUI app (ratatui in Cargo.toml)" do
      root = tmp_repo(%{"Cargo.toml" => ~s([dependencies]\nratatui = "0.26")})
      assert {:ok, [:tui]} = SurfaceDetector.detect(root)
    end

    test "classifies a TUI app (bubbletea in go.mod)" do
      root = tmp_repo(%{"go.mod" => "require github.com/charmbracelet/bubbletea v0.25.0"})
      assert {:ok, [:tui]} = SurfaceDetector.detect(root)
    end

    test "returns multiple surfaces when an app is both web and tui" do
      root =
        tmp_repo(%{
          "package.json" => ~s({"dependencies": {"react": "^18", "ink": "^4"}}),
          "assets/app.js" => "1"
        })

      assert {:ok, surfaces} = SurfaceDetector.detect(root)
      assert Enum.sort(surfaces) == [:tui, :web]
    end

    test "returns [] for a pure-backend library (no front end)" do
      root = tmp_repo(%{"mix.exs" => ~s(defp deps, do: [{:jason, "~> 1.4"}])})
      assert {:ok, []} = SurfaceDetector.detect(root)
    end

    test "returns [] fail-soft for a missing directory" do
      assert {:ok, []} = SurfaceDetector.detect("/nonexistent/path/xyz")
    end

    test "returns [] for a blank working dir" do
      assert {:ok, []} = SurfaceDetector.detect("")
    end
  end
end
