defmodule RepoBuilder.Session.SlashExpansionIntegrationTest do
  @moduledoc """
  Verifies that the single session chokepoint (`Session.Supervisor.start_session/1`)
  rewrites `opts[:prompt]` via the slash expander for interactive harnesses and
  leaves the `adw` harness untouched. A Mox harness adapter captures the exact prompt
  the runtime would hand to the CLI, so no real `claude`/`pi` process spawns.
  """
  use RepoBuilder.SessionCase, async: false

  alias RepoBuilder.Harness.Mock
  alias RepoBuilder.Session

  @moduletag :tmp_dir

  # A capturing adapter: report the prompt the runtime resolved, then spawn a no-op.
  defp stub_capturing_adapter(test_pid) do
    Mox.stub(Mock, :command, fn start_opts ->
      send(test_pid, {:command_prompt, start_opts.prompt})
      {"true", [], [], %{}}
    end)

    Mox.stub(Mock, :normalize, fn _raw, _ctx -> :skip end)
  end

  defp write_command(tmp_dir, name, body) do
    path = Path.join([tmp_dir, ".claude", "commands", name <> ".md"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "---\ndescription: test\n---\n\n#{body}\n")
  end

  # Both real interactive harnesses must expand identically — the gate keys on the
  # harness NAME (everything except "adw"), so claude and pi behave the same. Claude
  # would also expand natively; pi would NOT, which is exactly the bug this fixes.
  for harness <- ["claude", "pi"] do
    test "the #{harness} harness receives the expanded command body", %{tmp_dir: tmp} do
      harness = unquote(harness)
      register_harness(harness, Mock)
      stub_capturing_adapter(self())
      write_command(tmp, "greet", "Hello, expanded.")

      {:ok, _pid} =
        Session.Supervisor.start_session(
          agent_id: "#{harness}-#{System.unique_integer([:positive])}",
          harness: harness,
          prompt: "/greet",
          cwd: tmp
        )

      assert_receive {:command_prompt, "Hello, expanded."}, 2_000
    end
  end

  test "the adw harness is skipped — the prompt is delivered verbatim", %{tmp_dir: tmp} do
    register_harness("adw", Mock)
    stub_capturing_adapter(self())
    write_command(tmp, "greet", "Hello, expanded.")

    {:ok, _pid} =
      Session.Supervisor.start_session(
        agent_id: "adw-#{System.unique_integer([:positive])}",
        harness: "adw",
        prompt: "/greet",
        cwd: tmp
      )

    assert_receive {:command_prompt, "/greet"}, 2_000
  end

  test "an unknown command is delivered verbatim on an interactive harness", %{tmp_dir: tmp} do
    register_harness("cap", Mock)
    stub_capturing_adapter(self())

    {:ok, _pid} =
      Session.Supervisor.start_session(
        agent_id: "cap-#{System.unique_integer([:positive])}",
        harness: "cap",
        prompt: "/nope still here",
        cwd: tmp
      )

    assert_receive {:command_prompt, "/nope still here"}, 2_000
  end
end
