defmodule RepoBuilder.Orchestrator.UiEvidence do
  @moduledoc """
  The `:ui_ux` phase's TEST-STAGE evidence router (iterative-ui-ux polish phase, Phase 4).

  A UI/UX phase's `test` stage must produce REAL evidence per surface — not a self-report —
  and, on a failed rubric, a concrete failure note that drives the review→fix loop. This
  module is the pure, harness-agnostic decision layer: given a `surface` it names the capture
  contract (which tool, where artifacts land, the rubric to judge), and given an outcome it
  builds the `record_stage(stage: "test", …)` attrs (the artifact path + note). It performs
  NO IO — the worker (Claude or `pi`) runs the actual `playwright-cli` / snapshot capture; this
  keeps the gate deterministic and identical across harnesses.

  Every function is `@spec`'d and total.
  """

  alias RepoBuilder.Orchestrator.WorkstreamPhase

  @type surface :: WorkstreamPhase.surface()
  @type outcome :: :passed | :failed | :blocked

  @typedoc "The per-surface evidence contract the worker must satisfy for the test stage."
  @type contract :: %{
          surface: surface(),
          capture: atom(),
          tool: String.t(),
          report_dir: String.t(),
          rubric: [String.t()],
          harness_note: String.t()
        }

  # Where each surface's evidence artifacts are written, relative to the repo root. Web reuses
  # the existing `playwright-reports/` seam; the others get parallel dirs.
  @report_dirs %{
    web: "playwright-reports",
    tui: "tui-snapshots",
    desktop: "desktop-screenshots"
  }

  @doc """
  The evidence CONTRACT for `surface`: the capture kind, the harness-agnostic tool that
  produces it, where artifacts are written, and the UX rubric that decides pass/fail.
  """
  @spec contract(surface()) :: contract()
  def contract(:web) do
    %{
      surface: :web,
      capture: :playwright,
      tool: "playwright-cli",
      report_dir: @report_dirs.web,
      rubric: [
        "primary navigation reachable (no dead ends)",
        "focus visible + keyboard operable",
        "no console errors",
        "no failed network requests",
        "AA contrast + clear visual hierarchy",
        "none of the AI-slop tells"
      ],
      harness_note:
        "Drive the built app with the playwright-cli shell tool (works under Claude AND pi): " <>
          "capture a screenshot + accessibility snapshot + console + network logs, and emit a " <>
          "durable .spec.ts smoke test. On failure, Claude workers may deepen diagnosis with " <>
          "chrome-devtools-mcp / Tidewave browser_eval — enrichment only, never the gate."
    }
  end

  def contract(:tui) do
    %{
      surface: :tui,
      capture: :terminal_snapshot,
      tool: "terminal snapshot",
      report_dir: @report_dirs.tui,
      rubric: [
        "layout fits a standard 80x24 terminal (no overflow)",
        "key bindings discoverable (footer/help present)",
        "focus/selection indicator visible",
        "readable with NO_COLOR / no-color fallback"
      ],
      harness_note:
        "Capture the rendered terminal output as the artifact; assert the tui-ux-polish " <>
          "layout + keybinding invariants."
    }
  end

  def contract(:desktop) do
    %{
      surface: :desktop,
      capture: :window_screenshot,
      tool: "window screenshot",
      report_dir: @report_dirs.desktop,
      rubric: [
        "native window/menu conventions present",
        "standard keyboard shortcuts wired",
        "sensible information density + resizable layout"
      ],
      harness_note:
        "Capture a window screenshot where the harness can launch the app; if it cannot " <>
          "launch here, record the stage BLOCKED with a clear reason — never fake a pass."
    }
  end

  @doc """
  Build the `record_stage(stage: "test", …)` attrs for a `:ui_ux` phase's test outcome on
  `surface`. `report_path` (the captured evidence path) becomes the stage `artifact`. On a
  `:failed`/`:blocked` outcome a concrete `note` is REQUIRED so the fix loop has a cause — a
  blank one is backfilled with a rubric-derived default. Returns a map ready to pass through
  to `Workstreams.record_stage/3`.
  """
  @spec test_stage_attrs(surface(), outcome(), keyword()) :: %{
          stage: String.t(),
          outcome: String.t(),
          artifact: String.t() | nil,
          note: String.t() | nil
        }
  def test_stage_attrs(surface, outcome, opts \\ [])
      when surface in [:web, :desktop, :tui] and outcome in [:passed, :failed, :blocked] do
    report_path = opts |> Keyword.get(:report_path) |> blank_to_nil()
    note = opts |> Keyword.get(:note) |> blank_to_nil()

    %{
      stage: "test",
      outcome: to_string(outcome),
      artifact: report_path,
      note: note || default_note(surface, outcome)
    }
  end

  @doc "The evidence artifact directory for `surface` (relative to the repo root)."
  @spec report_dir(surface()) :: String.t()
  def report_dir(surface) when surface in [:web, :desktop, :tui],
    do: Map.fetch!(@report_dirs, surface)

  # A rubric-derived note when the worker supplied none: passed ⇒ nil (no note needed),
  # failed/blocked ⇒ a concrete first rubric item so the fix loop is never handed a bare "failed".
  @spec default_note(surface(), outcome()) :: String.t() | nil
  defp default_note(_surface, :passed), do: nil

  defp default_note(surface, :blocked),
    do: "#{surface} evidence capture blocked — record why (e.g. app could not launch here)."

  defp default_note(surface, :failed) do
    first_rubric = surface |> contract() |> Map.fetch!(:rubric) |> List.first()
    "#{surface} UX rubric failed (e.g. #{first_rubric}) — fix and re-review."
  end

  @spec blank_to_nil(term()) :: String.t() | nil
  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      _trimmed -> value
    end
  end

  defp blank_to_nil(_value), do: nil
end
