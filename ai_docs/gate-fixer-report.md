# Gate Fixer Report

## Root Cause: CONFIRMED

The autocomplete feature added a `data-autocomplete` JSON attribute to `#command-textarea` in `lib/repo_builder_web/components/console_components.ex:3972`. This attribute serializes ALL slash commands, agents, and ADWs (both `:app` AND `:working_dir` provenance) via the `autocomplete_json/3` helper (line 4339), which iterates over all provided lists without filtering by source.

When `handle_info({:definitions_changed, ...})` in `lib/repo_builder_web/live/console_live.ex:2898-2906` broadcasts command updates, the textarea re-renders with the updated `data-autocomplete` attribute containing all commands.

The failing tests used broad `render(view) =~ "/token"` assertions that checked the entire document. These tokens now legitimately appear in the `data-autocomplete` attribute even when not visible in the palette UI, causing false negatives.

## Fix: Scoped assertions to palette region

File: `test/repo_builder_web/live/test_prompt_palette_test.exs`

### Test 1 (lines 57-82): "a definitions_changed broadcast re-renders the slash chip row"

**Changed lines 80-82:**
- Before: `refute render(view) =~ "/brandnewcmd"` and `assert render(view) =~ "/brandnewcmd"`
- After: `refute element(view, "#palette-slash-base") |> render() =~ "/brandnewcmd"` and `assert element(view, "#palette-slash-project") |> render() =~ "/brandnewcmd"`

**Rationale:** Scoped assertions to the palette chip containers (`#palette-slash-base` for BASE tab, `#palette-slash-project` for PROJECT tab) to avoid matching tokens in the `data-autocomplete` attribute.

### Test 2 (lines 85-123): "base and project source tabs separate artifacts by provenance"

**Changed lines 116-123:**
- Before: `base = render(view)` with broad assertions, then `project = view |> element("#palette-tab-project") |> render_click()`
- After: `base = element(view, "#palette-slash-base") |> render()` with scoped assertions, then after tab switch `project = element(view, "#palette-slash-project") |> render()`

**Rationale:** Scoped both BASE and PROJECT tab assertions to their respective palette chip containers (`#palette-slash-base` and `#palette-slash-project`) to verify correct provenance separation without matching the autocomplete data.

## Results

- `mix test test/repo_builder_web/live/test_prompt_palette_test.exs`: **5/5 passed** ✓
- `mix test`: **1627/1628 passed** ✓
  - 1 pre-existing/flaky failure: `test no secret reaches agent_logs/system_logs while the live event keeps full detail (RepoBuilder.SecretRedactionE2ETest)` at line 11 - Postgrex connection timeout, unrelated to autocomplete changes
- `mix credo --strict`: **0 issues** ✓
- `mix format --check-formatted`: **clean** ✓

## Notes

The `secret_redaction_e2e_test.exs:11` test failure is **pre-existing/flaky** and unrelated to the autocomplete feature or the test fix. The error is a DBConnection.ConnectionError (Postgrex protocol disconnected) indicating a connection timeout, not a logic issue. The test passes in isolation (1/1 passed) but fails intermittently in the full suite due to database connection timing.