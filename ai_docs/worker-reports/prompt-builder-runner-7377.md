# Worker report: prompt-builder-runner (idle)

Done. Here is the honest, evidence-backed report.

## Step 1 — Builder located

**Two builders exist; I used the Elixir port (the preferred one, present in this repo).**

- **(a) Elixir port ✅ FOUND & USED** — `RepoBuilder.PromptStandard` at `lib/repo_builder/prompt_standard/` (a faithful, self-described port of the Python `prompt_builder`). It is the canonical home per the header in `ai_docs/prompt-standard-spec.md`.
- **(b) Python reference** — `prompt_builder/` at `/data/1.Projects/repo_builder` (commit `6249331`) exists too; I read its `ai_docs/prompt-builder-guide.md` to resolve the `$ARGUMENTS` semantics. Did not need to run it.

**Invocation interface used:**
```elixir
RepoBuilder.PromptStandard.build_and_validate(:a, %PopAInput{name:, purpose:, variables:, instructions:, expertise:, workflow:, report:, description:, argument_hint:, level: 7})
# => {:ok, prompt, %ValidationResult{}} | {:error, result}
```
Also available as the mix task `mix repo_builder.prompt_standard.validate <file> [--population A|B]`.

## Step 2 — Output-format match

**The builder produces the Claude-Code slash-command format DIRECTLY — no adaptation.** Population A (`build_population_a`) emits YAML frontmatter (`description`, `argument-hint`, optional `allowed-tools`/`model`) + `# Purpose` → `## Variables` → `## Instructions` → `## Expertise` (level≥7) → `## Workflow` → `## Report`. This is precisely the slash-command schema.

**The one genuine tension, resolved with evidence:** check **H9 forbids the literal `$ARGUMENTS`** (plural) in a delivered Population A prompt. But the builder-guide's *own canonical passing example* uses positional `$1`/`$2` in `## Variables` (H9 only flags `$ARGUMENTS`, not `$1`/`$2`/`$ARGUMENT`), and this repo's shipped `bug.md`/`fix.md` use `$1`/`$ARGUMENT`. So I used `$1` — §7-clean, repo-convention, and host-substitutable. I did **not** use `$ARGUMENTS` (it would fail H9).

## Step 3 — Build

Genuinely invoked the builder. Two real findings during the run:
1. **First run FAILED H1** ("Frontmatter YAML malformed") — the builder does not YAML-quote the `description`, and mine contained a colon-space. Fixed by authoring a YAML-safe `description`. *(Evidence the builder's validator genuinely gates.)*
2. **Second run PASS** — zero HARD errors, zero SOFT warnings. The `## Expertise` section was correctly placed *before* `## Workflow` (the level≥7 Workflow-frozen/Expertise-living invariant). Input blocks were `String.trim_trailing`'d so the builder's join produced clean single-blank-line spacing.

## Step 4 — Store & report

| | |
|---|---|
| **(1) Builder & invocation** | `RepoBuilder.PromptStandard.build_and_validate(:a, %PopAInput{...})` via `mix run --no-start`; re-validated independently with `mix repo_builder.prompt_standard.validate` |
| **(2) Exact stored path** | `/data/1.Projects/repo_builder_elixir/.claude/commands/troubleshooting.md` (6542 bytes, confirmed with `ls -la`) |
| **(3) Builder-produced vs adapted** | **100% builder-produced, stored verbatim.** The only edits I made were to the *inputs* (YAML-safe description, trimmed heredocs) — never to the builder's output. No hand-authoring. |
| **(4) Validation** | **PASS.** Independent mix task: `Overall: PASS`, H1–H9 all PASS (H10 deferred/SKIP), zero SOFT notes, exit 0. |

The command is general-purpose (not hardcoded to a module) and grounded in this stack: reproduce → isolate root cause → propose minimal fix, with Elixir/Phoenix/Ecto/OTP-specific failure signatures in `## Expertise`, Tidewave (`get_logs`/`project_eval`/`execute_sql_query`) for evidence, and the repo's `--warnings-as-errors`/credo/dialyzer gate in the workflow.
