defmodule RepoBuilderWeb.TestOrchestratorTurnStallTest do
  @moduledoc """
  LiveView proof that a stalled orchestrator turn surfaces on the console instead of
  hanging silently (issue orch-stall). A turn dispatched through the queue against a
  hung harness (emits nothing) trips the orchestrator's SHORT idle watchdog: the
  console feed renders the `idle timeout` error row and the per-orchestrator queue is
  no longer Busy — the turn ended cleanly rather than sitting stuck `:running` until an
  operator nudged it.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest

  alias RepoBuilder.Orchestrators

  @mock RepoBuilder.Harness.Mock

  setup do
    # The hung Mock is called from the spawned (out-of-test) session process, so the
    # stubs must be globally visible (ConnCase async:false ⇒ shared sandbox).
    Mox.set_mox_global()

    # Short orchestrator idle window so the stall surfaces in test time; restore on exit.
    original = Application.fetch_env!(:repo_builder, :orchestrator)
    Application.put_env(:repo_builder, :orchestrator, Keyword.put(original, :turn_idle_ms, 200))
    on_exit(fn -> Application.put_env(:repo_builder, :orchestrator, original) end)

    # Point the orchestrating "fake" harness at the hung Mock, PRESERVING `orchestrating:
    # true` (so the turn passes the orchestrating gate), then restore the registry.
    harnesses = Application.fetch_env!(:repo_builder, :harnesses)
    fake = harnesses |> Map.fetch!("fake") |> Map.merge(%{module: @mock})
    Application.put_env(:repo_builder, :harnesses, Map.put(harnesses, "fake", fake))
    on_exit(fn -> Application.put_env(:repo_builder, :harnesses, harnesses) end)

    stub(@mock, :command, fn _ -> {"sleep", ["10"], [], %{harness: :fake}} end)
    stub(@mock, :normalize, fn _, _ -> :skip end)

    on_exit(&drain_sessions/0)
    :ok
  end

  test "the console surfaces a stalled orchestrator turn and is no longer Busy", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    {:ok, orch} = Orchestrators.get_or_create_default()
    assert orch.harness == "fake"
    # Clear the no-model gate so the turn actually dispatches.
    {:ok, _} = Orchestrators.set_model(orch.id, "fake-model")

    # Dispatch a turn through the queue path (as an operator would).
    view
    |> form("#command-form", command: "stall please")
    |> render_submit()

    # The short idle watchdog fires and the `idle timeout` error row reaches the feed,
    # instead of the turn hanging silently for the worker-grade 5 minutes.
    assert eventually(fn -> render(view) =~ "idle timeout" end)

    # The turn ended (flushed :error) rather than sitting stuck at :running...
    assert eventually(fn ->
             {:ok, reloaded} = Orchestrators.fetch(orch.id)
             reloaded.status == :error
           end)

    # ...and the queue is no longer Busy — free to proceed with no operator nudge.
    assert eventually(fn -> not has_element?(view, "#queue-badge", "Busy") end)
  end

  defp eventually(fun, attempts \\ 300) do
    cond do
      fun.() -> true
      attempts > 0 -> Process.sleep(20) && eventually(fun, attempts - 1)
      true -> false
    end
  end

  defp drain_sessions(attempts \\ 200) do
    case DynamicSupervisor.count_children(RepoBuilder.SessionSupervisor) do
      %{active: 0} -> :ok
      _ when attempts > 0 -> Process.sleep(20) && drain_sessions(attempts - 1)
      _ -> :ok
    end
  end
end
