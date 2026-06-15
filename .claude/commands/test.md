---
command: test
version: 1.0.0
---

# Application Validation Test Suite

Execute comprehensive validation tests for this Elixir/Phoenix application, returning results in a standardized JSON format for automated processing.

## Purpose

Proactively identify and fix issues in the application before they impact users or developers. By running this comprehensive test suite, you can:
- Detect compile errors, type violations (gradual set-theoretic compiler + Dialyzer), and `@spec` contract mismatches
- Identify broken ExUnit tests, formatting drift, and Credo lint violations
- Verify dependencies resolve and the project compiles under `--warnings-as-errors`
- Ensure the application is in a healthy state at runtime (optionally via Tidewave runtime intelligence — see below)

## Variables

TEST_COMMAND_TIMEOUT: 5 minutes

## Instructions

- Execute each test in the sequence provided below
- Capture the result (passed/failed) and any error messages
- IMPORTANT: Return ONLY the JSON array with test results
  - IMPORTANT: Do not include any additional text, explanations, or markdown formatting
  - We'll immediately run JSON.parse() on the output, so make sure it's valid JSON
- If a test passes, omit the error field
- If a test fails, include the error message in the error field
- Execute all tests even if some fail
- Error Handling:
  - If a command returns non-zero exit code, mark as failed and immediately stop processing tests
  - Capture stderr output for error field
  - Timeout commands after `TEST_COMMAND_TIMEOUT`
  - IMPORTANT: If a test fails, stop processing tests and return the results thus far
- Test execution order is important - dependencies should be validated first (deps → compile → format → lint → tests → dialyzer)
- All file paths are relative to the project root and all commands run from the project root
- Run from the project root; the toolchain is project-scoped via `mise.toml`, so prefix with `mise exec --` (or run inside `mise` shell) if `mix` is not already on PATH

## Test Execution Sequence

### Core Validation (mix)

1. **Dependency Resolution**
   - Preparation Command: None
   - Command: `mix deps.get --check-locked`
   - test_name: "deps_resolution"
   - test_purpose: "Validates all dependencies resolve against the committed mix.lock without modifying it, catching unpinned or missing deps"

2. **Compile (warnings as errors)**
   - Preparation Command: None
   - Command: `mix compile --warnings-as-errors --force`
   - test_name: "compile_warnings_as_errors"
   - test_purpose: "Validates the project compiles cleanly under the gradual set-theoretic type checker with warnings treated as errors, catching guard/clause/map-key/type bugs and any warning"

3. **Format Check**
   - Preparation Command: None
   - Command: `mix format --check-formatted`
   - test_name: "format_check"
   - test_purpose: "Validates all source is formatted per .formatter.exs"

4. **Credo Lint**
   - Preparation Command: None
   - Command: `mix credo --strict`
   - test_name: "credo_lint"
   - test_purpose: "Validates code quality and conventions, including the 'every public function has an @spec' rule (BUILD_PROMPT.md §3)"

5. **ExUnit Tests**
   - Preparation Command: None
   - Command: `mix test --warnings-as-errors`
   - test_name: "exunit_tests"
   - test_purpose: "Validates all application behavior: harness normalizers, session runtime, workflow engine, persistence/contexts, Oban workers, LiveView, and crash isolation (BUILD_PROMPT.md §13)"

6. **Dialyzer**
   - Preparation Command: None
   - Command: `mix dialyzer --format github`
   - test_name: "dialyzer"
   - test_purpose: "Validates @spec/contract correctness Dialyzer catches that the compiler cannot (spec-vs-success-typing, unmatched/extra/missing returns, opaque misuse) with no stale ignore filters"

### Runtime Intelligence (Tidewave MCP — optional, requires the running app)

These checks use the **Tidewave** Phoenix integration (`{:tidewave, "~> 0.5", only: :dev}` + `plug Tidewave`, MCP at `http://localhost:4000/tidewave/mcp`). They are not shell commands — they are MCP tool calls — so run them only when a dev server is up and skip them gracefully otherwise (do not mark them failed if the server is not running). When available, prefer Tidewave over ad-hoc IEx/`curl`:

- `project_eval` — evaluate Elixir in the running app to smoke-test a context or OTP process end-to-end (e.g. start a `Harness.Fake` session and assert the canonical event sequence) instead of booting a separate IEx.
- `execute_sql_query` — verify persisted state directly against the app DB (e.g. `agent_logs` rows exist, `cost_usd` NULL-vs-0 preserved) rather than guessing.
- `get_logs` — read the server logs/stacktraces after exercising a path, to confirm no errors and no leaked secrets in `agent_logs`/`system_logs`.

If you run any Tidewave check, record it as a result with `execution_command` set to the tool name + a short description of the eval/query used.

## Report

- IMPORTANT: Return results exclusively as a JSON array based on the `Output Structure` section below.
- Sort the JSON array with failed tests (passed: false) at the top
- Include all tests in the output, both passed and failed
- The execution_command field should contain the exact command that can be run to reproduce the test
- This allows subsequent agents to quickly identify and resolve errors

### Output Structure

```json
[
  {
    "test_name": "string",
    "passed": boolean,
    "execution_command": "string",
    "test_purpose": "string",
    "error": "optional string"
  },
  ...
]
```

### Example Output

```json
[
  {
    "test_name": "compile_warnings_as_errors",
    "passed": false,
    "execution_command": "mix compile --warnings-as-errors --force",
    "test_purpose": "Validates the project compiles cleanly under the gradual set-theoretic type checker with warnings treated as errors",
    "error": "** (CompileError) lib/repo_builder/harness/pi.ex:42: undefined function normalize_usage/1"
  },
  {
    "test_name": "exunit_tests",
    "passed": true,
    "execution_command": "mix test --warnings-as-errors",
    "test_purpose": "Validates all application behavior: harness normalizers, session runtime, workflow engine, persistence/contexts, Oban workers, LiveView, and crash isolation"
  }
]
```
