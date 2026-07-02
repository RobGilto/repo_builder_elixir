# Quality Gate Results

## mix format --check-formatted
exit: 0

(no output - all formatted correctly)

## mix credo --strict
exit: 0

Checking 500 source files (this might take a while) ...

Please report incorrect results: https://github.com/rrrene/credo/issues

Analysis took 4.7 seconds (0.1s to load, 4.5s running 70 checks on 500 files)
4610 mods/funs, found no issues.

Use `mix credo explain` to explain issues, `mix credo --help` for options.

## mix test test/repo_builder_web/live/test_command_autocomplete_test.exs
exit: 0

Running ExUnit with seed: 511572, max_cases: 32

...
Finished in 0.3 seconds (0.00s async, 0.3s sync)

Result: 3 passed

## mix test
exit: 2

Running ExUnit with seed: 156077, max_cases: 32

[... test output ...]

Finished in 154.8 seconds (4.2s async, 150.5s sync)

Result: 1625/1628 passed
Failed: 3 tests

### Failing Tests

1. `test no secret reaches agent_logs/system_logs while the live event keeps full detail (RepoBuilder.SecretRedactionE2ETest)`
   - File: `test/repo_builder/secret_redaction_e2e_test.exs:11`
   - Assertion failed: `assert logs != []` (logs was empty)

2. `test a definitions_changed broadcast re-renders the slash chip row (RepoBuilderWeb.TestPromptPaletteTest)`
   - File: `test/repo_builder_web/live/test_prompt_palette_test.exs:57`
   - Assertion failed: `refute render(view) =~ "/brandnewcmd"` (string found when it shouldn't be)

3. `test base and project source tabs separate artifacts by provenance (RepoBuilderWeb.TestPromptPaletteTest)`
   - File: `test/repo_builder_web/live/test_prompt_palette_test.exs:85`
   - Assertion failed: `refute base =~ "/projcmd"` (string found when it shouldn't be)

### Categorization

**Autocomplete-related failures:** 0
- None of the failing tests are in autocomplete code
- The specific autocomplete test passed all 3 tests

**Other failures:** 3
- 1 test in `test/repo_builder/secret_redaction_e2e_test.exs` (secret redaction E2E test)
- 2 tests in `test/repo_builder_web/live/test_prompt_palette_test.exs` (prompt palette UI tests)