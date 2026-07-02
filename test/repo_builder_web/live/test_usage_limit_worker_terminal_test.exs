defmodule RepoBuilderWeb.TestUsageLimitWorkerTerminalTest do
  @moduledoc """
  LiveView proof for surfacing a worker's usage-limit terminal error (issue usage-limit): when
  a worker's harness exhausts a provider usage limit (e.g. pi/zai's `429 Usage limit reached`,
  normalized to `%Event.Error{reason: :auto_retry_exhausted}`), the auto-resume prompt delivered
  to the orchestrator must name the specific cause instead of the generic "finished with errors"
  — so the orchestrator brain can decide to switch harness/provider rather than re-dispatching
  into the same dead end.

  Uses a controllable `:starter` for the orchestrator resume turn (no real harness) and drives
  the terminal broadcast directly via `Dashboard.broadcast_worker_terminal/2`, mirroring the
  fields `Session.Server.maybe_emit_worker_terminal/2` now sends for an `%Event.Error{}` terminal.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Agents, Dashboard}
  alias RepoBuilder.Orchestrator.Queue
  alias RepoBuilder.Orchestrators

  defp controllable_starter(test_pid) do
    fn _orchestrator_id, prompt ->
      turn = spawn(fn -> receive(do: (:stop -> :ok)) end)
      send(test_pid, {:turn_started, prompt, turn})
      {:ok, turn, "agent-#{System.unique_integer([:positive])}"}
    end
  end

  setup do
    original = Application.get_env(:repo_builder, :orchestrator)
    on_exit(fn -> Application.put_env(:repo_builder, :orchestrator, original) end)

    Application.put_env(
      :repo_builder,
      :orchestrator,
      Keyword.put(original, :auto_resume_on_worker_return, true)
    )

    {:ok, orch} = Orchestrators.get_or_create_default()
    start_supervised!({Queue, orchestrator_id: orch.id, starter: controllable_starter(self())})
    %{orch: orch}
  end

  test "a usage-limit terminal error surfaces its reason and message in the auto-resume prompt",
       %{conn: conn, orch: orch} do
    {:ok, worker} =
      Agents.create_worker(orch.id, %{
        "name" => "autocomplete-impl-#{System.unique_integer([:positive])}",
        "harness" => "pi",
        "provider" => "anthropic",
        "model" => "fake-model"
      })

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#agent-#{worker.id}")

    Dashboard.broadcast_worker_terminal(orch.id, %{
      worker_id: worker.id,
      name: worker.name,
      ok?: false,
      context_tokens: 0,
      final_text:
        "429 Usage limit reached for 5 hour. Your limit will reset at 2026-07-02 21:28:56",
      error_reason: :auto_retry_exhausted,
      error_message:
        "429 Usage limit reached for 5 hour. Your limit will reset at 2026-07-02 21:28:56"
    })

    assert_receive {:turn_started, prompt, _resume}, 1_000

    assert prompt =~ "auto_retry_exhausted"
    assert prompt =~ "Usage limit reached"
    assert prompt =~ "harness/model/provider"
    refute prompt =~ "finished with errors"
  end
end
