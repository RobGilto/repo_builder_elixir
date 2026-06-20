defmodule RepoBuilderWeb.TestSlashCommandExpansionTest do
  @moduledoc """
  End-to-end LiveView proof of control-owned slash-command expansion: an operator
  submits a `/command` in the console; the real orchestrator-turn pipeline runs it on
  a capturing harness adapter, and the prompt that reaches the harness is the EXPANDED
  command body (resolved from the orchestrator's working directory). An unknown command
  is delivered verbatim.

  The default orchestrator already runs on the `fake` harness; we override that registry
  entry to point at a Mox adapter (keeping `orchestrating: true`) whose `command/1`
  reports the resolved prompt — so no real `claude`/`pi` spawns and the assertion sees
  exactly what the runtime would have handed the CLI.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Harness.Mock
  alias RepoBuilder.Orchestrators

  @moduletag :tmp_dir

  # Override the `fake` harness entry's module with the capturing Mock, preserving its
  # `orchestrating: true` / default_model so the default orchestrator stays runnable.
  defp register_capturing_fake(test_pid) do
    original = Application.fetch_env!(:repo_builder, :harnesses)
    entry = original |> Map.fetch!("fake") |> Map.merge(%{module: Mock, exe: "true"})
    Application.put_env(:repo_builder, :harnesses, Map.put(original, "fake", entry))
    on_exit(fn -> Application.put_env(:repo_builder, :harnesses, original) end)

    Mox.stub(Mock, :command, fn start_opts ->
      send(test_pid, {:command_prompt, start_opts.prompt})
      {"true", [], [], %{}}
    end)

    Mox.stub(Mock, :normalize, fn _raw, _ctx -> :skip end)
  end

  defp write_command(tmp_dir, name, body) do
    path = Path.join([tmp_dir, ".claude", "commands", name <> ".md"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "---\ndescription: #{name}\n---\n\n#{body}\n")
    path
  end

  defp run_via_command(view, text) do
    view
    |> form("#command-form", command: text)
    |> render_submit()
  end

  setup %{tmp_dir: tmp} do
    Mox.set_mox_global()
    register_capturing_fake(self())

    {:ok, orch} = Orchestrators.get_or_create_default()
    {:ok, _orch} = Orchestrators.set_working_dir(orch.id, tmp)
    # The fake orchestrator has no default model; a turn refuses to run without one.
    {:ok, _orch} = Orchestrators.set_model(orch.id, "fake-model-1")
    write_command(tmp, "greet", "Hello $ARGUMENTS, from greet.")
    :ok
  end

  test "an operator slash command is expanded before it reaches the harness", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    run_via_command(view, "/greet world")

    assert_receive {:command_prompt, "Hello world, from greet."}, 2_000
  end

  test "an unknown slash command is delivered verbatim", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    run_via_command(view, "/nope keep me")

    assert_receive {:command_prompt, "/nope keep me"}, 2_000
  end
end
