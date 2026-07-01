# Bug: pi-harness orchestrator silently loses its tail of tools (no parity with Claude)

## Metadata
issue_number: `noticed`
adw_id: `that`
issue_json: `Pi`

## Bug Description
When an orchestrator runs on the **pi** harness, it is missing tools that the
**Claude** orchestrator has. A pi (zai/GLM) orchestrator reported:

> `inspect_repo` isn't wired into my toolset, and my earlier generic-scout spawns
> failed on the claude harness (which is also what errored out `wall-base-aligner`
> and `wall-collision-fixer-2`). That's the real signal: the claude harness is
> flaky this session, and I was re-dispatching vague scouts with no concrete
> mandate.

**Expected:** the pi orchestrator advertises the EXACT same agent-management tool
surface as the Claude orchestrator — both bindings are derived from the single
source of truth `RepoBuilder.Orchestrator.ToolCatalog`. The platform invariant
(see `RepoBuilder.Orchestrator.ToolCatalogPiParityTest`) is that the MCP
`tools/list` path and the pi extension manifest never drift.

**Actual:** the pi orchestrator is missing `inspect_repo` and (per its symptoms)
the whole tail of the catalog after a certain point — the verification tool
(`inspect_repo`), the reflection tool, and the entire workstream/phase
orchestration set (`create_workstream`, `plan_phases`, `record_stage`,
`list_workstreams`, `get_workstream`, `close_workstream`, `compact_self`). With
`inspect_repo` and the workstream tools gone, the pi orchestrator cannot verify
worker output against the real tree and cannot run spec→implement→test→review
phases, so it falls back to re-dispatching "vague scouts with no concrete
mandate" — exactly the degraded behaviour described. The agent misattributed the
failure to "the claude harness is flaky"; the actual defect is its own missing
toolset.

## Problem Statement
The pi extension (`priv/orchestrator/pi_extension/orchestrator-tools.ts`) loads
the tool manifest correctly (the Elixir parity test proves all 34 tools — including
`inspect_repo` — are present in `ToolCatalog.pi_manifest_json/0`), but registers
the tools one-by-one in a `for` loop with **no error isolation**. When pi's
parameter validator rejects ONE tool's JSON Schema at `pi.registerTool(...)`, the
exception propagates out of the loop and **every tool after the rejected one is
silently never registered**. The orchestrator boots "cleanly" with a truncated
toolset and no diagnostic.

The tool that pi rejects is `get_logs`: its `numbers` property uses a JSON-Schema
**type-union array** —

```elixir
"numbers" => %{
  "type" => "array",
  "items" => %{"type" => ["integer", "string"]},   # <-- array-valued `type`
  ...
}
```

`get_logs` is at index 10 in `ToolCatalog.tools/0`. `inspect_repo` is at index 25,
and the workstream tools are 27–33 — all AFTER `get_logs`. A throw on `get_logs`'s
schema therefore drops precisely the tools the orchestrator reported missing.
(Claude reaches MCP natively and its `tools/list` validator accepts draft-07
union types, so Claude is unaffected — hence the asymmetry / "missing parity".)

## Solution Statement
Two surgical changes, addressing root cause and the failure-amplifier:

1. **Root cause — make every catalog schema pi-safe.** Replace the union
   `"type" => ["integer", "string"]` on `get_logs.numbers.items` with a single
   pi-compatible type (`"string"`), updating the description to note bare-integer
   forms are accepted. This is safe for both bindings: the Elixir handler's
   `parse_log_no/1` already accepts integers AND `"log-<n>"`/`"<n>"` strings
   (`lib/repo_builder/orchestrator/tools.ex:1552`), and string is valid draft-07
   so the MCP path is unaffected.

2. **Defense-in-depth — isolate per-tool registration in the extension.** Wrap
   each `pi.registerTool(...)` call in a `try/catch` so a single rejected tool can
   never again silently truncate the rest of the toolset; log the rejected tool
   name to stderr for diagnosability. This converts a catastrophic "lose the tail"
   failure into an isolated "lose one tool, keep the rest" failure and surfaces it.

3. **Regression guards.** Extend the existing parity test with (a) a hard
   assertion that NO catalog `input_schema` uses an array-valued `type` anywhere
   (the pi-incompatibility class), and (b) a source assertion that the extension
   wraps registration in `try`/`catch`.

This is the minimal change set that restores parity AND prevents the entire class
from recurring.

## Steps to Reproduce
1. Configure an orchestrator to run on the `pi` harness (any provider, e.g. zai/GLM).
2. Start the orchestrator; it spawns via `RepoBuilder.Harness.Pi.orchestrator_spawn/2`,
   which writes `ToolCatalog.pi_manifest_json/0` to `.pi-orch-tools.json` and the
   pi extension loads it.
3. Ask the orchestrator to verify a worker's output, or instruct it to call
   `inspect_repo` / open a workstream.
4. **Observed:** the orchestrator reports `inspect_repo` (and the workstream tools)
   are not in its toolset; it cannot verify against the tree and degrades to
   re-dispatching unscoped scouts.
5. **Manifest-level reproduction (no pi runtime needed):** the manifest *contains*
   all tools (`ToolCatalog.pi_manifest_json/0` decodes to 34 entries), but the
   manifest also contains the array-valued `type` that pi rejects at registration —
   confirming the truncation happens at pi's `registerTool`, not in the Elixir
   manifest.

## Root Cause Analysis
- The tool surface is correctly single-sourced: `ToolCatalog.tools/0` →
  `pi_manifest/0` → `pi_manifest_json/0` → `.pi-orch-tools.json` →
  `loadTools()` in the extension. The Elixir parity test confirms all 34 tools and
  their schemas reach the manifest intact. So the manifest is NOT the defect.
- The defect is at runtime in `orchestrator-tools.ts`:
  ```ts
  for (const tool of tools) {
    pi.registerTool({ name, label, description, parameters: tool.parameters, execute });
  }
  ```
  There is no `try/catch`. If `pi.registerTool` throws for any tool, the loop dies
  and all subsequent tools are dropped — a silent, order-dependent truncation.
- The tool that triggers the throw is `get_logs`, whose
  `numbers.items.type = ["integer","string"]` is a JSON-Schema union type. pi's
  parameter validator does not accept an array-valued `type`. `get_logs` precedes
  `inspect_repo` and all workstream tools in catalog order, so those are exactly
  the tools that vanish — matching the report.
- Claude is unaffected because it consumes the IDENTICAL schema over MCP, where the
  validator accepts draft-07 union types — which is why this surfaces as a pi-only
  parity gap.

## Relevant Files
Use these files to fix the bug:

- `lib/repo_builder/orchestrator/tool_catalog.ex` — **the source of the
  pi-incompatible schema.** `get_logs` (~line 246) declares
  `"items" => %{"type" => ["integer", "string"]}`. This is the one place to fix the
  root cause; both bindings re-derive from here.
- `priv/orchestrator/pi_extension/orchestrator-tools.ts` — **the failure
  amplifier.** The `for ... pi.registerTool` loop (lines ~103–114) lacks error
  isolation; wrap each registration in `try/catch` and log failures to stderr.
- `lib/repo_builder/orchestrator/tools.ex` — **confirms the fix is safe.**
  `dispatch("get_logs", ...)` (line 130) → `get_logs/1` (line 1475) →
  `parse_log_no/1` (line 1552) already coerces both integers and
  `"<n>"`/`"log-<n>"` strings, so narrowing the schema to `"string"` does not break
  the handler. No change needed here; read only to verify.
- `lib/repo_builder/harness/pi.ex` — the pi orchestrator spawn
  (`orchestrator_spawn/2`, lines 32–65) that materializes the manifest to
  `.pi-orch-tools.json` and wires `PI_ORCH_TOOLS_PATH`. Read only; no change.
- `test/repo_builder/orchestrator/tool_catalog_pi_parity_test.exs` — the existing
  parity regression guard; extend it with the no-union-type assertion and the
  extension `try/catch` source assertion.
- `BUILD_PROMPT.md` §4.3 / §10 — harness event contract and extensibility
  (pi ships no MCP; tools via `-e` extension). Context only.

### New Files
None. The fix is two edits to existing files plus assertions added to the existing
parity test. (No new library, no migration, no new module.)

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Fix the root cause — narrow the pi-incompatible schema in the catalog
- In `lib/repo_builder/orchestrator/tool_catalog.ex`, in the `get_logs` tool's
  `input_schema`, change the `numbers` property's items from
  `%{"type" => ["integer", "string"]}` to `%{"type" => "string"}`.
- Update the `numbers` description to state that values may be bare integers or
  `"log-<n>"` strings, both accepted (the handler coerces either). Keep the example
  but phrase the items as strings, e.g. `["8219", "log-8225", "8228"]`.
- Do NOT change any other schema or any tool ordering — this is the single
  offending union type (verified: it is the only `"type" => [` occurrence in the file).

### 2. Harden the pi extension so one rejected tool can't drop the rest
- In `priv/orchestrator/pi_extension/orchestrator-tools.ts`, wrap the body of the
  `for (const tool of tools)` loop so each `pi.registerTool(...)` is inside its own
  `try { ... } catch (err) { ... }`.
- On catch, write a diagnostic to stderr (e.g.
  `process.stderr.write(\`orchestrator-tools: failed to register \${tool.name}: \${String(err)}\n\`)`)
  and `continue` — never let one tool abort registration of the others.
- Keep the existing single source-of-truth load path (`PI_ORCH_TOOLS_PATH` /
  `readFileSync`) unchanged.

### 3. Extend the parity test with class-level regression guards
- In `test/repo_builder/orchestrator/tool_catalog_pi_parity_test.exs`, add a test
  asserting that for EVERY tool in `ToolCatalog.tools/0`, no JSON-Schema `type`
  anywhere in its `input_schema` (including nested `items`/`properties`) is a list —
  i.e. no array-valued `type`. Implement a small recursive walker over the
  string/atom-keyed schema maps. This fails fast if anyone reintroduces a
  pi-incompatible union type.
- Add a test asserting the on-disk extension source
  (`priv/orchestrator/pi_extension/orchestrator-tools.ts`) contains a `try` and a
  `catch` inside the registration path (mirror the existing
  "on-disk extension" source-assertion style at lines 48–56).
- Keep the existing assertions (name-set parity, parameters==input_schema, manifest
  load path) intact.

### 4. Run the validation suite
- Run every command in **Validation Commands** and confirm all are green with zero
  regressions. In particular the extended
  `tool_catalog_pi_parity_test.exs` must pass (proving no union types remain and the
  extension is hardened), and the full suite must stay green.

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- `mix test test/repo_builder/orchestrator/tool_catalog_pi_parity_test.exs` — the
  extended parity guard: all 34 tools advertised, parameters == input_schema, NO
  array-valued `type` anywhere, and the extension wraps registration in try/catch.
- `mix test test/repo_builder/orchestrator/get_logs_test.exs` — proves `get_logs`
  still resolves single/range/`numbers` references after the schema narrowing
  (string + integer inputs both coerced).
- Reproduce-the-class check (before and after): run a one-liner to assert the
  manifest contains NO array-valued `type` —
  `mix run -e 'm = RepoBuilder.Orchestrator.ToolCatalog.pi_manifest_json() |> Jason.decode!(); refute = Enum.any?(m, fn t -> Jason.encode!(t["parameters"]) =~ ~s("type":[) end); IO.puts(if refute, do: "FAIL: union type present", else: "OK: no union types")'`
  (expect `OK` after the fix; would print `FAIL` before).
- `mix compile --warnings-as-errors` — clean compile; gradual set-theoretic type
  checker and `warnings_as_errors` pass.
- `mix test --warnings-as-errors` — full ExUnit suite, zero failures.
- `mix format --check-formatted` — formatting.
- `mix credo --strict` — lint incl. the `@spec`-on-every-public-function rule.
- `mix dialyzer` — `@spec`/contract checking, no new warnings, no stale ignores.

## Notes
- **No LiveView change.** This is a harness/tooling-binding bug, not a UI
  interaction, so no `Phoenix.LiveViewTest` is required. The reproduction and proof
  are at the manifest/catalog and extension-source level, which is where the defect
  lives.
- **Why narrow to `"string"` and not keep both types?** The orchestrator LLM emits
  JSON arguments; passing log numbers as strings (`"8219"` / `"log-8219"`) is the
  natural and already-supported form (`parse_log_no/1` handles ints and strings).
  Narrowing avoids the pi-incompatible union while keeping the MCP path valid and
  the handler behaviour identical.
- **Tidewave aid:** if a live pi orchestrator is available, after the fix use
  Tidewave `project_eval` to print
  `RepoBuilder.Orchestrator.ToolCatalog.pi_manifest() |> Enum.map(& &1.name)` and
  confirm 34 names, and `get_logs` to read the actual extension stderr if any tool
  is still rejected. Not required for the fix; useful for live confirmation.
- **Out of scope (secondary signal):** the report also blames "the claude harness
  is flaky this session" for failed scout spawns. That is the orchestrator's own
  (incorrect) attribution — the scout degradation is a downstream effect of the
  missing `inspect_repo`/workstream tools, not a Claude harness defect. No Claude
  harness change is made here. If genuine Claude worker-spawn flakiness is observed
  independently after this fix, it should be filed and triaged as a separate bug
  with its own reproduction.
- **Forward-looking:** the recursive no-union-type assertion added in Step 3 guards
  the whole catalog, so any future tool that introduces a pi-incompatible schema
  fails CI immediately rather than silently truncating the pi orchestrator's
  toolset in production.
</content>
</invoke>
