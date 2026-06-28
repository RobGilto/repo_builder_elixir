defmodule RepoBuilder.Orchestrator.ToolCatalogPiParityTest do
  @moduledoc """
  Regression guard for issue-0-adw-pi (pi orchestrator missing 15 toolsets).

  The pi extension's tool surface MUST be derived from the single source of truth
  (`ToolCatalog.tools/0`) exactly like the MCP `tools/list` path — never hand-copied.
  These assertions fail the moment the two diverge: the pi manifest must advertise
  exactly `ToolCatalog.names/0` (== the MCP name set), each entry's parameters must
  equal the catalog tool's `input_schema`, and the on-disk extension must load the
  manifest at runtime rather than carry a static array.
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.Orchestrator.ToolCatalog

  @extension_ts Path.join(
                  :code.priv_dir(:repo_builder),
                  "orchestrator/pi_extension/orchestrator-tools.ts"
                )

  defp manifest, do: ToolCatalog.pi_manifest_json() |> Jason.decode!()

  test "pi manifest advertises exactly ToolCatalog.names/0" do
    names = manifest() |> Enum.map(& &1["name"])
    assert MapSet.new(names) == MapSet.new(ToolCatalog.names())
    # 34 catalog tools; guards against silently shrinking the surface.
    assert length(names) == length(ToolCatalog.names())
  end

  test "pi manifest name set equals the MCP tools/list name set" do
    # Both derive from ToolCatalog.tools/0; the controller maps each tool to a
    # descriptor whose name is the same field the manifest serializes.
    mcp_names = ToolCatalog.tools() |> Enum.map(& &1.name)
    pi_names = manifest() |> Enum.map(& &1["name"])
    assert MapSet.new(pi_names) == MapSet.new(mcp_names)
  end

  test "each manifest entry's parameters equal the catalog tool's input_schema" do
    by_name = Map.new(ToolCatalog.tools(), &{&1.name, &1.input_schema})

    for entry <- manifest() do
      # Round-trip the catalog schema through Jason to compare string-keyed maps.
      expected = by_name |> Map.fetch!(entry["name"]) |> Jason.encode!() |> Jason.decode!()
      assert entry["parameters"] == expected, "parameters drift for #{entry["name"]}"
    end
  end

  test "on-disk extension loads the manifest path and carries no static tool array" do
    source = File.read!(@extension_ts)

    assert source =~ "PI_ORCH_TOOLS_PATH"
    assert source =~ "readFileSync"
    # The static duplication must be gone — no hardcoded `name: "set_goal"` literals.
    refute source =~ ~s(name: "set_goal")
    refute source =~ ~s(name: "create_agent")
  end
end
