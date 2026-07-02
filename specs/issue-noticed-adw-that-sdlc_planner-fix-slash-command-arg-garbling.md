# Bug: Server-side slash-command expansion garbles arguments — `issue_json`/freeform text is shredded across `$1/$2/$3`

## Metadata
issue_number: `noticed`
adw_id: `that`
issue_json: `slash`

> Note: the three values above are *themselves the bug*. The operator invoked
> `/bug i noticed that slash commands ...`; the platform's server-side expander
> scattered the words of that sentence into the three positional variables
> (`issue_number=noticed`, `adw_id=that`, `issue_json=slash`). They are retained
> here verbatim as primary evidence rather than "cleaned up".

## Bug Description
When the orchestrator (or any worker LLM) emits a planning slash command —
`/feature`, `/bug`, `/chore` — the platform expands it **server-side** via
`RepoBuilder.Prompts.SlashExpander` before the prompt reaches the harness. The
three template variables — `issue_number` (`$1`), `adw_id` (`$2`),
`issue_json` (`$3`) — do not receive the values the caller intended. Instead,
whitespace-separated **words** of the argument string land in the wrong slots:

Observed by the operator across three consecutive invocations:

| Invocation (as emitted) | `issue_number` (`$1`) | `adw_id` (`$2`) | `issue_json` (`$3`) |
|---|---|---|---|
| `/feature the workstreams ui ...` | `the` | `workstreams` | `ui` |
| `/bug investigate why variables ...` | `investigate` | `why` | `variables` |
| `/bug i noticed that slash ...` (this run) | `noticed` | `that` | `slash` |

**Expected:** `issue_number` = the GitHub issue number (a single integer),
`adw_id` = the 8-char ADW id, `issue_json` = the *entire* JSON blob
`{"number":…,"title":…,"body":…}` (which contains spaces), OR — for a
freeform request — the whole prose preserved intact.

**Actual:** every argument is split on whitespace and only the 1st/2nd/3rd
*token* is bound to `$1/$2/$3`. Any argument containing spaces (a JSON payload,
or freeform prose) is truncated to its first word, and the remaining words are
dropped. Downstream the planner cannot parse `issue_json` as JSON (it is a bare
word like `slash`), so it either fabricates a plan from garbage or (correctly)
refuses.

## Problem Statement
`RepoBuilder.Prompts.SlashExpander.substitute/2` fills positional placeholders
(`$1`, `$2`, `$3`) by **splitting the argument string on whitespace**
(`String.split(args, ~r/\s+/, ...)`). This is lossy: argument boundaries are
destroyed the moment a single value contains a space. Since `issue_json` *always*
contains spaces (it is JSON) and freeform prose *always* contains spaces, the
positional binding used by the `/feature`, `/bug`, `/chore` templates is
fundamentally broken for the two most important call paths. This is the Elixir
analog of the same defect in the legacy Python `adws/` runner — but the
orchestrator's live path goes through `SlashExpander`, so the **Elixir** site is
the one that must be fixed.

## Solution Statement
Stop relying on whitespace to delimit arguments for values that can contain
whitespace. `SlashExpander` **already** substitutes `$ARGUMENTS` losslessly
(the full remainder of the invocation line, unsplit — `slash_expander.ex:173`).
The surgical, prompt-only fix — matching the pattern already shipped in
`.claude/commands/implement_elixir.md` — is:

1. **Convert the three planning templates to `$ARGUMENTS`.** Rewrite the
   `## Variables` block of `/feature`, `/bug`, `/chore` from positional
   `issue_number: $1 / adw_id: $2 / issue_json: $3` to a single lossless
   `REQUEST: $ARGUMENTS`, and instruct the planner to interpret `REQUEST`
   robustly — detect a JSON blob (parse `title`/`body`/`number`) vs. freeform
   prose, and degrade gracefully instead of shredding words. This requires **no
   code change** because `SlashExpander` passes `$ARGUMENTS` through intact.

2. **Harden `SlashExpander` against silent tail-loss (defensive).** Keep the
   `$N` positional path (other commands may use it legitimately for
   single-token args), but ensure the last positional placeholder is not the
   only thing capturing a multi-word tail. The minimal guard: document the
   whitespace-split semantics in `@doc`, and add a regression test proving a
   JSON/prose argument survives via `$ARGUMENTS` and is shredded via `$N` — so
   the contract is locked and future templates choose `$ARGUMENTS` for
   space-bearing values.

The template change is the root-cause fix for the live orchestrator path; the
test locks the `SlashExpander` contract so the regression cannot silently return.

## Steps to Reproduce
1. In `iex -S mix`, expand a `/bug` invocation whose argument is a JSON payload
   with internal spaces against a working dir that has the command files:
   ```elixir
   RepoBuilder.Prompts.SlashExpander.expand(
     ~s(/bug 42 abcd1234 {"number":42,"title":"Boom","body":"it broke"}),
     File.cwd!()
   )
   ```
   In the expanded body, `issue_number` = `42`, `adw_id` = `abcd1234`, but
   `issue_json` = `{"number":42,"title":"Boom","body":"it` — the JSON is
   truncated at the first space; the tail is dropped.
2. Simulate the freeform path:
   ```elixir
   RepoBuilder.Prompts.SlashExpander.expand(
     "/feature the workstreams ui should show in the ADWS tab",
     File.cwd!()
   )
   ```
   `$1=the`, `$2=workstreams`, `$3=ui`, and the rest is dropped — matching the
   operator's evidence table.
3. Confirm the split origin in code:
   `lib/repo_builder/prompts/slash_expander.ex` → `substitute/2` (line ~169:
   `String.split(args, ~r/\s+/, trim: true)`) and `replace_positional/2`
   (line ~182).

## Root Cause Analysis
The orchestrator system prompt instructs the model to "dispatch `/feature` |
`/bug` | `/chore`" (`lib/repo_builder/orchestrator/system_prompt.ex:586`,
`orchestrator/workstreams.ex:515`). The model emits that as a free-text line.
Before the prompt reaches a live session, `Session.Supervisor`
(`session/supervisor.ex:56`) calls `SlashExpander.expand/3`, which replaces the
leading `/<name>` line with the body of the matching `.claude/commands/<name>.md`
file, substituting arguments via `substitute/2`.

`substitute/2` computes positional args by whitespace-splitting the entire
remainder of the line:

```elixir
positional = if args == "", do: [], else: String.split(args, ~r/\s+/, trim: true)
# ... then $1,$2,$3 are Enum.at(positional, n-1)
```

The `/feature`, `/bug`, `/chore` templates declare
`issue_number: $1 / adw_id: $2 / issue_json: $3`. Because `issue_json` is JSON
(contains spaces) and freeform prose contains spaces, whitespace-splitting binds
only the first token of the intended value to each slot and discards the tail.
`$ARGUMENTS` is substituted losslessly on the same line
(`String.replace(body, "$ARGUMENTS", args)`, line 173), so the fix is simply to
have these templates consume `$ARGUMENTS` instead of positional `$N`.

The bug is a **boundary-loss defect** at the expansion seam, not a planner logic
error. The planner's downstream refusal is a correct symptom, not the cause.

## Relevant Files
Use these files to fix the bug:

- `lib/repo_builder/prompts/slash_expander.ex` — `substitute/2` (line ~168) and
  `replace_positional/2` (line ~182) perform the lossy whitespace-split for
  `$N`. `$ARGUMENTS` (line 173) is already lossless. Update `@doc`/`@moduledoc`
  to state the whitespace-split semantics of `$N` and steer space-bearing values
  to `$ARGUMENTS`. No behavioral change to `$ARGUMENTS` needed.
- `.claude/commands/bug.md` — `## Variables` uses `issue_number: $1 / adw_id: $2 /
  issue_json: $3` (lines 11–13) and "parse the JSON" instruction (line ~114).
  Convert to `REQUEST: $ARGUMENTS` + robust interpretation.
- `.claude/commands/feature.md` — same positional header (lines 11–13) and parse
  instruction (line ~133). Same conversion.
- `.claude/commands/chore.md` — same positional header (lines 11–13) and parse
  instruction (line ~91). Same conversion.
- `.claude/commands/implement_elixir.md` — **reference pattern already in the
  repo**: uses `REQUEST: $ARGUMENTS` with a robust "spec-path / JSON / freeform"
  classifier and an explicit anti-garbling note. Mirror its `## Variables` and
  Step-0 resolution prose in the three planning templates.
- `test/repo_builder/prompts/slash_expander_test.exs` — existing ExUnit test for
  the expander; add the regression cases here.
- `lib/repo_builder/orchestrator/system_prompt.ex` (line ~586) and
  `lib/repo_builder/orchestrator/workstreams.ex` (line ~515) — reference only:
  confirm the dispatch wording still matches after the templates change (no code
  change expected).

### New Files
- None required. Prefer adding the regression cases to the existing
  `test/repo_builder/prompts/slash_expander_test.exs`. Only create a new test
  file if the cases do not fit the existing module cleanly.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Lock the `SlashExpander` contract with a regression test (fails first)
- In `test/repo_builder/prompts/slash_expander_test.exs`, add tests that expand
  a minimal in-fixture command whose body contains both `$ARGUMENTS` and
  `$1/$2/$3`, invoked with a multi-word / JSON-shaped argument string. Assert:
  - `$ARGUMENTS` yields the **full** argument string intact (including spaces).
  - `$3` yields only the **third whitespace token** (documenting the shredding).
- These assertions encode the intended contract; the `$ARGUMENTS`-intact case is
  the behavior the templates will rely on.

### 2. Document the split semantics in `SlashExpander`
- Update `@moduledoc`/`@doc` on `slash_expander.ex` to state plainly: `$N`
  positional args are whitespace-split and therefore lossy for space-bearing
  values; templates with a JSON or freeform argument MUST use `$ARGUMENTS`.
- Keep `@spec`s intact; no signature change. This is a comment/contract-only edit
  to the module (no logic change), so the gradual type checker and Dialyzer stay
  green.

### 3. Convert `.claude/commands/bug.md` to `$ARGUMENTS`
- Replace the `## Variables` block (`issue_number: $1 / adw_id: $2 /
  issue_json: $3`) with `REQUEST: $ARGUMENTS` plus the anti-garbling note from
  `implement_elixir.md`.
- Replace the `## Bug` "Extract the bug details from the `issue_json` variable
  (parse the JSON …)" instruction with: interpret `REQUEST` as JSON (use
  `title`/`body`) OR, if it is not JSON, treat the full `REQUEST` as the freeform
  bug description; never bind individual words to positional slots. Preserve the
  `issue_number`/`adw_id` metadata by deriving them from the JSON when present,
  else synthesizing a placeholder.
- Keep the `Plan Format`, filename convention, and all other sections unchanged.

### 4. Convert `.claude/commands/feature.md` to `$ARGUMENTS`
- Same conversion as Step 3, adapted to the feature wording.

### 5. Convert `.claude/commands/chore.md` to `$ARGUMENTS`
- Same conversion as Step 3, adapted to the chore wording.

### 6. Run the full validation suite
- Execute every command in *Validation Commands*; confirm the new expander tests
  pass and the green gate is clean with zero regressions.

> Note: This fix lives in the Elixir platform (`lib/repo_builder/prompts/…`) and
> the `.claude/commands/*.md` templates it expands — **not** the legacy Python
> `adws/` runner. There is no LiveView UI change, so no `Phoenix.LiveViewTest`
> and no Tidewave reproduction are required; the mix green gate proves zero
> regressions.

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

Reproduce/verify the expander contract (the fix's own test):
- `mix test test/repo_builder/prompts/slash_expander_test.exs` — the new
  `$ARGUMENTS`-intact and `$N`-shreds regression cases pass.

Elixir green gate (prove no platform regressions — all must pass clean):
- `mix compile --warnings-as-errors` — Compile clean; gradual set-theoretic type checker and `warnings_as_errors` pass.
- `mix format --check-formatted` — Ensure code is formatted.
- `mix credo --strict` — Lint, including the "every public function has an `@spec`" convention.
- `mix test --warnings-as-errors` — Full ExUnit suite (Postgres-backed) with zero failures.
- `mix dialyzer` — `@spec`/contract checking with no new warnings and no stale ignore filters.

## Notes
- **Why `$ARGUMENTS` over encoding the JSON:** on the Elixir path, `SlashExpander`
  already substitutes `$ARGUMENTS` losslessly, so simply having the templates
  consume it removes the defect with zero code change and no base64 round-trip.
  (The earlier Python-oriented draft of this spec proposed base64url-encoding the
  JSON arg; that was for the `adws/` runner. On the live Elixir path, `$ARGUMENTS`
  is the simpler, idiomatic fix.)
- **Alternative (heavier) design:** add a structured multi-arg API to
  `SlashExpander` (e.g. accept an explicit `%{"1" => …, "2" => …, "json" => …}`
  arg map instead of a flat string), so positional binding never depends on
  whitespace. This is more robust for callers that genuinely need multiple
  space-bearing positional args, but touches the expander's public contract and
  every caller — heavier than the template-only change chosen above. Recorded for
  reviewers who prefer structured transport.
- **`implement_elixir.md` already demonstrates the target pattern** — reuse its
  `## Variables` note and Step-0 "spec-path / JSON / freeform" classifier prose so
  all four planning/build commands handle arguments identically.
- **Legacy Python parity (out of scope here):** the same defect exists in
  `adws/adw_modules/agent.py::execute_template` and
  `adws/adw_slash_command.py::compose_prompt`. Not fixed by this Elixir-focused
  spec; file separately if the Python runner remains in use.
- No new libraries; no `mix.exs` change.
