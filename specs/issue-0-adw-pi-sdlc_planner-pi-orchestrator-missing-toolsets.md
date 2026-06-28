# Bug: pi orchestrator agent is missing 15 toolsets that the Claude orchestrator advertises

## Metadata
issue_number: `0`
adw_id: `pi`
issue_json: `orchestrator`

## Bug Description
When the orchestrator runs on the **pi** harness it is missing whole families of
agent-management tools that the **Claude** orchestrator has. Comparing the live console
event stream from `log-26477` onwards (a Claude orchestrator run) against a pi
orchestrator run, the Claude orchestrator can call `set_goal`, `record_progress`,
`get_ledger`, `report_complete`, `inspect_repo`, `record_reflection`, the entire
workstream suite (`create_workstream`, `plan_phases`, `record_stage`,
`list_workstreams`, `get_workstream`, `close_workstream`, `compact_self`), plus
`list_apis` and `clear_context` — but the pi orchestrator has **none of these tools
registered**, so it cannot drive the autonomous self-healing loop or run
spec-driven phased workstreams at all.

**Expected:** Both bindings advertise the IDENTICAL tool set, exactly as
`RepoBuilder.Orchestrator.ToolCatalog`'s `@moduledoc` already promises:

> Both bindings advertise the IDENTICAL tools from here: the MCP `tools/list` response
> (`RepoBuilderWeb.OrchestratorMCPController`) and the pi extension manifest
> (`priv/orchestrator/pi_extension`).

**Actual:** The Claude/MCP path advertises all 34 catalog tools (it is generated from
`ToolCatalog.tools()`), but the pi extension hardcodes a stale 19-tool subset, so a pi
orchestrator silently loses 15 tools and several tool parameters.

## Problem Statement
The pi orchestrator's tool surface is defined by a **hand-maintained static TypeScript
array** in `priv/orchestrator/pi_extension/orchestrator-tools.ts` that duplicates
`ToolCatalog.tools()`. The MCP `tools/list` path
(`lib/repo_builder_web/controllers/orchestrator_mcp_controller.ex:52`) derives its tool
list from `ToolCatalog.tools()` and is therefore always complete; the pi extension does
not, so it inevitably drifts. There is **no mechanism keeping the two in sync and no test
guarding the invariant**, which is why the self-healing tools (commit `70952cc`) and the
workstream tools (commit `de59371`) — added to `ToolCatalog` but never mirrored into the
TypeScript array — are absent on pi.

## Solution Statement
Eliminate the duplication: make the pi extension derive its tool definitions from the
**single source of truth** (`ToolCatalog.tools()`) instead of a hardcoded array, and add a
parity test that fails if the two ever diverge again.

Approach (drift-proof, deterministic, Elixir-controlled — mirrors how
`Harness.Claude.orchestrator_spawn/2` already writes `.mcp.json`):

1. Add `ToolCatalog.pi_manifest_json/0` that serializes every catalog tool into pi's
   `registerTool` shape (`name` / `description` / `parameters`, where `parameters` is the
   tool's `input_schema`).
2. In `RepoBuilder.Harness.Pi.orchestrator_spawn/2`, write that JSON to the session cwd
   (e.g. `.pi-orch-tools.json`) and pass its absolute path to the extension via a new env
   var `PI_ORCH_TOOLS_PATH` (path in env, consistent with the existing token-in-env rule).
3. Rewrite `orchestrator-tools.ts` to `readFileSync` that JSON at load and register each
   tool dynamically (generic `execute` that forwards to `tools/call`), deleting the static
   array entirely so future catalog changes propagate automatically.
4. Add an Elixir parity test asserting the pi manifest's tool-name set equals
   `ToolCatalog.names()` (and equals the MCP `tools/list` set), so any future tool added to
   the catalog is automatically available on pi and the regression cannot recur.

This is surgical: tool **dispatch** already lives server-side in
`RepoBuilder.Orchestrator.Tools` (the extension only forwards `tools/call`), so once the
manifest advertises a tool, it is immediately callable — no per-tool handler code is
needed.

## Steps to Reproduce
1. Start the app (`scripts/pg.sh start` then `mix phx.server`).
2. Configure an orchestrator to run on the **pi** harness.
3. In the console, observe the pi orchestrator's available tools (or compare against a
   Claude orchestrator run around `log-26477`+).
4. Observe that the pi orchestrator cannot call `set_goal` / `record_progress` /
   `create_workstream` / `report_complete` etc. — the autonomous drive loop never advances
   because the tools it depends on are not registered.
5. Confirm statically: the names in
   `priv/orchestrator/pi_extension/orchestrator-tools.ts` `tools` array (19) ≠
   `RepoBuilder.Orchestrator.ToolCatalog.names()` (34). Missing on pi: `list_apis`,
   `clear_context`, `set_goal`, `record_progress`, `get_ledger`, `report_complete`,
   `inspect_repo`, `record_reflection`, `create_workstream`, `plan_phases`, `record_stage`,
   `list_workstreams`, `get_workstream`, `close_workstream`, `compact_self`. Also drifted
   params: `create_agent` (missing `category`/`tools`/`apis`), `command_agent` (missing
   `workstream`/`apis`), `update_agent` (missing `tools`), `start_adw` (stale enum, missing
   `adw` harness mode + `working_dir`).

   Reproduce the gap as a failing assertion via Tidewave `project_eval`:
   ```elixir
   pi_names =
     "priv/orchestrator/pi_extension/orchestrator-tools.ts"
     |> File.read!()
     |> then(&Regex.scan(~r/name:\s*"([a-z_]+)"/, &1))
     |> Enum.map(fn [_, n] -> n end)
     |> Enum.uniq()

   MapSet.difference(MapSet.new(RepoBuilder.Orchestrator.ToolCatalog.names()), MapSet.new(pi_names))
   # => the 15 missing tool names
   ```

## Root Cause Analysis
The pi harness ships no MCP (BUILD_PROMPT.md §4.3 / §10); its orchestrator tools are
registered by a TypeScript extension loaded with `-e`
(`Harness.Pi.orchestrator_spawn/2`, `lib/repo_builder/harness/pi.ex:31-53`). That
extension (`orchestrator-tools.ts`) hardcodes a `tools` array that **manually duplicates**
`ToolCatalog.tools()`. Because the duplication is manual and unguarded:

- Commit `70952cc` (self-healing) added `set_goal`, `record_progress`, `get_ledger`,
  `report_complete`, `inspect_repo`, `record_reflection` to `ToolCatalog` — never mirrored
  into the TS array.
- Commit `de59371` (workstreams) added `create_workstream`, `plan_phases`, `record_stage`,
  `list_workstreams`, `get_workstream`, `close_workstream`, `compact_self` — never
  mirrored.
- The external-API work added `list_apis` (+ `apis`/`tools` params and `clear_context`) —
  never mirrored.

The Claude path is generated from the catalog
(`orchestrator_mcp_controller.ex:52`), so it never drifts. The pi path is the only
hand-copied surface, so it is the only one that loses tools. **Root cause: a manually
duplicated tool manifest with no single-source-of-truth derivation and no parity test.**

## Relevant Files
Use these files to fix the bug:

- `lib/repo_builder/orchestrator/tool_catalog.ex` — the single source of truth for tool
  defs. Add `pi_manifest_json/0` (serialize `tools()` to pi's `name/description/parameters`
  shape).
- `priv/orchestrator/pi_extension/orchestrator-tools.ts` — the drifted static manifest.
  Replace the hardcoded `tools` array with a `readFileSync(PI_ORCH_TOOLS_PATH)` load + a
  generic registration loop; keep the existing `callTool`/`tools/call` forwarding.
- `lib/repo_builder/harness/pi.ex` — `orchestrator_spawn/2`. Write the generated manifest to
  the session cwd and inject `PI_ORCH_TOOLS_PATH` (absolute path) into the extension env
  alongside `PI_ORCH_BASE_URL`/`PI_ORCH_TOKEN`. Mirror Claude's `.mcp.json` write pattern
  (`mkdir_p!` + absolute path) so a relative path is not resolved twice.
- `lib/repo_builder_web/controllers/orchestrator_mcp_controller.ex` — reference only; its
  `tools/list` (line 52) is the correct, catalog-derived behaviour the pi path must match.
- `lib/repo_builder/orchestrator/tools.ex` — reference only; confirms server-side dispatch
  exists for every catalog tool, so advertising them is sufficient (no new handlers).
- `test/repo_builder/harness/orchestrator_tool_restriction_test.exs`,
  `test/repo_builder/harness/orchestrating_test.exs` — existing harness-binding tests to
  model the new test's setup on.

### New Files
- `test/repo_builder/orchestrator/tool_catalog_pi_parity_test.exs` — asserts the pi manifest
  (`ToolCatalog.pi_manifest_json/0` decoded) advertises exactly `ToolCatalog.names()`, that
  it equals the MCP `tools/list` name set, and that the on-disk
  `priv/orchestrator/pi_extension/orchestrator-tools.ts` no longer carries a hardcoded tool
  array (i.e. it reads the manifest path) — guarding against re-introducing the drift.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Reproduce and confirm the gap
- Read `lib/repo_builder/orchestrator/tool_catalog.ex`,
  `priv/orchestrator/pi_extension/orchestrator-tools.ts`, and
  `lib/repo_builder/harness/pi.ex` to confirm the 15-tool delta and the spawn env wiring.
- Optionally run the `project_eval` snippet from "Steps to Reproduce" via Tidewave to print
  the exact missing-name set as the pre-fix baseline.

### 2. Add a single-source-of-truth serializer to ToolCatalog
- In `lib/repo_builder/orchestrator/tool_catalog.ex`, add:
  - `@spec pi_manifest/0 :: [%{name: String.t(), description: String.t(), parameters: map()}]`
    mapping each `tool_def()` to `%{name:, description:, parameters: input_schema}`.
  - `@spec pi_manifest_json/0 :: String.t()` returning `Jason.encode!(pi_manifest())`.
- Keep it pure data (no side effects), preserving the existing typed style and `@spec`s.

### 3. Write the manifest at spawn and inject the path (Harness.Pi)
- In `RepoBuilder.Harness.Pi.orchestrator_spawn/2`
  (`lib/repo_builder/harness/pi.ex`), before building `args`/`env`:
  - Compute `cwd = Path.expand(ctx.cwd)`, `path = Path.join(cwd, ".pi-orch-tools.json")`,
    `File.mkdir_p!(cwd)`, `File.write!(path, ToolCatalog.pi_manifest_json())` — mirroring
    `Harness.Claude.orchestrator_spawn/2`'s `.mcp.json` write.
  - Add `alias RepoBuilder.Orchestrator.ToolCatalog` to the module.
- Append `{"PI_ORCH_TOOLS_PATH", path}` to the returned `env`.
- Confirm `tool_ctx()` carries `:cwd` (Claude's spawn uses `ctx.cwd`); if pi's spawn does
  not currently receive cwd, thread it through the same way Claude does — do not invent a
  new field.

### 4. Rewrite the pi extension to load the manifest dynamically
- In `priv/orchestrator/pi_extension/orchestrator-tools.ts`:
  - Delete the hardcoded `tools` array.
  - At module load, read `process.env.PI_ORCH_TOOLS_PATH`, `readFileSync(path, "utf8")`,
    `JSON.parse` into `Array<{ name; description; parameters }>`.
  - Register each tool in the existing `export default function (pi)` loop, reusing the
    current generic `execute` that forwards to `callTool(tool.name, params)`.
  - Guard an empty/missing path gracefully (register nothing rather than throwing at load).
  - Update the moduledoc comment to state tools are now sourced from
    `ToolCatalog.pi_manifest_json/0` via `PI_ORCH_TOOLS_PATH`, removing the
    "Mirror RepoBuilder.Orchestrator.ToolCatalog" hand-sync note.

### 5. Add the parity regression test
- Create `test/repo_builder/orchestrator/tool_catalog_pi_parity_test.exs`:
  - `pi_manifest_json/0` decodes to a list whose `"name"` set == `ToolCatalog.names()`.
  - The pi manifest name set == the MCP `tools/list` name set (decode the controller's
    `tools/list` descriptors, or assert both derive from `ToolCatalog.tools()`).
  - Each manifest entry's `"parameters"` equals the catalog tool's `input_schema`
    (round-trip through `Jason` to compare string-keyed maps).
  - The on-disk `orchestrator-tools.ts` contains `PI_ORCH_TOOLS_PATH` and does NOT contain
    a hardcoded `name: "set_goal"`-style array (assert the static duplication is gone).

### 6. Verify the spawn wiring with a focused harness test
- Extend (or add alongside) `test/repo_builder/harness/orchestrating_test.exs` /
  `orchestrator_tool_restriction_test.exs` to assert `Harness.Pi.orchestrator_spawn/2`:
  - writes `.pi-orch-tools.json` containing all `ToolCatalog.names()`, and
  - returns `PI_ORCH_TOOLS_PATH` (absolute) in its env.

### 7. Run the full validation suite
- Run every command in "Validation Commands" and confirm zero failures/warnings.

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- `mix test test/repo_builder/orchestrator/tool_catalog_pi_parity_test.exs` — the new parity
  test fails before the fix (manifest is missing 15 names) and passes after.
- `mix test test/repo_builder/harness/orchestrating_test.exs test/repo_builder/harness/orchestrator_tool_restriction_test.exs` —
  the spawn wiring writes the manifest and injects `PI_ORCH_TOOLS_PATH`.
- `mix compile --warnings-as-errors` — clean compile; gradual set-theoretic checker and
  `warnings_as_errors` pass.
- `mix test --warnings-as-errors` — full ExUnit suite green (no regressions across the
  orchestrator/harness suites).
- `mix format --check-formatted` — formatting.
- `mix credo --strict` — lint, including the `@spec`-on-every-public-function gate
  (`pi_manifest/0`, `pi_manifest_json/0` must carry `@spec`s).
- `mix dialyzer` — no new contract warnings, no stale ignore filters.
- Post-fix sanity (Tidewave `project_eval`):
  `MapSet.equal?(MapSet.new(RepoBuilder.Orchestrator.ToolCatalog.names()), MapSet.new(Enum.map(Jason.decode!(RepoBuilder.Orchestrator.ToolCatalog.pi_manifest_json()), & &1["name"])))`
  returns `true`.

## Notes
- No new dependencies. `Jason` is already used throughout the harness layer.
- This is **not** a LiveView UI bug — the defect is in the harness/extension tool-binding
  layer, so no `Phoenix.LiveViewTest` is required.
- Server-side dispatch for every advertised tool already exists in
  `RepoBuilder.Orchestrator.Tools` (the catalog's tools are all wired for `tools/call`), so
  advertising the missing tools is sufficient to make them callable — no new handler logic.
- The TypeScript extension is loaded at runtime by the pi CLI, not compiled by `mix`, so the
  Elixir-side parity test (Step 5) is the durable regression guard; it reads the `.ts` file
  text to ensure the static array cannot be reintroduced.
- After the fix, the worker-facing pi path (`worker_mcp_args/1`) is unchanged — this bug and
  fix are scoped strictly to the orchestrator spawn (`orchestrator_spawn/2`) and its
  extension manifest.
- Keep the env contract consistent with the existing rule: secrets/tokens ride in env, never
  argv; `PI_ORCH_TOOLS_PATH` is a path (not a secret) but follows the same env-injection
  pattern for uniformity.
