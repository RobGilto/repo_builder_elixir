defmodule RepoBuilder.Orchestrator.WorkerReportFullFidelityTest do
  @moduledoc """
  Regression test for the >10 KB worker-report truncation bug (issue worker-report-truncation).

  A finalized `Event.TextDelta` whose `text` exceeds `@max_blob_bytes` (10 KB) must be
  persisted VERBATIM by `Logs.event_payload/2` — not routed through `Redact.scrub_term/1`,
  which capped any binary over 10 KB and appended `...[truncated]`. The worker-report spill
  path (`Orchestrator.Tools.spill_report/4`) re-reads that persisted payload, so a scrubbed
  source silently amputated long reports at exactly the blob boundary.

  This pins the fix end-to-end (persist → `result_text/1` → spill) AND at the persistence
  boundary directly. It exercises the `Orchestrator.Tools` boundary (no LiveView surface).

  Reproduction: re-introducing the `Redact.scrub_term/1` wrapper around the `TextDelta`
  payload in `lib/repo_builder/logs.ex` makes both the persistence-boundary and spill-body
  assertions fail (text cut at ~10 KB with the truncation suffix).
  """
  use RepoBuilder.SessionCase, async: false

  alias RepoBuilder.{Agents, Logs, Orchestrators}
  alias RepoBuilder.Harness.Event
  alias RepoBuilder.Orchestrator.Tools

  # Unique, verifiable text well over the 10 KB `@max_blob_bytes` blob cap. The trailing
  # sentinel can only survive if the full binary was stored — it sits past the old cut point.
  @long String.duplicate("Z", 12_000) <> "END-OF-REPORT-SENTINEL"

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

  @tag :tmp_dir
  test "a >10 KB finalized TextDelta is persisted verbatim and spilled in full", %{
    tmp_dir: tmp_dir
  } do
    orch = orchestrator()
    {:ok, _} = Orchestrators.set_working_dir(orch.id, tmp_dir)
    {name, agent} = create_worker(orch)

    persist(
      %Event.TextDelta{harness: :fake, text: @long, partial?: false, thinking?: false},
      agent.id
    )

    # Persistence boundary: the stored canonical text is the full binary, no truncation
    # marker — this pins the `logs.ex` fix independent of the spill path.
    [log | _] =
      agent.id
      |> Logs.list_recent(20)
      |> Enum.filter(&(&1.event_type == :text_delta))

    assert log.payload["text"] == @long
    refute log.payload["text"] =~ "...[truncated]"

    # End-to-end spill: the report file carries the worker's complete output.
    assert {:ok, result} = Tools.call("check_agent_status", orch.id, %{"name" => name})

    path = result["report_file"]
    assert is_binary(path)
    refute Path.type(path) == :absolute
    assert path =~ "ai_docs/worker-reports/"

    body = File.read!(Path.join(tmp_dir, path))
    # The full text, including the trailing sentinel past the old 10 KB cut point.
    assert body =~ @long
    refute body =~ "…[truncated]"
    refute body =~ "...[truncated]"
    # Sanity: the file is larger than the old 10 KB blob cap.
    assert byte_size(body) > 12_000
  end
end
