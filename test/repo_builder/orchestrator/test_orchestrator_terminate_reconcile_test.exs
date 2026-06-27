defmodule RepoBuilder.Orchestrator.TerminateReconcileTest do
  @moduledoc """
  Issue orchestrator-stuck (primary, in-process): an orchestrator turn that reaches
  `Orchestrator.Server.terminate/2` WITHOUT having flushed a terminal `:idle|:error`
  (the harness session died silently, or this Server was stopped) must reconcile the
  `orchestrators` row to `:idle` — never leave it wedged at `:running`. A turn that
  already flushed a terminal status (`flushed?: true`) must NOT be overwritten.
  """
  use RepoBuilder.DataCase, async: false

  alias RepoBuilder.Orchestrator.Server
  alias RepoBuilder.Orchestrators

  defp uniq, do: System.unique_integer([:positive])

  defp running_orchestrator do
    {:ok, orch} = Orchestrators.create(%{name: "orch-#{uniq()}", harness: "fake"})
    {:ok, orch} = Orchestrators.set_status(orch.id, :running)
    orch
  end

  defp base_state(orch, flushed?) do
    %Server.State{
      orchestrator_id: orch.id,
      agent_id: "orch-#{orch.id}-#{uniq()}",
      prompt: "go",
      harness: "fake",
      in_process?: false,
      flushed?: flushed?
    }
  end

  test "a non-terminal exit reconciles the orchestrator to :idle" do
    orch = running_orchestrator()
    assert :ok = Server.terminate(:killed, base_state(orch, false))

    {:ok, reconciled} = Orchestrators.fetch(orch.id)
    assert reconciled.status == :idle
  end

  test "a turn that already flushed a terminal status is NOT overwritten to :idle" do
    orch = running_orchestrator()
    # A terminal :error already flushed (flushed?: true short-circuits terminate/2).
    {:ok, _} = Orchestrators.set_status(orch.id, :error)

    assert :ok = Server.terminate(:normal, base_state(orch, true))

    {:ok, untouched} = Orchestrators.fetch(orch.id)
    assert untouched.status == :error
  end
end
