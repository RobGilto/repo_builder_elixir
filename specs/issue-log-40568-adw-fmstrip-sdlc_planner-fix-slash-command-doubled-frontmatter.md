# Bug: `/build` (and other pack-wrapped slash commands) leak raw frontmatter to pi — `provider exited {:exit_status, 256}`, `Error: Unknown option: --- description: …`

## Metadata
issue_number: `log-40568`
adw_id: `fmstrip`
issue_json: `null` (freeform bug report, not issue JSON)

## Bug Description
Running the slash command

```
/build specs/issue-adws-swimlane-adw-workstreams-sdlc_planner-adws-phase-swimlane.md
```

against a pi-harnessed session fails immediately with:

```
provider_error: provider exited: {:exit_status, 256}
stderr: Error: Unknown option: --- description: Build the codebase based on the plan
argument-hint: [path-to-plan] allowed-tools: Read, Write, Bash --- # Build
Follow the `Workflow` to implement the `PATH_TO_PLAN` then `Report` the completed work. …
```

**Expected:** `/build <path>` expands to the *body* of `.claude/commands/build.md` (frontmatter stripped, `$ARGUMENTS` substituted) and that clean prompt is handed to the pi provider, which runs the build workflow.

**Actual:** The text handed to pi still begins with a second, embedded YAML frontmatter fence (`--- description: … allowed-tools: … ---`). pi has no native slash-command handling and receives the prompt as argv; its CLI parser sees the leading `---` as a flag and dies with `Unknown option: ---`, exit status 256.

The stderr is verbatim the *body* of `build.md` starting at the embedded fence — proof that the platform's slash expansion ran but left a residual frontmatter block at the top of the expanded body.

## Problem Statement
`.claude/commands/build.md` (and four sibling command files) contain **two stacked frontmatter blocks**: the platform's pack-manifest frontmatter (`command:`/`version:`) followed by the *original* Claude Code command frontmatter (`description:`/`argument-hint:`/`allowed-tools:`) that was never removed when the manifest wrapper was prepended. `RepoBuilder.Orchestrator.Template.from_markdown/1` — used by both `SlashExpander` (to get the expandable body) and `Definitions.SlashCommand` (to read palette metadata) — strips only the **first** fence, so the second frontmatter block survives inside the "body" and is shipped to the harness.

Two observable symptoms flow from this single cause:
1. **pi crash** (this report): the expanded body begins with `---`, which pi treats as an unknown CLI option.
2. **Blank palette descriptions**: `Definitions.SlashCommand.read_frontmatter/1` reads `description`/`argument-hint` from the *first* (manifest) block, which has neither, so these commands show `description: nil` in the command palette even though a real description is trapped in the embedded block.

## Solution Statement
Two coordinated, minimal changes:

1. **Data fix (root cause):** Collapse the doubled frontmatter in the five affected `.claude/commands/*.md` files into a single frontmatter block that preserves every useful key (`command`, `version`, `description`, `argument-hint`, `allowed-tools`), and normalize their CRLF line endings to LF. This makes the files well-formed so `from_markdown/1` yields a clean body and populated palette metadata.

2. **Code fix (regression guard / defense-in-depth):** Harden `RepoBuilder.Orchestrator.Template.split_frontmatter/1` so that after stripping the leading frontmatter it also strips **consecutive** leading frontmatter blocks — i.e. a body that *still* begins (after trimming) with a `---`-fenced YAML block has that block removed too. This guarantees no expanded slash-command body can ever begin with a raw `---` fence again, regardless of how a future command file or command pack is authored. The fix is surgical (one private function), preserves the `{:ok, map()} | {:error, reason()}` contract, and leaves single-frontmatter files byte-for-byte unchanged.

The code fix alone would stop the pi crash even if a bad file slips through again; the data fix additionally restores the correct palette descriptions (symptom 2), which the code fix cannot recover because the manifest block genuinely lacks those keys.

## Steps to Reproduce
1. Register/point a project at this repo and start a **pi** session (the `pi` harness has no native slash expansion — `Session.Supervisor.expand_prompt/1` is the only expander).
2. Send the prompt `/build specs/<any-plan>.md`.
3. Observe the session terminate with `provider_error: provider exited: {:exit_status, 256}` and stderr `Error: Unknown option: --- description: Build the codebase …`.

Deterministic unit reproduction (no live pi needed):
```elixir
raw = File.read!(".claude/commands/build.md")
{:ok, attrs} = RepoBuilder.Orchestrator.Template.from_markdown(raw)
String.starts_with?(attrs["body"], "---")   # => true  (BUG; should be false)
```

## Root Cause Analysis
`RepoBuilder.Orchestrator.Template.split_frontmatter/1` splits on the frontmatter fence with `parts: 3`:

```elixir
String.split(markdown, ~r/^---\s*$/m, parts: 3)   # [leading, yaml, body]
```

`parts: 3` stops after the **second** `---`, so only the first frontmatter block is consumed; anything after it — including a *second* stacked frontmatter block — is returned as `body`.

`.claude/commands/build.md` is authored as:
```
---
command: build
version: 1.0.0
---

---            <-- second, embedded Claude Code frontmatter
description: Build the codebase based on the plan
argument-hint: [path-to-plan]
allowed-tools: Read, Write, Bash
---

# Build
…
```

So `from_markdown/1` returns `body = "---\ndescription: …\n---\n\n# Build\n…"`. `SlashExpander.expand/2` substitutes `$ARGUMENTS` into this body and hands it to the session. For the `pi` harness (no native `/command` handling) the prompt reaches pi's CLI as argv; the leading `---` is parsed as an option → `Error: Unknown option: ---` → exit 256.

The doubled frontmatter exists because these command files were originally Claude Code commands (with `description`/`argument-hint`/`allowed-tools` frontmatter) and were later wrapped with the platform's pack-manifest frontmatter (`command`/`version`) **without** removing the original block. CRLF (`^M`) line endings on the embedded block are a secondary authoring artifact from the same import.

## Relevant Files
Use these files to fix the bug:

- `lib/repo_builder/orchestrator/template.ex` — `split_frontmatter/1` (line ~152) uses `parts: 3` and only strips the first fence. Home of the regression-guard fix. `from_markdown/1` (line ~43) and its `{:ok, map()} | {:error, reason()}` contract must be preserved.
- `lib/repo_builder/prompts/slash_expander.ex` — consumes `Template.from_markdown/1` via its private `body/1`; the source of the expanded prompt that leaked. No change required if the fix lands in `template.ex`, but it is the observable seam and its tests validate the end-to-end expansion.
- `lib/repo_builder/definitions/slash_command.ex` — `read_frontmatter/1` also calls `Template.from_markdown/1`; benefits from the data fix (populated `description`/`argument-hint`). No code change.
- `lib/repo_builder/session/supervisor.ex` — `expand_prompt/1` is the single expansion seam (pi included; `adw` skipped). Confirms the pi path has no other expander. No change.
- `.claude/commands/build.md` — the file in this report; doubled frontmatter + CRLF. **Data fix.**
- `.claude/commands/commit.md`, `.claude/commands/implement.md`, `.claude/commands/implement_elixir.md`, `.claude/commands/plan.md` — same doubled-frontmatter defect (found by scan). **Data fix.**
- `test/repo_builder/orchestrator/template_test.exs` — existing `from_markdown/1` tests; add a stacked-frontmatter case here.
- `test/repo_builder/prompts/slash_expander_test.exs` — existing expander tests; add an end-to-end case proving an expanded body never starts with `---`.

### New Files
- `test/repo_builder/prompts/test_doubled_frontmatter_expansion_test.exs` — focused regression test that (a) asserts `from_markdown/1` strips stacked frontmatter and (b) asserts every discoverable `.claude/commands/*.md` expands to a body whose first non-blank line is not a `---` fence (guards all current command files at once).

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Add the regression guard in `Template.split_frontmatter/1`
- In `lib/repo_builder/orchestrator/template.ex`, change `split_frontmatter/1` so that after extracting `{yaml, body}` from the first fence it also strips any **consecutive** leading frontmatter block(s) from `body`. Implementation: after the current split, `String.trim_leading(body)` and, while it begins with a `^---\s*$`-fenced block, split *that* off and drop it; return the remaining body.
- Keep the existing behavior intact: `leading` must still be empty (a doc with no frontmatter is still `{:error, :missing_frontmatter}`), the returned `yaml` is unchanged (still the FIRST block — the manifest keys stay authoritative), and single-frontmatter files produce an identical body to today.
- Preserve `@spec split_frontmatter(String.t()) :: {:ok, String.t(), String.t()} | {:error, reason()}` and keep the function total (never raises).
- Do NOT change `from_markdown/1`'s public contract; it continues to `String.trim(body)` the returned body.

### 2. Fix the five doubled-frontmatter command files (data)
For each of `.claude/commands/{build,commit,implement,implement_elixir,plan}.md`:
- Merge the two frontmatter blocks into ONE leading `---`-fenced block that keeps `command`, `version`, and the previously-embedded `description`, `argument-hint`, and `allowed-tools` keys.
- Remove the now-redundant second `---…---` block from the body.
- Normalize line endings to LF (strip `\r`).
- Leave the markdown body content (`# Build`, `## Workflow`, `$ARGUMENTS`, etc.) otherwise unchanged.

### 3. Add unit coverage for stacked frontmatter in `template_test.exs`
- In `test/repo_builder/orchestrator/template_test.exs`, add a test feeding a two-stacked-frontmatter string to `from_markdown/1` and asserting: `attrs["body"]` does not start with `---`, the first block's keys are returned (manifest wins), and the real body text (`# Build`) is present. This test fails before Step 1 and passes after.

### 4. Add the end-to-end expansion regression test (new file)
- Create `test/repo_builder/prompts/test_doubled_frontmatter_expansion_test.exs`.
- Test A (reproduction): build a temp working dir with a `.claude/commands/<name>.md` containing stacked frontmatter, call `RepoBuilder.Prompts.SlashExpander.expand("/#{name} some/path", tmp_dir)`, and assert the result’s first non-blank line is NOT a `---` fence and that `$ARGUMENTS` was substituted. Fails before the fix, passes after.
- Test B (guards all shipped files): for every file discovered under `.claude/commands/*.md`, assert `SlashExpander.expand("/#{name} X", ".")` yields a body whose first non-blank line does not start with `---`. This catches any future doubled-frontmatter command file.

### 5. Run the full validation gate
- Execute every command in `Validation Commands` and confirm all pass with zero failures/warnings.

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- Reproduce BEFORE the fix (expected `true` on unpatched tree, `false` after):
  `mix run -e 'raw = File.read!(".claude/commands/build.md"); {:ok, a} = RepoBuilder.Orchestrator.Template.from_markdown(raw); IO.inspect(String.starts_with?(a["body"], "---"), label: "leaks_frontmatter")'`
- `mix test test/repo_builder/orchestrator/template_test.exs` — stacked-frontmatter parsing case passes.
- `mix test test/repo_builder/prompts/test_doubled_frontmatter_expansion_test.exs` — new end-to-end regression test passes.
- `mix test test/repo_builder/prompts/slash_expander_test.exs test/repo_builder/prompts/test_slash_expander_platform_fallback_test.exs` — existing expander suites stay green.
- `mix compile --warnings-as-errors` — clean; gradual set-theoretic type checker + `warnings_as_errors` pass.
- `mix test --warnings-as-errors` — full ExUnit suite, zero failures.
- `mix format --check-formatted` — formatted.
- `mix credo --strict` — lint incl. the `@spec`-on-every-public-function convention.
- `mix dialyzer` — no new warnings, no stale ignore filters.

## Notes
- **No LiveView change.** The defect is in server-side prompt expansion / command-file data, not the dashboard, so no `Phoenix.LiveViewTest` is required.
- **Scope confirmed by scan.** Only `.claude/commands/{build,commit,implement,implement_elixir,plan}.md` carry doubled frontmatter; the `priv/command_packs/*/*/commands/*.md` packs are clean (single frontmatter). The code guard in Step 1 nonetheless protects every future command file and pack.
- **Why keep `yaml` = first block.** The platform manifest keys (`command`, `version`) are the ones the pack/definition layer expects to be authoritative; merging the embedded `description`/`argument-hint` into that same first block (Step 2) is what restores the palette metadata that `Definitions.SlashCommand.read_frontmatter/1` reads.
- **Secondary win.** After the data fix, `Definitions.SlashCommand` will surface real `description`/`argument-hint` for these five commands in the command palette (currently `nil`).
- **Runtime intelligence (optional during implementation).** With the app running, Tidewave `project_eval` can reproduce the parse (`RepoBuilder.Orchestrator.Template.from_markdown/1` on the raw file) and `get_logs` can confirm the pi `provider_error` stderr, rather than relying on the reported string alone.
- No new dependencies; `mix.exs` unchanged.
```

