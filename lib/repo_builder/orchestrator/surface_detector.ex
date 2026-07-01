defmodule RepoBuilder.Orchestrator.SurfaceDetector do
  @moduledoc """
  Deterministic, repo-agnostic FRONT-END SURFACE detection (iterative-ui-ux polish phase).

  Answers the gate question "does this built app have a user-facing surface, and what kind?"
  by inspecting files and dependency manifests on disk — never by assuming a language or
  running the app. The orchestrator uses it AFTER the backend phases pass to decide whether
  to append a `:ui_ux` phase (one per detected surface), and skips UI/UX entirely on an empty
  result (a library / pure-backend build).

  Three surfaces, and an app may present more than one (e.g. web + tui):

    * `:web`     — `assets/`, a `package.json` with a bundler, HTML/JSX/LiveView templates, or
                   a served endpoint (Phoenix / Rails / Django / Flask / Express).
    * `:desktop` — Electron / Tauri / native-GUI dependencies or project markers.
    * `:tui`     — curses / ratatui / ink / bubbletea / textual-style terminal-UI dependencies.

  Every function is `@spec`'d, returns a tagged tuple, and never raises — a missing dir or an
  unreadable manifest yields `{:ok, []}`, not a crash.
  """

  @type surface :: :web | :desktop | :tui

  # Bound the manifest read so a pathological file can never blow up memory (mirrors the
  # inspect_repo read cap rationale). Manifests are tiny; this is a safety valve.
  @manifest_read_cap 200_000

  # Dependency-manifest files we sniff for framework markers, relative to the working dir.
  @manifests ~w(package.json Cargo.toml go.mod mix.exs pyproject.toml requirements.txt Gemfile pom.xml build.gradle)

  # Substring markers per surface, matched case-insensitively against the concatenated
  # manifest text. Curated from the ecosystem's dominant front-end libraries.
  @web_markers ~w(vite webpack esbuild rollup parcel next react vue svelte angular @angular
                  tailwind phoenix phoenix_live_view rails sinatra django flask express fastapi)
  @desktop_markers ~w(electron @tauri-apps tauri wails neutralinojs pywebview
                      "system.windows.forms" avaloniaui gtk qt pyqt pyside kivy javafx)
  @tui_markers ~w(ratatui crossterm tui-rs blessed ink bubbletea tview termui urwid
                  prompt_toolkit textual rich curses ncurses charmbracelet)

  @doc """
  Classify the front-end surface(s) of the built repo at `working_dir`. Returns the sorted,
  de-duplicated list of detected surfaces (an empty list means no user-facing surface — the
  orchestrator then skips the UI/UX phase). Fail-soft: a missing/unreadable dir ⇒ `{:ok, []}`.
  """
  @spec detect(String.t()) :: {:ok, [surface()]}
  def detect(working_dir) when is_binary(working_dir) and working_dir != "" do
    if File.dir?(working_dir) do
      manifest_text = read_manifests(working_dir)

      surfaces =
        [:web, :desktop, :tui]
        |> Enum.filter(&surface_present?(&1, working_dir, manifest_text))
        |> Enum.sort()

      {:ok, surfaces}
    else
      {:ok, []}
    end
  rescue
    _error -> {:ok, []}
  catch
    _kind, _reason -> {:ok, []}
  end

  def detect(_working_dir), do: {:ok, []}

  # --- per-surface presence ---

  @spec surface_present?(surface(), String.t(), String.t()) :: boolean()
  defp surface_present?(:web, dir, manifest_text) do
    web_file_signal?(dir) or marker_hit?(manifest_text, @web_markers)
  end

  defp surface_present?(:desktop, dir, manifest_text) do
    File.dir?(Path.join(dir, "src-tauri")) or marker_hit?(manifest_text, @desktop_markers)
  end

  defp surface_present?(:tui, _dir, manifest_text) do
    marker_hit?(manifest_text, @tui_markers)
  end

  # Web is also signalled by disk shape independent of a manifest: a Phoenix/JS `assets/`
  # dir, an `index.html`, a `public/` served dir, or LiveView/JSX templates in the tree.
  @spec web_file_signal?(String.t()) :: boolean()
  defp web_file_signal?(dir) do
    File.dir?(Path.join(dir, "assets")) or
      File.regular?(Path.join(dir, "index.html")) or
      File.dir?(Path.join(dir, "public")) or
      template_files?(dir)
  end

  # A bounded walk for web template extensions (`.html`/`.heex`/`.jsx`/`.tsx`/`.vue`/`.svelte`),
  # skipping heavy vendor dirs. Short-circuits on the first hit.
  @spec template_files?(String.t()) :: boolean()
  defp template_files?(dir) do
    dir
    |> web_candidate_files()
    |> Enum.any?(&(Path.extname(&1) in ~w(.heex .jsx .tsx .vue .svelte)))
  end

  @skip_dirs ~w(node_modules deps _build .git target vendor .elixir_ls priv)

  @spec web_candidate_files(String.t()) :: [String.t()]
  defp web_candidate_files(dir) do
    dir
    |> ls_dirs()
    |> Enum.flat_map(fn sub ->
      case File.ls(sub) do
        {:ok, entries} -> Enum.map(entries, &Path.join(sub, &1))
        {:error, _reason} -> []
      end
    end)
  end

  # The immediate + one-level-down directories under `dir`, excluding vendor/build dirs.
  @spec ls_dirs(String.t()) :: [String.t()]
  defp ls_dirs(dir) do
    tops =
      case File.ls(dir) do
        {:ok, entries} ->
          entries
          |> Enum.reject(&(&1 in @skip_dirs))
          |> Enum.map(&Path.join(dir, &1))
          |> Enum.filter(&File.dir?/1)

        {:error, _reason} ->
          []
      end

    subs =
      Enum.flat_map(tops, fn top ->
        case File.ls(top) do
          {:ok, entries} ->
            entries
            |> Enum.reject(&(&1 in @skip_dirs))
            |> Enum.map(&Path.join(top, &1))
            |> Enum.filter(&File.dir?/1)

          {:error, _reason} ->
            []
        end
      end)

    [dir | tops] ++ subs
  end

  # --- manifest reading / matching ---

  @spec read_manifests(String.t()) :: String.t()
  defp read_manifests(dir) do
    @manifests
    |> Enum.map_join("\n", &read_manifest(Path.join(dir, &1)))
    |> String.downcase()
  end

  @spec read_manifest(String.t()) :: String.t()
  defp read_manifest(path) do
    case File.read(path) do
      {:ok, content} -> String.slice(content, 0, @manifest_read_cap)
      {:error, _reason} -> ""
    end
  end

  @spec marker_hit?(String.t(), [String.t()]) :: boolean()
  defp marker_hit?(manifest_text, markers) do
    Enum.any?(markers, &String.contains?(manifest_text, String.downcase(&1)))
  end
end
