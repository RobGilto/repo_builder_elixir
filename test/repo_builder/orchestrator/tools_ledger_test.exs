defmodule RepoBuilder.Orchestrator.ToolsLedgerTest do
  @moduledoc """
  Self-healing Phase 3: the leadership/ledger tools round-trip through `Tools.call/3` (the
  single harness-blind entry point) — set_goal / record_progress / get_ledger /
  report_complete — and `inspect_repo` reads the actual tree while staying path-jailed to the
  orchestrator's working_dir.
  """
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.Orchestrator.Ledgers
  alias RepoBuilder.Orchestrator.Tools
  alias RepoBuilder.Orchestrators

  setup do
    dir = Path.join(System.tmp_dir!(), "ledger-repo-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    git!(dir, ["init"])
    git!(dir, ["config", "user.email", "t@example.com"])
    git!(dir, ["config", "user.name", "Tester"])
    File.write!(Path.join(dir, "README.md"), "hello world\n")
    git!(dir, ["add", "."])
    git!(dir, ["commit", "-m", "init"])
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, orch} =
      Orchestrators.create(%{
        name: "orch-#{System.unique_integer([:positive])}",
        harness: "fake",
        working_dir: dir
      })

    %{orch: orch, dir: dir}
  end

  defp git!(dir, args) do
    {_out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    :ok
  end

  describe "ledger tools" do
    test "set_goal then get_ledger round-trips", %{orch: orch} do
      assert {:ok, %{"status" => "goal_set"}} =
               Tools.call("set_goal", orch.id, %{
                 "goal" => "make it work",
                 "definition_of_done" => "all tests green",
                 "plan" => ["a", "b"]
               })

      assert {:ok, ledger} = Tools.call("get_ledger", orch.id, %{})
      assert ledger["goal"] == "make it work"
      assert ledger["definition_of_done"] == "all tests green"
      assert ledger["status"] == "active"
    end

    test "get_ledger with no goal reports no_goal", %{orch: orch} do
      assert {:ok, %{"status" => "no_goal"}} = Tools.call("get_ledger", orch.id, %{})
    end

    test "record_progress persists and surfaces via get_ledger", %{orch: orch} do
      {:ok, _} =
        Tools.call("set_goal", orch.id, %{"goal" => "g", "definition_of_done" => "d"})

      assert {:ok, %{"status" => "recorded"}} =
               Tools.call("record_progress", orch.id, %{
                 "made_progress" => true,
                 "summary" => "wired the thing",
                 "next_agent" => "tester"
               })

      assert {:ok, ledger} = Tools.call("get_ledger", orch.id, %{})
      assert ledger["progress"]["summary"] == "wired the thing"
      assert ledger["progress"]["next_agent"] == "tester"
    end

    test "record_progress without a goal errors", %{orch: orch} do
      assert {:error, :no_active_ledger} =
               Tools.call("record_progress", orch.id, %{"made_progress" => true})
    end

    test "report_complete marks the ledger :done", %{orch: orch} do
      {:ok, _} = Tools.call("set_goal", orch.id, %{"goal" => "g", "definition_of_done" => "d"})

      assert {:ok, %{"status" => "done"}} =
               Tools.call("report_complete", orch.id, %{"summary" => "shipped it"})

      assert Ledgers.current(orch.id) == nil
    end
  end

  describe "inspect_repo" do
    test "git_status returns the short status", %{orch: orch} do
      assert {:ok, %{"op" => "git_status", "output" => output}} =
               Tools.call("inspect_repo", orch.id, %{"op" => "git_status"})

      assert is_binary(output)
    end

    test "changed_files lists working-tree changes", %{orch: orch, dir: dir} do
      File.write!(Path.join(dir, "new.txt"), "x")

      assert {:ok, %{"op" => "changed_files", "files" => files}} =
               Tools.call("inspect_repo", orch.id, %{"op" => "changed_files"})

      assert Enum.any?(files, &(&1["path"] == "new.txt"))
    end

    test "read_file returns a jailed file's content", %{orch: orch} do
      assert {:ok, %{"op" => "read_file", "content" => content}} =
               Tools.call("inspect_repo", orch.id, %{"op" => "read_file", "path" => "README.md"})

      assert content == "hello world\n"
    end

    test "read_file refuses a path outside the working dir", %{orch: orch} do
      assert {:error, :path_outside_working_dir} =
               Tools.call("inspect_repo", orch.id, %{
                 "op" => "read_file",
                 "path" => "../../etc/passwd"
               })
    end

    test "read_file refuses descending into .git", %{orch: orch} do
      assert {:error, :path_forbidden} =
               Tools.call("inspect_repo", orch.id, %{"op" => "read_file", "path" => ".git/config"})
    end

    test "inspect_repo errors when the orchestrator has no working dir" do
      {:ok, orch} =
        Orchestrators.create(%{
          name: "orch-#{System.unique_integer([:positive])}",
          harness: "fake"
        })

      assert {:error, :no_working_dir} =
               Tools.call("inspect_repo", orch.id, %{"op" => "git_status"})
    end
  end
end
