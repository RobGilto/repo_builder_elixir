defmodule RepoBuilder.Adw.GeneratedDriftTest do
  @moduledoc """
  Drift gate for GENERATED ADW combo scripts (audit F5, roadmap Phase 4.2): every
  sidecar-backed combo under `adws/.combos/` must byte-match a fresh
  `Scaffold.render/1` of its definition — a hand-edit to a generated `.py` (or a
  template change without regeneration) fails the gate instead of silently drifting.

  Scope note (recorded in the audit plan's Amendments): the legacy hand-written
  `adws/adw_*_iso.py` scripts are deliberately NOT under this gate — Phase 2's
  ship-to-trunk blocks intentionally diverged the five plan_build* composites from
  the plain template, and the phase scripts (plan/build/test/…) were never
  generated. Only sidecar-backed combos are contract-bound to the generator.
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.Adw.{Combos, Scaffold}

  @root File.cwd!()

  test "every sidecar-backed combo script matches its Scaffold render byte-for-byte" do
    for combo <- Combos.list(@root) do
      assert {:ok, rendered} =
               Scaffold.render(%{name: combo.name, steps: combo.steps, flavor: combo.flavor})

      # Deterministic path from the definition (sidecars may carry a stale absolute
      # path from another checkout).
      script = Scaffold.script_path(%{root: @root}, combo.name, combo.flavor)

      assert File.exists?(script),
             "combo #{combo.name}: generated script missing at #{combo.script_path}"

      assert File.read!(script) == rendered,
             "combo #{combo.name}: #{combo.script_path} drifted from its Scaffold render — " <>
               "regenerate via Combos.save/2 (overwrite: true) or revert the hand-edit"
    end
  end
end
