defmodule RepoBuilder.DefinitionsWatchTest do
  @moduledoc """
  Watch/broadcast test for the file-driven prompt palette. Starts a `Definitions`
  instance pointed at a tmp root with POLLING enabled and a short interval, so the
  broadcast path is deterministic without relying on inotify. Asserts that adding a
  file in a watched category broadcasts `{:definitions_changed, category, list}` and
  that an unrelated category does NOT broadcast (per-category signature diff).
  """
  use ExUnit.Case, async: false

  alias RepoBuilder.Definitions

  defp write!(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  setup %{tmp_dir: root} do
    # Pre-create the watched dirs so the (filtered) watcher has something to attach to.
    File.mkdir_p!(Path.join(root, "adws"))
    File.mkdir_p!(Path.join(root, ".claude/commands"))

    {:ok, pid} =
      Definitions.start_link(
        name: :"definitions_watch_#{System.unique_integer([:positive])}",
        app_root: root,
        working_dir: nil,
        watch_enabled?: true,
        poll_interval_ms: 100
      )

    :ok = Definitions.subscribe()
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {:ok, root: root}
  end

  @tag :tmp_dir
  test "adding an ADW and a slash command broadcasts those categories", %{root: root} do
    write!(Path.join(root, "adws/adw_freshly_added.py"), """
    \"\"\"
    Freshly added workflow
    \"\"\"
    """)

    write!(Path.join(root, ".claude/commands/freshcmd.md"), """
    ---
    description: a fresh command
    ---
    """)

    assert_receive {:definitions_changed, :adw, adws}, 2_000
    assert Enum.any?(adws, &(&1.name == "freshly_added"))

    assert_receive {:definitions_changed, :slash_command, cmds}, 2_000
    assert Enum.any?(cmds, &(&1.name == "freshcmd"))
  end

  @tag :tmp_dir
  test "an unchanged category does not broadcast", %{root: root} do
    write!(Path.join(root, "adws/adw_only_adw.py"), "print('x')\n")

    assert_receive {:definitions_changed, :adw, _adws}, 2_000
    # No agent/slash broadcast should arrive — those categories did not change.
    refute_receive {:definitions_changed, :slash_command, _}, 400
  end
end
