# Quality-Gate Plugins — authoring a gate for a new stack

The **quality gate** is the orchestrator's stack-aware, per-phase "am I done?" oracle: an
ordered five-stage green gate (**format · lint · type · test · mutation**) it runs at each
workstream phase's `:test` stage, looping fix-workers until the gate is green. This doc is
for adding or customizing a gate for a stack.

## The moving parts

| Piece | Module / path | Role |
|-------|---------------|------|
| Contribution kind | `RepoBuilder.Plugins.Contribution` (`:quality_gate`) | the CLOSED extension point |
| Descriptor domain | `RepoBuilder.Plugins.QualityGate` | wire→domain validation of the JSON descriptor (never raises) |
| Capability tokens | `RepoBuilder.Projects.CapabilityTokens` | shared `{{TOKEN}}` → capability-field fill |
| Resolver | `RepoBuilder.Orchestrator.GateResolver` | precedence chain + token fill + variant selection |
| Runner | `RepoBuilder.Orchestrator.GateRunner` | ordered execution plan + GateResult evaluation |
| Tool | `run_quality_gate` (`ToolCatalog`/`Tools`) | the orchestrator-callable entry point |
| Builtins | `priv/quality_gates/<stack>.json` | zero-plugins defaults |
| Plugins | `plugin_library/quality-gates-<stack>/` | a descriptor + a foundations skill |

## The descriptor format

A gate descriptor is a JSON object: `{"stack": "<name>", "stages": [ ... ]}`. Each stage:

```json
{
  "id": "lint",
  "label": "lint",
  "command": "{{LINT_COMMAND}}",
  "strict": true,
  "cadence": "per_phase",
  "diagnostic": "file_line",
  "variant": "standard"
}
```

- **`command`** — a capability-tokenized shell command. Tokens (`{{FORMAT_COMMAND}}`,
  `{{LINT_COMMAND}}`, `{{TYPECHECK_COMMAND}}`, `{{TYPECHECK_STRICT_COMMAND}}`,
  `{{TYPE_COVERAGE_COMMAND}}`, `{{TEST_COMMAND}}`, `{{MUTATION_COMMAND}}`, …) are filled from
  the project's `Capabilities`. A stage whose required token is **empty is dropped** — never
  emit a broken command.
- **`strict`** (default `true`) — a red strict stage halts the gate.
- **`cadence`** — `per_phase` (fast: format/lint/type/test, every phase) or `pre_merge`
  (slow: mutation/property, once at `close_workstream`).
- **`diagnostic`** — `file_line` (parse `path:line[:col]` findings for the fix-worker),
  `summary` (capture the output tail), or `none`.
- **`variant`** — for the type stage, encode it TWICE: a `"standard"` form
  (`{{TYPECHECK_COMMAND}}`) and a `"strict"` form (`{{TYPECHECK_STRICT_COMMAND}}` +
  a `{{TYPE_COVERAGE_COMMAND}}` sub-stage). `GateResolver` selects one by the project's
  `capabilities.typed_enforcement` (`:off` drops it, `:standard` keeps the plain checker,
  `:strict` swaps in the strict command + coverage). A `:strict` stage whose strict token is
  empty **degrades to `:standard`** rather than emitting a broken command.

## Steps to add a stack

1. **Builtin default** — write `priv/quality_gates/<stack>.json` mirroring an existing
   descriptor (Elixir is the reference — it reproduces this repo's own gate). This makes the
   gate work with zero plugins installed.
2. **Capability defaults** — add the `mutation_command`, `typecheck_strict_command`, and
   `type_coverage_command` defaults for the language in `RepoBuilder.Projects.Capabilities`.
3. **Stack map** — add the language → descriptor mapping in `GateResolver`'s `@stack_gates`.
4. **Plugin (optional)** — package `plugin_library/quality-gates-<stack>/` with a
   `plugin.json` declaring a `quality_gate` contribution (pointing at a `gate.json`) plus a
   `skill` contribution (`skills/quality-gate-foundations/SKILL.md`). An active plugin's gate
   **wins over the builtin default** for that stack.
5. **Test** — assert the descriptor parses (`QualityGate.read/1`) and the resolver picks it.

## Why mutation testing

LLM-written tests are exceptionally good at passing while asserting nothing — the vacuous-test
failure mode a line-coverage gate rewards. Mutation testing perturbs the code and requires
some test to fail; if none does, the test was theater. It is slow, so it runs at `pre_merge`
cadence (workstream close), not per edit. Property-based tests (StreamData/Hypothesis/
fast-check/proptest) are the other spec-encoding lever — run deeper sweeps at pre-merge too.
