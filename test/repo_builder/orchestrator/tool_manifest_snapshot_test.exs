defmodule RepoBuilder.Orchestrator.ToolManifestSnapshotTest do
  @moduledoc """
  Byte-stability snapshot of the LLM-facing orchestrator tool manifest
  (audit F3 / roadmap Phase 3.3). `ToolCatalog.tools/0` is the single source of
  truth both harness bindings advertise (the MCP `tools/list` response and the pi
  extension manifest), so ANY drift in a tool's name, description, or JSON-Schema
  input silently changes what every orchestrator brain is told it can do.

  The committed fixture was rendered from the catalog as it stood BEFORE the
  `Orchestrator.Tools` decomposition; this test fails the gate on any future
  drift. If a manifest change is INTENTIONAL, regenerate the fixture with:

      mix run --no-start -e '
        manifest = RepoBuilder.Orchestrator.ToolCatalog.tools() |> Jason.encode!(pretty: true)
        File.write!("test/support/fixtures/orchestrator/tool_manifest.json", manifest <> "\n")'
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.Orchestrator.ToolCatalog

  @fixture_path Path.expand("../../support/fixtures/orchestrator/tool_manifest.json", __DIR__)

  test "rendered tool manifest matches the committed snapshot byte-for-byte" do
    rendered = Jason.encode!(ToolCatalog.tools(), pretty: true) <> "\n"
    committed = File.read!(@fixture_path)

    assert rendered == committed,
           "ToolCatalog manifest drifted from test/support/fixtures/orchestrator/" <>
             "tool_manifest.json — if intentional, regenerate the fixture (see @moduledoc)"
  end

  test "pi manifest stays a pure projection of the same catalog" do
    assert ToolCatalog.pi_manifest() ==
             Enum.map(ToolCatalog.tools(), fn tool ->
               %{name: tool.name, description: tool.description, parameters: tool.input_schema}
             end)
  end
end
