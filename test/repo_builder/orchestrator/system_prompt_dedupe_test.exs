defmodule RepoBuilder.Orchestrator.SystemPromptDedupeTest do
  @moduledoc """
  Regression guards for the 2026-07 system-prompt consolidation
  (`ai_docs/system-prompt-dedupe-ledger.md`):

    * sentinel policy phrases occur EXACTLY once per render (duplicates can't
      silently regrow);
    * the concept-before-mechanic section order holds;
    * repo-dependent blocks gate on `repo_bound?` (present with a working dir,
      absent — replaced by the inactive-protocols notice — without one);
    * the prompt's tools block renders terse `summary` lines while the MCP/pi
      channel keeps the full `description`.

  `async: false` — checks out the SQL sandbox directly (a working_dir triggers
  the registered-project lookup) outside `DataCase`.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias RepoBuilder.Orchestrator.{Orchestrator, SystemPrompt, ToolCatalog}

  setup do
    :ok = Sandbox.checkout(RepoBuilder.Repo)

    dir = Path.join(System.tmp_dir!(), "rb_sp_dedupe_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    base = %Orchestrator{
      name: "dedupe",
      harness: "fake",
      provider: nil,
      model: nil,
      metadata: %{}
    }

    %{
      bound: SystemPrompt.build(%{base | working_dir: dir}),
      unbound: SystemPrompt.build(base)
    }
  end

  defp occurrences(prompt, phrase), do: length(String.split(prompt, phrase)) - 1

  describe "sentinel phrases occur exactly once (repo-bound render)" do
    for phrase <- [
          # concept 2 — compact_self safety rationale lives only in Durable memory
          "rehydrate-on-resume",
          # concept 1 — the ADW selection ladder lives only in the ADWs section
          "trivial change",
          # concept 4 — the canonical VERIFY rule lives only in the core loop
          "never assume a worker",
          # concept 7 — the five-stage listing lives only in the quality gate
          "format · lint · type · test · mutation",
          # dispatch mechanics stated once
          "ultrathink",
          # worker-context lifecycle stated once
          "GRACEFUL HANDOVER"
        ] do
      test "#{inspect(phrase)}", %{bound: bound} do
        assert occurrences(bound, unquote(phrase)) == 1
      end
    end

    test "the subagent-template roster prints once (worker_roles_block is gone)", %{bound: bound} do
      assert occurrences(bound, "Available subagent templates & worker roles") == 1
      refute bound =~ "Worker roles (data-driven"
    end
  end

  test "concept-before-mechanic section order", %{bound: bound} do
    offsets =
      [
        "Durable memory (workstreams)",
        "Autonomous leadership — the core loop",
        "Spec-driven phased delivery",
        "Quality gate (per-phase rigorous testing",
        "Context management:",
        "Dispatching workers:",
        "Available tools"
      ]
      |> Enum.map(fn header ->
        assert {offset, _len} = :binary.match(bound, header), "missing section: #{header}"
        offset
      end)

    assert offsets == Enum.sort(offsets)
  end

  describe "conditional inclusion (repo_bound?)" do
    test "the no-repo render omits repo-dependent protocols", %{unbound: unbound} do
      refute unbound =~ "Quality gate (per-phase rigorous testing"
      refute unbound =~ "Spec-driven phased delivery"
      refute unbound =~ "CROSS-REPO"
      refute unbound =~ "ITERATIVE UI/UX POLISH"
      assert unbound =~ "INACTIVE until a working directory is set"
    end

    test "the no-repo render keeps the unconditional layers", %{unbound: unbound} do
      assert unbound =~ "Durable memory (workstreams)"
      assert unbound =~ "Autonomous leadership — the core loop"
      assert unbound =~ "Context management:"
      assert unbound =~ "Available tools"
      assert unbound =~ "Available ADW types"
    end

    test "the repo-bound render includes them (no notice)", %{bound: bound} do
      assert bound =~ "Spec-driven phased delivery"
      assert bound =~ "Quality gate (per-phase rigorous testing"
      assert bound =~ "CROSS-REPO"
      refute bound =~ "INACTIVE until a working directory is set"
    end
  end

  describe "terse tools block vs full MCP descriptions" do
    test "the prompt renders tool summaries, not the full policy descriptions", %{bound: bound} do
      # start_adw's summary points at the ADW section; its full description
      # (with the restated ladder) must NOT be in the prompt.
      assert bound =~ "- start_adw: Launch an AI Developer Workflow run"
      refute bound =~ "Two modes by `harness`"
    end

    test "prompt_line prefers summary and falls back to description" do
      assert ToolCatalog.prompt_line(%{summary: "short", description: "long"}) == "short"
      assert ToolCatalog.prompt_line(%{description: "long"}) == "long"
    end

    test "the MCP/pi channel still carries the full descriptions" do
      manifest = ToolCatalog.pi_manifest()
      start_adw = Enum.find(manifest, &(&1.name == "start_adw"))
      assert start_adw.description =~ "Two modes by `harness`"

      # Every catalog tool keeps a non-empty description for the tool channel.
      assert Enum.all?(ToolCatalog.tools(), &(String.trim(&1.description) != ""))
    end
  end
end
