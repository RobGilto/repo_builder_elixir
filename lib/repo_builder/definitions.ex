defmodule RepoBuilder.Definitions do
  @moduledoc """
  The runtime source of truth for "what can I reference in a prompt" — the
  file-driven prompt palette (issue-prompt-adw-palette).

  This supervised GenServer scans three definition categories from a MERGED root
  (the app repo as the base layer, the operator-selected `working_dir`'s `.claude/`
  as an overlay that shadows app entries by name):

    * `:slash_command` — `.claude/commands/**/*.md` (see `Definitions.SlashCommand`)
    * `:agent`         — `Orchestrator.Templates` + working-dir `.claude/agents/*.md`
                         (see `Definitions.Agent`)
    * `:adw`           — `adws/adw_*.py` (see `Definitions.Adw`)

  It WATCHES the source directories with `FileSystem` (debouncing save-storms),
  diffs an `(name, mtime, source)` signature per category, and broadcasts
  `{:definitions_changed, category, list}` on the `"definitions:changed"`
  `Phoenix.PubSub` topic for only the categories that actually changed. A slow poll
  fallback covers environments where inotify events are missed (CI/containers).

  Reads (`all/1`, `list/2`) re-resolve the merged root on demand and are pure
  filesystem reads — they never go through the server, so a slow scan can't block
  the watcher. `WorkflowEngine.Catalog` remains the validation source for `start_adw`;
  this list is presentation only.
  """
  use GenServer
  use TypedStruct

  require Logger

  alias RepoBuilder.Definitions.Adw
  alias RepoBuilder.Definitions.Agent
  alias RepoBuilder.Definitions.SlashCommand

  @type category :: :slash_command | :agent | :adw
  @type entry :: SlashCommand.t() | Agent.t() | Adw.t()
  @type listing :: %{slash_command: [SlashCommand.t()], agent: [Agent.t()], adw: [Adw.t()]}

  @topic "definitions:changed"
  @categories [:slash_command, :agent, :adw]
  @debounce_ms 250
  @default_poll_interval_ms 30_000

  typedstruct module: State, enforce: true do
    @typedoc "Watcher state: the resolved working dir, cached signatures, and timers."
    field :working_dir, String.t() | nil
    field :app_root, String.t()
    field :poll_interval_ms, pos_integer()
    field :watch_enabled?, boolean()
    field :signatures, %{atom() => MapSet.t()}
    field :watched_dirs, [String.t()]
    field :fs_pid, pid() | nil, default: nil
    field :rescan_ref, reference() | nil, default: nil
    field :poll_ref, reference() | nil, default: nil
  end

  # --- read API (stateless filesystem reads) ---

  @doc "Start the watcher. Accepts `:name`, `:app_root`, `:working_dir`, `:watch_enabled?`, `:poll_interval_ms`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Subscribe the calling process to `{:definitions_changed, category, list}` broadcasts."
  @spec subscribe() :: :ok
  def subscribe do
    _ = Phoenix.PubSub.subscribe(RepoBuilder.PubSub, @topic)
    :ok
  end

  @doc "All three categories for the merged (app + `working_dir`) root, freshly scanned."
  @spec all(working_dir :: String.t() | nil) :: listing()
  def all(working_dir) do
    %{
      slash_command: merge(SlashCommand.scan(app_root(), :app), working_slash(working_dir)),
      agent: Agent.scan(working_dir),
      adw: merge(Adw.scan(app_root(), :app), working_adw(working_dir))
    }
  end

  @doc "A single category for the merged root."
  @spec list(category(), working_dir :: String.t() | nil) :: [entry()]
  def list(category, working_dir) when category in @categories do
    Map.fetch!(all(working_dir), category)
  end

  @doc """
  Update the watcher's tracked `working_dir`, re-scan, and broadcast every category
  so already-connected consoles re-seed immediately when the operator changes dirs.
  """
  @spec refresh(working_dir :: String.t() | nil) :: :ok
  def refresh(working_dir) do
    GenServer.cast(__MODULE__, {:refresh, working_dir})
  end

  @doc "The PubSub topic broadcasts land on."
  @spec topic() :: String.t()
  def topic, do: @topic

  # --- GenServer ---

  @impl true
  def init(opts) do
    env = env()
    app_root = opts[:app_root] || Keyword.get(env, :app_root) || File.cwd!()
    working_dir = opts[:working_dir]

    watch_enabled? =
      Keyword.get(opts, :watch_enabled?, Keyword.get(env, :watch_enabled?, true))

    poll_interval_ms =
      opts[:poll_interval_ms] ||
        Keyword.get(env, :poll_interval_ms, @default_poll_interval_ms)

    listing = resolve(app_root, working_dir)
    watched = watched_dirs(app_root, working_dir)

    state =
      %State{
        working_dir: working_dir,
        app_root: app_root,
        poll_interval_ms: poll_interval_ms,
        watch_enabled?: watch_enabled?,
        signatures: signatures(listing),
        watched_dirs: watched
      }
      |> maybe_start_watcher()
      |> maybe_schedule_poll()

    {:ok, state}
  end

  @impl true
  def handle_cast({:refresh, working_dir}, %State{} = state) do
    listing = resolve(state.app_root, working_dir)
    Enum.each(@categories, &broadcast(&1, Map.fetch!(listing, &1)))

    {:noreply,
     %State{state | working_dir: working_dir, signatures: signatures(listing)}
     |> restart_watcher_if_dirs_changed()}
  end

  @impl true
  def handle_info({:file_event, _pid, {_path, _events}}, %State{} = state) do
    # Coalesce a save-storm (editor temp+rename) into a single rescan.
    _ = if state.rescan_ref, do: Process.cancel_timer(state.rescan_ref)
    ref = Process.send_after(self(), :rescan, @debounce_ms)
    {:noreply, %State{state | rescan_ref: ref}}
  end

  def handle_info({:file_event, _pid, :stop}, %State{} = state) do
    {:noreply, %State{state | fs_pid: nil}}
  end

  def handle_info(:rescan, %State{} = state) do
    {:noreply, %State{rescan_and_broadcast(state) | rescan_ref: nil}}
  end

  def handle_info(:poll, %State{} = state) do
    {:noreply, maybe_schedule_poll(rescan_and_broadcast(state))}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # --- internals ---

  @doc false
  @spec resolve(String.t(), String.t() | nil) :: listing()
  def resolve(app_root, working_dir) do
    %{
      slash_command: merge(SlashCommand.scan(app_root, :app), working_slash(working_dir)),
      agent: Agent.scan(working_dir),
      adw: merge(Adw.scan(app_root, :app), working_adw(working_dir))
    }
  end

  @spec rescan_and_broadcast(State.t()) :: State.t()
  defp rescan_and_broadcast(%State{} = state) do
    listing = resolve(state.app_root, state.working_dir)
    new_sigs = signatures(listing)

    changed =
      Enum.filter(@categories, fn category ->
        Map.fetch!(new_sigs, category) != Map.fetch!(state.signatures, category)
      end)

    Enum.each(changed, &broadcast(&1, Map.fetch!(listing, &1)))
    %State{state | signatures: new_sigs}
  end

  @spec broadcast(category(), [entry()]) :: :ok | {:error, term()}
  defp broadcast(category, list) do
    Phoenix.PubSub.broadcast(
      RepoBuilder.PubSub,
      @topic,
      {:definitions_changed, category, list}
    )
  end

  @spec working_slash(String.t() | nil) :: [SlashCommand.t()]
  defp working_slash(nil), do: []
  defp working_slash(dir), do: SlashCommand.scan(dir, :working_dir)

  @spec working_adw(String.t() | nil) :: [Adw.t()]
  defp working_adw(nil), do: []
  defp working_adw(dir), do: Adw.scan(dir, :working_dir)

  # Merge two same-category lists by `name`; working-dir entries (the second list)
  # shadow app entries of the same name. Result is sorted by name for stable render.
  @spec merge([entry()], [entry()]) :: [entry()]
  defp merge(app, working) do
    app
    |> Map.new(&{&1.name, &1})
    |> Map.merge(Map.new(working, &{&1.name, &1}))
    |> Map.values()
    |> Enum.sort_by(& &1.name)
  end

  @spec signatures(listing()) :: %{category() => MapSet.t()}
  defp signatures(listing) do
    Map.new(@categories, fn category ->
      sig =
        listing
        |> Map.fetch!(category)
        |> Enum.map(&{&1.name, &1.mtime, &1.source})
        |> MapSet.new()

      {category, sig}
    end)
  end

  @spec maybe_start_watcher(State.t()) :: State.t()
  defp maybe_start_watcher(%State{watch_enabled?: false} = state), do: state
  defp maybe_start_watcher(%State{watched_dirs: []} = state), do: state

  defp maybe_start_watcher(%State{watched_dirs: dirs} = state) do
    case FileSystem.start_link(dirs: dirs) do
      {:ok, pid} ->
        FileSystem.subscribe(pid)
        %State{state | fs_pid: pid}

      other ->
        Logger.warning(
          "Definitions: FileSystem watcher unavailable (#{inspect(other)}); " <>
            "relying on poll fallback"
        )

        state
    end
  end

  @spec restart_watcher_if_dirs_changed(State.t()) :: State.t()
  defp restart_watcher_if_dirs_changed(%State{} = state) do
    new_dirs = watched_dirs(state.app_root, state.working_dir)

    if new_dirs == state.watched_dirs do
      state
    else
      _ = if is_pid(state.fs_pid), do: GenServer.stop(state.fs_pid, :normal)
      maybe_start_watcher(%State{state | fs_pid: nil, watched_dirs: new_dirs})
    end
  end

  @spec maybe_schedule_poll(State.t()) :: State.t()
  defp maybe_schedule_poll(%State{watch_enabled?: false} = state), do: state

  defp maybe_schedule_poll(%State{} = state) do
    ref = Process.send_after(self(), :poll, state.poll_interval_ms)
    %State{state | poll_ref: ref}
  end

  # The existing watchable source directories under the merged root. FileSystem
  # requires existing dirs, so absent ones are filtered out.
  @spec watched_dirs(String.t(), String.t() | nil) :: [String.t()]
  defp watched_dirs(app_root, working_dir) do
    roots = [app_root | List.wrap(working_dir)]

    roots
    |> Enum.flat_map(fn root ->
      [Path.join(root, ".claude"), Path.join(root, "adws")]
    end)
    |> Enum.filter(&File.dir?/1)
    |> Enum.uniq()
  end

  @spec app_root() :: String.t()
  defp app_root, do: Keyword.get(env(), :app_root) || File.cwd!()

  @spec env() :: keyword()
  defp env, do: Application.get_env(:repo_builder, __MODULE__, [])
end
