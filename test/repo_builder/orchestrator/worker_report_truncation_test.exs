defmodule RepoBuilder.Orchestrator.WorkerReportTruncationTest do
  @moduledoc """
  Regression test for the worker-report truncation bug across both fixes:

  1. prompt + marker (logs 6779–6809): every worker is told the surfaced window is finite
     and given an `ai_docs/` file-handoff path; the truncation marker is actionable.
  2. deterministic platform-side spill (logs 7131–7151): because real workers ignore the
     prompt clause and inline long reports, the platform itself spills the full untruncated
     `final_message` to a file under the orchestrator working dir and returns its path as
     `report_file`, guaranteeing retrievability without worker compliance.

  This exercises the `Orchestrator.Tools` boundary directly (no LiveView surface involved).
  """
  use RepoBuilder.SessionCase, async: false

  alias RepoBuilder.{Agents, Logs, Orchestrators}
  alias RepoBuilder.Harness.Event
  alias RepoBuilder.Orchestrator.Tools

  # Mirrors @worker_text_cap in Orchestrator.Tools; the prompt interpolates this constant
  # so the documented limit and the enforced cap can never drift.
  @cap 2_000

  defp uniq, do: System.unique_integer([:positive])

  defp orchestrator(attrs \\ %{}) do
    {:ok, orch} =
      Orchestrators.create(Map.merge(%{name: "orch-#{uniq()}", harness: "fake"}, attrs))

    orch
  end

  defp create_worker(orch, args \\ %{}) do
    name = "scout-#{uniq()}"

    {:ok, _} =
      Tools.call("create_agent", orch.id, Map.merge(%{"name" => name, "harness" => "fake"}, args))

    {:ok, agent} = Agents.get_by_name_for_orchestrator(orch.id, name)
    {name, agent}
  end

  defp persist(event, agent_id),
    do: {:ok, _} = Logs.persist_event(event, %{agent_id: agent_id, session_id: "s"})

  test "the worker reporting clause documents the surfaced cap and the ai_docs/ overflow path" do
    orch = orchestrator()
    {_name, agent} = create_worker(orch)

    # The clause is appended to every worker's system prompt.
    assert agent.system_prompt =~ "#{@cap}"
    assert agent.system_prompt =~ "ai_docs/"
    assert agent.system_prompt =~ "check_agent_status"
    assert agent.system_prompt =~ ~r/final message/i
  end

  test "the clause is appended even when the orchestrator supplies its own system prompt" do
    orch = orchestrator()
    {_name, agent} = create_worker(orch, %{"system_prompt" => "You are a focused scout."})

    assert agent.system_prompt =~ "You are a focused scout."
    assert agent.system_prompt =~ "ai_docs/"
    assert agent.system_prompt =~ "#{@cap}"
  end

  @tag :tmp_dir
  test "check_agent_status still bounds final_message and marks legacy overflow actionably", %{
    tmp_dir: tmp_dir
  } do
    orch = orchestrator()
    {:ok, _} = Orchestrators.set_working_dir(orch.id, tmp_dir)
    {name, agent} = create_worker(orch)

    long = String.duplicate("A", 5_000)

    persist(
      %Event.Done{harness: :fake, ok: true, reason: :success, raw: %{"result" => long}},
      agent.id
    )

    assert {:ok, result} = Tools.call("check_agent_status", orch.id, %{"name" => name})

    final = result["final_message"]

    marker =
      "… (truncated at #{@cap} chars — read this result's `report_file` path for the full output, or ask the worker for an ai_docs/ file)"

    assert String.ends_with?(final, marker)
    assert result["final_message"] =~ "report_file"
    # Bounded to the cap plus the (short, fixed) marker — the surfaced preview stays small.
    assert String.length(final) <= @cap + String.length(marker)
  end

  @tag :tmp_dir
  test "platform spills overflowing final_message to report_file under the working dir", %{
    tmp_dir: tmp_dir
  } do
    orch = orchestrator()
    {:ok, _} = Orchestrators.set_working_dir(orch.id, tmp_dir)
    {name, agent} = create_worker(orch)

    long = String.duplicate("Z", 5_000)

    persist(
      %Event.Done{harness: :fake, ok: true, reason: :success, raw: %{"result" => long}},
      agent.id
    )

    assert {:ok, result} = Tools.call("check_agent_status", orch.id, %{"name" => name})

    # final_message is still capped; the full text is recoverable via report_file.
    assert String.length(result["final_message"]) <= @cap + 200
    path = result["report_file"]
    assert is_binary(path)
    # Path is relative to the working dir when one is set.
    refute Path.type(path) == :absolute
    assert path =~ "ai_docs/worker-reports/"

    body = File.read!(Path.join(tmp_dir, path))
    assert body =~ long
    # The spilled body is the FULL untruncated message, not the preview.
    refute body =~ "(truncated at"
  end

  @tag :tmp_dir
  test "the spill is idempotent across repeated status polls", %{tmp_dir: tmp_dir} do
    orch = orchestrator()
    {:ok, _} = Orchestrators.set_working_dir(orch.id, tmp_dir)
    {name, agent} = create_worker(orch)

    persist(
      %Event.Done{
        harness: :fake,
        ok: true,
        reason: :success,
        raw: %{"result" => String.duplicate("Z", 5_000)}
      },
      agent.id
    )

    assert {:ok, first} = Tools.call("check_agent_status", orch.id, %{"name" => name})
    assert {:ok, second} = Tools.call("check_agent_status", orch.id, %{"name" => name})

    # Same source log → same path, never an accumulating pile of duplicate files.
    assert first["report_file"] == second["report_file"]
    files = Path.wildcard(Path.join(tmp_dir, "ai_docs/worker-reports/*.md"))
    assert length(files) == 1
  end

  @tag :tmp_dir
  test "a short final_message yields no report_file", %{tmp_dir: tmp_dir} do
    orch = orchestrator()
    {:ok, _} = Orchestrators.set_working_dir(orch.id, tmp_dir)
    {name, agent} = create_worker(orch)

    persist(
      %Event.Done{harness: :fake, ok: true, reason: :success, raw: %{"result" => "All done."}},
      agent.id
    )

    assert {:ok, result} = Tools.call("check_agent_status", orch.id, %{"name" => name})

    assert result["final_message"] == "All done."
    assert result["report_file"] == nil
    assert Path.wildcard(Path.join(tmp_dir, "ai_docs/worker-reports/*.md")) == []
  end
end
