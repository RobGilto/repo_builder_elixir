defmodule RepoBuilder.ModuleSizeTest do
  @moduledoc """
  Regression guard for the god-module decomposition (docs/audit-2026-07.md F3,
  roadmap Phase 3): the three files that had absorbed every console/orchestrator
  feature must not silently regrow. New console features belong in a panel module
  (`console_live/`, `components/console/`) or a tools domain module (`tools/`) —
  if a legitimate change trips a cap, extract first, don't raise the cap.
  """
  use ExUnit.Case, async: true

  # Caps are set with ~15% headroom over the post-decomposition size.
  @caps %{
    "lib/repo_builder_web/live/console_live.ex" => 2_700,
    "lib/repo_builder_web/components/console_components.ex" => 1_000,
    "lib/repo_builder/orchestrator/tools.ex" => 400
  }

  for {path, cap} <- @caps do
    test "#{path} stays under #{cap} lines" do
      path = unquote(path)
      cap = unquote(cap)
      lines = path |> File.read!() |> String.split("\n") |> length()

      assert lines <= cap,
             "#{path} is #{lines} lines (cap #{cap}). Extract into a panel/domain module " <>
               "instead of growing this file — see docs/audit-2026-07.md F3."
    end
  end
end
