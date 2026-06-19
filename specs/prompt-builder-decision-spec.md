# Prompt-Builder Decision Spec

> **Purpose of this document:** This is a self-contained decision record. It captures the full context of the prompt-builder initiative — the goal, the research, the extracted standard, and the open decisions — so that it can be resumed in a future session even after the orchestrator loses context. Read this file top-to-bottom and you have everything needed to make the decisions and proceed.

- **Status:** Decision-pending (awaiting operator confirmation on 3 items in §9)
- **Date:** 2026-06-20
- **Primary spec artifact:** `/data/1.Projects/repo_builder/ai_docs/prompt-standard-spec.md`
- **This document:** `/data/1.Projects/repo_builder_elixir/specs/prompt-builder-decision-spec.md`

---

## 1. The decision in one sentence

**Whether and how to build a spec-driven prompt-builder + validator** — an agent (and its wrapping workflow) that generates prompts conforming to a reverse-engineered standard, with an automated validation gate enforcing that standard.

## 2. How we got here (the arc)

- **Operator goal:** building ADW workflows reliably requires prompts that adhere to a consistent standard (headings, metadata, structure). Operator has good-prompt examples but wants a *prompt-builder agent with skills in this*.
- **Key realization (operator):** an ADW will only be useful if prompts conform to a standard. So the real prerequisite is a prompt-builder, and the standard it builds against must be *explicit*, not just inferred from examples.
- **Architecture insight (orchestrator + operator):** consistency isn't guaranteed by a single smart agent — it's guaranteed by a **draft → validate → fix loop**. So the deliverable is a small ADW: the prompt-builder is the `/build` node, a validator is the `/review` node. Examples ≠ spec; we must reverse-engineer explicit rules from the existing artifacts first.
- **Research executed:** a worker (spec-writer, glm-5.2) read all reference artifacts and produced `ai_docs/prompt-standard-spec.md` — the explicit standard (8 sections, machine-checkable where possible, with real file:line citations).
- **Where we are now:** the spec is written. It surfaced 10 open questions. Three of them shape the build. This document captures everything so the operator can decide and we can proceed.

## 3. The goal

Build a **prompt-builder** that:
- Generates prompts conforming to the extracted standard (`prompt-standard-spec.md`).
- Targets two "populations": (A) factory slash-commands, (B) runtime `.md` prompts.
- Includes a built-in **validator** (the §7 checklist) that acts as a quality gate.
- Reuses existing reference material: `prompt-anatomy.md`, `build-prompt.md`, `improve-build-prompt.md`.

Framed as a workflow: **draft → validate against spec → fix → validate again** (generator is `/build`, validator is `/review`).

## 4. Repository layout (critical — two repos, easy to confuse)

| Repo | Role | Key contents |
|---|---|---|
| `/data/1.Projects/repo_builder/` (Python) | **The factory — DEFINES the standard** | `ai_docs/prompt-anatomy.md` + the new `prompt-standard-spec.md`; `commands/tac/` (versioned command sources); `configs/templates/orchestration/app/` (production prompts + assembly + DB schema) |
| `/data/1.Projects/repo_builder_elixir/` (Elixir port) | **Consumes the standard** | Phoenix app under `lib/`, `.planning/`, slimmer `.claude/commands/` (bug, build, chore, commit, conditional_docs, feature, fix, implement, prime, review, test). **No** `prompt-anatomy.md` / `build-prompt.md` / `commands/tac/`. |

**The standard lives entirely in the Python repo_builder.** This decision document lives in repo_builder_elixir/specs (per operator instruction).

### Path corrections from research (verified)
- Production SQL migrations are at `.../app/orchestrator_db/migrations/`, **NOT** `.../app/backend/orchestrator_db/` (operator's original brief had `backend/`).
- Production prompts are at `.../app/backend/prompts/`.

## 5. Key reference artifacts

### Previous prompt-builder attempt (the thing being improved)
- `/data/1.Projects/repo_builder/ai_docs/` — especially `prompt-anatomy.md`
- `/data/1.Projects/repo_builder/commands/tac/` — versioned command sources
- `/data/1.Projects/repo_builder/.claude/commands/build-prompt.md`
- `/data/1.Projects/repo_builder/.claude/commands/improve-build-prompt.md`

### Production prompt artifacts (the real deployed standard)
- `.../app/backend/prompts/orchestrator_agent_system_prompt.md`
- `.../app/backend/prompts/event_summarizer_system_prompt.md` + `event_summarizer_user_prompt.md`
- `.../app/backend/modules/single_agent_prompt.py` — assembly logic
- `.../app/backend/tests/test_orchestrator_prompt_injection.py` — injection-hardening test
- `.../app/orchestrator_db/migrations/2_prompts.sql` — persistence schema

## 6. The reverse-engineered standard (summary)

Full detail in `prompt-standard-spec.md`. Headline findings:

**§1 PROMPT ANATOMY — two competing taxonomies that must be reconciled:**
- *Factory standard* (`prompt-anatomy.md`): `frontmatter → # Purpose → ## Variables → ## Instructions → ## Workflow → ## Report`, with `## Expertise` before `## Workflow` for living/L7 builders.
- *Production reality* (orchestrator prompt): `# Title`, `## Core Operating Principle`, `## Instructions`, `## Variables`, token-wrapper headings, `## Your Tools`, `### Routing rules` (decision tables).
- They diverge materially → resolved by supporting **two populations** (A and B).

**§2 METADATA / FRONT-MATTER — three distinct schemas:**
- (a) Population-A front-matter: `description`, `argument-hint`, `allowed-tools`, `model` (ADW commands add outer `command` + `version`).
- (b) Runtime `.md` files are front-matter-**free** as-shipped (loader does raw `.read_text()`); `SubagentFrontmatter` + `agents.system_prompt` TEXT columns are the only structured data.
- (c) `prompts` SQL table: full DDL with `author` CHECK (`engineer` | `orchestrator_agent`), `prompt_text` NOT NULL, FK CASCADE, no UNIQUE — it's an **audit log**, not a versioned registry.

**§4 ASSEMBLY MODEL — two paths:**
- Path 1 (orchestrator): `_load_system_prompt` does file-load → `.replace()` on `{{SUBAGENT_MAP}}` / `{{HARNESS_CATALOG}}` with non-empty fallbacks → passed as `system_prompt`.
- Path 2 (summarizer): `str.format()` on `{event_type}` / `{details}` named slots → passed as `prompt`.
- Tokens use `.replace` (literal, double-brace); slots use `.format`. **Mutually exclusive within a file.**

**§5 INJECTION-HARDENING — the core invariant (verbatim from the test):**

```python
assert "{{" not in rendered and "}}" not in rendered
```

Plus: SQL `author` CHECK as trust boundary; one-mechanism-per-file; "never guess"; inspect-not-execute.

## 7. The proposed architecture

**Generator + Validator loop** (draft → validate → fix):

- **Generator (the prompt-builder):** writes prompts conforming to the standard. Targets Population A or B. Reuses `build-prompt.md` / `prompt-anatomy.md` as reference.
- **Validator:** enforces the §7 checklist as a quality gate. Two tiers:
  - **HARD checks (pass/fail, machine-enforced)** — H1 (front-matter for slash-commands), H2 (runtime prompts front-matter-free), H3 (no undeclared `{{TOKEN}}` + the injection assertion), H4 (no token renders blank; fallbacks required), H5 (stale-snapshot caveat present), H6 (`.format` templates have exactly their fields), H7 (one mechanism per file), H8-H9 (in spec), H10 (managed-agent template exists — currently FAILS, see Q6).
  - **SOFT checks (judgment rubric)** — anatomy compliance, prose voice, structure conventions.

On the platform this maps to a **prompt-builder subagent template** (the generator) wrapped in a **draft→validate→fix ADW**, OR driven via the repo's own `/feature` → `/build` issue-driven SDLC.

## 8. The 10 open questions (from the spec) + recommendations

### Must-confirm (these reshape the build)

**Q10 — Generator or validator?** Is this spec feeding (a) a validator that lints existing prompts, (b) a generator that writes them, or both?
→ **Rec: BOTH** — generator is the primary deliverable, validator is its built-in quality gate (the /review step). This is the architecture agreed with the operator.

**Q7 — Orchestrator prompt as exemplar, or refactor it toward the factory anatomy?** They diverge materially.
→ **Rec: Support BOTH as two populations** (A = factory slash-commands per anatomy; B = runtime prompts per orchestrator exemplar). Do NOT refactor the existing orchestrator prompt — too risky given test coverage gaps (Q8).

**Q6 — The missing `managed_agent_system_prompt_template.md`.** `config.py:182-184` defaults to a file that doesn't exist; validator check H10 FAILs.
→ **Rec: Note as a known gap; exclude H10 from the hard-gate until the file ships or the default is removed.** Do NOT bundle a loader bugfix into this feature.

### Safe-to-defer (recommended conservative defaults)

| Q | Issue | Recommendation |
|---|---|---|
| Q1 | Front-matter for runtime prompts? | **No for v1** — avoid loader changes |
| Q2 | Runtime prompt versioning model? | **Defer** — out of scope (audit log, no versioning columns) |
| Q3 | ``{{TOKEN}}`` (`.replace`) vs ``{slot}`` (`.format`)? | **Adopt `.replace`/double-brace as canonical** (matches injection test, tolerates prose/JSON) |
| Q4 | Closed token registry? | **Closed for v1** — builder only emits ``{{SUBAGENT_MAP}}`` / ``{{HARNESS_CATALOG}}`` |
| Q5 | System+user prompt pairing? | **Formalize it** — filename convention (system + optional templated user file) |
| Q8 | Injection test coverage gaps? | **Require a per-token test** as part of generator output |
| Q9 | `prompts.author` enum ownership? | **Keep `engineer` / `orchestrator_agent`**; revisit later |

## 9. The decision gate (what the operator must confirm)

**Three confirmations to proceed:**
1. **Q10:** Generator + validator (both)? *(recommended: yes)*
2. **Q7:** Support both populations, don't refactor the orchestrator prompt? *(recommended: yes)*
3. **Q6:** Defer the `managed_agent_system_prompt_template.md` bug, exclude H10 from the gate? *(recommended: yes)*

**One routing choice:**
4. **Route:** via the repo's `/feature` command (issue-driven, produces a plan under `specs/`) **OR** a direct ADW `plan_build_review_fix` (full cycle)?

## 10. How to proceed once decided

**If /feature route chosen:**
- Launch `/feature` on the pi tier, `cwd = /data/1.Projects/repo_builder`, with the feature described as:
  > "A spec-driven prompt-builder + validator that generates Population-A (factory slash-command) and Population-B (runtime) prompts conforming to `ai_docs/prompt-standard-spec.md`, with the §7 checklist as its review gate. Reuses `build-prompt.md` / `prompt-anatomy.md` as reference."
- `/feature` takes `issue_number`, `adw_id`, `issue_json`; it researches the codebase and writes a plan to `specs/issue-{n}-adw-{id}-sdlc_planner-{name}.md`, which then feeds a `/build` step.

**If ADW route chosen:**
- `start_adw` with `workflow_type: plan_build_review_fix`, `harness: "adw"`, input describing the feature above.

## 11. How to resume this in a future session (instructions for the orchestrator)

If context is lost, a future orchestrator session should:
1. **Read this file** (`specs/prompt-builder-decision-spec.md`) — it's the handover record.
2. **Read the spec:** `/data/1.Projects/repo_builder/ai_docs/prompt-standard-spec.md` (the full standard).
3. **Check the decision gate (§9)** — has the operator confirmed the 3 items? If yes, proceed per §10. If no, ask.
4. **Apply the operational lessons (§12)** — especially: workers must read→analyze→write in ONE pass; retrieve `final_message` / read files directly (relay truncates); the Anthropic tier may be session-capped, use pi/zai.

## 12. Operational lessons learned (for future sessions)

- **Worker context does NOT persist between turns.** A worker must read, analyze, and write its output ALL in a single dispatch. Splitting analysis and file-write across two dispatches loses the analysis. (Cost a round-trip when a scout correctly refused to "reproduce" a report it no longer had.)
- **The status relay truncates long `final_message`s.** To read long worker output, either write it to a file and read the file, or ask for a small, specific slice (it truncates at a fixed size; requesting only §8 fit where the full report didn't).
- **Anthropic/claude tier is subject to a session cap** ("resets 4am Sydney"). The pi/zai tier is a separate provider and unaffected. **Current config: all tiers = pi/zai** (fast = glm-4.5-air; main/heavy/leader = glm-5.2).
- **Injection-hardened workers resist fabrication cues.** When asked to reproduce content not in their context, a well-tuned worker refuses rather than invents — this is correct behavior. Don't override it; re-dispatch as a fresh single-pass task instead.
- **A large inline write can get cut off mid-turn.** Verify every file write independently on disk (wc -l, head, tail); do not trust a worker's "done" status alone. Use a quoted shell heredoc for reliable literal writes of large content.

## Appendix A — the §7 HARD validator checklist (from the spec)

- **H1** — Factory slash-commands MUST carry front-matter (`description` non-empty; `allowed-tools` minimal-but-complete; ADW adds outer `command` + `version`).
- **H2** — Runtime prompts (`app/backend/prompts/`) MUST be front-matter-free (loader does raw `.read_text()`).
- **H3** — No undeclared `{{TOKEN}}`; after render: `assert "{{" not in rendered and "}}" not in rendered`.
- **H4** — No token renders blank; empty cases emit a fallback sentence/line.
- **H5** — Stale-snapshot tokens MUST carry a trust disclaimer naming the live source.
- **H6** — `.format()` templates MUST contain exactly their named fields, no stray braces; render smoke-test must not raise.
- **H7** — One templating mechanism per file (`.replace` XOR `.format`).
- **H8 / H9** — (detailed in the spec; file-missing fallback and related checks).
- **H10** — Managed-agent system prompt template exists — **currently FAILS** (file missing; see Q6).

## Appendix B — sample citations

(Full citations in `prompt-standard-spec.md`; listed here for quick reference.)
- `prompt-anatomy.md`: heading taxonomy, L1-L7 ladder, control-flow patterns.
- `orchestrator_agent_system_prompt.md`: `{{SUBAGENT_MAP}}` (~line 55), `{{HARNESS_CATALOG}}` (~line 200).
- `orchestrator_service.py`: `_load_system_prompt` (~lines 161-274).
- `test_orchestrator_prompt_injection.py`: assertions (~lines 62-70, 89-93).
- `2_prompts.sql`: full DDL.
- `single_agent_prompt.py`: `PROMPTS_DIR`/`read_text` (~lines 30-37), `summarize_event` `.format()` calls.
- `subagent_models.py`: `SubagentFrontmatter` schema (~lines 13-46).
