defmodule RepoBuilder.Orchestrator.UiEvidenceTest do
  @moduledoc """
  The `:ui_ux` test-stage evidence router (orchestrator-iterative-ui-ux-polish-phase,
  Phase 4): picks the right capture per surface, routes artifacts to the right report dir,
  and always hands the fix loop a concrete failure note.
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.Orchestrator.UiEvidence

  describe "contract/1" do
    test "web uses the playwright-cli gate into playwright-reports/" do
      c = UiEvidence.contract(:web)
      assert c.capture == :playwright
      assert c.tool == "playwright-cli"
      assert c.report_dir == "playwright-reports"
      assert Enum.any?(c.rubric, &(&1 =~ "console"))
    end

    test "tui uses a terminal snapshot" do
      c = UiEvidence.contract(:tui)
      assert c.capture == :terminal_snapshot
      assert c.report_dir == "tui-snapshots"
    end

    test "desktop uses a window screenshot with an honest-block harness note" do
      c = UiEvidence.contract(:desktop)
      assert c.capture == :window_screenshot
      assert c.harness_note =~ "never fake a pass"
    end
  end

  describe "test_stage_attrs/3" do
    test "a passed capture routes the report path as the artifact, no forced note" do
      attrs =
        UiEvidence.test_stage_attrs(:web, :passed,
          report_path: "playwright-reports/2026/01-home.png"
        )

      assert attrs.stage == "test"
      assert attrs.outcome == "passed"
      assert attrs.artifact == "playwright-reports/2026/01-home.png"
      assert attrs.note == nil
    end

    test "a failed capture backfills a concrete rubric-derived note for the fix loop" do
      attrs = UiEvidence.test_stage_attrs(:web, :failed, [])

      assert attrs.outcome == "failed"
      assert is_binary(attrs.note)
      assert attrs.note =~ "rubric"
    end

    test "a caller-supplied note wins over the default" do
      attrs = UiEvidence.test_stage_attrs(:tui, :failed, note: "footer missing")
      assert attrs.note == "footer missing"
    end

    test "a blocked desktop capture records why, never a silent skip" do
      attrs = UiEvidence.test_stage_attrs(:desktop, :blocked, [])
      assert attrs.outcome == "blocked"
      assert attrs.note =~ "blocked"
    end
  end

  describe "report_dir/1" do
    test "maps each surface to its artifact dir" do
      assert UiEvidence.report_dir(:web) == "playwright-reports"
      assert UiEvidence.report_dir(:tui) == "tui-snapshots"
      assert UiEvidence.report_dir(:desktop) == "desktop-screenshots"
    end
  end
end
