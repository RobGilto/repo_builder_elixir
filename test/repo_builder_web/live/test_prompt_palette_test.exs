defmodule RepoBuilderWeb.TestPromptPaletteTest do
  @moduledoc """
  Integration test for the file-driven prompt palette (issue-prompt-adw-palette): the
  ⌘K command modal renders live, file-derived chips for slash commands, agents, and
  ADWs (one per fixture on disk); empty categories show an actionable hint; each chip
  carries the `rb:insert-token` client dispatch; and a `{:definitions_changed, …}`
  PubSub broadcast re-renders the matching chip row with no panel re-open.

  `async: false` so the shared Ecto sandbox reaches the LiveView process.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Definitions

  test "chips render one per on-disk fixture across the three categories", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    # Slash commands from the repo's .claude/commands/*.md.
    assert html =~ "/feature"
    assert html =~ "/implement"
    # Agent template from priv/orchestrator/agents.
    assert html =~ "code-scout"
    # An ADW slug from adws/adw_*.py (prefix stripped).
    assert html =~ "plan_build_iso"
  end

  test "each chip carries the rb:insert-token client dispatch", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "rb:insert-token"
  end

  test "an empty category renders its actionable empty-state hint", %{conn: conn} do
    empty = Path.join(System.tmp_dir!(), "rb-palette-empty-#{System.unique_integer([:positive])}")
    File.mkdir_p!(empty)

    prev = Application.get_env(:repo_builder, Definitions)

    Application.put_env(:repo_builder, Definitions,
      app_root: empty,
      watch_enabled?: false,
      poll_interval_ms: 30_000
    )

    on_exit(fn ->
      if prev, do: Application.put_env(:repo_builder, Definitions, prev)
      File.rm_rf!(empty)
    end)

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "add `.claude/commands"
    assert html =~ "add `adws/adw_*.py`"
  end

  test "a definitions_changed broadcast re-renders the slash chip row", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    new_list = [
      %Definitions.SlashCommand{
        name: "brandnewcmd",
        namespace: [],
        path: "/tmp/brandnewcmd.md",
        source: :working_dir,
        description: "freshly broadcast",
        argument_hint: nil,
        mtime: 0
      }
    ]

    Phoenix.PubSub.broadcast(
      RepoBuilder.PubSub,
      Definitions.topic(),
      {:definitions_changed, :slash_command, new_list}
    )

    # The broadcast command is :working_dir, so it lives under the PROJECT tab (the BASE tab
    # is active by default and the inactive tab is not in the DOM). Switch tabs to see it.
    # Scope to the palette row to avoid matching the data-autocomplete attribute.
    refute element(view, "#palette-slash-base") |> render() =~ "/brandnewcmd"
    view |> element("#palette-tab-project") |> render_click()
    assert element(view, "#palette-slash-project") |> render() =~ "/brandnewcmd"
  end

  test "base and project source tabs separate artifacts by provenance", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    # An :app slash command and a :working_dir one share the row data but split across tabs.
    list = [
      %Definitions.SlashCommand{
        name: "basecmd",
        namespace: [],
        path: "/tmp/basecmd.md",
        source: :app,
        description: "from the platform repo",
        argument_hint: nil,
        mtime: 0
      },
      %Definitions.SlashCommand{
        name: "projcmd",
        namespace: [],
        path: "/tmp/projcmd.md",
        source: :working_dir,
        description: "from the project overlay",
        argument_hint: nil,
        mtime: 0
      }
    ]

    Phoenix.PubSub.broadcast(
      RepoBuilder.PubSub,
      Definitions.topic(),
      {:definitions_changed, :slash_command, list}
    )

    # BASE tab (default): the :app command shows, the :working_dir one does not.
    # Scope to the palette row to avoid matching the data-autocomplete attribute.
    base = element(view, "#palette-slash-base") |> render()
    assert base =~ "/basecmd"
    refute base =~ "/projcmd"

    # PROJECT tab: the reverse.
    view |> element("#palette-tab-project") |> render_click()
    project = element(view, "#palette-slash-project") |> render()
    assert project =~ "/projcmd"
    refute project =~ "/basecmd"
  end
end
