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
    # 36 catalog tools; guards against silently shrinking the surface.
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

  test "no tool schema uses an array-valued JSON-Schema `type` (pi-incompatible)" do
    # pi's parameter validator rejects a union `type` like ["integer","string"]; a
    # rejection truncates the pi orchestrator's toolset at registration. Guard the
    # whole catalog so the class cannot be reintroduced (regression: get_logs.numbers).
    for tool <- ToolCatalog.tools() do
      offenders = list_typed_paths(tool.input_schema, [tool.name])

      assert offenders == [],
             "tool #{tool.name} has an array-valued `type` at: #{inspect(offenders)}"
    end
  end

  test "on-disk extension isolates each tool registration in try/catch" do
    source = File.read!(@extension_ts)

    # One rejected tool must not abort the registration loop and drop the tail.
    assert source =~ "registerTool"
    assert source =~ "try {"
    assert source =~ "catch"
  end

  # Walk a string/atom-keyed JSON-Schema map and collect the paths where a `type`
  # key holds a list (an array-valued type union). Returns [] when the schema is clean.
  @spec list_typed_paths(term(), [String.t()]) :: [[String.t()]]
  defp list_typed_paths(schema, path) when is_map(schema) do
    here =
      case Map.get(schema, "type") do
        list when is_list(list) -> [Enum.reverse(path)]
        _ -> []
      end

    nested =
      schema
      |> Enum.flat_map(fn {key, value} ->
        list_typed_paths(value, [to_string(key) | path])
      end)

    here ++ nested
  end

  defp list_typed_paths(schema, path) when is_list(schema) do
    schema
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, idx} ->
      list_typed_paths(value, ["[#{idx}]" | path])
    end)
  end

  defp list_typed_paths(_schema, _path), do: []
end
